"""Build client assets privately with the unchanged installed Windows builder."""

import argparse
import contextlib
import ctypes
import hashlib
import io
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import struct
import subprocess
import zipfile

LINKER_TIMEOUT_SECONDS = 45
MAX_LINKER_ATTEMPTS = 5
D3DCOMPILE_OPTIMIZATION_LEVEL3 = 1 << 15
SHADER_NAME = "opencj_flag_atlas"
UINT32_MASK = 0xFFFFFFFF
SHADER_RECORD_BYTES = 8
# ID3DBlob inherits IUnknown, so these slots follow QueryInterface and AddRef.
COM_RELEASE_SLOT = 2
BLOB_POINTER_SLOT = 3
BLOB_SIZE_SLOT = 4


class BuildPaths:
    """Keep the private build tree separate from the selected installation."""

    def __init__(self, build_root, installation, game_directory):
        self.root = build_root.resolve()
        self.installation = installation.resolve()
        self.game_directory = game_directory.resolve()
        self.installed_builder = self.installation / "Mods/opencj/cod4/makeMod.py"
        self.toolroot = self.root / "toolroot"
        self.raw = self.toolroot / "raw"
        self.cod4 = self.toolroot / "Mods/proof/cod4"
        self.stage = self.root / "stage"
        self.evidence = self.root / "evidence"
        self.shader_source = self.root / "source/opencj_flag_atlas.hlsl"


def validate_inputs(paths):
    """Reject the wrong installation or incomplete staging before creating output."""
    if paths.root.parent != paths.installed_builder.parent or not paths.root.name.startswith("_"):
        raise ValueError("Build root must be a private Mod Tools subfolder")
    required_files = [
        paths.installed_builder,
        paths.shader_source,
        paths.stage / "mod.csv",
        paths.installation / "raw/fileSysCheck.cfg",
        paths.installation / "raw/shader_bin/shader_names",
    ]
    required_files.extend(
        paths.installation / "bin" / name
        for name in ["linker_pc.exe", "MSVCP71.DLL", "msvcr71.dll", "mss32.dll"]
    )
    required_directories = [
        paths.stage / "techsets",
        paths.stage / "techniques",
        paths.stage / "licenses",
        paths.game_directory / "main",
    ]
    required_directories.extend(
        paths.installation / "raw" / name
        for name in ["techsets", "techniques", "statemaps", "shader_bin", "ui", "ui_mp", "mp"]
    )
    missing = [str(path) for path in required_files if not path.is_file()]
    missing.extend(str(path) for path in required_directories if not path.is_dir())
    if missing:
        raise ValueError("Missing build inputs:\n" + "\n".join(missing))


def snapshot_shared_files(paths):
    """Include absent outputs so an unexpected newly created shared file is visible."""
    watched = [
        paths.installed_builder,
        paths.installed_builder.parent / "mod.csv",
        paths.installed_builder.parent.parent / "mod.ff",
        paths.installed_builder.parent.parent / "z_opencj.iwd",
        paths.installation / "raw/shader_bin/shader_names",
        paths.installation / "zone_source/mod.csv",
        paths.installation / "zone/english/mod.ff",
    ]
    return {
        str(path): hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
        for path in watched
    }


def copy_stock_assets(paths):
    """Copy stock dependencies into private files; never link shared writable inputs."""
    for name in ["techsets", "techniques", "statemaps", "shader_bin", "ui", "ui_mp", "mp"]:
        target = paths.raw / name
        if not target.exists():
            shutil.copytree(paths.installation / "raw" / name, target)
    for folder in [
        "materials",
        "material_properties",
        "images",
        "xmodel",
        "xmodelparts",
        "xmodelsurfs",
        "xanim",
        "soundaliases",
        "sound",
        "fx",
        "animtrees",
        "english",
        "info",
        "vision",
        # Weapon and projectile models name stock physics presets.
        "physic",
    ]:
        source_folder = paths.installation / "raw" / folder
        if not source_folder.exists():
            continue
        for source in source_folder.rglob("*"):
            if not source.is_file():
                continue
            target = paths.raw / folder / source.relative_to(source_folder)
            if not target.exists():
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)


def prepare_toolroot(paths):
    """Prepare the layout expected by makeMod.py without changing that script."""
    for directory in [
        paths.toolroot / "bin",
        paths.raw,
        paths.cod4,
        paths.toolroot / "zone_source",
        paths.toolroot / "zone_source/english/assetlist",
        paths.toolroot / "zone/english",
        paths.evidence,
    ]:
        directory.mkdir(parents=True, exist_ok=True)
    for name in ["linker_pc.exe", "MSVCP71.DLL", "msvcr71.dll", "mss32.dll"]:
        shutil.copy2(paths.installation / "bin" / name, paths.toolroot / "bin" / name)
    for library in paths.installation.glob("*.dll"):
        shutil.copy2(library, paths.toolroot / library.name)
    shutil.copy2(paths.installation / "raw/fileSysCheck.cfg", paths.raw / "fileSysCheck.cfg")
    for folder in ["materials", "material_properties"]:
        (paths.raw / folder).mkdir(exist_ok=True)
        white_material = paths.installation / "raw" / folder / "white"
        if white_material.exists():
            shutil.copy2(white_material, paths.raw / folder / "white")
    copy_stock_assets(paths)
    shutil.copytree(paths.stage, paths.cod4, dirs_exist_ok=True)
    for folder in ["techsets", "techniques"]:
        shutil.copytree(paths.stage / folder, paths.raw / folder, dirs_exist_ok=True)


def blob_method(blob, slot, result_type, *argument_types):
    vtable = ctypes.cast(blob, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
    return ctypes.WINFUNCTYPE(result_type, ctypes.c_void_p, *argument_types)(vtable[slot])


def read_blob(blob):
    if not blob.value:
        return b""
    buffer_pointer = blob_method(blob, BLOB_POINTER_SLOT, ctypes.c_void_p)(blob)
    buffer_size = blob_method(blob, BLOB_SIZE_SLOT, ctypes.c_size_t)(blob)
    return ctypes.string_at(buffer_pointer, buffer_size)


def release_blob(blob):
    if blob.value:
        blob_method(blob, COM_RELEASE_SLOT, ctypes.c_ulong)(blob)


class ShaderCompiler:
    """Own compiler calls and release both COM outputs on success and failure."""

    def __init__(self):
        # Use the installed DirectX compiler; no downloaded executable is needed.
        self.library = ctypes.WinDLL("d3dcompiler_47.dll")
        self.compile_function = self.library.D3DCompile
        self.compile_function.argtypes = [
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_char_p,
            ctypes.c_void_p,
            ctypes.c_void_p,
            ctypes.c_char_p,
            ctypes.c_char_p,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.POINTER(ctypes.c_void_p),
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self.compile_function.restype = ctypes.c_long
        self.disassemble_function = self.library.D3DDisassemble
        self.disassemble_function.argtypes = [
            ctypes.c_void_p,
            ctypes.c_size_t,
            ctypes.c_uint,
            ctypes.c_char_p,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        self.disassemble_function.restype = ctypes.c_long

    def compile(self, source, profile, log_path):
        bytecode_blob = ctypes.c_void_p()
        message_blob = ctypes.c_void_p()
        try:
            status = self.compile_function(
                source,
                len(source),
                b"opencj_flag_atlas.hlsl",
                None,
                None,
                b"main",
                profile.encode(),
                D3DCOMPILE_OPTIMIZATION_LEVEL3,
                0,
                ctypes.byref(bytecode_blob),
                ctypes.byref(message_blob),
            )
            messages = read_blob(message_blob).decode(errors="replace")
            log_path.write_text(messages)
            if status < 0:
                raise RuntimeError(f"D3DCompile {profile} failed ({status}): {messages}")
            bytecode = read_blob(bytecode_blob)
            if not bytecode:
                raise RuntimeError(f"D3DCompile {profile} returned no bytecode")
            return bytecode
        finally:
            release_blob(bytecode_blob)
            release_blob(message_blob)

    def disassemble(self, bytecode):
        assembly_blob = ctypes.c_void_p()
        try:
            status = self.disassemble_function(
                bytecode, len(bytecode), 0, None, ctypes.byref(assembly_blob)
            )
            return read_blob(assembly_blob) if status >= 0 else None
        finally:
            release_blob(assembly_blob)


def shader_identifier(name):
    """Match the engine's name hash and byte-swapped complemented file identifier."""
    name_hash = 0
    for character in name.encode():
        name_hash = ((name_hash * 33) ^ character) & UINT32_MASK
    file_id = UINT32_MASK - int.from_bytes(name_hash.to_bytes(4, "little"), "big")
    return name_hash, file_id


def register_shader_name(table, name):
    """Validate the lookup before returning its updated pixel-shader records."""
    if len(table) < 8:
        raise ValueError("Truncated shader lookup header")
    vertex_count = struct.unpack_from("<I", table)[0]
    pixel_count_offset = 4 + vertex_count * SHADER_RECORD_BYTES
    if pixel_count_offset + 4 > len(table):
        raise ValueError("Vertex shader records exceed the lookup size")
    pixel_count = struct.unpack_from("<I", table, pixel_count_offset)[0]
    if len(table) != 8 + (vertex_count + pixel_count) * SHADER_RECORD_BYTES:
        raise ValueError("Pixel shader records do not match the lookup size")
    records = [
        struct.unpack_from("<II", table, pixel_count_offset + 4 + index * SHADER_RECORD_BYTES)
        for index in range(pixel_count)
    ]
    if any(first[0] >= second[0] for first, second in zip(records, records[1:])):
        raise ValueError("Pixel shader hashes must be unique and sorted")
    name_hash, file_id = shader_identifier(name)
    existing = [record for record in records if record[0] == name_hash]
    if existing and existing != [(name_hash, file_id)]:
        raise ValueError("Shader name collides with a different file identifier")
    if not existing:
        records.append((name_hash, file_id))
    records.sort()
    updated = (
        table[:pixel_count_offset]
        + struct.pack("<I", len(records))
        + b"".join(struct.pack("<II", *record) for record in records)
    )
    return updated, file_id


def compile_shaders(paths):
    """Compile both linker variants before replacing the private lookup or bytecode."""
    compiler = ShaderCompiler()
    source = paths.shader_source.read_bytes()
    bytecodes = {}
    for profile, expected_version, log_name in [
        ("ps_2_0", 0xFFFF0200, "compiler.log"),
        ("ps_3_0", 0xFFFF0300, "compiler-sm3.log"),
    ]:
        bytecode = compiler.compile(source, profile, paths.evidence / log_name)
        if bytecode[:4] != struct.pack("<I", expected_version):
            raise ValueError("Unexpected compiled shader version: " + profile)
        bytecodes[profile] = bytecode

    lookup = paths.raw / "shader_bin/shader_names"
    updated_lookup, file_id = register_shader_name(lookup.read_bytes(), SHADER_NAME)
    for profile, bytecode in bytecodes.items():
        shader_path = paths.raw / "shader_bin" / f"{profile}_{file_id:08x}"
        shader_path.write_bytes(struct.pack("<I", len(bytecode)) + bytecode)
    lookup.write_bytes(updated_lookup)
    (paths.evidence / "compiled-shader.bin").write_bytes(bytecodes["ps_2_0"])
    (paths.evidence / "compiled-shader-sm3.bin").write_bytes(bytecodes["ps_3_0"])
    assembly = compiler.disassemble(bytecodes["ps_2_0"])
    if assembly is not None:
        (paths.evidence / "shader.asm").write_bytes(assembly)
    print("Both shader variants compiled into the private lookup.", flush=True)


def run_installed_builder(paths):
    """Bound the legacy linker's wait and restore process state even if it exits."""
    original_run = subprocess.run

    def bounded_linker(arguments, **options):
        if not arguments or arguments[0] != "linker_pc.exe":
            raise RuntimeError("Unexpected subprocess in installed builder: " + str(arguments))
        try:
            options["timeout"] = min(
                options.get("timeout", LINKER_TIMEOUT_SECONDS), LINKER_TIMEOUT_SECONDS
            )
            return original_run(arguments, **options)
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            output = error.stdout or b""
            if isinstance(output, str):
                output = output.encode()
            (paths.evidence / "linker-error.log").write_bytes(output)
            raise

    stdout = io.StringIO()
    stderr = io.StringIO()
    return_code = 0
    previous_directory = Path.cwd()
    try:
        os.chdir(paths.cod4)
        subprocess.run = bounded_linker
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                runpy.run_path(str(paths.installed_builder), run_name="__main__")
            except SystemExit as error:
                return_code = error.code or 0
            except subprocess.TimeoutExpired:
                return_code = 124
                print("Isolated linker timed out; see linker-error.log.")
    finally:
        os.chdir(previous_directory)
        subprocess.run = original_run
    return subprocess.CompletedProcess(
        [str(paths.installed_builder)], return_code, stdout.getvalue(), stderr.getvalue()
    )


def extract_stock_images(paths, requested_images):
    """Resolve linker-reported dependencies only inside the private images folder."""
    targets = {}
    for name in requested_images:
        target = paths.raw / name
        if not name.startswith("images/") or not target.resolve().is_relative_to(
            (paths.raw / "images").resolve()
        ):
            raise ValueError("Invalid stock image dependency: " + name)
        targets[name] = target
    missing = set(requested_images)
    for archive in sorted((paths.game_directory / "main").glob("*.iwd")):
        with zipfile.ZipFile(archive) as source:
            lookup = {name.lower(): name for name in source.namelist()}
            for name in list(missing):
                entry = lookup.get(name.lower())
                if entry is None:
                    continue
                target = targets[name]
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read(entry))
                missing.remove(name)
        if not missing:
            break
    if missing:
        raise RuntimeError("Missing stock images in --game-dir: " + ", ".join(sorted(missing)))
    print(
        "Copied",
        len(requested_images),
        "stock image dependencies into private raw files.",
        flush=True,
    )


def link_assets(paths):
    """Retry only after supplying missing stock images, within a fixed attempt limit."""
    for attempt in range(MAX_LINKER_ATTEMPTS):
        result = run_installed_builder(paths)
        log = result.stdout + "\n" + result.stderr
        (paths.evidence / f"makeMod-attempt-{attempt + 1}.log").write_text(log)
        missing = set(re.findall(r"ERROR: image '(images/[^']+\.iwi)' is missing", result.stdout))
        if not missing:
            break
        if attempt == MAX_LINKER_ATTEMPTS - 1:
            raise RuntimeError("Stock image dependencies did not resolve linker errors")
        extract_stock_images(paths, missing)
    (paths.evidence / "makeMod.log").write_text(result.stdout + "\n" + result.stderr)
    if result.returncode or not (paths.cod4.parent / "mod.ff").exists():
        raise RuntimeError("See makeMod.log; no usable compiled fastfile")
    if (
        "Menu load error" in result.stdout
        or "UNRECOVERABLE ERROR" in result.stdout
        or re.search(r"(?m)^ERROR:", result.stdout)
    ):
        raise RuntimeError("Linker reported errors; see makeMod.log")
    return result


def include_notices(paths):
    """Check every existing notice before adding any omitted by the installed builder."""
    archive_path = paths.cod4.parent / "z_opencj.iwd"
    missing = []
    with zipfile.ZipFile(archive_path) as archive:
        for notice in (paths.stage / "licenses").glob("*"):
            if not notice.is_file():
                continue
            entry_name = "licenses/" + notice.name
            if entry_name in archive.namelist():
                if archive.read(entry_name) != notice.read_bytes():
                    raise RuntimeError("Built archive contains a different notice: " + entry_name)
            else:
                missing.append((notice, entry_name))
    if missing:
        with zipfile.ZipFile(archive_path, "a", compression=zipfile.ZIP_DEFLATED) as archive:
            for notice, entry_name in missing:
                archive.write(notice, entry_name)


def build(paths):
    validate_inputs(paths)
    before = snapshot_shared_files(paths)
    result = None
    completed = False
    try:
        prepare_toolroot(paths)
        compile_shaders(paths)
        result = link_assets(paths)
        include_notices(paths)
        completed = True
    finally:
        after = snapshot_shared_files(paths)
        changed = [name for name in before if before[name] != after[name]]
        if paths.evidence.exists():
            report = {
                "before": before,
                "after": after,
                "shared_files_changed": changed,
                "makeMod_sha256": before[str(paths.installed_builder)],
                "returncode": result.returncode if result else None,
                "completed": completed,
            }
            (paths.evidence / "build-isolation.json").write_text(json.dumps(report, indent=2))
        if changed:
            print("Shared outputs changed concurrently; left untouched:", changed)
    print("BUILD COMPLETE; outputs are in the private toolroot.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mod-tools", type=Path, required=True)
    parser.add_argument("--game-dir", type=Path, required=True)
    options = parser.parse_args()
    paths = BuildPaths(Path(__file__).resolve().parents[1], options.mod_tools, options.game_dir)
    build(paths)


if __name__ == "__main__":
    main()
