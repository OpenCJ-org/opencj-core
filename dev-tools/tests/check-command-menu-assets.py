"""#217: check real compiled menus after Unlinker extraction, including key codes."""
from pathlib import Path
import argparse
import json
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("compiled", type=Path, help="Unlinker output directory")
parser.add_argument("--before", type=Path, help="Previous Unlinker output, for unrelated-menu comparison")
parser.add_argument("--output", type=Path, help="Write JSON evidence")
args = parser.parse_args()
checks = {}

def check(label, condition):
    checks[label] = bool(condition)

def menu(name):
    return (args.compiled / "ui_mp/scriptmenus" / ("opencj_" + name + ".menu")).read_text()

commands = menu("commands")
check("CoD4 Backspace key 127 invokes input handler",
      re.search(r'execKeyInt\s+127\s*\{\s*exec "inputkey backspace";', commands))
check("incorrect ASCII Backspace binding absent",
      not re.search(r'execKeyInt\s+8\s*\{', commands))
check("search prompt covers names and aliases only",
      "Type to search command names or aliases..." in commands)
check("open and close notify server", all(
    "scriptMenuResponse " + event + ";" in commands
    for event in ("open_commands", "close_commands")))
check("all twelve selectable command rows", all(
    f"scriptMenuResponse select_{i};" in commands
    and f"opencj_ui_commands_row{i}" in commands for i in range(12)))
check("all eleven detail lines", all(
    f"opencj_ui_commands_line{i}" in commands for i in range(11)))
check("page navigation and clear", all(
    "scriptMenuResponse " + event + ";" in commands
    for event in ("prev", "next", "detail_prev", "detail_next", "clear")))

def items(text):
    return re.split(r"\bitemDef\s*\{", text)[1:]

panels = []
for item in items(commands):
    if re.search(r"\brect\s+(?:32 148 200 226|244 148 364 226)\b", item):
        panels.append(item)
check("list and details have distinct lighter panel backgrounds",
      len(panels) == 2 and all(re.search(r"\bbackcolor\s+0.065\s+0.09\s+0.105\s+1\b", p) for p in panels))

for name in ("commands", "maplist", "leaderboard", "runsboard"):
    text = menu(name)
    exits = [item for item in items(text) if re.search(r'\bname\s+"exit"', item)]
    check(name + ": one compact red X that closes the menu",
          len(exits) == 1
          and re.search(r'\btext\s+"X"', exits[0])
          and re.search(r"\brect\s+\S+\s+\S+\s+26\s+22\b", exits[0])
          and re.search(r"\bbackcolor\s+0.5\s+0.04\s+0.04\s+0.9\b", exits[0])
          and "close self;" in exits[0])
    check(name + ": no misleading Back or Close text",
          not re.search(r'\btext\s+"(?:Back|Close)"', text))
shop = menu("shop_confirm")
check("shop retains genuine Back navigation and its red X",
      re.search(r'\btext\s+"Back"', shop) and "open opencj_shop;" in shop
      and re.search(r'\btext\s+"X"', shop))

changed = None
unchanged = None
if args.before:
    old = {p.relative_to(args.before): p.read_bytes() for p in args.before.rglob("*.menu")}
    new = {p.relative_to(args.compiled): p.read_bytes() for p in args.compiled.rglob("*.menu")}
    changed = sorted(str(k) for k in old.keys() | new.keys() if old.get(k) != new.get(k))
    expected = sorted("ui_mp/scriptmenus/opencj_" + n + ".menu"
                      for n in ("commands", "maplist", "leaderboard", "runsboard"))
    check("only four requested compiled menus changed", changed == expected)
    unchanged = sum(k in new and new[k] == v for k, v in old.items())
report = {"passed": all(checks.values()), "checks": checks,
          "changedMenus": changed, "unchangedMenus": unchanged}
if args.output:
    args.output.write_text(json.dumps(report, indent=2) + "\n")
for label, passed in checks.items():
    print(("PASS: " if passed else "FAIL: ") + label)
assert report["passed"], "Compiled menu validation failed"
print(f"PASS: {len(checks)} compiled-menu checks")
