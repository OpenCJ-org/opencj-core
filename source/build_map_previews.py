"""Compile 2D UI materials for bundled map-list preview images.

Run on the authoritative source host before the existing Windows makeMod.py.
Images are copied unchanged from the original map archives; provenance/hashes
are in map_previews.json. That manifest inventories assets, not voting policy.
"""
from pathlib import Path
import hashlib
import json
import struct

ROOT = Path(__file__).resolve().parents[1]
COD4 = ROOT / "cod4"


def build():
    manifest = json.loads((ROOT / "source/map_previews.json").read_text())
    template = (COD4 / "materials/opencj_rank_1").read_bytes()
    old = b"opencj_rank_1"
    # Existing Mod Tools 2D material layout: material name, image name,
    # colorMap semantic and its image reference. Check before patching offsets.
    for offset, expected in [(0, old), (4, old), (64, b"colorMap"), (72, old)]:
        pointer = struct.unpack_from("<I", template, offset)[0]
        assert template[pointer:].split(b"\0", 1)[0] == expected
    assert template[76:79] == b"2d\0"
    materials = []
    for entry in manifest["maps"]:
        name = entry["material"]
        assert entry["image"] == name
        if entry["kind"] == "starting_area_capture":
            from PIL import Image
            source = ROOT / entry["source"]
            assert hashlib.sha256(source.read_bytes()).hexdigest() == entry["sourceSHA256"]
            im = Image.open(source).convert("RGBA").resize((entry["width"], entry["height"]), Image.Resampling.LANCZOS)
            levels = [im]
            while levels[-1].width > 1 or levels[-1].height > 1:
                q = levels[-1]
                levels.append(q.resize((max(1, q.width // 2), max(1, q.height // 2)), Image.Resampling.LANCZOS))
            sizes = [len(q.tobytes()) for q in levels]
            header = b"IWi" + bytes([6, 1, 193]) + struct.pack("<HHH", im.width, im.height, 1)
            header += struct.pack("<4I", *[28 + sum(sizes[min(i, len(sizes)-1):]) for i in range(4)])
            converted = header + b"".join(q.tobytes("raw", "BGRA") for q in reversed(levels))
            if entry.get("encoding") == "DXT1_no_mipmaps":
                # Keep existing loading-zone image metadata valid for an image-only
                # replacement: the original texture is DXT1, clamped, no mipmaps.
                import io
                output = io.BytesIO()
                im.convert("RGB").save(output, format="DDS", pixel_format="DXT1")
                dds = output.getvalue()
                assert dds[84:88] == b"DXT1"
                pixels = dds[128:]
                converted = b"IWi" + bytes([6, 11, 195])
                converted += struct.pack("<HHH", im.width, im.height, 1)
                converted += struct.pack("<4I", *([28 + len(pixels)] * 4)) + pixels
            (COD4 / "images" / (name + ".iwi")).write_bytes(converted)
        image = (COD4 / "images" / (name + ".iwi")).read_bytes()
        assert image[:4] == b"IWi\x06"
        assert hashlib.sha256(image).hexdigest() == entry["imageSHA256"]
        width, height = struct.unpack_from("<HH", image, 6)
        assert (width, height) == (entry["width"], entry["height"])
        data = bytearray(template)
        delta = len(name.encode("ascii")) - len(old)
        for offset in (4, 72):
            struct.pack_into("<I", data, offset, struct.unpack_from("<I", data, offset)[0] + delta)
        struct.pack_into("<I", data, 64, struct.unpack_from("<I", data, 64)[0] + 2 * delta)
        struct.pack_into("<HH", data, 24, width, height)
        data = bytes(data).replace(old, name.encode("ascii"))
        (COD4 / "materials" / name).write_bytes(data)
        (COD4 / "material_properties" / name).write_bytes((COD4 / "material_properties/opencj_rank_1").read_bytes())
        materials.append("material," + name)
    csv = COD4 / "mod.csv"
    text = csv.read_text()
    for material in materials:
        if material not in text.splitlines():
            text += material + "\n"
    csv.write_text(text)
    print("Prepared", len(materials), "map preview materials; original image bytes verified.")


if __name__ == "__main__":
    build()
