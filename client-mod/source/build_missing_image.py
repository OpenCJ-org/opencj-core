"""Build the engine missing-material image from the shared question-mark artwork.

Use lossless BGRA pixels for clean UI edges. Keep the original 1024-square
dimensions, flags and mip chain. Intentional branding has its own image.
"""

from pathlib import Path
import hashlib

from PIL import Image

from iwi_texture import IWI_FORMAT_RGBA, encode_iwi, mipmaps

ROOT = Path(__file__).resolve().parents[1]
TEXTURE_SIZE_PX = 1024


def build():
    """Render the fallback artwork and retain the existing lossless texture layout."""
    source = ROOT / "assets/map-replacements/mp_bouncer_training/missing-picture.png"
    with Image.open(source) as original:
        image = original.convert("RGBA").resize(
            (TEXTURE_SIZE_PX, TEXTURE_SIZE_PX), Image.Resampling.LANCZOS
        )
    encoded_mips = [mip.tobytes("raw", "BGRA") for mip in mipmaps(image)]
    texture_bytes = encode_iwi(image.width, image.height, encoded_mips, IWI_FORMAT_RGBA)
    image.save(ROOT / "source/texture_source/default.tga")
    (ROOT / "cod4/images/default.iwi").write_bytes(texture_bytes)
    print("Prepared engine missing-image fallback", hashlib.sha256(texture_bytes).hexdigest())


if __name__ == "__main__":
    build()
