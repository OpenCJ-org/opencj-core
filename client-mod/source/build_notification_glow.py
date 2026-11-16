"""Build tintable soft side-glow materials on the authoritative source host.

Uses the existing 2D rank-material template and uncompressed RGBA IWI format.
Run with the existing Pillow environment, then the unchanged Windows makeMod.py.
"""

from pathlib import Path
import struct
from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
COD4 = ROOT / "cod4"
WIDTH, HEIGHT = 128, 256


def smoothstep(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def glow():
    image = Image.new("RGBA", (WIDTH, HEIGHT), (255, 255, 255, 0))
    pixels = image.load()
    for y in range(HEIGHT):
        v = y / (HEIGHT - 1)
        corners = smoothstep(min(v, 1.0 - v) / 0.22)
        for x in range(WIDTH):
            u = x / (WIDTH - 1)
            inward = (1.0 - smoothstep(u)) ** 1.5
            pixels[x, y] = (255, 255, 255, round(255 * inward * corners))
    return image


def compile_asset(name, image):
    levels = [image]
    while levels[-1].width > 1 or levels[-1].height > 1:
        q = levels[-1]
        levels.append(
            q.resize((max(1, q.width // 2), max(1, q.height // 2)), Image.Resampling.LANCZOS)
        )
    sizes = [len(q.tobytes()) for q in levels]
    header = b"IWi" + bytes([6, 1, 193]) + struct.pack("<HHH", image.width, image.height, 1)
    header += struct.pack("<4I", *[28 + sum(sizes[min(i, len(sizes) - 1) :]) for i in range(4)])
    (COD4 / "images" / (name + ".iwi")).write_bytes(
        header + b"".join(q.tobytes("raw", "BGRA") for q in reversed(levels))
    )
    old = b"opencj_rank_1"
    data = bytearray((COD4 / "materials/opencj_rank_1").read_bytes())
    for offset, expected in [(0, old), (4, old), (64, b"colorMap"), (72, old)]:
        pointer = struct.unpack_from("<I", data, offset)[0]
        assert data[pointer:].split(b"\0", 1)[0] == expected
    assert data[76:79] == b"2d\0"
    delta = len(name.encode("ascii")) - len(old)
    for offset in (4, 72):
        struct.pack_into("<I", data, offset, struct.unpack_from("<I", data, offset)[0] + delta)
    struct.pack_into("<I", data, 64, struct.unpack_from("<I", data, 64)[0] + 2 * delta)
    struct.pack_into("<HH", data, 24, image.width, image.height)
    (COD4 / "materials" / name).write_bytes(bytes(data).replace(old, name.encode("ascii")))
    (COD4 / "material_properties" / name).write_bytes(
        (COD4 / "material_properties/opencj_rank_1").read_bytes()
    )


def build():
    left = glow()
    for side, image in [("left", left), ("right", ImageOps.mirror(left))]:
        name = "opencj_notify_glow_" + side
        compile_asset(name, image)
        csv = COD4 / "mod.csv"
        text = csv.read_text()
        entry = "material," + name
        if entry not in text.splitlines():
            csv.write_text(text + entry + "\n")
    print("Prepared two mirrored notification glow materials.")


if __name__ == "__main__":
    build()
