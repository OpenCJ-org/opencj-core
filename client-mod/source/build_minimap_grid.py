"""Build the repeating minimap grid while preserving its existing material."""

from pathlib import Path

from PIL import Image

from iwi_texture import IWI_FORMAT_RGBA, encode_iwi, mipmaps

ROOT = Path(__file__).resolve().parents[1]
TEXTURE_SIZE_PX = 256
CELLS_PER_TILE = 3
LINE_HALF_WIDTH_PX = 7
EDGE_FEATHER_PX = 3
MAX_LINE_ALPHA = 88
GRID_COLOR = (166, 181, 175)
# Preserve the original minimap image's sampler flags.
IWI_MINIMAP_FLAGS = 193


def line_alpha(position_px):
    """Sample a periodic, feathered line across tile edges so adjacent tiles have no seam."""
    cell_fraction = ((position_px + 0.5) * CELLS_PER_TILE / float(TEXTURE_SIZE_PX)) % 1
    distance_px = min(cell_fraction, 1 - cell_fraction) * TEXTURE_SIZE_PX / CELLS_PER_TILE
    edge_fraction = max(0.0, min(1.0, (LINE_HALF_WIDTH_PX - distance_px) / EDGE_FEATHER_PX))
    # Smoothstep softens the 14-pixel line to about one pixel at its HUD scale.
    return round(MAX_LINE_ALPHA * edge_fraction * edge_fraction * (3 - 2 * edge_fraction))


def build():
    image = Image.new("RGBA", (TEXTURE_SIZE_PX, TEXTURE_SIZE_PX), (0, 0, 0, 0))
    for y in range(TEXTURE_SIZE_PX):
        for x in range(TEXTURE_SIZE_PX):
            alpha = max(line_alpha(x), line_alpha(y))
            image.putpixel((x, y), (*GRID_COLOR, alpha))
    encoded_mips = [mip.tobytes("raw", "BGRA") for mip in mipmaps(image)]
    texture_bytes = encode_iwi(
        image.width, image.height, encoded_mips, IWI_FORMAT_RGBA, flags=IWI_MINIMAP_FLAGS
    )
    image.save(ROOT / "source/texture_source/opencj_minimapbg.tga")
    (ROOT / "cod4/images/opencj_minimapbg.iwi").write_bytes(texture_bytes)
    print(
        "Quiet grid: 3x3 cells; 14px feathered periodic lines; alpha 88, original material preserved."
    )


if __name__ == "__main__":
    build()
