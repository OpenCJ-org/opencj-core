"""Check demo menu asset registration, actions and toolbar geometry.

Startup/stop GSC behavior belongs to the demo engine fixture. This source check
does not establish that a compiled menu or a human client's rendering works.
An optional unlinked menu file also checks the actual compiled geometry.
"""

import argparse
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
MENU_SOURCE = ROOT / "client-mod/cod4/ui_mp/scriptmenus/opencj_demo.menu"
QUOTED_OR_COMMENT = re.compile(r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/', re.S)
BRACES_OR_STRING = re.compile(r'"(?:\\.|[^"\\])*"|[{}]')


def strip_comments(source):
    """Leave quoted menu values intact while removing comments from syntax checks."""
    return QUOTED_OR_COMMENT.sub(
        lambda match: match.group(0) if match.group(0).startswith('"') else " ",
        source,
    )


def blocks(source, keyword):
    """Read bounded brace blocks, ignoring braces inside quoted menu values."""
    source = strip_comments(source)
    for opening in re.finditer(r"\b" + re.escape(keyword) + r"\s*\{", source):
        depth = 1
        for token in BRACES_OR_STRING.finditer(source, opening.end()):
            if token.group() == "{":
                depth += 1
            elif token.group() == "}":
                depth -= 1
            if depth == 0:
                yield source[opening.end() : token.start()]
                break
        else:
            raise ValueError("Unclosed " + keyword + " block")


def menu_items(source):
    """Decode each named control's rectangle, including linker origin offsets."""
    controls = {}
    for block in blocks(source, "itemDef"):
        name_match = re.search(r'\bname\s+"?([^\s"]+)', block)
        if not name_match:
            raise ValueError("Menu item has no name")
        name = name_match.group(1)
        if name in controls:
            raise ValueError("Duplicate menu item: " + name)
        rectangle = re.search(r"\brect\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)", block)
        if not rectangle:
            raise ValueError("Menu item has no numeric rectangle: " + name)
        rect = tuple(float(value) for value in rectangle.groups())
        origin = re.search(r"\borigin\s+([-\d.]+)\s+([-\d.]+)", block)
        if origin:
            rect = (rect[0] + float(origin[1]), rect[1] + float(origin[2]), rect[2], rect[3])
        text = re.search(r'\btext\s+"([^"]*)"', block)
        controls[name] = {"rect": rect, "text": text[1] if text else None, "block": block}
    if not controls:
        raise ValueError("No menu items found")
    return controls


def check_asset_registration():
    registration = ROOT / "client-mod/cod4/ui_mp/ingame.txt"
    manifest = ROOT / "client-mod/cod4/mod.csv"
    assert "ui_mp/scriptmenus/opencj_demo.menu" in registration.read_text()
    assert "menufile,ui_mp\\scriptmenus\\opencj_demo.menu" in manifest.read_text().splitlines()
    print("Demo menu source registration checks passed")


def check_menu_actions(source):
    """Check the menu protocol and independent direction/speed controls."""
    menu = strip_comments(source)
    responses = re.findall(r'scriptMenuResponse\s+"([^"]+)"', menu)
    assert responses, "Demo menu must send script responses"
    assert all(
        not any(character.isspace() for character in response) for response in responses
    ), "Menu responses must fit the engine's single-token protocol"
    on_open = list(blocks(menu, "onOpen"))
    on_escape = list(blocks(menu, "onEsc"))
    assert len(on_open) == len(on_escape) == 1
    assert re.search(r'scriptMenuResponse\s+"opened"\s*;', on_open[0])
    stop_and_close = r'scriptMenuResponse\s+"stop"\s*;\s*close\s+self\s*;'
    assert re.search(
        stop_and_close, on_escape[0]
    ), "Escape must stop playback and close the toolbar"
    exit_control = menu_items(menu)["exit"]
    assert re.search(
        stop_and_close, exit_control["block"]
    ), "Exit must stop playback and close the toolbar"

    assert sorted({response for response in responses if response.startswith("speed_")}) == [
        "speed_0.25",
        "speed_0.5",
        "speed_1",
        "speed_2",
        "speed_4",
    ]
    assert responses.count("direction") == 2
    for label in ("Slowest", "Slow", "Normal", "Fast", "Fastest"):
        assert re.search(r'\btext\s+"' + label + '"', menu), label
    assert "Normal: 1x (default)" in menu
    selected_speed = r'visible\s+when\s*\(\s*dvarFloat\s*\(\s*"opencj_demo_speed"\s*\)\s*=='
    assert len(re.findall(selected_speed, menu)) == 5
    assert "<4x" not in menu and "4x>" not in menu
    print("Demo menu response, exit and selected-control checks passed")


def check_nonoverlap(controls, names, paired_states):
    """Only mutually exclusive states may share the same rectangle."""
    for index, first_name in enumerate(names):
        first_x, first_y, first_width, first_height = controls[first_name]["rect"]
        for second_name in names[index + 1 :]:
            second_x, second_y, second_width, second_height = controls[second_name]["rect"]
            overlaps_x = max(first_x, second_x) < min(
                first_x + first_width, second_x + second_width
            )
            overlaps_y = max(first_y, second_y) < min(
                first_y + first_height, second_y + second_height
            )
            if overlaps_x and overlaps_y:
                assert frozenset([first_name, second_name]) in paired_states, (
                    first_name,
                    second_name,
                )
                assert controls[first_name]["rect"] == controls[second_name]["rect"], (
                    first_name,
                    second_name,
                )


def check_layout(source):
    controls = menu_items(source)
    assert controls["toolbar"]["rect"] == (0, 443, 640, 37), "Restore the original bar height"
    names = [
        "previous",
        "pause",
        "resume",
        "next",
        "direction_forward",
        "direction_reverse",
        "exit",
    ]
    speeds = [name for name in controls if name.startswith("speed_")]
    assert len(speeds) == 10, "Five speed choices, each with selected/unselected states"
    names += speeds + ["technique"]
    # The stock linker parses origin offsets as integers (449.5 -> 449).
    row_y = controls["pause"]["rect"][1]
    assert row_y in (449, 449.5)
    for name in names:
        control = controls[name]
        x, y, w, h = control["rect"]
        assert y + h / 2 == 461.5 and 8 <= x and x + w <= 632, (name, control["rect"])
        if name not in ("previous", "pause", "resume", "next", "technique"):
            assert control["text"], name + " must own its visible label"
        assert re.search(r"\btype\s+(?:ITEM_TYPE_BUTTON|1)\b", control["block"]), name
    pairs = {frozenset(["pause", "resume"]), frozenset(["direction_forward", "direction_reverse"])}
    pairs.update(
        frozenset([name, name + "_selected"]) for name in speeds if not name.endswith("_selected")
    )
    assert controls["exit"]["text"] == "X" and controls["exit"]["rect"] == (606, 450.5, 26, 22)
    # Visual bounds were calibrated from a supplied 3x in-game screenshot.
    # Raw texture rectangles are deliberately offset: they include padding.
    glyphs = {
        "previous_bar": (15.5, 458.5, 2, 8),
        "previous_arrow": (17.5, 456.5, 12, 12),
        "next_bar": (80.5, 458.5, 2, 8),
        "next_arrow": (68.5, 456.5, 12, 12),
        "pause_bar_left": (45, 458.5, 3, 8),
        "pause_bar_right": (50, 458.5, 3, 8),
        "resume_arrow": (43, 456.5, 12, 12),
    }
    for name, rect in glyphs.items():
        assert controls[name]["rect"] == rect and "decoration" in controls[name]["block"], name
        if name.startswith(("previous_", "next_")):
            assert controls[name + "_disabled"]["rect"] == rect
    for name in speeds + ["direction_forward", "direction_reverse"]:
        block = controls[name]["block"]
        assert re.search(r"textalignx\s+-1(?:\s|$)", block), name
        assert re.search(r"textaligny\s+-1.5(?:\s|$)", block), name
    assert re.search(r"textaligny\s+10", controls["status"]["block"])
    assert controls["checkpoint"]["rect"] == (96, 464.5, 116, 12)
    assert re.search(r"textalignx\s+-0.5", controls["exit"]["block"])
    # Status must retain its own space; invisible counterparts are the only overlap.
    assert controls["status"]["rect"] == (96, 450.5, 116, 12)
    assert controls["technique"]["rect"] == (536, 449.5, 46, 24)
    assert re.search(
        r'setdvar\s+opencj_demo_hint\s+"Switch viewing technique', controls["technique"]["block"]
    )
    assert re.search(r'setdvar\s+opencj_demo_hint\s+""', controls["technique"]["block"])
    names += ["status", "checkpoint"]
    check_nonoverlap(controls, names, pairs)
    assert not any(
        name.startswith(("label_", "multiplier_", "selected_")) for name in controls
    ), "No detached speed labels or overlay cards"
    print(
        "37-unit single-row geometry: transport, time, direction, speeds and Exit fit without overlap; screenshot-calibrated glyph offsets, time baseline and red X preserved"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiled_menu", nargs="?", type=Path)
    options = parser.parse_args()
    menu = MENU_SOURCE.read_text()
    check_asset_registration()
    check_menu_actions(menu)
    check_layout(menu)
    if options.compiled_menu:
        check_layout(options.compiled_menu.read_text())
        print("Compiled menu geometry checked")


if __name__ == "__main__":
    main()
