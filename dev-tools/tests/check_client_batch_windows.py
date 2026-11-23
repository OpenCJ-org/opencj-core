"""Exercise a staged batch builder with synthetic assets and the installed 7-Zip.

Run on Windows with explicit builder, C# compiler and archiver paths. The synthetic
linker never reads game assets. All build and compiler outputs are temporary.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

PROCESS_TIMEOUT_SECONDS = 30
FAKE_LINKER_SOURCE = r"""
using System;
using System.IO;
using System.Text;

class FakeLinker
{
    static int Main(string[] arguments)
    {
        // The same fixture also models an archiver that opens but cannot write.
        if (arguments.Length > 0 && arguments[0] == "i")
        {
            return 0;
        }
        if (arguments.Length > 0 && arguments[0] == "a")
        {
            return 7;
        }
        string behavior = Environment.GetEnvironmentVariable("OPENCJ_TEST_LINKER");
        if (behavior == "fail")
        {
            return 7;
        }
        if (behavior != "no-output")
        {
            string output = Path.GetFullPath("../zone/english/mod.ff");
            File.WriteAllBytes(output, Encoding.UTF8.GetBytes("synthetic fastfile"));
        }
        return 0;
    }
}
"""


def prepare_fixture(workspace, scenario, builder_path, linker_path):
    """Keep every path the batch file can delete inside this run's owned tree."""
    installation = (workspace / scenario / "Mod Tools synthetic").resolve()
    source = installation / "Mods/opencj/cod4"
    if not installation.is_relative_to(workspace.resolve()):
        raise ValueError("Fixture installation escaped its workspace")
    source.mkdir(parents=True)
    for folder in ["bin", "raw", "zone_source", "zone/english"]:
        (installation / folder).mkdir(parents=True)
    shutil.copy2(linker_path, installation / "bin/linker_pc.exe")
    shutil.copy2(builder_path, source / "makeMod.bat")
    (source / "mod.csv").write_text("rawfile,synthetic.txt\n")
    (source / "images").mkdir()
    (source / "images/synthetic.iwi").write_bytes(b"synthetic image")
    (source / "licenses").mkdir()
    (source / "licenses/source.txt").write_text("synthetic notice")
    for output in [
        source.parent / "mod.ff",
        source.parent / "z_opencj.iwd",
        installation / "zone/english/mod.ff",
    ]:
        if not output.resolve().is_relative_to(workspace.resolve()):
            raise ValueError("Fixture output escaped its workspace")
        output.write_bytes(b"previous output")
    return source


def run_scenario(workspace, scenario, builder_path, linker_path, archiver_path, behavior):
    source = prepare_fixture(workspace, scenario, builder_path, linker_path)
    environment = dict(os.environ)
    environment["OPENCJ_7ZIP"] = str(archiver_path)
    environment["OPENCJ_TEST_LINKER"] = behavior
    result = subprocess.run(
        ["cmd.exe", "/d", "/c", "makeMod.bat"],
        cwd=source,
        env=environment,
        capture_output=True,
        text=True,
        input="",
        timeout=PROCESS_TIMEOUT_SECONDS,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    outputs = {name: source.parent / name for name in ["mod.ff", "z_opencj.iwd"]}
    return result, source, outputs


def check_scenarios(workspace, builder_path, linker_path, archiver_path):
    result, source, outputs = run_scenario(
        workspace, "success", builder_path, linker_path, archiver_path, "success"
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert outputs["mod.ff"].read_bytes() == b"synthetic fastfile"
    with zipfile.ZipFile(outputs["z_opencj.iwd"]) as archive:
        assert archive.read("images/synthetic.iwi") == b"synthetic image"
        assert archive.read("licenses/source.txt") == b"synthetic notice"
    assert not (source / "weapons").exists(), "The builder created a missing source folder"
    print("PASS: build and notice packaging with spaces in the installation path")

    result, _, outputs = run_scenario(
        workspace, "missing-tool", builder_path, linker_path, workspace / "missing.exe", "success"
    )
    assert result.returncode != 0, "Missing archiver reported success"
    assert all(path.read_bytes() == b"previous output" for path in outputs.values())
    print("PASS: missing archiver preserves previous outputs")

    for scenario, behavior, selected_archiver in [
        ("linker-failure", "fail", archiver_path),
        ("missing-fastfile", "no-output", archiver_path),
        ("archive-failure", "success", linker_path),
    ]:
        result, _, outputs = run_scenario(
            workspace, scenario, builder_path, linker_path, selected_archiver, behavior
        )
        assert result.returncode != 0, scenario + " reported success"
        assert not any(path.exists() for path in outputs.values()), (
            scenario + " left a stale or partial package"
        )
        print("PASS: " + scenario.replace("-", " "))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--builder", type=Path, required=True, help="Current staged makeMod.bat")
    parser.add_argument("--compiler", type=Path, required=True, help="Installed .NET C# compiler")
    parser.add_argument("--archiver", type=Path, required=True, help="Installed 7z.exe")
    options = parser.parse_args()
    if os.name != "nt":
        parser.error("The batch builder requires Windows")
    for path in [options.builder, options.compiler, options.archiver]:
        if not path.is_file():
            parser.error("Required tool or builder is missing: " + str(path))

    with tempfile.TemporaryDirectory(prefix="opencj-batch-test-") as directory:
        workspace = Path(directory)
        source_path = workspace / "FakeLinker.cs"
        linker_path = workspace / "FakeLinker.exe"
        source_path.write_text(FAKE_LINKER_SOURCE)
        subprocess.run(
            [
                str(options.compiler.resolve()),
                "/nologo",
                "/out:" + str(linker_path),
                str(source_path),
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=PROCESS_TIMEOUT_SECONDS,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        check_scenarios(
            workspace, options.builder.resolve(), linker_path, options.archiver.resolve()
        )


if __name__ == "__main__":
    main()
