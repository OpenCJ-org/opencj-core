"""Validate source notification glow textures and materials without rendering them."""

from pathlib import Path
import struct

ROOT = Path(__file__).resolve().parents[2]
COD4 = ROOT / "client-mod/cod4"
EXPECTED_SIZE = (128, 256, 1)
IWI_HEADER_BYTES = 28
PIXEL_BYTES = 4
ALPHA_CHANNEL_OFFSET = 3
MIN_ALPHA_LEVELS = 200  # Reject visibly coarse fades while allowing rounding differences.
MAX_ALPHA_BYTE = 255

# Independent expectations for the compiled 2D material layout.
NAME_POINTER_OFFSET = 0
IMAGE_POINTER_OFFSET = 4
DIMENSIONS_OFFSET = 24
SAMPLER_POINTER_OFFSET = 64
TEXTURE_POINTER_OFFSET = 72
TECHNIQUE_NAME_OFFSET = 76
TECHNIQUE_NAME = b"2d\0"


def read_alpha_rows(material_name):
    image_bytes = (COD4 / "images" / (material_name + ".iwi")).read_bytes()
    assert len(image_bytes) >= IWI_HEADER_BYTES, (material_name, "truncated IWI header")
    assert image_bytes[:6] == b"IWi\x06\x01\xc1", (material_name, "unexpected IWI format")
    width, height, depth = struct.unpack_from("<HHH", image_bytes, 6)
    assert (width, height, depth) == EXPECTED_SIZE, (material_name, width, height, depth)

    # The generator stores mip levels smallest first; the full-size image is last.
    pixel_bytes = width * height * PIXEL_BYTES
    assert len(image_bytes) >= IWI_HEADER_BYTES + pixel_bytes, (material_name, "truncated pixels")
    pixels = image_bytes[-pixel_bytes:]
    stride = width * PIXEL_BYTES
    alpha_rows = []
    for y in range(height):
        row_start = y * stride
        alpha_rows.append(
            list(pixels[row_start + ALPHA_CHANNEL_OFFSET : row_start + stride : PIXEL_BYTES])
        )
    return alpha_rows


def verify_fade(side, alpha_rows):
    width, height, _ = EXPECTED_SIZE
    inward_column = width - 1 if side == "left" else 0
    outer_column = 0 if side == "left" else width - 1
    assert all(row[inward_column] == 0 for row in alpha_rows), (side, "hard inner boundary")
    assert max(alpha_rows[0]) == 0 and max(alpha_rows[-1]) == 0, (side, "hard corner boundary")
    assert alpha_rows[height // 2][outer_column] == MAX_ALPHA_BYTE, (side, "missing edge peak")

    alpha_levels = set()
    for row in alpha_rows:
        alpha_levels.update(row)
        inward_values = row if side == "left" else row[::-1]
        assert all(left >= right for left, right in zip(inward_values, inward_values[1:])), (
            side,
            "non-monotonic inward fade",
        )
    assert len(alpha_levels) >= MIN_ALPHA_LEVELS, (side, "gradient banding", len(alpha_levels))
    return len(alpha_levels)


def verify_material(material_name, manifest_entries):
    material = (COD4 / "materials" / material_name).read_bytes()
    technique_end = TECHNIQUE_NAME_OFFSET + len(TECHNIQUE_NAME)
    assert len(material) >= technique_end, (material_name, "truncated material")
    encoded_name = material_name.encode("ascii")
    expected_strings = {
        NAME_POINTER_OFFSET: encoded_name,
        IMAGE_POINTER_OFFSET: encoded_name,
        SAMPLER_POINTER_OFFSET: b"colorMap",
        TEXTURE_POINTER_OFFSET: encoded_name,
    }
    for pointer_offset, expected in expected_strings.items():
        string_offset = struct.unpack_from("<I", material, pointer_offset)[0]
        assert string_offset < len(material), (material_name, "string pointer", pointer_offset)
        actual = material[string_offset:].split(b"\0", 1)[0]
        assert actual == expected, (material_name, pointer_offset, expected, actual)
    assert material[TECHNIQUE_NAME_OFFSET:technique_end] == TECHNIQUE_NAME, material_name
    assert (
        struct.unpack_from("<HH", material, DIMENSIONS_OFFSET) == EXPECTED_SIZE[:2]
    ), material_name
    assert manifest_entries.count("material," + material_name) == 1, (
        material_name,
        "manifest count",
    )


def verify():
    manifest_entries = (COD4 / "mod.csv").read_text().splitlines()
    images = {}
    alpha_level_counts = {}
    for side in ("left", "right"):
        material_name = "opencj_notify_glow_" + side
        images[side] = read_alpha_rows(material_name)
        alpha_level_counts[side] = verify_fade(side, images[side])
        verify_material(material_name, manifest_entries)
    assert all(
        left == right[::-1] for left, right in zip(images["left"], images["right"])
    ), "asymmetric edges"
    return {
        "textures": 2,
        "materialReferences": 2,
        "mirrored": True,
        "inwardAndCornerEdgesTransparent": True,
        "alphaLevels": alpha_level_counts["left"],
    }


if __name__ == "__main__":
    print("NOTIFICATION GLOW ASSETS PASS", verify())
