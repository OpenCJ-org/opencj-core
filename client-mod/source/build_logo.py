"""Encode the cleaned branding icon using the existing CoD4 DXT5 mip layout."""

from pathlib import Path
import hashlib
import io
import json
import struct
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def build():
    source = ROOT / "assets/branding/opencj-logo-clean.png"
    image = Image.open(source).convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS)
    image.save(ROOT / "source/texture_source/opencj_logo_nobg.tga")
    levels = [image]
    while levels[-1].width > 1 or levels[-1].height > 1:
        q = levels[-1]
        levels.append(
            q.resize((max(1, q.width // 2), max(1, q.height // 2)), Image.Resampling.LANCZOS)
        )
    encoded = []
    for level in levels:
        output = io.BytesIO()
        level.save(output, format="DDS", pixel_format="DXT5")
        dds = output.getvalue()
        assert dds[84:88] == b"DXT5"
        encoded.append(dds[128:])
    header = b"IWi" + bytes([6, 13, 0]) + struct.pack("<HHH", 1024, 1024, 1)
    header += struct.pack("<4I", *[28 + sum(len(x) for x in encoded[i:]) for i in range(4)])
    data = header + b"".join(reversed(encoded))
    (ROOT / "cod4/images/opencj_logo_nobg.iwi").write_bytes(data)
    print("Prepared cleaned OpenCJ logo", hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    build()
