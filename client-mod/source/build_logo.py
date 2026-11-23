"""Encode the cleaned branding icon using the existing CoD4 DXT5 mip layout."""

from pathlib import Path
import hashlib
import io

from PIL import Image

from iwi_texture import IWI_FORMAT_DXT5, encode_iwi, mipmaps

ROOT = Path(__file__).resolve().parents[1]
TEXTURE_SIZE_PX = 1024
DDS_HEADER_BYTES = 128
DDS_FOURCC_OFFSET = 84


def build():
    """Encode every DXT5 mip before replacing the branding texture."""
    source = ROOT / "assets/branding/opencj-logo-clean.png"
    with Image.open(source) as original:
        image = original.convert("RGBA").resize(
            (TEXTURE_SIZE_PX, TEXTURE_SIZE_PX), Image.Resampling.LANCZOS
        )
    encoded_mips = []
    for mip_image in mipmaps(image):
        output = io.BytesIO()
        mip_image.save(output, format="DDS", pixel_format="DXT5")
        dds = output.getvalue()
        # IWI stores only the compressed pixels; its own header replaces the DDS header.
        if dds[DDS_FOURCC_OFFSET : DDS_FOURCC_OFFSET + 4] != b"DXT5":
            raise ValueError("The image encoder did not produce DXT5")
        encoded_mips.append(dds[DDS_HEADER_BYTES:])
    texture_bytes = encode_iwi(image.width, image.height, encoded_mips, IWI_FORMAT_DXT5)
    image.save(ROOT / "source/texture_source/opencj_logo_nobg.tga")
    (ROOT / "cod4/images/opencj_logo_nobg.iwi").write_bytes(texture_bytes)
    print("Prepared cleaned OpenCJ logo", hashlib.sha256(texture_bytes).hexdigest())


if __name__ == "__main__":
    build()
