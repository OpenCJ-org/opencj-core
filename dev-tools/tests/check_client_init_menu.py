"""Replay linked startup actions with controlled client cvars.

This checks immediate and deferred commands from actual Unlinker output.
It does not run the game client or establish how its menus render.
"""

import argparse
import json
from pathlib import Path
import re
import shlex

from check_demo_menu import blocks

ACTION_TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|[^\s;]+|;')
STARTUP_REPETITIONS = 3


def read_open_actions(menu_root, menu_name):
    """Decode the single onOpen block without splitting quoted console commands."""
    source = (menu_root / (menu_name + ".menu")).read_text()
    opening_blocks = list(blocks(source, "onOpen"))
    if len(opening_blocks) != 1:
        raise ValueError(f"{menu_name}: expected one onOpen block")

    actions = []
    current_action = []
    for token in ACTION_TOKEN.findall(opening_blocks[0]):
        if token == ";":
            if not current_action:
                raise ValueError(f"{menu_name}: empty action")
            actions.append(current_action)
            current_action = []
        else:
            value = json.loads(token) if token.startswith('"') else token
            current_action.append(value)
    if current_action:
        raise ValueError(f"{menu_name}: unterminated action {current_action}")
    return actions


class Client:
    """Model only the console and menu operations used by startup registration."""

    def __init__(self, menu_root, fps="333", max_packets="100", register=True):
        self.menu_root = menu_root
        self.cvars = dict(
            com_maxfps=fps,
            cl_maxpackets=max_packets,
            temp="user-owned",
            opencj_init_once="1",
            opencj_init_fps=str(int(register)),
            sm_sunEnable="1",
            sm_spotEnable="0",
            r_blur="2",
        )
        self.userinfo = set()
        self.queued = []
        self.responses = []
        self.closed = []
        self.binds = []
        self.archived = set()

    def command(self, text):
        arguments = shlex.split(text)
        operation = arguments[0]
        if operation == "setfromdvar":
            destination, source = arguments[1:]
            self.cvars[destination] = self.cvars[source]
        elif operation in ("set", "setu", "seta"):
            name, value = arguments[1:]
            self.cvars[name] = value
            if operation == "setu":
                self.userinfo.add(name)
            if operation == "seta":
                self.archived.add(name)
        elif operation == "bind":
            self.binds.append(arguments[1:])
        else:
            raise AssertionError(f"Unexpected console command: {arguments}")

    def open(self, menu_name):
        for action in read_open_actions(self.menu_root, menu_name):
            operation = action[0].lower()
            if operation == "execnow":
                self.command(action[1])
            elif operation == "execnowondvarintvalue":
                cvar_name, expected_value, command = action[1:]
                if int(self.cvars.get(cvar_name, "0")) == int(expected_value):
                    self.command(command)
            elif operation == "setdvar":
                name, value = action[1:]
                self.cvars[name] = value
            elif operation == "scriptmenuresponse":
                self.responses.append((menu_name, action[1]))
            elif operation == "close":
                self.closed.append(action[1])
            elif operation == "exec":
                self.queued.append(action[1])
            else:
                raise AssertionError(f"Unexpected menu operation in {menu_name}: {action}")


def check_repeated_registration(menu_root):
    """Registration must expose existing settings without changing their values."""
    for fps in ("43", "76", "125", "250", "333", "0", "500", "999"):
        for max_packets in ("15", "30", "100", "125"):
            client = Client(menu_root, fps=fps, max_packets=max_packets)
            scenario = f"FPS {fps}, max packets {max_packets}"
            for _ in range(STARTUP_REPETITIONS):
                client.open("opencj_client_init")
                assert client.cvars["com_maxfps"] == fps, scenario
                assert client.cvars["cl_maxpackets"] == max_packets, scenario
                assert not client.queued, "Registration must finish before deferred commands"

            assert {"com_maxfps", "cl_maxpackets"} <= client.userinfo, scenario
            assert client.cvars["temp"] == "user-owned", scenario
            assert client.cvars["opencj_sb_ready"] == "3", scenario
            assert len(client.binds) == 1, "A startup retry must not reinstall controls"
            assert (
                client.responses == [("opencj_client_init", "ready")] * STARTUP_REPETITIONS
            ), scenario
            assert client.closed == ["opencj_client_init"] * STARTUP_REPETITIONS, scenario


def check_late_retry(menu_root):
    """A retry must preserve settings and the held scoreboard after initial setup."""
    client = Client(menu_root)
    client.open("opencj_client_init")
    map_defaults = {
        name: value for name, value in client.cvars.items() if name.startswith("opencj_gfx_map_")
    }
    # Model settings application and a player holding Tab after initial success.
    client.cvars.update(
        sm_sunEnable="0",
        sm_spotEnable="1",
        r_blur="0",
        opencj_sb_held="1",
        opencj_sb_active="1",
        com_maxfps="125",
        cl_maxpackets="30",
    )
    client.open("opencj_client_init")
    assert client.cvars["com_maxfps"] == "125", "Late retry changed FPS"
    assert client.cvars["cl_maxpackets"] == "30", "Late retry changed max packets"
    assert all(
        client.cvars[name] == value for name, value in map_defaults.items()
    ), "Late retry recaptured map defaults"
    assert client.cvars["opencj_sb_held"] == client.cvars["opencj_sb_active"] == "1"


def check_registration_disabled(menu_root):
    client = Client(menu_root, register=False)
    client.open("opencj_client_init")
    assert client.cvars["com_maxfps"] == "333"
    assert client.cvars["cl_maxpackets"] == "100"
    assert "opencj_fps_saved" not in client.cvars
    assert "opencj_maxpackets_saved" not in client.cvars
    assert not {"com_maxfps", "cl_maxpackets"}.intersection(client.userinfo)


def check_standalone_registration(menu_root):
    client = Client(menu_root)
    for _ in range(STARTUP_REPETITIONS):
        client.open("opencj_fps_userinfo")
    assert client.cvars["com_maxfps"] == "333"
    assert client.cvars["cl_maxpackets"] == "100"
    assert {"com_maxfps", "cl_maxpackets"} <= client.userinfo
    assert not client.queued
    assert client.closed == ["opencj_fps_userinfo"] * STARTUP_REPETITIONS


def check_shared_scoreboard_bindings(menu_root):
    scoreboard_client = Client(menu_root)
    scoreboard_client.open("opencj_scoreboard_setup")
    startup_client = Client(menu_root)
    startup_client.open("opencj_client_init")
    assert scoreboard_client.cvars["opencj_sb_up"] == startup_client.cvars["opencj_sb_up"]
    assert scoreboard_client.cvars["opencj_sb_down"] == startup_client.cvars["opencj_sb_down"]
    assert 'bind TAB "+scores; vstr opencj_sb_up; set opencj_sb_release"' in (
        scoreboard_client.cvars["opencj_sb_down"]
    ), "Nested binding quotes were lost during linking"


def press_idle_tab(cvars):
    """Expand the idle TAB bind; a missing dvar expands to nothing."""
    executed = []
    pending = ["vstr opencj_sb_tab"]
    while pending:
        arguments = shlex.split(pending.pop(0))
        if arguments == ["vstr", "opencj_sb_down"]:
            executed.append("vstr opencj_sb_down")
        elif arguments[0] == "vstr":
            value = cvars.get(arguments[1], "")
            pending[:0] = value.split("; ") if value else []
        elif arguments[0] == "setfromdvar":
            cvars[arguments[1]] = cvars[arguments[2]]
        elif arguments[0] == "set":
            cvars[arguments[1]] = arguments[2]
        else:
            executed.append(" ".join(arguments))
    return executed


def check_idle_tab_on_any_server(menu_root):
    client = Client(menu_root)
    client.open("opencj_client_init")
    assert client.binds[-1] == ["TAB", "vstr", "opencj_sb_tab"], client.binds
    assert {"opencj_sb_stock", "opencj_sb_tab"} <= client.archived
    assert "opencj_sb_mod" not in client.archived
    on_opencj = press_idle_tab(dict(client.cvars))
    assert on_opencj == ["vstr opencj_sb_down"], on_opencj
    # A restarted game keeps only archived dvars, so the OpenCJ marker is gone.
    saved = {name: client.cvars[name] for name in client.archived}
    elsewhere = press_idle_tab(saved)
    assert elsewhere == ["bind TAB +scores", "+scores"], elsewhere


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiled", type=Path, help="Current Unlinker output directory")
    options = parser.parse_args()
    menu_root = options.compiled / "ui_mp/scriptmenus"
    scenarios = [
        check_repeated_registration,
        check_late_retry,
        check_registration_disabled,
        check_standalone_registration,
        check_shared_scoreboard_bindings,
        check_idle_tab_on_any_server,
    ]
    for scenario in scenarios:
        scenario(menu_root)
        print("PASS: " + scenario.__name__.removeprefix("check_").replace("_", " "))
    print("PASS: 6 linked startup scenarios; 32 FPS/max-packets combinations")


if __name__ == "__main__":
    main()
