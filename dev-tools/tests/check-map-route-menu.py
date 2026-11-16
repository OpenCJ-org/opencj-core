"""Validate the current compiled route panel geometry and controls."""

from pathlib import Path
import argparse
import json
import re

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("compiled", type=Path)
p.add_argument("--output", type=Path)
args = p.parse_args()
checks = {}


def check(label, value):
    checks[label] = bool(value)


def items(text):
    return re.split(r"\bitemDef\s*\{", text)[1:]


def rect(item):
    m = re.search(r"\brect\s+(-?[\d.]+)\s+(-?[\d.]+)\s+([\d.]+)\s+([\d.]+)", item)
    return tuple(map(float, m.groups()))


path = "ui_mp/scriptmenus/opencj_maplist.menu"
text = (args.compiled / path).read_text()
parts = items(text)


def named(name):
    return next(x for x in parts if re.search(r'\bname\s+"' + re.escape(name) + '"', x))


colors = [
    0xFFFFFF,
    0x0000FF,
    0x00FFFF,
    0x00FF00,
    0xFFFF00,
    0xFF8800,
    0xFF7777,
    0xAA55FF,
    0x00CCFF,
    0xFF0000,
    0xAA0000,
    0xFF80CC,
]
boxes = []
valid = True
palette = True
for i in range(10):
    item = named("route" + str(i) + "_color0")
    box = rect(item)
    boxes.append(box)
    for j, packed in enumerate(colors):
        item = named("route" + str(i) + "_color" + str(j))
        valid &= rect(item) == box and '"opencj_ui_maplist_route' + str(i) + '"' in item
        valid &= (
            'routecount") > ' + str(i) in item
            and 'route' + str(i) + '_color") == ' + str(j) in item
        )
        m = re.search(r"\bforecolor\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", item)
        rgb = tuple(map(float, m.groups())) if m else (1, 1, 1)
        palette &= all(
            abs(a - ((packed >> shift) & 255) / 255) < 0.00001 for a, shift in zip(rgb, (16, 8, 0))
        )
check("ten bounded route rows with conditional palette items", valid)
check("compiled route colors match checkpoint palette", palette)
check(
    "two columns of five",
    len({x for x, y, w, h in boxes}) == 2 and len({y for x, y, w, h in boxes}) == 5,
)
check(
    "rows do not overlap",
    all(
        a[0] + a[2] <= b[0] or b[0] + b[2] <= a[0] or a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1]
        for i, a in enumerate(boxes)
        for b in boxes[i + 1 :]
    ),
)
vx, vy, vw, vh = rect(named("maplist_vote"))
check("route rows have space above vote control", max(y + h for x, y, w, h in boxes) + 6 <= vy)
check(
    "no route page controls", not any(s in text for s in ["routeprev", "routenext", "routepagetxt"])
)
check(
    "preview and metadata retained",
    all('opencj_ui_maplist_' + x in text for x in ["loadimage", "selectedname", "date", "author"]),
)
check("empty and unavailable state field", '"opencj_ui_maplist_routemessage"' in text)
check("existing red exit preserved", '"X"' in named("exit") and "close self;" in named("exit"))
report = {"checks": len(checks), "failures": sum(not x for x in checks.values()), "results": checks}
if args.output:
    args.output.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
assert not report["failures"], "Compiled menu validation failed"
