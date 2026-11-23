"""Offline checks for private client-build validation and owned shader resources."""

import importlib.util
from pathlib import Path
import struct
import tempfile
import types
import unittest
from unittest import mock
import zipfile

SOURCE = Path(__file__).resolve().parents[2] / "client-mod/source/build_client_assets_windows.py"
SPEC = importlib.util.spec_from_file_location("windows_asset_builder", SOURCE)
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class ShaderLookupTests(unittest.TestCase):
    def test_registration_preserves_vertex_records_and_is_repeatable(self):
        vertex_record = struct.pack("<II", 0x12345678, 0xFEDC)
        existing_pixel = struct.pack("<II", 0x20, 0x99)
        original = struct.pack("<I", 1) + vertex_record + struct.pack("<I", 1) + existing_pixel

        updated, file_id = builder.register_shader_name(original, "a")

        # A one-byte name hashes to its ASCII code; the file ID reverses and complements it.
        self.assertEqual(file_id, 0x9EFFFFFF)
        expected = (
            struct.pack("<I", 1)
            + vertex_record
            + struct.pack("<I", 2)
            + existing_pixel
            + struct.pack("<II", 0x61, 0x9EFFFFFF)
        )
        self.assertEqual(updated, expected)
        self.assertEqual(builder.register_shader_name(updated, "a"), (updated, file_id))

    def test_invalid_lookup_is_rejected(self):
        fixtures = {
            "truncated header": b"\x00",
            "truncated vertex records": struct.pack("<II", 1, 0),
            "truncated pixel records": struct.pack("<II", 0, 1),
            "unsorted pixel hashes": (
                struct.pack("<II", 0, 2) + struct.pack("<IIII", 2, 20, 1, 10)
            ),
            "conflicting file identifier": (
                struct.pack("<II", 0, 1) + struct.pack("<II", 0x61, 0x1234)
            ),
        }
        for description, table in fixtures.items():
            with self.subTest(description=description), self.assertRaises(ValueError):
                builder.register_shader_name(table, "a")


class ShaderOwnershipTests(unittest.TestCase):
    def make_compiler(self, status):
        compiler = builder.ShaderCompiler.__new__(builder.ShaderCompiler)

        def compile_function(*arguments):
            arguments[-2]._obj.value = 101
            arguments[-1]._obj.value = 102
            return status

        compiler.compile_function = compile_function
        return compiler

    def test_failed_compile_releases_both_outputs(self):
        compiler = self.make_compiler(-1)
        released = []
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.object(builder, "read_blob", return_value=b"synthetic compiler error"),
                mock.patch.object(
                    builder, "release_blob", side_effect=lambda blob: released.append(blob.value)
                ),
            ):
                with self.assertRaisesRegex(RuntimeError, "synthetic compiler error"):
                    compiler.compile(b"invalid", "ps_2_0", Path(directory) / "compiler.log")
        self.assertEqual(released, [101, 102])

    def test_log_failure_still_releases_both_outputs(self):
        compiler = self.make_compiler(0)
        released = []
        with tempfile.TemporaryDirectory() as directory:
            with (
                mock.patch.object(builder, "read_blob", return_value=b""),
                mock.patch.object(
                    builder, "release_blob", side_effect=lambda blob: released.append(blob.value)
                ),
            ):
                with self.assertRaises(OSError):
                    compiler.compile(b"source", "ps_2_0", Path(directory))
        self.assertEqual(released, [101, 102])

    def test_second_profile_failure_preserves_lookup_and_bytecode(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = builder.BuildPaths(root / "task", root / "install", root / "game")
            paths.evidence.mkdir(parents=True)
            paths.shader_source.parent.mkdir()
            paths.shader_source.write_bytes(b"synthetic shader")
            shader_folder = paths.raw / "shader_bin"
            shader_folder.mkdir(parents=True)
            lookup = shader_folder / "shader_names"
            lookup.write_bytes(struct.pack("<II", 0, 0))
            _, file_id = builder.shader_identifier(builder.SHADER_NAME)
            bytecode_path = shader_folder / f"ps_2_0_{file_id:08x}"
            bytecode_path.write_bytes(b"previous bytecode")
            before = {path.name: path.read_bytes() for path in shader_folder.iterdir()}
            compiler = mock.Mock()
            compiler.compile.side_effect = [
                struct.pack("<I", 0xFFFF0200),
                RuntimeError("SM3 failed"),
            ]
            with mock.patch.object(builder, "ShaderCompiler", return_value=compiler):
                with self.assertRaisesRegex(RuntimeError, "SM3 failed"):
                    builder.compile_shaders(paths)
            after = {path.name: path.read_bytes() for path in shader_folder.iterdir()}
            self.assertEqual(after, before)


class BuildInputTests(unittest.TestCase):
    def test_missing_inputs_create_no_build_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            installation = Path(directory) / "ModTools"
            paths = builder.BuildPaths(
                installation / "Mods/opencj/cod4/_test", installation, Path(directory) / "game"
            )
            with self.assertRaisesRegex(ValueError, "Missing build inputs"):
                builder.build(paths)
            self.assertFalse(paths.root.exists())

    def test_external_build_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = builder.BuildPaths(
                Path(directory) / "outside", Path(directory), Path(directory)
            )
            with self.assertRaisesRegex(ValueError, "private Mod Tools subfolder"):
                builder.validate_inputs(paths)

    def test_invalid_image_path_is_rejected_before_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = builder.BuildPaths(root / "task", root / "install", root / "game")
            with self.assertRaisesRegex(ValueError, "Invalid stock image"):
                builder.extract_stock_images(
                    paths, ["images/valid.iwi", "images/../../outside.iwi"]
                )
            self.assertFalse(paths.raw.exists())


class NoticePackagingTests(unittest.TestCase):
    def test_conflicting_notice_leaves_archive_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notices = root / "stage/licenses"
            notices.mkdir(parents=True)
            (notices / "new.txt").write_text("new notice")
            (notices / "conflict.txt").write_text("expected notice")
            paths = types.SimpleNamespace(stage=root / "stage", cod4=root / "cod4")
            archive_path = root / "z_opencj.iwd"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("licenses/conflict.txt", "different notice")
            original = archive_path.read_bytes()

            with self.assertRaisesRegex(RuntimeError, "different notice"):
                builder.include_notices(paths)

            self.assertEqual(archive_path.read_bytes(), original)

    def test_missing_notices_are_added_once(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            notices = root / "stage/licenses"
            notices.mkdir(parents=True)
            (notices / "source.txt").write_text("source notice")
            paths = types.SimpleNamespace(stage=root / "stage", cod4=root / "cod4")
            archive_path = root / "z_opencj.iwd"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("images/synthetic.iwi", b"image")

            builder.include_notices(paths)
            builder.include_notices(paths)

            with zipfile.ZipFile(archive_path) as archive:
                self.assertEqual(
                    archive.namelist(), ["images/synthetic.iwi", "licenses/source.txt"]
                )
                self.assertEqual(archive.read("licenses/source.txt"), b"source notice")


if __name__ == "__main__":
    unittest.main()
