"""Build replacement Bouncer Training artwork without altering map geometry.

Install requirements-art.txt and supply the original map IWD and output directory.
Replace both custom picture textures; retain DXT1, flags and mip layout.
"""

import argparse
import hashlib
import io
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zipfile

import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "client-mod/assets/map-replacements/mp_bouncer_training"
sys.path.insert(0, str(ROOT / "client-mod/source"))
from iwi_texture import IWI_FORMAT_DXT1, IWI_HEADER_BYTES, IWI_VERSION_COD4, mipmaps

IWI_FLAGS_OFFSET = 5
IWI_DIMENSIONS_OFFSET = 6
IWI_NO_MIPMAPS_FLAG = 2
DDS_HEADER_BYTES = 128
DDS_FOURCC_OFFSET = 84
PICTURE_NAMES = ("christina", "compass_map_mp_bouncer_training")


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def encode_like(image, original):
    """Keep the map's existing IWI header and encode replacement pixels in the same layout."""
    signature = b"IWi" + bytes((IWI_VERSION_COD4, IWI_FORMAT_DXT1))
    if len(original) < IWI_HEADER_BYTES or original[:5] != signature:
        raise ValueError("Expected a complete CoD4 DXT1 image")
    dimensions = struct.unpack_from("<HH", original, IWI_DIMENSIONS_OFFSET)
    if 0 in dimensions:
        raise ValueError("Original image dimensions must be positive")
    image = image.convert("RGB").resize(dimensions, Image.Resampling.LANCZOS)
    levels = [image]
    if not original[IWI_FLAGS_OFFSET] & IWI_NO_MIPMAPS_FLAG:
        levels = mipmaps(image)
    encoded_levels = []
    for level in levels:
        output = io.BytesIO()
        level.save(output, format="DDS", pixel_format="DXT1")
        dds = output.getvalue()
        if dds[DDS_FOURCC_OFFSET:DDS_FOURCC_OFFSET + 4] != b"DXT1":
            raise ValueError("The image encoder did not produce DXT1")
        encoded_levels.append(dds[DDS_HEADER_BYTES:])
    encoded_image = original[:IWI_HEADER_BYTES] + b"".join(reversed(encoded_levels))
    if len(encoded_image) != len(original):
        raise ValueError("Replacement texture length differs from its original")
    return encoded_image


def verify_archive(source, candidate, replacements):
    """Verify membership, checksums and the exact set of changed archive entries."""
    with zipfile.ZipFile(source) as before, zipfile.ZipFile(candidate) as after:
        if before.namelist() != after.namelist() or after.testzip() is not None:
            raise ValueError("Replacement archive membership or checksum changed unexpectedly")
        changed = []
        for source_entry, output_entry in zip(before.infolist(), after.infolist()):
            if before.read(source_entry) != after.read(output_entry):
                changed.append(source_entry.filename)
        if set(changed) != set(replacements):
            raise ValueError("Unexpected changed archive entries: " + str(changed))
    return changed


def replace_iwd(source, destination, replacements):
    """Validate a temporary archive before replacing an earlier successful build."""
    if source.resolve() == destination.resolve():
        raise ValueError("Keep the original map IWD separate from the output")
    with tempfile.NamedTemporaryFile(
        dir=destination.parent, prefix=".bouncer-", suffix=".iwd", delete=False
    ) as temporary:
        candidate = Path(temporary.name)
    try:
        with zipfile.ZipFile(source) as before, zipfile.ZipFile(candidate, "w") as after:
            after.comment = before.comment
            for entry in before.infolist():
                if entry.filename in replacements:
                    content = replacements[entry.filename]
                else:
                    content = before.read(entry)
                after.writestr(entry, content)
        changed = verify_archive(source, candidate, replacements)
        candidate.replace(destination)
        return changed
    finally:
        candidate.unlink(missing_ok=True)


def prepare_pictures(map_archive):
    """Render the editable placeholder and preserve each original picture's image layout."""
    placeholder_bytes = cairosvg.svg2png(url=str(SOURCE / "missing-picture.svg"))
    generated_images = {SOURCE / "missing-picture.png": placeholder_bytes}
    replacements = {}
    image_report = []
    with Image.open(io.BytesIO(placeholder_bytes)) as image, zipfile.ZipFile(map_archive) as archive:
        for name in PICTURE_NAMES:
            original = archive.read("images/" + name + ".iwi")
            encoded = encode_like(image, original)
            generated_images[SOURCE / (name + ".iwi")] = encoded
            replacements["images/" + name + ".iwi"] = encoded
            image_report.append({
                "image": name,
                "imageSHA256": sha256_bytes(encoded),
                "imageHeaderUnchanged": encoded[:IWI_HEADER_BYTES] == original[:IWI_HEADER_BYTES],
                "imageLengthUnchanged": len(encoded) == len(original),
            })
    # Validate both original image layouts before replacing any generated picture.
    for path, content in generated_images.items():
        path.write_bytes(content)
    return replacements, image_report


def build(map_archive, output_directory):
    replacements, images = prepare_pictures(map_archive)
    # The loading-screen source and checksum are maintained by the preview builder.
    subprocess.run(
        [sys.executable, str(ROOT / "client-mod/source/build_map_previews.py")], check=True
    )
    replacements["images/loadscreen_mp_bouncer_training.iwi"] = (
        ROOT / "client-mod/cod4/images/loadscreen_mp_bouncer_training.iwi"
    ).read_bytes()
    output = output_directory / "mp_bouncer_training.iwd"
    changed = replace_iwd(map_archive, output, replacements)
    report = {
        "source": str(map_archive),
        "baselineSHA256": sha256_bytes(map_archive.read_bytes()),
        "outputSHA256": sha256_bytes(output.read_bytes()),
        "changedEntries": changed,
        "images": images,
        "sourceSVG_SHA256": sha256_bytes((SOURCE / "missing-picture.svg").read_bytes()),
    }
    (output_directory / "map-validation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map-iwd", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    options = parser.parse_args()
    map_archive = options.map_iwd.resolve()
    output_directory = options.output_dir.resolve()
    if not map_archive.is_file():
        parser.error("The original map IWD is missing")
    if map_archive == (output_directory / "mp_bouncer_training.iwd").resolve():
        parser.error("Keep the original map IWD separate from the output")
    output_directory.mkdir(parents=True, exist_ok=True)
    build(map_archive, output_directory)


if __name__ == "__main__":
    main()
