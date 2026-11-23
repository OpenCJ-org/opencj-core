"""Build the lossless country atlas and matching GSC lookup.

Sources are pinned SVGs under assets/flags. Requires Pillow and CairoSVG.
"""

import argparse
import hashlib
import io
import json
import math
from pathlib import Path
import struct
import textwrap

import cairosvg
from PIL import Image

CLIENT = Path(__file__).resolve().parents[1]
FLAG_WIDTH_PX = 128
FLAG_HEIGHT_PX = 96
GUTTER_PX = 16
CELL_SIDE_PX = FLAG_WIDTH_PX + 2 * GUTTER_PX
ATLAS_SIDE_PX = 1024
ATLAS_COLUMNS = 6
FLAGS_PER_PAGE = ATLAS_COLUMNS * ATLAS_COLUMNS
COUNTRY_COUNT = 256
# The stock loader stages one image in a 6 MiB scratch buffer, including its mip chain.
IMAGE_SCRATCH_LIMIT_BYTES = 6 * 1024 * 1024
SHADER_NAME = "opencj_flag_atlas"
TEMPLATE_MATERIAL_NAME = b"opencj_rank_1"

# Offsets belong to the existing compiled material template, not Python object fields.
NAME_POINTER_OFFSET = 0
IMAGE_POINTER_OFFSET = 4
DIMENSIONS_OFFSET = 24
SAMPLER_POINTER_OFFSET = 64
TEXTURE_POINTER_OFFSET = 72
TECHNIQUE_NAME_OFFSET = 76
TEMPLATE_TECHNIQUE_NAME = b"2d\0"

# CoD4 IWI v6 stores BGRA pixels and four file-size entries for streamed mip groups.
IWI_VERSION = 6
IWI_BGRA_FORMAT = 1
IWI_HEADER_BYTES = 28
IWI_SIZE_ENTRY_COUNT = 4


def read_provenance():
    """Keep the published atlas order fixed; changing it requires a matching GSC build."""
    provenance = json.loads((CLIENT / "assets/flags/provenance.json").read_text())
    codes = provenance["codes"]
    valid_codes = (
        len(codes) == COUNTRY_COUNT
        and len(set(codes)) == COUNTRY_COUNT
        and codes == sorted(codes)
        and "xx" not in codes
    )
    if not valid_codes:
        raise ValueError("Expected the 256 unique, sorted country codes from flag provenance")
    return provenance


def build_material(template, material_name):
    """Rename a compiled material and adjust the pointers shifted by its longer strings."""
    material_bytes = bytearray(template)
    expected_strings = {
        NAME_POINTER_OFFSET: TEMPLATE_MATERIAL_NAME,
        IMAGE_POINTER_OFFSET: TEMPLATE_MATERIAL_NAME,
        SAMPLER_POINTER_OFFSET: b"colorMap",
        TEXTURE_POINTER_OFFSET: TEMPLATE_MATERIAL_NAME,
    }
    technique_end = TECHNIQUE_NAME_OFFSET + len(TEMPLATE_TECHNIQUE_NAME)
    if len(material_bytes) < technique_end:
        raise ValueError("Flag material template is truncated")
    for pointer_offset, expected_name in expected_strings.items():
        string_offset = struct.unpack_from("<I", material_bytes, pointer_offset)[0]
        actual_name = material_bytes[string_offset:].split(b"\0", 1)[0]
        if actual_name != expected_name:
            raise ValueError(f"Unexpected flag material string at pointer {pointer_offset}")
    if material_bytes[TECHNIQUE_NAME_OFFSET:technique_end] != TEMPLATE_TECHNIQUE_NAME:
        raise ValueError("Flag material template must use the 2d technique")

    name_growth = len(material_name.encode("ascii")) - len(TEMPLATE_MATERIAL_NAME)
    # The image and texture strings follow one renamed string; the sampler follows two.
    for pointer_offset, preceding_names in (
        (IMAGE_POINTER_OFFSET, 1),
        (TEXTURE_POINTER_OFFSET, 1),
        (SAMPLER_POINTER_OFFSET, 2),
    ):
        string_offset = struct.unpack_from("<I", material_bytes, pointer_offset)[0]
        struct.pack_into(
            "<I", material_bytes, pointer_offset, string_offset + preceding_names * name_growth
        )
    struct.pack_into("<HH", material_bytes, DIMENSIONS_OFFSET, ATLAS_SIDE_PX, ATLAS_SIDE_PX)
    material_bytes = material_bytes.replace(TEMPLATE_MATERIAL_NAME, material_name.encode("ascii"))
    technique_growth = len(SHADER_NAME) - len(TEMPLATE_TECHNIQUE_NAME.rstrip(b"\0"))
    for pointer_offset in expected_strings:
        string_offset = struct.unpack_from("<I", material_bytes, pointer_offset)[0]
        struct.pack_into("<I", material_bytes, pointer_offset, string_offset + technique_growth)
    return (
        bytes(material_bytes[:TECHNIQUE_NAME_OFFSET])
        + SHADER_NAME.encode("ascii")
        + b"\0"
        + bytes(material_bytes[technique_end:])
    )


def render_flag_tile(svg_bytes):
    """Pad each flag and extend its edge pixels so filtering does not sample a neighbor."""
    raster = cairosvg.svg2png(
        bytestring=svg_bytes, output_width=FLAG_WIDTH_PX, output_height=FLAG_HEIGHT_PX
    )
    flag = Image.open(io.BytesIO(raster)).convert("RGBA")
    square = Image.new("RGBA", (FLAG_WIDTH_PX, FLAG_WIDTH_PX))
    vertical_inset = (FLAG_WIDTH_PX - FLAG_HEIGHT_PX) // 2
    square.paste(flag, (0, vertical_inset))

    tile = Image.new("RGBA", (CELL_SIDE_PX, CELL_SIDE_PX))
    tile.paste(square, (GUTTER_PX, GUTTER_PX))
    tile.paste(
        square.crop((0, 0, 1, FLAG_WIDTH_PX)).resize((GUTTER_PX, FLAG_WIDTH_PX)), (0, GUTTER_PX)
    )
    tile.paste(
        square.crop((FLAG_WIDTH_PX - 1, 0, FLAG_WIDTH_PX, FLAG_WIDTH_PX)).resize(
            (GUTTER_PX, FLAG_WIDTH_PX)
        ),
        (GUTTER_PX + FLAG_WIDTH_PX, GUTTER_PX),
    )
    tile.paste(
        tile.crop((0, GUTTER_PX, CELL_SIDE_PX, GUTTER_PX + 1)).resize((CELL_SIDE_PX, GUTTER_PX)),
        (0, 0),
    )
    bottom_edge = GUTTER_PX + FLAG_WIDTH_PX
    tile.paste(
        tile.crop((0, bottom_edge - 1, CELL_SIDE_PX, bottom_edge)).resize(
            (CELL_SIDE_PX, GUTTER_PX)
        ),
        (0, bottom_edge),
    )
    return tile


def encode_atlas(atlas):
    """Encode a complete mip chain in the loader's smallest-to-largest pixel order."""
    mip_levels = []
    for mip_index in range(ATLAS_SIDE_PX.bit_length()):
        mip_side = max(1, ATLAS_SIDE_PX >> mip_index)
        mip = atlas.resize((mip_side, mip_side), Image.Resampling.LANCZOS)
        mip_levels.append(mip.tobytes("raw", "BGRA"))
    mip_sizes = [len(pixels) for pixels in mip_levels]
    payload_bytes = sum(mip_sizes)
    if payload_bytes > IMAGE_SCRATCH_LIMIT_BYTES:
        raise ValueError("Flag atlas exceeds the stock image loader's scratch buffer")
    file_sizes = [
        IWI_HEADER_BYTES + sum(mip_sizes[index:]) for index in range(IWI_SIZE_ENTRY_COUNT)
    ]
    header = (
        b"IWi"
        + bytes([IWI_VERSION, IWI_BGRA_FORMAT, 0])
        + struct.pack("<HHH", ATLAS_SIDE_PX, ATLAS_SIDE_PX, 1)
        + struct.pack("<4I", *file_sizes)
    )
    return header + b"".join(reversed(mip_levels)), payload_bytes


def write_shader_files(output):
    technique = f"""\
{{
    stateMap "default2d";
    vertexShader 1.1 "vertcol_simple.hlsl"\n    {{\n    }}
    pixelShader 2.0 "{SHADER_NAME}"
    {{
        colorMapSampler = material.colorMap;
    }}
    vertex.position = code.position;
    vertex.color[0] = code.color;
    vertex.texcoord[0] = code.texcoord[0];
}}
"""
    (output / "techniques" / (SHADER_NAME + ".tech")).write_text(technique)
    for folder in ("techsets", "techsets/sm2"):
        (output / folder / (SHADER_NAME + ".techset")).write_text(
            '"unlit":\n ' + SHADER_NAME + ";\n"
        )


def lookup_source(country_codes):
    """Generate the selector calculation from the same ordered input as the image pages."""
    code_lines = textwrap.wrap(" ".join(country_codes), width=84)
    code_literals = []
    for index, line in enumerate(code_lines):
        if index < len(code_lines) - 1:
            line += " "
        code_literals.append('            "' + line + '"')
    code_expression = (" +\n").join(code_literals)
    return """// Generated by client-mod/source/build_flag_atlas.py. Keep in sync with atlas assets.
resolve(country)
{
    if(!isDefined(level.countryAtlasSlots))
    {
        level.countryAtlasSlots = [];
        countryCodes = strTok(
COUNTRY_CODES, " ");
        for(i = 0; i < countryCodes.size; i++)
        {
            level.countryAtlasSlots[countryCodes[i]] = i;
        }
    }
    countryCode = "";
    if(isDefined(country))
    {
        countryCode = toLower(country);
    }
    if(countryCode == "uk")
    {
        countryCode = "gb";
    }
    flag = spawnStruct();
    flag.known = isDefined(level.countryAtlasSlots[countryCode]);
    if(!flag.known)
    {
        flag.material = "default";
        flag.selector = 0;
        return flag;
    }
    flagsPerPage = FLAGS_PER_PAGE;
    countryIndex = level.countryAtlasSlots[countryCode];
    pageIndex = int(countryIndex / flagsPerPage);
    flag.material = "opencj_flag_atlas_" + pageIndex;
    // Selector zero means no tile; the shader numbers atlas cells from one.
    flag.selector = countryIndex - pageIndex * flagsPerPage + 1;
    return flag;
}
""".replace("COUNTRY_CODES", code_expression).replace("FLAGS_PER_PAGE", str(FLAGS_PER_PAGE))


def build(output, gsc_output, manifest_output):
    """Write the atlas pages, matching resolver, and source/hash manifest together."""
    provenance = read_provenance()
    country_codes = provenance["codes"]
    page_count = math.ceil(len(country_codes) / FLAGS_PER_PAGE)
    template = (CLIENT / "cod4/materials/opencj_rank_1").read_bytes()
    properties = (CLIENT / "cod4/material_properties/opencj_rank_1").read_bytes()
    # Validate the binary template before creating output or rendering any images.
    materials = [
        build_material(template, f"{SHADER_NAME}_{page_index}") for page_index in range(page_count)
    ]
    for folder in ("images", "materials", "material_properties", "techniques", "techsets/sm2"):
        (output / folder).mkdir(parents=True, exist_ok=True)

    entries = []
    total_payload_bytes = 0
    for page_index in range(page_count):
        atlas = Image.new("RGBA", (ATLAS_SIDE_PX, ATLAS_SIDE_PX))
        first_country = page_index * FLAGS_PER_PAGE
        page_codes = country_codes[first_country : first_country + FLAGS_PER_PAGE]
        for slot_index, country_code in enumerate(page_codes):
            svg = CLIENT / "assets/flags" / f"flag-icons-v7.5.0/{country_code}.svg"
            svg_bytes = svg.read_bytes()
            tile = render_flag_tile(svg_bytes)
            column = slot_index % ATLAS_COLUMNS
            row = slot_index // ATLAS_COLUMNS
            atlas.paste(tile, (column * CELL_SIDE_PX, row * CELL_SIDE_PX))
            entries.append(
                {
                    "code": country_code,
                    "page": page_index,
                    "selector": slot_index + 1,
                    "sha256": hashlib.sha256(svg_bytes).hexdigest(),
                }
            )
        image_bytes, payload_bytes = encode_atlas(atlas)
        material_name = f"{SHADER_NAME}_{page_index}"
        (output / "images" / (material_name + ".iwi")).write_bytes(image_bytes)
        (output / "materials" / material_name).write_bytes(materials[page_index])
        (output / "material_properties" / material_name).write_bytes(properties)
        total_payload_bytes += payload_bytes

    write_shader_files(output)
    gsc_output.parent.mkdir(parents=True, exist_ok=True)
    gsc_output.write_text(lookup_source(country_codes))
    report = {
        "source": provenance["source"],
        "format": "BGRA8, full mip chain",
        "flag_content": [FLAG_WIDTH_PX, FLAG_HEIGHT_PX],
        "cell": CELL_SIDE_PX,
        "padding": GUTTER_PX,
        "dimensions": [ATLAS_SIDE_PX, ATLAS_SIDE_PX],
        "columns": ATLAS_COLUMNS,
        "capacity": FLAGS_PER_PAGE,
        "image_count": page_count,
        "material_count": page_count,
        "texture_payload_bytes": total_payload_bytes,
        "entries": entries,
    }
    manifest_output.parent.mkdir(parents=True, exist_ok=True)
    manifest_output.write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"{len(country_codes)} flags: {page_count} materials, {page_count} images; "
        f"{total_payload_bytes} texture bytes"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=CLIENT / "cod4")
    parser.add_argument(
        "--gsc-output", type=Path, default=CLIENT.parent / "server-gsc/opencj/flagatlas.gsc"
    )
    parser.add_argument(
        "--manifest-output", type=Path, default=CLIENT / "source/flag_atlas_manifest.json"
    )
    options = parser.parse_args()
    build(options.output, options.gsc_output, options.manifest_output)


if __name__ == "__main__":
    main()
