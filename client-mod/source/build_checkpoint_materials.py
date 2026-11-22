"""Render the editable CoD4 checkpoint waypoint into every existing color texture.

Requires Pillow and CairoSVG. Existing world and objective materials continue to
reference these images; their shader techniques and registrations are preserved.
"""

from pathlib import Path
import hashlib
import io
import json
import re
import struct
import xml.etree.ElementTree as ElementTree

import cairosvg
from PIL import Image

CLIENT_ROOT = Path(__file__).resolve().parents[1]
ART_DIRECTORY = CLIENT_ROOT / "assets/checkpoints"
TEXTURE_SIZE_PX = 512
SUPERSAMPLE_FACTOR = 4
IWI_VERSION_COD4 = 6
IWI_FORMAT_RGBA = 1
# Keep the original textures' clamp flags so sprite edges do not wrap.
IWI_CLAMP_FLAGS = 0xC0
IWI_HEADER_BYTES = 28
IWI_RECORDED_MIP_OFFSETS = 4


def load_palette():
    """Reject missing or unknown variants before replacing any existing texture."""
    palette = json.loads((ART_DIRECTORY / "palette.json").read_text())
    image_directory = CLIENT_ROOT / "cod4/images"
    existing_names = set()
    for image_path in image_directory.glob("opencj_checkpoint_*.iwi"):
        existing_names.add(image_path.stem.removeprefix("opencj_checkpoint_"))
    if set(palette) != existing_names:
        raise ValueError("Checkpoint palette must cover exactly the existing CoD4 textures")
    for name, color in palette.items():
        if not isinstance(color, str) or re.fullmatch(r"#[0-9a-fA-F]{6}", color) is None:
            raise ValueError(f"Invalid checkpoint color for {name}: {color!r}")
        for suffix in ("", "_obj"):
            material = CLIENT_ROOT / "cod4/materials" / f"opencj_checkpoint_{name}{suffix}"
            if not material.is_file():
                raise FileNotFoundError(f"Missing checkpoint material: {material.name}")
    if palette.get("tint", "").lower() != "#ffffff":
        raise ValueError("The tint texture must stay white for arbitrary HUD route colors")
    return palette


def render_waypoint(svg_source, color):
    """Preserve manual SVG geometry and recolor only its route-colored stroke."""
    svg = ElementTree.fromstring(svg_source)
    svg.set("color", color)
    raster_size_px = TEXTURE_SIZE_PX * SUPERSAMPLE_FACTOR
    raster = cairosvg.svg2png(
        bytestring=ElementTree.tostring(svg),
        output_width=raster_size_px,
        output_height=raster_size_px,
    )
    with Image.open(io.BytesIO(raster)) as rendered:
        texture = rendered.convert("RGBA").resize(
            (TEXTURE_SIZE_PX, TEXTURE_SIZE_PX), Image.Resampling.LANCZOS
        )
    return texture


def encode_iwi(texture):
    """Write the CoD4 BGRA mip chain, with offsets from the file's beginning."""
    mip_images = [texture]
    while mip_images[-1].width > 1:
        previous = mip_images[-1]
        next_size_px = previous.width // 2
        mip_images.append(
            previous.resize((next_size_px, next_size_px), Image.Resampling.LANCZOS)
        )
    mip_bytes = []
    for mip_image in mip_images:
        mip_bytes.append(mip_image.tobytes("raw", "BGRA"))
    header = b"IWi" + bytes((IWI_VERSION_COD4, IWI_FORMAT_RGBA, IWI_CLAMP_FLAGS))
    header += struct.pack("<HHH", texture.width, texture.height, 1)
    file_sizes = []
    for first_mip in range(IWI_RECORDED_MIP_OFFSETS):
        payload_bytes = sum(len(mip) for mip in mip_bytes[first_mip:])
        file_sizes.append(IWI_HEADER_BYTES + payload_bytes)
    header += struct.pack("<4I", *file_sizes)
    return header + b"".join(reversed(mip_bytes))


def record_file(manifest, path):
    content = path.read_bytes()
    manifest[str(path.relative_to(CLIENT_ROOT))] = {
        "sha256": hashlib.sha256(content).hexdigest(),
        "bytes": len(content),
    }


def main():
    """Build all variants before writing them, then record their editable inputs."""
    palette = load_palette()
    svg_source = (ART_DIRECTORY / "waypoint.svg").read_bytes()
    textures = {}
    encoded_images = {}
    for name, color in palette.items():
        texture = render_waypoint(svg_source, color)
        textures[name] = texture
        encoded_images[name] = encode_iwi(texture)

    files = {}
    for name, texture in textures.items():
        stem = f"opencj_checkpoint_{name}"
        tga_path = CLIENT_ROOT / "source/texture_source" / (stem + ".tga")
        iwi_path = CLIENT_ROOT / "cod4/images" / (stem + ".iwi")
        texture.save(tga_path)
        iwi_path.write_bytes(encoded_images[name])
        record_file(files, tga_path)
        record_file(files, iwi_path)
    preview_path = ART_DIRECTORY / "waypoint.png"
    textures["tint"].save(preview_path)
    record_file(files, preview_path)
    source_paths = [
        ART_DIRECTORY / "waypoint.svg",
        ART_DIRECTORY / "palette.json",
        ART_DIRECTORY / "source/map-pin.svg",
        ART_DIRECTORY / "source.json",
        ART_DIRECTORY / "LICENSE-lucide.txt",
        Path(__file__).resolve(),
    ]
    for source_path in source_paths:
        record_file(files, source_path)
    manifest = {
        "texture_size_px": TEXTURE_SIZE_PX,
        "supersample_factor": SUPERSAMPLE_FACTOR,
        "format": "CoD4 RGBA, complete mip chain, clamp U/V",
        "files": files,
    }
    (ART_DIRECTORY / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Built {len(textures)} checkpoint waypoint textures; materials are unchanged.")


if __name__ == "__main__":
    main()
