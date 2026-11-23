"""Validate current linked route controls, colors and non-overlapping geometry.

Requires Unlinker output. This does not render the menu or run its server actions.
"""

import argparse
import json
from pathlib import Path
import re

from check_demo_menu import blocks

ROUTE_ROW_COUNT = 10
# Expected checkpoint text colors in their menu palette order, packed as RGB.
ROUTE_COLORS = [
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
# Unlinker prints decimal channels; allow rounding below one byte of color.
COLOR_ROUNDING_TOLERANCE = 0.00001
VOTE_CONTROL_GAP = 6


def rectangle(item):
    match = re.search(r"\brect\s+(-?[\d.]+)\s+(-?[\d.]+)\s+([\d.]+)\s+([\d.]+)", item)
    if not match:
        raise ValueError("Compiled route item has no numeric rectangle")
    return tuple(float(value) for value in match.groups())


def named_items(menu):
    """Index only named controls, rejecting duplicate names needed by this check."""
    items = {}
    for item in blocks(menu, "itemDef"):
        match = re.search(r'\bname\s+"([^"]+)"', item)
        if not match:
            continue
        name = match[1]
        # Other map rows deliberately reuse names for mutually exclusive states.
        if name not in ("maplist_vote", "exit") and not re.fullmatch(r"route\d+_color\d+", name):
            continue
        if name in items:
            raise ValueError("Duplicate compiled route item: " + name)
        items[name] = item
    return items


def foreground_color(item):
    match = re.search(r"\bforecolor\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", item)
    # The compiler omits the property when it uses the engine's default white.
    if not match:
        return (1.0, 1.0, 1.0)
    return tuple(float(value) for value in match.groups())


def check_route_rows(items):
    """Check every palette variant against its row, visibility condition and color."""
    boxes = []
    failures = []
    for row_index in range(ROUTE_ROW_COUNT):
        box = rectangle(items[f"route{row_index}_color0"])
        boxes.append(box)
        for color_index, packed_rgb in enumerate(ROUTE_COLORS):
            name = f"route{row_index}_color{color_index}"
            item = items[name]
            matches_row = rectangle(item) == box and f'"opencj_ui_maplist_route{row_index}"' in item
            count_condition = (
                r'dvarint\s*\(\s*"opencj_ui_maplist_routecount"\s*\)\s*>\s*'
                + str(row_index)
                + r"\b"
            )
            color_condition = (
                r'dvarint\s*\(\s*"opencj_ui_maplist_route'
                + str(row_index)
                + r'_color"\s*\)\s*==\s*'
                + str(color_index)
                + r"\b"
            )
            if not (
                matches_row
                and re.search(count_condition, item)
                and re.search(color_condition, item)
            ):
                failures.append(name + ": wrong row field, rectangle or visibility")
            expected_rgb = tuple(((packed_rgb >> shift) & 255) / 255 for shift in (16, 8, 0))
            actual_rgb = foreground_color(item)
            if any(
                abs(actual - expected) >= COLOR_ROUNDING_TOLERANCE
                for actual, expected in zip(actual_rgb, expected_rgb)
            ):
                failures.append(f"{name}: expected {expected_rgb}, got {actual_rgb}")
    return boxes, failures


def rectangles_overlap(first, second):
    first_x, first_y, first_width, first_height = first
    second_x, second_y, second_width, second_height = second
    overlap_x = max(first_x, second_x) < min(first_x + first_width, second_x + second_width)
    overlap_y = max(first_y, second_y) < min(first_y + first_height, second_y + second_height)
    return overlap_x and overlap_y


def check_menu(menu):
    items = named_items(menu)
    boxes, row_failures = check_route_rows(items)
    vote_x, vote_y, vote_width, vote_height = rectangle(items["maplist_vote"])
    exit_control = items["exit"]
    checks = {
        "ten bounded route rows and twelve palette variants": not row_failures,
        "two columns of five": len({x for x, y, width, height in boxes}) == 2
        and len({y for x, y, width, height in boxes}) == 5,
        "rows do not overlap": all(
            not rectangles_overlap(first, second)
            for index, first in enumerate(boxes)
            for second in boxes[index + 1 :]
        ),
        "route rows have space above vote control": max(y + height for x, y, width, height in boxes)
        + VOTE_CONTROL_GAP
        <= vote_y,
        "no route page controls": not any(
            name in menu for name in ["routeprev", "routenext", "routepagetxt"]
        ),
        "preview and metadata retained": all(
            "opencj_ui_maplist_" + field in menu
            for field in ["loadimage", "selectedname", "date", "author"]
        ),
        "empty and unavailable state field": '"opencj_ui_maplist_routemessage"' in menu,
        "existing red exit preserved": '"X"' in exit_control
        and bool(re.search(r"\bclose\s+self\s*;", exit_control)),
    }
    return checks, row_failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiled", type=Path, help="Current Unlinker output directory")
    parser.add_argument("--output", type=Path, help="Write private JSON evidence")
    options = parser.parse_args()
    menu = options.compiled / "ui_mp/scriptmenus/opencj_maplist.menu"
    checks, details = check_menu(menu.read_text())
    report = {
        "checks": len(checks),
        "failures": sum(not passed for passed in checks.values()),
        "results": checks,
        "details": details,
    }
    if options.output:
        options.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    if report["failures"]:
        raise SystemExit("Compiled route-menu validation failed")


if __name__ == "__main__":
    main()
