"""Render approved stacked mode badges in logical HUD proportions.

Textures remain power-of-two squares; drawing is pre-scaled so rendering at
24x20 (FPS) or 16x20 (modifiers) restores normal-width type and glyphs.
Ele, split-route and bot geometry derives from Lucide 0.468.0 (ISC license);
the Oldschool rabbit and Tutorial graduation cap are Lucide 0.468.0 SVGs.
Tutorial runs show their badge in the FPS slot, since the server picks their FPS.
"""

from pathlib import Path
import hashlib
import io
import json
import math
import struct
import sys
import zipfile
from PIL import Image, ImageDraw, ImageFont

from iwi_texture import IWI_FORMAT_RGBA, encode_iwi, mipmaps

ROOT = Path(__file__).resolve().parents[1]
RASTER_SCALE = 32
FPS_WIDTH = 24
MODIFIER_WIDTH = 16
BADGE_HEIGHT = 20
TEXTURE_SIZE_PX = 512
GLYPH_SIZE = 11.5
LUCIDE_VIEWBOX_SIZE = 24
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
COLORS = {
    "classic": "#80b8ff",
    "standard": "#d9e2e7",
    "expanded": "#efbb65",
    "assisted": "#c7a3ff",
    "tutorial": "#7fd18b",
}
# Badges whose glyph is a stock Lucide SVG, rasterized at source resolution.
SVG_GLYPHS = {"oldschool": "rabbit.svg", "fps_tutorial": "graduation-cap.svg"}
# Compiled 2D icon material that new badge materials are cloned from.
MATERIAL_TEMPLATE = "opencj_icon_fps_any"


def draw_svg_glyph(image, badge_name, color, glyph_size, x, y):
    """Draw a badge's Lucide glyph, glyph_size logical units square, with its top left at x, y.

    Rasterizes the curves at source resolution before game-sized mipmaps are made.
    """
    import cairosvg

    source = (ROOT / "source/mode-icons" / SVG_GLYPHS[badge_name]).read_text()
    source = source.replace("currentColor", color).replace('stroke-width="2"', 'stroke-width="2.2"')
    raster = cairosvg.svg2png(
        bytestring=source.encode(),
        output_width=round(glyph_size * RASTER_SCALE),
        output_height=round(glyph_size * RASTER_SCALE),
    )
    with Image.open(io.BytesIO(raster)) as rendered:
        glyph = rendered.convert("RGBA")
    image.alpha_composite(glyph, (round(x * RASTER_SCALE), round(y * RASTER_SCALE)))


def draw_badge_text(image, logical_width, value, x, y, size, fill):
    """Fit a centered label within the badge using logical HUD coordinates."""
    draw = ImageDraw.Draw(image)
    font = ImageFont.truetype(FONT, round(size * RASTER_SCALE))
    while draw.textlength(value, font=font) > (logical_width - 1.7) * RASTER_SCALE:
        font = ImageFont.truetype(FONT, font.size - 1)
    draw.text((x * RASTER_SCALE, y * RASTER_SCALE), value, font=font, fill=fill, anchor="mm")


def draw_modifier_glyph(image, badge_name, color, logical_width):
    """Draw the approved modifier geometry in the Lucide 24-unit coordinate space."""
    draw = ImageDraw.Draw(image)
    scale = GLYPH_SIZE / LUCIDE_VIEWBOX_SIZE
    origin_x = (logical_width - GLYPH_SIZE) / 2
    origin_y = 1.9

    def glyph_point(x, y):
        return ((origin_x + x * scale) * RASTER_SCALE, (origin_y + y * scale) * RASTER_SCALE)

    stroke_width_px = round(2.2 * scale * RASTER_SCALE)

    def stroke_line(points):
        points_px = [glyph_point(*point) for point in points]
        draw.line(points_px, fill=color, width=stroke_width_px, joint="curve")
        for x, y in points_px:
            draw.ellipse(
                (
                    x - stroke_width_px / 2,
                    y - stroke_width_px / 2,
                    x + stroke_width_px / 2,
                    y + stroke_width_px / 2,
                ),
                fill=color,
            )

    if badge_name == "ele":
        stroke_line([(18, 9), (12, 3), (6, 9)])
        stroke_line([(12, 3), (12, 17)])
        stroke_line([(5, 21), (19, 21)])
    elif badge_name == "anypct":
        stroke_line([(16, 3), (21, 3), (21, 8)])
        stroke_line([(8, 3), (3, 3), (3, 8)])
        arc = [
            (
                8 + 4 * math.cos(-math.pi / 4 * i / 12),
                13.7 + 4 * math.sin(-math.pi / 4 * i / 12),
            )
            for i in range(13)
        ]
        stroke_line([(12, 22), (12, 13.7)] + arc + [(3, 3)])
        stroke_line([(15, 9), (21, 3)])
    elif badge_name == "tas":
        stroke_line([(12, 8), (12, 4), (8, 4)])
        top_left = glyph_point(4, 8)
        bottom_right = glyph_point(20, 20)
        draw.rounded_rectangle(
            (*top_left, *bottom_right),
            radius=2 * scale * RASTER_SCALE,
            outline=color,
            width=stroke_width_px,
        )
        for point in [
            [(2, 14), (4, 14)],
            [(20, 14), (22, 14)],
            [(15, 13), (15, 15)],
            [(9, 13), (9, 15)],
        ]:
            stroke_line(point)
    elif badge_name in SVG_GLYPHS:
        # Keep the approved Lucide silhouette at the modifier glyph size.
        draw_svg_glyph(image, badge_name, color, GLYPH_SIZE, origin_x, origin_y)
    elif badge_name == "halfbeat":
        # Equal-height, side-by-side keys, with a clear gap at small sizes.
        for letter, x in [("A", 1.2), ("D", 8.4)]:
            draw.rounded_rectangle(
                (x * RASTER_SCALE, 4 * RASTER_SCALE, (x + 6.4) * RASTER_SCALE, 11.5 * RASTER_SCALE),
                radius=0.65 * RASTER_SCALE,
                outline=color,
                width=round(0.6 * RASTER_SCALE),
            )
            draw_badge_text(image, logical_width, letter, x + 3.2, 7.8, 4.8, color)


def render_badge(badge_name, label, palette_role):
    """Draw a label and glyph at their intended HUD proportions before square texture scaling."""
    is_fps_badge = badge_name.startswith("fps_")
    logical_width = FPS_WIDTH if is_fps_badge else MODIFIER_WIDTH
    image = Image.new("RGBA", (logical_width * RASTER_SCALE, BADGE_HEIGHT * RASTER_SCALE))
    draw = ImageDraw.Draw(image)
    color = COLORS[palette_role]
    draw.rounded_rectangle(
        (0, 0, logical_width * RASTER_SCALE - 1, BADGE_HEIGHT * RASTER_SCALE - 1),
        radius=int(0.8 * RASTER_SCALE),
        fill="#26313b",
    )
    draw.rectangle(
        (0, 0, logical_width * RASTER_SCALE - 1, int(0.8 * RASTER_SCALE) - 1), fill=color
    )

    if is_fps_badge and badge_name in SVG_GLYPHS:
        # A mode that replaces the FPS category shows its glyph instead of "FPS".
        glyph_size = 10.5
        draw_svg_glyph(image, badge_name, color, glyph_size, (logical_width - glyph_size) / 2, 1.9)
        draw_badge_text(image, logical_width, label, logical_width / 2, 15.6, 4.6, "#edf2f5")
    elif is_fps_badge:
        draw_badge_text(image, logical_width, "FPS", logical_width / 2, 6.3, 5.3, color)
        draw_badge_text(image, logical_width, label, logical_width / 2, 15.6, 4.6, "#edf2f5")
    else:
        draw_badge_text(image, logical_width, label, logical_width / 2, 15.9, 4.5, "#edf2f5")
        draw_modifier_glyph(image, badge_name, color, logical_width)
    return image


def encode_badge_texture(image):
    """Keep the badge's existing lossless BGRA mip chain and sampler flags."""
    encoded_mips = [mip.tobytes("raw", "BGRA") for mip in mipmaps(image)]
    return encode_iwi(image.width, image.height, encoded_mips, IWI_FORMAT_RGBA)


def clone_badge_material(material_name):
    """Rename the validated 2D icon template and shift its stored string pointers."""
    template_name = MATERIAL_TEMPLATE.encode("ascii")
    material = bytearray((ROOT / "cod4/materials" / MATERIAL_TEMPLATE).read_bytes())
    name_pointer_offset = 0
    image_pointer_offset = 4
    sampler_pointer_offset = 64
    texture_pointer_offset = 72
    technique_name_offset = 76
    technique_name = b"2d\0"
    if len(material) < technique_name_offset + len(technique_name):
        raise ValueError("Badge material template is truncated")
    expected_strings = {
        name_pointer_offset: template_name,
        image_pointer_offset: template_name,
        sampler_pointer_offset: b"colorMap",
        texture_pointer_offset: template_name,
    }
    for pointer_offset, expected_name in expected_strings.items():
        string_offset = struct.unpack_from("<I", material, pointer_offset)[0]
        if material[string_offset:].split(b"\0", 1)[0] != expected_name:
            raise ValueError(f"Unexpected badge material string at pointer {pointer_offset}")
    if (
        material[technique_name_offset : technique_name_offset + len(technique_name)]
        != technique_name
    ):
        raise ValueError("Badge template must use the 2d technique")
    encoded_name = material_name.encode("ascii")
    name_growth = len(encoded_name) - len(template_name)
    # Image and texture pointers follow one renamed name; the sampler follows two.
    for pointer_offset, preceding_names in (
        (image_pointer_offset, 1),
        (texture_pointer_offset, 1),
        (sampler_pointer_offset, 2),
    ):
        string_offset = struct.unpack_from("<I", material, pointer_offset)[0]
        struct.pack_into(
            "<I", material, pointer_offset, string_offset + preceding_names * name_growth
        )
    return bytes(material).replace(template_name, encoded_name)


def register_material(badge_name):
    """Prepare material, package and GDT entries before writing any registration change."""
    material_name = "opencj_icon_" + badge_name
    material_path = ROOT / "cod4/materials" / material_name
    material_bytes = None
    if not material_path.exists():
        material_bytes = clone_badge_material(material_name)

    csv_path = ROOT / "cod4/mod.csv"
    manifest_entry = "material," + material_name
    manifest_entries = csv_path.read_text().splitlines()
    add_manifest_entry = manifest_entry not in manifest_entries
    if add_manifest_entry:
        template_index = manifest_entries.index("material," + MATERIAL_TEMPLATE)
        manifest_entries.insert(template_index + 1, manifest_entry)

    gdt_path = ROOT / "source/cod4/source_data/opencj_icons.gdt"
    gdt_text = gdt_path.read_text()
    header = '\t"' + material_name + '" ( "material.gdf" )\n'
    add_gdt_entry = header not in gdt_text
    if add_gdt_entry:
        template_header = '\t"' + MATERIAL_TEMPLATE + '" ( "material.gdf" )\n'
        start = gdt_text.index(template_header)
        end = gdt_text.index("\n\t}\n", start) + len("\n\t}\n")
        block = gdt_text[start:end].replace(MATERIAL_TEMPLATE, material_name)
        gdt_text = gdt_text[:end] + block + gdt_text[end:]

    if material_bytes is not None:
        material_path.write_bytes(material_bytes)
    if add_manifest_entry:
        csv_path.write_text("\n".join(manifest_entries) + "\n")
    if add_gdt_entry:
        gdt_path.write_text(gdt_text)


def main():
    output_directory = ROOT / "assets/mode-icons"
    output_directory.mkdir(parents=True, exist_ok=True)
    manifest = {
        "logical_dimensions": {"fps": [24, 20], "modifier": [16, 20]},
        "glyphs": "Lucide 0.468.0 (Tutorial: graduation-cap); Halfbeat original A/D keycaps",
        "icons": {},
    }
    sheet = Image.new("RGBA", (1100, 240), "#171f26")
    preview_draw = ImageDraw.Draw(sheet)
    for i, (badge_name, label, palette_role) in enumerate(
        [
            ("fps_classic", "Classic", "classic"),
            ("fps_standard", "Standard", "standard"),
            ("fps_any", "Hax", "expanded"),
            ("fps_tutorial", "Tutorial", "tutorial"),
            ("ele", "ELE", "expanded"),
            ("anypct", "ANY%", "expanded"),
            ("halfbeat", "HB", "expanded"),
            ("tas", "TAS", "assisted"),
        ]
    ):
        badge_image = render_badge(badge_name, label, palette_role)
        badge_image.save(output_directory / (badge_name + ".png"))
        texture = badge_image.resize((TEXTURE_SIZE_PX, TEXTURE_SIZE_PX), Image.Resampling.LANCZOS)
        texture.save(ROOT / "source/texture_source" / ("opencj_icon_" + badge_name + ".tga"))
        texture_bytes = encode_badge_texture(texture)
        image_path = ROOT / "cod4/images" / ("opencj_icon_" + badge_name + ".iwi")
        image_path.write_bytes(texture_bytes)
        register_material(badge_name)
        manifest["icons"][badge_name] = {
            "label": label,
            "role": palette_role,
            "sha256": hashlib.sha256(texture_bytes).hexdigest(),
            "bytes": len(texture_bytes),
        }
        preview_width = FPS_WIDTH if badge_name.startswith("fps_") else MODIFIER_WIDTH
        large_preview = badge_image.resize((preview_width * 4, 80), Image.Resampling.LANCZOS)
        sheet.alpha_composite(large_preview, (i * 136 + 10, 20))
        small_preview = badge_image.resize((preview_width * 2, 40), Image.Resampling.LANCZOS)
        sheet.alpha_composite(small_preview, (i * 136 + 10, 120))
    sheet.save(output_directory / "contact-sheet.png")
    (output_directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Built eight mode badges; FPS 24x20, modifiers 16x20.")


def export_oldschool():
    """Export the approved optional badge without changing the eight live modes."""
    import cairosvg

    output_directory = ROOT / "assets/mode-icons/oldschool"
    output_directory.mkdir(parents=True, exist_ok=True)
    badge_image = render_badge("oldschool", "OS", "expanded")
    badge_image.save(output_directory / "oldschool-badge.png")
    texture = badge_image.resize((TEXTURE_SIZE_PX, TEXTURE_SIZE_PX), Image.Resampling.LANCZOS)
    texture.save(output_directory / "opencj_icon_oldschool.tga")
    (output_directory / "opencj_icon_oldschool.iwi").write_bytes(encode_badge_texture(texture))
    source = (ROOT / "source/mode-icons/rabbit.svg").read_text()
    source = source.replace("currentColor", COLORS["expanded"]).replace(
        'stroke-width="2"', 'stroke-width="2.2"'
    )
    (output_directory / "oldschool-symbol.svg").write_text(source)
    cairosvg.svg2png(
        bytestring=source.encode(),
        output_width=512,
        output_height=512,
        write_to=str(output_directory / "oldschool-symbol.png"),
    )
    (output_directory / "LICENSE-lucide.txt").write_bytes(
        (ROOT / "cod4/licenses/lucide.txt").read_bytes()
    )
    (output_directory / "README.txt").write_text("""OpenCJ Oldschool bunny badge
Approved concept: 16 November 2026. Amber rabbit with the OS label.

oldschool-badge.png: 512 x 640 RGBA artwork, correct 16:20 display ratio.
oldschool-symbol.svg / .png: standalone amber rabbit, transparent background.
opencj_icon_oldschool.tga / .iwi: 512 x 512 pre-scaled game texture.
Draw the game texture at 16 x 20 HUD units (or another 4:5 rectangle).
Do not draw the square texture at a square display size.
The IWI includes all ten mip levels. Lucide 0.468.0, ISC; see LICENSE-lucide.txt.

Prepared for later integration; not registered in mod.csv or any live mode.
Integration will need the matching material and appropriate UI/HUD slot.
Regenerate on the source host with the existing image-venv Python:
  source/build_mode_icons.py --oldschool-only
Dependencies: Pillow, CairoSVG, DejaVuSans-Bold.ttf.
""")
    paths = sorted(
        path
        for path in output_directory.iterdir()
        if path.is_file() and path.name != "manifest.json"
    )
    manifest = {
        "mode": "oldschool",
        "label": "OS",
        "logical_dimensions": [16, 20],
        "glyph_source": "https://github.com/lucide-icons/lucide/blob/0.468.0/icons/rabbit.svg",
        "files": {
            path.name: {
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "bytes": path.stat().st_size,
            }
            for path in paths
        },
    }
    (output_directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    bundle = ROOT / "assets/mode-icons/oldschool-bunny.zip"
    with zipfile.ZipFile(bundle, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(output_directory.iterdir()):
            if path.is_file():
                archive.write(path, path.name)
    print("Exported Oldschool bunny badge and reusable symbol: " + str(bundle))


if __name__ == "__main__":
    if sys.argv[1:] == ["--oldschool-only"]:
        export_oldschool()
    elif not sys.argv[1:]:
        main()
    else:
        raise SystemExit("Usage: build_mode_icons.py [--oldschool-only]")
