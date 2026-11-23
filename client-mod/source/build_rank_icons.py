"""Build the approved continuous-ring ranks from editable SVG and palette sources.

Run with the project's image-venv Python. --render-only preserves manual SVG edits.
Only the ten rank images are replaced; materials, menu sizes and game logic stay intact.
"""

from pathlib import Path
import argparse
import hashlib
import io
import json
import math
import cairosvg
from PIL import Image, ImageDraw, ImageFont

from iwi_texture import IWI_FORMAT_RGBA, encode_iwi, mipmaps

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "assets/ranks/rings"
MAX_RANK = 10
SPECTRUM_SEGMENTS = 720
SECTOR_OVERLAP_RADIANS = 0.0005
FONT_MEASURE_SCALE = 10


def spectrum(stops, spectrum_position):
    """Interpolate the two color stops surrounding this point around the ring."""
    for (start_position, start_color), (end_position, end_color) in zip(stops, stops[1:]):
        if spectrum_position <= end_position:
            interpolation_factor = (spectrum_position - start_position) / (
                end_position - start_position
            )
            channels = []
            for offset in (1, 3, 5):
                start_channel = int(start_color[offset : offset + 2], 16)
                end_channel = int(end_color[offset : offset + 2], 16)
                channels.append(
                    round(
                        start_channel * (1 - interpolation_factor)
                        + end_channel * interpolation_factor
                    )
                )
            return "#" + "".join(f"{channel:02x}" for channel in channels)
    return stops[-1][1]


def svg_source(rank, palette):
    """Draw the rank's progress ring and center its number by the actual glyph bounds."""
    radius = palette["radius"]
    stroke_width = palette["stroke_width"]
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 100 100">',
        f'<title>OpenCJ rank {rank}: {palette["names"][rank-1]}</title>',
        f'<circle id="backing" cx="50" cy="50" r="{radius}" fill="{palette["backing_color"]}"/>',
        f'<circle id="center" cx="50" cy="50" r="{palette["center_radius"]}" fill="{palette["center_color"]}"/>',
        f'<circle id="track" cx="50" cy="50" r="{radius}"'
        ' fill="none"'
        f' stroke="{palette["track_color"]}"'
        f' stroke-width="{stroke_width}"/>',
    ]
    if rank == MAX_RANK:
        parts += spectrum_ring(palette, radius, stroke_width)
    else:
        cap_angle = stroke_width / (2 * radius)
        start_angle, end_angle = (
            -math.pi / 2 + cap_angle,
            -math.pi / 2 + rank / MAX_RANK * 2 * math.pi - cap_angle,
        )
        x1, y1 = 50 + radius * math.cos(start_angle), 50 + radius * math.sin(start_angle)
        x2, y2 = 50 + radius * math.cos(end_angle), 50 + radius * math.sin(end_angle)
        is_large_arc = int(end_angle - start_angle > math.pi)
        parts.append(
            f'<path id="progress" d="M{x1:.5f} {y1:.5f} A{radius} {radius} 0 {is_large_arc} 1 {x2:.5f} {y2:.5f}"'
            ' fill="none"'
            f' stroke="{palette["colors"][rank-1]}"'
            f' stroke-width="{stroke_width}" stroke-linecap="round"/>'
        )
    # Center by visible glyph bounds. Same font size and baseline rule for 1-10.
    font = ImageFont.truetype(palette["font_file"], palette["number_size"] * FONT_MEASURE_SCALE)
    bounds = font.getbbox(str(rank), anchor="ls")
    baseline = 50 - (bounds[1] + bounds[3]) / (2 * FONT_MEASURE_SCALE)
    parts.append(
        f'<text id="number" x="50" y="{baseline:.3f}"'
        ' text-anchor="middle"'
        f' font-family="{palette["font_family"]}"'
        ' font-weight="700"'
        f' font-size="{palette["number_size"]}"'
        f' fill="{palette["number_color"]}">{rank}</text>'
    )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def spectrum_ring(palette, radius, stroke_width):
    """Overlap the colored sectors inside a circular mask to avoid seams."""
    # One smooth circular alpha mask owns both boundaries. Color sectors
    # overlap inside the mask, preventing seams and polygonal outer edges.
    parts = [
        '<defs><mask id="ring-mask" maskUnits="userSpaceOnUse" x="0" y="0"'
        ' width="100" height="100">'
        f'<circle cx="50" cy="50" r="{radius}"'
        ' fill="none"'
        ' stroke="white"'
        f' stroke-width="{stroke_width}"/></mask></defs>',
        '<g id="spectrum" mask="url(#ring-mask)">',
    ]
    segment_count = SPECTRUM_SEGMENTS
    for i in range(segment_count):
        spectrum_position = (i + 0.5) / segment_count
        start_angle = (i / segment_count) * 2 * math.pi - math.pi / 2
        end_angle = ((i + 1) / segment_count) * 2 * math.pi - math.pi / 2 + SECTOR_OVERLAP_RADIANS
        x1, y1 = 50 + 60 * math.cos(start_angle), 50 + 60 * math.sin(start_angle)
        x2, y2 = 50 + 60 * math.cos(end_angle), 50 + 60 * math.sin(end_angle)
        parts.append(
            f'<path d="M50 50 L{x1:.5f} {y1:.5f} A60 60 0 0 1 {x2:.5f} {y2:.5f} Z"'
            f' fill="{spectrum(palette["spectrum_stops"],spectrum_position)}"/>'
        )
    parts.append("</g>")
    return parts


def build_size_preview(images, palette):
    """Compare the generated ranks at actual HUD sizes and one enlarged size."""
    # Actual pixel samples plus enlarged samples, without game capture.
    sheet = Image.new("RGBA", (800, 340), "#171f26")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype(palette["font_file"], 14)
    for size, y in [(64, 28), (28, 124), (26, 206), (15, 272)]:
        for i, image in enumerate(images):
            sheet.alpha_composite(
                image.resize((size, size), Image.Resampling.LANCZOS), (i * 78 + (78 - size) // 2, y)
            )
        draw.text((12, y + size + 8), f"{size} px", font=font, fill="#a5b7c2")
    sheet.save(ART / "size-preview.png")


def render_rank(rank, palette, render_only):
    """Render an existing editable SVG, or deliberately regenerate it from the palette."""
    svg_path = ART / f"rank-{rank}.svg"
    if not render_only:
        svg_path.write_text(svg_source(rank, palette))
    texture_size_px = palette["texture_size"]
    raster_size_px = texture_size_px * palette["supersample"]
    raster = cairosvg.svg2png(
        url=str(svg_path), output_width=raster_size_px, output_height=raster_size_px
    )
    with Image.open(io.BytesIO(raster)) as rendered:
        image = rendered.convert("RGBA").resize(
            (texture_size_px, texture_size_px), Image.Resampling.LANCZOS
        )
    return svg_path, image


def main():
    """Build the ten approved textures and their size-preview/source manifest."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--render-only",
        action="store_true",
        help="Render manually edited SVGs without regenerating them from palette.json",
    )
    options = parser.parse_args()
    palette = json.loads((ART / "palette.json").read_text())
    images = []
    manifest = {
        "config": "palette.json",
        "sources": {},
        "outputs": {},
        "consumers": {
            "challenge_tabs": 28,
            "challenge_own_rank": 26,
            "escape_menu": 15,
            "scoreboard": "75% of row height, centered in its slot",
        },
    }
    for rank in range(1, MAX_RANK + 1):
        svg_path, image = render_rank(rank, palette, options.render_only)
        image.save(ART / f"rank-{rank}.png")
        images.append(image)
        tga_path = ROOT / "source/texture_source" / f"opencj_rank_{rank}.tga"
        image.save(tga_path)
        iwi_path = ROOT / "cod4/images" / f"opencj_rank_{rank}.iwi"
        encoded_mips = [mip.tobytes("raw", "BGRA") for mip in mipmaps(image)]
        iwi_path.write_bytes(encode_iwi(image.width, image.height, encoded_mips, IWI_FORMAT_RGBA))
        for path, group in [
            (svg_path, "sources"),
            (ART / f"rank-{rank}.png", "outputs"),
            (tga_path, "outputs"),
            (iwi_path, "outputs"),
        ]:
            manifest[group][str(path.relative_to(ROOT))] = {
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "bytes": path.stat().st_size,
            }
    for source_path in (Path(__file__), Path(__file__).with_name("iwi_texture.py")):
        content = source_path.read_bytes()
        manifest["sources"][str(source_path.relative_to(ROOT))] = {
            "sha256": hashlib.sha256(content).hexdigest(),
            "bytes": len(content),
        }
    build_size_preview(images, palette)
    (ART / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Built ten rank rings: editable SVG, PNG, TGA, RGBA IWI with full mipmaps.")


if __name__ == "__main__":
    main()
