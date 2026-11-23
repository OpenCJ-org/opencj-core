"""Synthetic image/archive checks; requires the artwork build dependencies."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile

from PIL import Image

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/build-bouncer-art.py"
SPEC = importlib.util.spec_from_file_location("bouncer_art", SCRIPT)
art = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(art)


class BouncerArtTests(unittest.TestCase):
    def create_archive(self, path):
        with zipfile.ZipFile(path, "w") as archive:
            archive.comment = b"synthetic map notice"
            archive.writestr("images/picture.iwi", b"old picture")
            archive.writestr("maps/geometry", b"geometry must stay intact")

    def test_encoding_keeps_original_header_and_length(self):
        # One 4x4 DXT1 block is eight bytes, following the 28-byte IWI header.
        header = struct.pack("<3sBBB3H4I", b"IWi", 6, 11, 2, 4, 4, 1, 36, 36, 36, 36)
        original = header + bytes(8)
        with Image.new("RGB", (4, 4), "red") as image:
            encoded = art.encode_like(image, original)
        self.assertEqual(encoded[:28], header)
        self.assertEqual(len(encoded), 36)
        self.assertNotEqual(encoded, original)

    def test_invalid_image_header_is_rejected(self):
        with Image.new("RGB", (4, 4)) as image:
            for original in [b"", b"IWi\\x06\\x0b", bytes(36)]:
                with self.subTest(original=original):
                    with self.assertRaisesRegex(ValueError, "CoD4 DXT1"):
                        art.encode_like(image, original)

    def test_archive_replaces_only_selected_picture(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "original.iwd"
            output = Path(directory) / "result.iwd"
            self.create_archive(source)
            original_bytes = source.read_bytes()
            changed = art.replace_iwd(source, output, {"images/picture.iwi": b"new picture"})
            self.assertEqual(changed, ["images/picture.iwi"])
            self.assertEqual(source.read_bytes(), original_bytes)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read("images/picture.iwi"), b"new picture")
                self.assertEqual(archive.read("maps/geometry"), b"geometry must stay intact")
                self.assertEqual(archive.comment, b"synthetic map notice")

    def test_failed_verification_keeps_previous_output(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "original.iwd"
            output = Path(directory) / "result.iwd"
            self.create_archive(source)
            output.write_bytes(b"previous successful build")
            with self.assertRaisesRegex(ValueError, "Unexpected changed"):
                art.replace_iwd(source, output, {"missing/image.iwi": b"replacement"})
            self.assertEqual(output.read_bytes(), b"previous successful build")
            self.assertEqual(list(Path(directory).glob(".bouncer-*.iwd")), [])

    def test_same_file_and_symlink_output_preserve_original(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "original.iwd"
            alias = Path(directory) / "alias.iwd"
            self.create_archive(source)
            original_bytes = source.read_bytes()
            alias.symlink_to(source)
            for destination in [source, alias]:
                with self.subTest(destination=destination):
                    with self.assertRaisesRegex(ValueError, "original map IWD separate"):
                        art.replace_iwd(source, destination, {"images/picture.iwi": b"new picture"})
                    self.assertEqual(source.read_bytes(), original_bytes)


if __name__ == "__main__":
    unittest.main()
