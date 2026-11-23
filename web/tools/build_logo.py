#!/usr/bin/env python3
"""Build the OpenCJ logo files: SVGs with all text converted to outlines, plus PNG exports.

The logo shows the letters C and J with a player jumping from the C onto the J.
The word OPEN follows the jump's arc, fading through the FPS colors (cyan 125,
white 250, periwinkle 333). Requires fontTools and CairoSVG, and the Chakra
Petch Bold font file (SIL Open Font License), which is not stored in Git.
"""

import argparse
import math
from pathlib import Path

import cairosvg
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

# All geometry uses a 128 x 128 canvas, the size the logo was designed at.
CANVAS_SIZE = 128
PANEL_COLOR = "#141920"
CYAN = "#5fd4e6"
WHITE = "#e8ecf2"
PERIWINKLE = "#93a2ec"

C_CENTER_X = 47
J_CENTER_X = 82
LETTER_BASELINE_Y = 108
LETTER_SIZE = 52

# Quadratic arc that OPEN follows: start, control and end points.
ARC_START = (29.0, 56.0)
ARC_CONTROL = (64.0, 12.0)
ARC_END = (100.0, 56.0)
ARC_TEXT_SIZE = 17
ARC_LETTER_SPACING = 2.5
ARC_SAMPLE_COUNT = 2000

# Player figures: feet position, nominal height and pose.
PLAYER_SIZE_FACTOR = 1.35
PLAYER_STROKE_WIDTH = 3.3
PLAYER_HEAD_RADIUS = 3.4
PLAYER_POSES = {
    "takeoff": "M10.5 9.5 L5 6 M10.5 9.5 L16 7 M9.5 15 L5 19.5 L6 24 M9.5 15 L14 19 L13 24",
    "land": "M10.5 9.5 L4.5 9 M10.5 9.5 L16.5 8 M9.5 15 L6 20 L8 24 M9.5 15 L13.5 20 L12.5 24",
}
PLAYERS = (
    {"feet_x": C_CENTER_X, "feet_y": 71, "height": 15, "color": CYAN, "pose": "takeoff"},
    {"feet_x": J_CENTER_X, "feet_y": 71, "height": 15, "color": PERIWINKLE, "pose": "land"},
)

TILE_CORNER_RADIUS = 28  # Rounded tile for the browser tab icon only.
DISCORD_PNG_SIZES = (512, 1024)
FAVICON_PNG_SIZE = 32
APPLE_TOUCH_ICON_SIZE = 180


class GlyphOutliner:
    """Turns characters of one font into SVG path data at a given position and size."""

    def __init__(self, font_path):
        self.font = TTFont(str(font_path))
        self.glyph_set = self.font.getGlyphSet()
        self.character_map = self.font.getBestCmap()
        self.units_per_em = self.font["head"].unitsPerEm
        self.horizontal_metrics = self.font["hmtx"]

    def advance_width(self, character, font_size):
        glyph_name = self.character_map[ord(character)]
        advance_units, _ = self.horizontal_metrics[glyph_name]
        return advance_units * font_size / self.units_per_em

    def path_data(self, character, transform):
        """Return SVG path data; transform maps font units to canvas units."""
        glyph_name = self.character_map[ord(character)]
        svg_pen = SVGPathPen(self.glyph_set)
        self.glyph_set[glyph_name].draw(TransformPen(svg_pen, transform))
        return svg_pen.getCommands()


def quadratic_point(start, control, end, position):
    remaining = 1 - position
    x = remaining * remaining * start[0] + 2 * remaining * position * control[0] + position * position * end[0]
    y = remaining * remaining * start[1] + 2 * remaining * position * control[1] + position * position * end[1]
    return x, y


def sample_arc():
    """Return (points, cumulative lengths) along the OPEN arc."""
    points = [quadratic_point(ARC_START, ARC_CONTROL, ARC_END, index / ARC_SAMPLE_COUNT)
              for index in range(ARC_SAMPLE_COUNT + 1)]
    lengths = [0.0]
    for previous, current in zip(points, points[1:]):
        lengths.append(lengths[-1] + math.dist(previous, current))
    return points, lengths


def point_and_angle_at(points, lengths, distance):
    """Position and direction (degrees) at a distance along the sampled arc."""
    for index in range(1, len(lengths)):
        if lengths[index] >= distance:
            previous, current = points[index - 1], points[index]
            angle = math.degrees(math.atan2(current[1] - previous[1], current[0] - previous[0]))
            return current, angle
    return points[-1], 0.0


def letter_paths(outliner):
    """C and J, each centered on its x position like SVG text-anchor="middle"."""
    scale = LETTER_SIZE / outliner.units_per_em
    paths = []
    for character, center_x, color in (("C", C_CENTER_X, CYAN), ("J", J_CENTER_X, PERIWINKLE)):
        left_x = center_x - outliner.advance_width(character, LETTER_SIZE) / 2
        transform = (scale, 0, 0, -scale, left_x, LETTER_BASELINE_Y)
        paths.append(f'<path d="{outliner.path_data(character, transform)}" fill="{color}"/>')
    return paths


def arc_text_paths(outliner, word):
    """Each letter of the word sits on the arc, rotated to follow it, centered as a whole.

    Matches SVG textPath with startOffset 50% and text-anchor middle: browsers add
    the letter spacing after every letter, including the last one.
    """
    scale = ARC_TEXT_SIZE / outliner.units_per_em
    points, lengths = sample_arc()
    advances = [outliner.advance_width(character, ARC_TEXT_SIZE) for character in word]
    total_width = sum(advances) + ARC_LETTER_SPACING * len(word)
    distance = lengths[-1] / 2 - total_width / 2
    paths = []
    for character, advance in zip(word, advances):
        (center_x, center_y), angle = point_and_angle_at(points, lengths, distance + advance / 2)
        cosine = math.cos(math.radians(angle))
        sine = math.sin(math.radians(angle))
        # Font units -> centered on the glyph's advance -> rotated -> placed on the arc.
        offset_x = -advance / 2
        transform = (
            scale * cosine, scale * sine,
            scale * sine, -scale * cosine,
            center_x + offset_x * cosine,
            center_y + offset_x * sine,
        )
        paths.append(f'<path d="{outliner.path_data(character, transform)}"/>')
        distance += advance + ARC_LETTER_SPACING
    return paths


def player_markup(feet_x, feet_y, height, color, pose):
    scale = height * PLAYER_SIZE_FACTOR / 24
    return (
        f'<g transform="translate({feet_x - 10 * scale:.3f} {feet_y - 24 * scale:.3f}) scale({scale:.5f})">'
        f'<circle cx="11" cy="3.6" r="{PLAYER_HEAD_RADIUS}" fill="{color}"/>'
        f'<path d="M10.8 7.4 L9.5 15 {PLAYER_POSES[pose]}" fill="none" stroke="{color}" '
        f'stroke-width="{PLAYER_STROKE_WIDTH}" stroke-linecap="round" stroke-linejoin="round"/></g>'
    )


def logo_svg(outliner, background):
    """background: "none", "square" (Discord avatar) or "rounded" (browser tab icon)."""
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {CANVAS_SIZE} {CANVAS_SIZE}" '
        f'width="{CANVAS_SIZE}" height="{CANVAS_SIZE}" role="img" aria-label="OpenCJ">',
        "<title>OpenCJ</title>",
        # The gradient spans the width of the word so it runs from cyan through white to periwinkle.
        '<defs><linearGradient id="opencj-fps" gradientUnits="userSpaceOnUse" x1="37" y1="0" x2="91" y2="0">'
        f'<stop offset="0" stop-color="{CYAN}"/><stop offset="0.5" stop-color="{WHITE}"/>'
        f'<stop offset="1" stop-color="{PERIWINKLE}"/></linearGradient></defs>',
    ]
    if background == "square":
        parts.append(f'<rect width="{CANVAS_SIZE}" height="{CANVAS_SIZE}" fill="{PANEL_COLOR}"/>')
    elif background == "rounded":
        parts.append(f'<rect width="{CANVAS_SIZE}" height="{CANVAS_SIZE}" rx="{TILE_CORNER_RADIUS}" fill="{PANEL_COLOR}"/>')
    parts.extend(letter_paths(outliner))
    parts.append('<g fill="url(#opencj-fps)">' + "".join(arc_text_paths(outliner, "OPEN")) + "</g>")
    for player in PLAYERS:
        parts.append(player_markup(**player))
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def write_png(svg_text, output_path, size):
    cairosvg.svg2png(bytestring=svg_text.encode(), write_to=str(output_path),
                     output_width=size, output_height=size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--font", type=Path, required=True, help="ChakraPetch-Bold.ttf")
    parser.add_argument("--static-dir", type=Path, required=True, help="Website static folder")
    parser.add_argument("--brand-dir", type=Path, required=True, help="Folder for avatar exports")
    options = parser.parse_args()

    outliner = GlyphOutliner(options.font)
    mark_svg = logo_svg(outliner, "none")
    avatar_svg = logo_svg(outliner, "square")
    tab_icon_svg = logo_svg(outliner, "rounded")

    options.static_dir.mkdir(parents=True, exist_ok=True)
    options.brand_dir.mkdir(parents=True, exist_ok=True)
    (options.static_dir / "logo-mark.svg").write_text(mark_svg)
    (options.static_dir / "favicon.svg").write_text(tab_icon_svg)
    write_png(tab_icon_svg, options.static_dir / "favicon-32.png", FAVICON_PNG_SIZE)
    write_png(avatar_svg, options.static_dir / "apple-touch-icon.png", APPLE_TOUCH_ICON_SIZE)

    (options.brand_dir / "opencj-logo.svg").write_text(avatar_svg)
    (options.brand_dir / "opencj-logo-mark.svg").write_text(mark_svg)
    for size in DISCORD_PNG_SIZES:
        write_png(avatar_svg, options.brand_dir / f"opencj-logo-{size}.png", size)
    print("Logo files written")


if __name__ == "__main__":
    main()
