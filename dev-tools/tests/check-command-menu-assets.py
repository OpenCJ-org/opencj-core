"""Check linked command-menu controls, key codes and shared close buttons.

Requires current Unlinker output. These checks inspect compiled properties;
they do not establish in-game rendering or server-side command behavior.
"""

import argparse
import json
from pathlib import Path
import re

from check_demo_menu import blocks

COMMAND_ROW_COUNT = 12
DETAIL_LINE_COUNT = 11


def menu_text(compiled_root, name):
    path = compiled_root / "ui_mp/scriptmenus" / ("opencj_" + name + ".menu")
    return path.read_text()


def sends_response(menu, response):
    return re.search(r"\bscriptMenuResponse\s+" + re.escape(response) + r"\s*;", menu) is not None


def check_command_controls(commands):
    """Check the input protocol and the fixed number of visible result slots."""
    return {
        "CoD4 Backspace key 127 invokes input handler": bool(
            re.search(r'execKeyInt\s+127\s*\{\s*exec\s+"inputkey backspace"\s*;', commands)
        ),
        "incorrect ASCII Backspace binding absent": not re.search(r"execKeyInt\s+8\s*\{", commands),
        "search prompt covers names and aliases only": "Type to search command names or aliases..."
        in commands,
        "open and close notify server": all(
            sends_response(commands, event) for event in ("open_commands", "close_commands")
        ),
        "all twelve selectable command rows": all(
            sends_response(commands, f"select_{row_index}")
            and f"opencj_ui_commands_row{row_index}" in commands
            for row_index in range(COMMAND_ROW_COUNT)
        ),
        "all eleven detail lines": all(
            f"opencj_ui_commands_line{line_index}" in commands
            for line_index in range(DETAIL_LINE_COUNT)
        ),
        "page navigation and clear": all(
            sends_response(commands, event)
            for event in ("prev", "next", "detail_prev", "detail_next", "clear")
        ),
    }


def check_panel_backgrounds(commands):
    panels = []
    for item in blocks(commands, "itemDef"):
        if re.search(r"\brect\s+(?:32\s+148\s+200\s+226|244\s+148\s+364\s+226)\b", item):
            panels.append(item)
    return len(panels) == 2 and all(
        re.search(r"\bbackcolor\s+0.065\s+0.09\s+0.105\s+1\b", panel) for panel in panels
    )


def check_close_button(menu):
    exits = [item for item in blocks(menu, "itemDef") if re.search(r'\bname\s+"exit"', item)]
    if len(exits) != 1:
        return False
    exit_control = exits[0]
    return bool(
        re.search(r'\btext\s+"X"', exit_control)
        and re.search(r"\brect\s+\S+\s+\S+\s+26\s+22\b", exit_control)
        and re.search(r"\bbackcolor\s+0.5\s+0.04\s+0.04\s+0.9\b", exit_control)
        and re.search(r"\bclose\s+self\s*;", exit_control)
    )


def check_menus(compiled_root):
    commands = menu_text(compiled_root, "commands")
    checks = check_command_controls(commands)
    checks["list and details have distinct lighter panel backgrounds"] = check_panel_backgrounds(
        commands
    )
    for name in ("commands", "maplist", "leaderboard", "runsboard"):
        menu = menu_text(compiled_root, name)
        checks[name + ": one compact red X that closes the menu"] = check_close_button(menu)
        checks[name + ": no misleading Back or Close text"] = not re.search(
            r'\btext\s+"(?:Back|Close)"', menu
        )

    shop = menu_text(compiled_root, "shop_confirm")
    checks["shop retains genuine Back navigation and its red X"] = bool(
        re.search(r'\btext\s+"Back"', shop)
        and re.search(r"\bopen\s+opencj_shop\s*;", shop)
        and re.search(r'\btext\s+"X"', shop)
    )
    return checks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiled", type=Path, help="Current Unlinker output directory")
    parser.add_argument("--output", type=Path, help="Write private JSON evidence")
    options = parser.parse_args()
    checks = check_menus(options.compiled)
    report = {"passed": all(checks.values()), "checks": checks}
    if options.output:
        options.output.write_text(json.dumps(report, indent=2) + "\n")
    for label, passed in checks.items():
        print(("PASS: " if passed else "FAIL: ") + label)
    if not report["passed"]:
        raise SystemExit("Compiled command-menu validation failed")
    print(f"PASS: {len(checks)} compiled-menu checks")


if __name__ == "__main__":
    main()
