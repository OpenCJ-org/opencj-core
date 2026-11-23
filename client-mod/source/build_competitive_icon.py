"""Render the approved editable Competitive trophy podium; never overwrite the SVG."""

from pathlib import Path
import hashlib
import io
import json

import cairosvg
from PIL import Image

from iwi_texture import IWI_FORMAT_RGBA, encode_iwi, mipmaps

ROOT = Path(__file__).resolve().parents[1]
ART = ROOT / "assets/ranks/competitive"
TEXTURE_WIDTH_PX = 512
TEXTURE_HEIGHT_PX = 256
SUPERSAMPLE_FACTOR = 4


def main():
    """Render and validate the podium, then write its textures and input/output hashes."""
    svg_path = ART / "competitive.svg"
    raster = cairosvg.svg2png(
        url=str(svg_path),
        output_width=TEXTURE_WIDTH_PX * SUPERSAMPLE_FACTOR,
        output_height=TEXTURE_HEIGHT_PX * SUPERSAMPLE_FACTOR,
    )
    with Image.open(io.BytesIO(raster)) as rendered:
        image = rendered.convert("RGBA").resize(
            (TEXTURE_WIDTH_PX, TEXTURE_HEIGHT_PX), Image.Resampling.LANCZOS
        )
    if (
        image.getpixel((0, 0))[3] != 0
        or image.getpixel((image.width - 1, image.height - 1))[3] != 0
    ):
        raise ValueError("Competitive artwork must retain its transparent background")

    mip_images = mipmaps(image)
    encoded_mips = [mip.tobytes("raw", "BGRA") for mip in mip_images]
    texture_bytes = encode_iwi(image.width, image.height, encoded_mips, IWI_FORMAT_RGBA)
    png_path = ART / "competitive.png"
    tga_path = ROOT / "source/texture_source/opencj_competitive.tga"
    iwi_path = ROOT / "cod4/images/opencj_competitive.iwi"
    image.save(png_path)
    image.save(tga_path)
    iwi_path.write_bytes(texture_bytes)

    files = {}
    for path in (
        svg_path,
        Path(__file__),
        Path(__file__).with_name("iwi_texture.py"),
        png_path,
        tga_path,
        iwi_path,
    ):
        content = path.read_bytes()
        files[str(path.relative_to(ROOT))] = {
            "sha256": hashlib.sha256(content).hexdigest(),
            "bytes": len(content),
        }
    manifest = {
        "texture_size": list(image.size),
        "mip_levels": len(mip_images),
        "supersample": SUPERSAMPLE_FACTOR,
        "menu_icon_size": [64, 32],
        "transparent_background": True,
        "files": files,
    }
    (ART / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Built final Competitive trophies: SVG master, PNG, TGA and RGBA IWI.")


if __name__ == "__main__":
    main()
