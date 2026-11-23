"""Build OpenCJ from a staged Mods/opencj/cod4 directory in Windows Mod Tools."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

LINKER_TIMEOUT_SECONDS = 180
FASTFILE_NAME = "mod.ff"
ARCHIVE_NAME = "z_opencj.iwd"
FASTFILE_FOLDERS = [
    "opencj",
    "animtrees",
    "english",
    "fx",
    "images",
    "maps",
    "material_properties",
    "materials",
    "info",
    "mp",
    "soundaliases",
    "sound",
    "ui",
    "ui_mp",
    "weapons",
    "vision",
    "xanim",
    "xmodel",
    "xmodelparts",
    "xmodelsurfs",
]
ARCHIVE_FOLDERS = ["images", "weapons", "licenses"]


def validate_layout(source_directory):
    """Resolve the legacy relative layout and reject missing inputs before writes."""
    if len(source_directory.parents) < 3:
        raise ValueError("Run from the staged Mods/opencj/cod4 directory")
    installation = source_directory.parents[2]
    required_files = [
        source_directory / "mod.csv",
        installation / "bin/linker_pc.exe",
    ]
    required_directories = [
        installation / "raw",
        installation / "zone_source",
        installation / "zone/english",
        source_directory / "licenses",
    ]
    missing = [str(path) for path in required_files if not path.is_file()]
    missing.extend(str(path) for path in required_directories if not path.is_dir())
    if missing:
        raise ValueError("Missing build inputs:\n" + "\n".join(missing))
    if not any((source_directory / folder).is_dir() for folder in FASTFILE_FOLDERS):
        raise ValueError("No fastfile asset folders found in " + str(source_directory))
    for name in [FASTFILE_NAME, ARCHIVE_NAME]:
        output = source_directory.parent / name
        if output.exists() and not output.is_file():
            raise ValueError("Build output is not a file: " + str(output))
    return installation


def copy_fastfile_inputs(source_directory, installation):
    for folder in FASTFILE_FOLDERS:
        source = source_directory / folder
        if source.is_dir():
            shutil.copytree(source, installation / "raw" / folder, dirs_exist_ok=True)
    shutil.copyfile(source_directory / "mod.csv", installation / "zone_source/mod.csv")


def run_linker(installation):
    """Keep the legacy command and working directory, with a bounded wait."""
    previous_directory = Path.cwd()
    try:
        os.chdir(installation / "bin")
        result = subprocess.run(
            ["linker_pc.exe", "-language", "english", "-compress", "-cleanup", "mod"],
            capture_output=True,
            text=True,
            timeout=LINKER_TIMEOUT_SECONDS,
        )
    finally:
        os.chdir(previous_directory)
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr, file=sys.stderr)
    if result.returncode:
        raise RuntimeError(f"Linker failed with exit code {result.returncode}")
    if any(
        marker in result.stdout for marker in ["Menu load error", "UNRECOVERABLE ERROR", "\nERROR:"]
    ) or result.stdout.startswith("ERROR:"):
        raise RuntimeError("Linker reported asset errors")
    if not (installation / "zone/english" / FASTFILE_NAME).is_file():
        raise RuntimeError("Linker produced no " + FASTFILE_NAME)


def build_archive(source_directory, temporary_directory):
    """Package assets and notices without creating missing folders in the source."""
    archive_root = temporary_directory / "archive"
    archive_root.mkdir()
    for folder in ARCHIVE_FOLDERS:
        source = source_directory / folder
        destination = archive_root / folder
        if source.is_dir():
            shutil.copytree(source, destination)
        else:
            destination.mkdir()
    archive_path = shutil.make_archive(
        str(temporary_directory / "z_opencj"), "zip", root_dir=archive_root, base_dir="./"
    )
    return Path(archive_path)


def publish_outputs(staged_outputs, output_directory):
    """Publish complete files; remove this attempt's outputs if either move fails."""
    published = []
    try:
        for staged, name in staged_outputs:
            destination = output_directory / name
            staged.replace(destination)
            published.append(destination)
    except OSError:
        for path in published:
            path.unlink(missing_ok=True)
        raise


def build(source_directory):
    source_directory = source_directory.resolve()
    installation = validate_layout(source_directory)
    output_directory = source_directory.parent

    # Once a valid build starts, remove old outputs so a failure cannot look like success.
    for name in [FASTFILE_NAME, ARCHIVE_NAME]:
        (output_directory / name).unlink(missing_ok=True)
    copy_fastfile_inputs(source_directory, installation)
    (installation / "zone/english" / FASTFILE_NAME).unlink(missing_ok=True)
    run_linker(installation)

    # A unique owned folder cannot pick up debris from a previous interrupted build.
    with tempfile.TemporaryDirectory(prefix=".opencj-build-", dir=source_directory) as directory:
        temporary_directory = Path(directory)
        archive = build_archive(source_directory, temporary_directory)
        fastfile = temporary_directory / FASTFILE_NAME
        shutil.copyfile(installation / "zone/english" / FASTFILE_NAME, fastfile)
        publish_outputs([(fastfile, FASTFILE_NAME), (archive, ARCHIVE_NAME)], output_directory)
    print("Mod created successfully!")


def main():
    try:
        # The installed-builder wrapper deliberately runs this script from a private tree.
        build(Path.cwd())
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("Build failed: " + str(error), file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
