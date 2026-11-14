"""Build the engine missing-material image from the shared question-mark artwork.

Keep the original default image's CoD4 DXT3 format, 1024-square dimensions,
flags, mip chain and byte layout. Intentional branding has its own image.
"""
from pathlib import Path
import hashlib
import io
import struct
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def build():
    source = ROOT / "assets/map-replacements/mp_bouncer_training/missing-picture.png"
    image = Image.open(source).convert("RGBA").resize((1024, 1024), Image.Resampling.LANCZOS)
    image.save(ROOT / "source/texture_source/default.tga")
    levels = [image]
    while levels[-1].width > 1 or levels[-1].height > 1:
        previous = levels[-1]
        levels.append(previous.resize((max(1, previous.width // 2), max(1, previous.height // 2)), Image.Resampling.LANCZOS))
    encoded = []
    for level in levels:
        output = io.BytesIO()
        level.save(output, format="DDS", pixel_format="DXT3")
        dds = output.getvalue()
        assert dds[84:88] == b"DXT3"
        encoded.append(dds[128:])
    header = b"IWi" + bytes([6, 12, 0]) + struct.pack("<HHH", 1024, 1024, 1)
    header += struct.pack("<4I", *[28 + sum(len(part) for part in encoded[i:]) for i in range(4)])
    data = header + b"".join(reversed(encoded))
    (ROOT / "cod4/images/default.iwi").write_bytes(data)
    print("Prepared engine missing-image fallback", hashlib.sha256(data).hexdigest())


if __name__ == "__main__":
    build()
