"""Build the replacement Bouncer Training artwork without altering map geometry.
Install requirements-art.txt and supply the original map IWD and output directory.
Replace both custom picture textures; retain DXT1, flags and mip layout.
"""

from pathlib import Path
import argparse
import hashlib
import io
import json
import struct
import zipfile
import subprocess
import sys
import cairosvg
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "client-mod/assets/map-replacements/mp_bouncer_training"
WORK = None
MAP = None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encode_like(image, original):
    assert original[:5] == b"IWi\x06\x0b", "Expected CoD4 DXT1 image"
    size = struct.unpack_from("<HH", original, 6)
    image = image.convert("RGB").resize(size, Image.Resampling.LANCZOS)
    levels = [image]
    if not original[5] & 2:
        while levels[-1].width > 1 or levels[-1].height > 1:
            q = levels[-1]
            levels.append(
                q.resize((max(1, q.width // 2), max(1, q.height // 2)), Image.Resampling.LANCZOS)
            )
    encoded = []
    for level in levels:
        output = io.BytesIO()
        level.save(output, format="DDS", pixel_format="DXT1")
        dds = output.getvalue()
        assert dds[84:88] == b"DXT1"
        encoded.append(dds[128:])
    data = original[:28] + b"".join(reversed(encoded))
    assert len(data) == len(original), (len(data), len(original))
    return data


def replace_iwd(source, destination, replacements):
    with zipfile.ZipFile(source) as before, zipfile.ZipFile(destination, "w") as after:
        after.comment = before.comment
        for entry in before.infolist():
            after.writestr(entry, replacements.get(entry.filename, before.read(entry.filename)))
    with zipfile.ZipFile(source) as before, zipfile.ZipFile(destination) as after:
        assert before.namelist() == after.namelist()
        assert after.testzip() is None
        changed = [n for n in before.namelist() if before.read(n) != after.read(n)]
        assert set(changed) == set(replacements), changed
    return changed


def build():
    global WORK, MAP
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--map-iwd", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    MAP = args.map_iwd.resolve()
    WORK = args.output_dir.resolve()
    if not MAP.is_file():
        parser.error("The original map IWD is missing")
    if MAP == WORK / "mp_bouncer_training.iwd":
        parser.error("Keep the original map IWD separate from the output")
    WORK.mkdir(parents=True, exist_ok=True)
    cairosvg.svg2png(
        url=str(SOURCE / "missing-picture.svg"), write_to=str(SOURCE / "missing-picture.png")
    )
    replacements = {}
    images = []
    with zipfile.ZipFile(MAP) as archive:
        for name in ["christina", "compass_map_mp_bouncer_training"]:
            original = archive.read("images/" + name + ".iwi")
            encoded = encode_like(Image.open(SOURCE / "missing-picture.png"), original)
            (SOURCE / (name + ".iwi")).write_bytes(encoded)
            replacements["images/" + name + ".iwi"] = encoded
            images.append(
                {
                    "image": name,
                    "imageSHA256": sha(encoded),
                    "imageHeaderUnchanged": encoded[:28] == original[:28],
                    "imageLengthUnchanged": len(encoded) == len(original),
                }
            )
    subprocess.run(
        [sys.executable, str(ROOT / "client-mod/source/build_map_previews.py")], check=True
    )
    replacements["images/loadscreen_mp_bouncer_training.iwi"] = (
        ROOT / "client-mod/cod4/images/loadscreen_mp_bouncer_training.iwi"
    ).read_bytes()
    output = WORK / "mp_bouncer_training.iwd"
    changed = replace_iwd(MAP, output, replacements)
    report = {
        "source": str(MAP),
        "baselineSHA256": sha(MAP.read_bytes()),
        "outputSHA256": sha(output.read_bytes()),
        "changedEntries": changed,
        "images": images,
        "sourceSVG_SHA256": sha((SOURCE / "missing-picture.svg").read_bytes()),
    }
    (WORK / "map-validation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    build()
