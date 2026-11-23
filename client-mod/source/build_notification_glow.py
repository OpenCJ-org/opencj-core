"""Build the two mirrored notification glows with the existing rank material template.

Requires Pillow. Rebuild the client package with makeMod.py after changing assets.
"""

import argparse
from pathlib import Path
import struct

from PIL import Image
from PIL import ImageOps

CLIENT = Path(__file__).resolve().parents[1]
COD4 = CLIENT / "cod4"
GLOW_WIDTH_PX = 128
GLOW_HEIGHT_PX = 256
CORNER_FADE_FRACTION = 0.22
INWARD_FADE_EXPONENT = 1.5
MAX_ALPHA_BYTE = 255

# CoD4 IWI v6 stores BGRA pixels and four streamed mip-group sizes.
IWI_VERSION = 6
IWI_BGRA_FORMAT = 1
IWI_HEADER_BYTES = 28
IWI_SIZE_ENTRY_COUNT = 4
IWI_GLOW_FLAGS = 193  # Preserve the flags in the existing notification textures.

# These offsets describe the compiled rank material used as the 2D template.
TEMPLATE_NAME = b"opencj_rank_1"
NAME_POINTER_OFFSET = 0
IMAGE_POINTER_OFFSET = 4
DIMENSIONS_OFFSET = 24
SAMPLER_POINTER_OFFSET = 64
TEXTURE_POINTER_OFFSET = 72
TECHNIQUE_NAME_OFFSET = 76
TECHNIQUE_NAME = b"2d\0"


def smoothstep(interpolation_factor):
    interpolation_factor = max(0.0, min(1.0, interpolation_factor))
    return interpolation_factor * interpolation_factor * (3.0 - 2.0 * interpolation_factor)


def render_left_glow():
    """Fade inward from the screen edge and soften the top and bottom corners."""
    image = Image.new("RGBA", (GLOW_WIDTH_PX, GLOW_HEIGHT_PX), (255, 255, 255, 0))
    pixels = image.load()
    for y in range(GLOW_HEIGHT_PX):
        vertical_fraction = y / (GLOW_HEIGHT_PX - 1)
        corner_alpha = smoothstep(
            min(vertical_fraction, 1.0 - vertical_fraction) / CORNER_FADE_FRACTION
        )
        for x in range(GLOW_WIDTH_PX):
            horizontal_fraction = x / (GLOW_WIDTH_PX - 1)
            inward_alpha = (1.0 - smoothstep(horizontal_fraction)) ** INWARD_FADE_EXPONENT
            alpha_byte = round(MAX_ALPHA_BYTE * inward_alpha * corner_alpha)
            pixels[x, y] = (255, 255, 255, alpha_byte)
    return image


def encode_iwi(image):
    """Build each mip from its predecessor and store pixels smallest first."""
    mip_levels = [image]
    while mip_levels[-1].width > 1 or mip_levels[-1].height > 1:
        previous_level = mip_levels[-1]
        next_size = (max(1, previous_level.width // 2), max(1, previous_level.height // 2))
        mip_levels.append(previous_level.resize(next_size, Image.Resampling.LANCZOS))

    mip_pixels = [level.tobytes("raw", "BGRA") for level in mip_levels]
    mip_sizes = [len(pixels) for pixels in mip_pixels]
    file_sizes = []
    for entry_index in range(IWI_SIZE_ENTRY_COUNT):
        first_mip = min(entry_index, len(mip_sizes) - 1)
        file_sizes.append(IWI_HEADER_BYTES + sum(mip_sizes[first_mip:]))
    header = (
        b"IWi"
        + bytes([IWI_VERSION, IWI_BGRA_FORMAT, IWI_GLOW_FLAGS])
        + struct.pack("<HHH", image.width, image.height, 1)
        + struct.pack("<4I", *file_sizes)
    )
    return header + b"".join(reversed(mip_pixels))


def build_material(template, material_name, image_size):
    """Rename a validated material and adjust pointers shifted by its longer strings."""
    material = bytearray(template)
    technique_end = TECHNIQUE_NAME_OFFSET + len(TECHNIQUE_NAME)
    if len(material) < technique_end:
        raise ValueError("Notification material template is truncated")
    expected_strings = {
        NAME_POINTER_OFFSET: TEMPLATE_NAME,
        IMAGE_POINTER_OFFSET: TEMPLATE_NAME,
        SAMPLER_POINTER_OFFSET: b"colorMap",
        TEXTURE_POINTER_OFFSET: TEMPLATE_NAME,
    }
    for pointer_offset, expected_name in expected_strings.items():
        string_offset = struct.unpack_from("<I", material, pointer_offset)[0]
        actual_name = material[string_offset:].split(b"\0", 1)[0]
        if actual_name != expected_name:
            raise ValueError(f"Unexpected notification material string at pointer {pointer_offset}")
    if material[TECHNIQUE_NAME_OFFSET:technique_end] != TECHNIQUE_NAME:
        raise ValueError("Notification material template must use the 2d technique")

    encoded_name = material_name.encode("ascii")
    name_growth = len(encoded_name) - len(TEMPLATE_NAME)
    # Image and texture strings follow one renamed name; the sampler follows two.
    for pointer_offset, preceding_names in (
        (IMAGE_POINTER_OFFSET, 1),
        (TEXTURE_POINTER_OFFSET, 1),
        (SAMPLER_POINTER_OFFSET, 2),
    ):
        string_offset = struct.unpack_from("<I", material, pointer_offset)[0]
        struct.pack_into(
            "<I", material, pointer_offset, string_offset + preceding_names * name_growth
        )
    struct.pack_into("<HH", material, DIMENSIONS_OFFSET, *image_size)
    return bytes(material).replace(TEMPLATE_NAME, encoded_name)


def register_materials(manifest, material_names):
    """Preserve existing package entries and add each generated material once."""
    entries = manifest.splitlines()
    for material_name in material_names:
        entry = "material," + material_name
        if entry not in entries:
            manifest += entry + "\n"
            entries.append(entry)
    return manifest


def build(output):
    """Prepare and validate all assets before replacing generated output files."""
    template = (COD4 / "materials/opencj_rank_1").read_bytes()
    properties = (COD4 / "material_properties/opencj_rank_1").read_bytes()
    manifest_path = output / "mod.csv"
    manifest_source = manifest_path if manifest_path.is_file() else COD4 / "mod.csv"
    manifest = manifest_source.read_text()

    left_glow = render_left_glow()
    materials = []
    outputs = {}
    for side, image in (("left", left_glow), ("right", ImageOps.mirror(left_glow))):
        material_name = "opencj_notify_glow_" + side
        materials.append(material_name)
        outputs[Path("images") / (material_name + ".iwi")] = encode_iwi(image)
        outputs[Path("materials") / material_name] = build_material(
            template, material_name, image.size
        )
        outputs[Path("material_properties") / material_name] = properties
    manifest = register_materials(manifest, materials)

    for relative_path, content in outputs.items():
        destination = output / relative_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
    manifest_path.write_text(manifest)
    print("Prepared two mirrored notification glow materials.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=COD4,
        help="Output directory; defaults to the compiled client asset tree",
    )
    options = parser.parse_args()
    build(options.output.resolve())


if __name__ == "__main__":
    main()
