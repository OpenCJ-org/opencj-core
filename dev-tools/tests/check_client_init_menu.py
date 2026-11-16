"""Replay the compiled startup menu's commands with controlled cvars.
Usage: python3 dev-tools/tests/check_client_init_menu.py UNLINKED_MENU_ROOT
This checks the actual linked scripts, not source macro expansion. It models
only their immediate/deferred command behavior; it is not a live-client test.
"""
from pathlib import Path
import json
import re
import shlex
import sys

root = Path(sys.argv[1]) / "ui_mp/scriptmenus"
TOKEN = re.compile(r'"(?:\\.|[^"\\])*"|[^\s;]+|;')

def actions(name):
    text = (root / (name + ".menu")).read_text()
    body = text.split("onOpen", 1)[1].split("{", 1)[1].split("}", 1)[0]
    tokens = TOKEN.findall(body)
    result, action = [], []
    for token in tokens:
        if token == ";":
            result.append(action)
            action = []
        else:
            action.append(json.loads(token) if token.startswith('"') else token)
    assert not action, action
    return result

class Client:
    def __init__(self, fps="333", register=True):
        self.cvars = dict(com_maxfps=fps, temp="user-owned",
                          opencj_init_once="1", opencj_init_fps=str(int(register)),
                          sm_sunEnable="1", sm_spotEnable="0", r_blur="2")
        self.userinfo = set()
        self.queued = []
        self.responses = []
        self.closed = []
        self.binds = []

    def command(self, text):
        cmd = shlex.split(text)
        if cmd[0] == "setfromdvar":
            self.cvars[cmd[1]] = self.cvars[cmd[2]]
        elif cmd[0] in ("set", "setu"):
            self.cvars[cmd[1]] = cmd[2]
            if cmd[0] == "setu":
                self.userinfo.add(cmd[1])
        elif cmd[0] == "bind":
            self.binds.append(cmd[1:])
        else:
            raise AssertionError(("unexpected console command", cmd))

    def open(self, name):
        for a in actions(name):
            op = a[0].lower()
            if op == "execnow":
                self.command(a[1])
            elif op == "execnowondvarintvalue":
                if int(self.cvars.get(a[1], "0")) == int(a[2]):
                    self.command(a[3])
            elif op == "setdvar":
                self.cvars[a[1]] = a[2]
            elif op == "scriptmenuresponse":
                self.responses.append((name, a[1]))
            elif op == "close":
                self.closed.append(a[1])
            elif op == "exec":
                self.queued.append(a[1])
            else:
                raise AssertionError(("unexpected menu operation", a))

for fps in ("43", "76", "125", "250", "333", "0", "500", "999"):
    c = Client(fps)
    for _ in range(3):
        c.open("opencj_client_init")
        assert c.cvars["com_maxfps"] == fps, (fps, c.cvars)
        assert not c.queued, "registration must finish before command-buffer execution"
    assert "com_maxfps" in c.userinfo
    assert c.cvars["temp"] == "user-owned"
    assert c.cvars["opencj_sb_ready"] == "3"
    assert len(c.binds) == 1, "duplicate startup must not reinstall active controls"
    assert len(c.responses) == 3 and all(r[1] == "ready" for r in c.responses)
    assert c.closed == ["opencj_client_init"] * 3

c = Client()
c.open("opencj_client_init")
saved = {k: v for k, v in c.cvars.items() if k.startswith("opencj_gfx_map_")}
# Model settings application and a player holding Tab after initial success.
c.cvars.update(sm_sunEnable="0", sm_spotEnable="1", r_blur="0",
               opencj_sb_held="1", opencj_sb_active="1", com_maxfps="125")
c.open("opencj_client_init")
assert c.cvars["com_maxfps"] == "125", "late retry must preserve the current FPS"
assert all(c.cvars[k] == v for k, v in saved.items()), "late retry recaptured map defaults"
assert c.cvars["opencj_sb_held"] == c.cvars["opencj_sb_active"] == "1"

c = Client("333", register=False)
c.open("opencj_client_init")
assert c.cvars["com_maxfps"] == "333" and "opencj_fps_saved" not in c.cvars

c = Client()
for _ in range(3):
    c.open("opencj_fps_userinfo")
assert c.cvars["com_maxfps"] == "333" and not c.queued
assert c.closed == ["opencj_fps_userinfo"] * 3

# Shared scoreboard scripts must retain the same binding strings after linking.
c = Client()
c.open("opencj_scoreboard_setup")
d = Client()
d.open("opencj_client_init")
assert c.cvars["opencj_sb_up"] == d.cvars["opencj_sb_up"]
assert c.cvars["opencj_sb_down"] == d.cvars["opencj_sb_down"]
assert 'bind TAB "+scores; vstr opencj_sb_up; set opencj_sb_release"' in c.cvars["opencj_sb_down"]
print("PASS: linked menu preserves FPS across batched/late retries; map defaults, held scoreboard, user temp and binding quotes are preserved; acknowledgement follows immediate setup.")
