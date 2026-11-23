"""Compile 2D UI materials for bundled map-list preview images.

Run on the authoritative source host before the existing Windows makeMod.py.
Original archive images are verified unchanged; captures and placeholders are
encoded from their recorded sources. Provenance/hashes are in map_previews.json.
That manifest inventories assets, not voting policy.
"""

from pathlib import Path
import hashlib
import io
import json
import struct

from PIL import Image

from iwi_texture import (
    IWI_FORMAT_DXT1,
    IWI_FORMAT_RGBA,
    IWI_HEADER_BYTES,
    encode_iwi,
    mipmaps,
)

ROOT = Path(__file__).resolve().parents[1]
COD4 = ROOT / "cod4"
TEMPLATE_NAME = b"opencj_rank_1"
NAME_POINTER_OFFSET = 0
IMAGE_POINTER_OFFSET = 4
SAMPLER_POINTER_OFFSET = 64
TEXTURE_POINTER_OFFSET = 72
DIMENSIONS_OFFSET = 24
TECHNIQUE_NAME_OFFSET = 76
TECHNIQUE_NAME = b"2d\0"
DDS_HEADER_BYTES = 128
DDS_FOURCC_OFFSET = 84
# Retain the original preview sampler flags and loading-screen no-mipmap layout.
IWI_PREVIEW_FLAGS = 193
IWI_LOADING_SCREEN_FLAGS = 195


def load_material_template():
    """Validate the known 2D material layout before changing its string pointers."""
    template = (COD4 / "materials/opencj_rank_1").read_bytes()
    technique_end = TECHNIQUE_NAME_OFFSET + len(TECHNIQUE_NAME)
    if len(template) < technique_end:
        raise ValueError("Preview material template is truncated")
    expected_strings = {
        NAME_POINTER_OFFSET: TEMPLATE_NAME,
        IMAGE_POINTER_OFFSET: TEMPLATE_NAME,
        SAMPLER_POINTER_OFFSET: b"colorMap",
        TEXTURE_POINTER_OFFSET: TEMPLATE_NAME,
    }
    for pointer_offset, expected_name in expected_strings.items():
        string_offset = struct.unpack_from("<I", template, pointer_offset)[0]
        if template[string_offset:].split(b"\0", 1)[0] != expected_name:
            raise ValueError(f"Unexpected preview material string at pointer {pointer_offset}")
    if template[TECHNIQUE_NAME_OFFSET:technique_end] != TECHNIQUE_NAME:
        raise ValueError("Preview material template must use the 2d technique")
    return template


def encode_preview(entry):
    """Re-encode a recorded capture or placeholder without changing its texture format."""
    source = ROOT / entry["source"]
    if hashlib.sha256(source.read_bytes()).hexdigest() != entry["sourceSHA256"]:
        raise ValueError("Preview source checksum does not match: " + entry["material"])
    with Image.open(source) as original:
        image = original.convert("RGBA").resize(
            (entry["width"], entry["height"]), Image.Resampling.LANCZOS
        )
    if entry.get("encoding") == "DXT1_no_mipmaps":
        # Loading-zone metadata already expects DXT1 without mipmaps.
        output = io.BytesIO()
        image.convert("RGB").save(output, format="DDS", pixel_format="DXT1")
        dds = output.getvalue()
        if dds[DDS_FOURCC_OFFSET : DDS_FOURCC_OFFSET + 4] != b"DXT1":
            raise ValueError("The image encoder did not produce DXT1")
        return encode_iwi(
            image.width,
            image.height,
            [dds[DDS_HEADER_BYTES:]],
            IWI_FORMAT_DXT1,
            flags=IWI_LOADING_SCREEN_FLAGS,
        )
    encoded_mips = [mip.tobytes("raw", "BGRA") for mip in mipmaps(image)]
    return encode_iwi(
        image.width, image.height, encoded_mips, IWI_FORMAT_RGBA, flags=IWI_PREVIEW_FLAGS
    )


def verify_preview(entry, image_bytes):
    """Check the recorded image checksum and dimensions before preparing its material."""
    if len(image_bytes) < IWI_HEADER_BYTES or image_bytes[:4] != b"IWi\x06":
        raise ValueError("Preview image is not a complete CoD4 IWI: " + entry["material"])
    if hashlib.sha256(image_bytes).hexdigest() != entry["imageSHA256"]:
        raise ValueError("Preview image checksum does not match: " + entry["material"])
    dimensions = struct.unpack_from("<HH", image_bytes, 6)
    if dimensions != (entry["width"], entry["height"]):
        raise ValueError("Preview dimensions do not match: " + entry["material"])
    return dimensions


def build_material(template, material_name, dimensions):
    """Shift pointers past the renamed strings while preserving the 2D material fields."""
    material = bytearray(template)
    encoded_name = material_name.encode("ascii")
    name_growth = len(encoded_name) - len(TEMPLATE_NAME)
    # Image and texture pointers follow one name; the sampler pointer follows two.
    for pointer_offset, preceding_names in (
        (IMAGE_POINTER_OFFSET, 1),
        (TEXTURE_POINTER_OFFSET, 1),
        (SAMPLER_POINTER_OFFSET, 2),
    ):
        string_offset = struct.unpack_from("<I", material, pointer_offset)[0]
        struct.pack_into(
            "<I", material, pointer_offset, string_offset + preceding_names * name_growth
        )
    struct.pack_into("<HH", material, DIMENSIONS_OFFSET, *dimensions)
    return bytes(material).replace(TEMPLATE_NAME, encoded_name)


def prepare_outputs(entries, template):
    """Validate the entire input set before replacing any existing generated asset."""
    properties = (COD4 / "material_properties/opencj_rank_1").read_bytes()
    outputs = {}
    material_entries = []
    for entry in entries:
        material_name = entry["material"]
        if entry["image"] != material_name:
            raise ValueError("Preview material and image names must match")
        image_path = COD4 / "images" / (material_name + ".iwi")
        if entry["kind"] in ("starting_area_capture", "generated_placeholder"):
            image_bytes = encode_preview(entry)
            outputs[image_path] = image_bytes
        else:
            image_bytes = image_path.read_bytes()
        dimensions = verify_preview(entry, image_bytes)
        outputs[COD4 / "materials" / material_name] = build_material(
            template, material_name, dimensions
        )
        outputs[COD4 / "material_properties" / material_name] = properties
        material_entries.append("material," + material_name)

    csv_path = COD4 / "mod.csv"
    manifest_text = csv_path.read_text()
    existing_entries = manifest_text.splitlines()
    for entry in material_entries:
        if entry not in existing_entries:
            manifest_text += entry + "\n"
            existing_entries.append(entry)
    outputs[csv_path] = manifest_text.encode()
    return outputs


def build():
    """Prepare verified preview materials, then write the complete build output."""
    manifest = json.loads((ROOT / "source/map_previews.json").read_text())
    entries = list(manifest["maps"])
    if "fallback" in manifest:
        entries.append(manifest["fallback"])
    outputs = prepare_outputs(entries, load_material_template())
    for path, content in outputs.items():
        path.write_bytes(content)
    print("Prepared", len(entries), "preview/fallback materials; image bytes verified.")


if __name__ == "__main__":
    build()
