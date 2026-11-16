"""Validate source notification glow textures and material references without a game."""

from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
COD4 = ROOT / "client-mod/cod4"


def verify():
    images = {}
    for side in ["left", "right"]:
        name = "opencj_notify_glow_" + side
        data = (COD4 / "images" / (name + ".iwi")).read_bytes()
        assert data[:6] == b"IWi\x06\x01\xc1"
        width, height, depth = struct.unpack_from("<HHH", data, 6)
        assert (width, height, depth) == (128, 256, 1)
        pixels = data[-width * height * 4 :]
        alpha = [list(pixels[(y * width * 4) + 3 : (y + 1) * width * 4 : 4]) for y in range(height)]
        images[side] = alpha
        inward = width - 1 if side == "left" else 0
        outer = 0 if side == "left" else width - 1
        assert all(row[inward] == 0 for row in alpha), "hard inner boundary"
        assert max(alpha[0]) == 0 and max(alpha[-1]) == 0, "hard corner boundary"
        assert alpha[height // 2][outer] == 255, "missing edge peak"
        assert len(set(v for row in alpha for v in row)) >= 200, "gradient banding"
        for row in alpha:
            values = row if side == "left" else row[::-1]
            assert all(a >= b for a, b in zip(values, values[1:])), "non-monotonic fade"
        material = (COD4 / "materials" / name).read_bytes()
        for offset, expected in [
            (0, name.encode()),
            (4, name.encode()),
            (64, b"colorMap"),
            (72, name.encode()),
        ]:
            ptr = struct.unpack_from("<I", material, offset)[0]
            assert material[ptr:].split(b"\0", 1)[0] == expected
        assert material[76:79] == b"2d\0"
        assert struct.unpack_from("<HH", material, 24) == (width, height)
        assert (COD4 / "mod.csv").read_text().splitlines().count("material," + name) == 1
    assert all(a == b[::-1] for a, b in zip(images["left"], images["right"])), "asymmetric edges"
    return {
        "textures": 2,
        "materialReferences": 2,
        "mirrored": True,
        "inwardAndCornerEdgesTransparent": True,
        "alphaLevels": len(set(v for row in images["left"] for v in row)),
    }


if __name__ == "__main__":
    print("NOTIFICATION GLOW ASSETS PASS", verify())
