"""Build only private sticky-wall objects, reusing the existing engine link inputs."""

import hashlib
import json
import re
from pathlib import Path
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
ENGINE = ROOT / "cod4x-server"
BINARY_NAME = "cod4x18_sticky_live_test"
COMMAND_TIMEOUT_SECONDS = 90


def instrument_slide_trace(home):
    """Hook the native frame in a private assembly copy; leave production objects alone."""
    source = (ENGINE / "src/asmsource/_bg_slidemove.asm").read_text()
    source, section_count = re.subn(
        r"(?m)^[ \t]*SECTION[ \t]+\.text[ \t]*$",
        "extern StickyTrace\nSECTION .text",
        source,
    )
    source, declaration_count = re.subn(
        r"(?m)^[ \t]*extern[ \t]+PM_playerTrace[ \t]*$",
        "extern StickyTestPlayerTrace",
        source,
    )
    trace_pattern = r"(?m)^[ \t]*call[ \t]+PM_playerTrace[ \t]*$"
    source, call_count = re.subn(trace_pattern, "\tcall StickyTestPlayerTrace", source)
    if section_count != 1 or declaration_count != 1 or call_count == 0:
        raise RuntimeError("Native slide assembly no longer has the expected trace entry")
    # The C hook receives the saved EBP frame without changing live registers.
    trace_call = "\tcall StickyTestPlayerTrace\n"
    source = source.replace(
        trace_call,
        trace_call + "\tpushad\n\tpush ebp\n\tcall StickyTrace\n\tadd esp, 4\n\tpopad\n",
        1,
    )
    assembly_path = home / "slide-live-test.asm"
    assembly_path.write_text(source)
    return assembly_path


def compile_instrumented_objects(home):
    assembly = instrument_slide_trace(home)
    commands = [
        ["nasm", "-f", "elf", str(assembly), "-o", str(home / "slide-live-test.o")],
        [
            "gcc",
            "-m32",
            "-msse2",
            "-mfpmath=sse",
            "-fno-pie",
            "-O0",
            "-Wall",
            "-Werror",
            "-c",
            str(ROOT / "dev-tools/tests/sticky-walls-native.c"),
            "-o",
            str(home / "trace.o"),
        ],
        [
            "gcc",
            "-m32",
            "-msse2",
            "-mfpmath=sse",
            "-fno-pie",
            "-O1",
            "-Wall",
            "-Werror",
            "-DOpenCJ_StickyWallRecovery=StickyWallFixed",
            "-c",
            "src/opencj_stickywalls.c",
            "-o",
            str(home / "fixed-test.o"),
        ],
    ]
    for command in commands:
        subprocess.run(command, cwd=ENGINE, check=True, timeout=COMMAND_TIMEOUT_SECONDS)


def link_private_engine(home):
    """Use the current Makefile's link arguments and record the reused object hashes."""
    plan = subprocess.check_output(
        ["make", "-n", "TARGETNAME=" + BINARY_NAME],
        cwd=ENGINE,
        text=True,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )
    output = "bin/" + BINARY_NAME
    link_commands = []
    for line in plan.splitlines():
        if line.startswith("gcc ") and " -o " + output + " " in line:
            link_commands.append(shlex.split(line))
    if len(link_commands) != 1:
        raise RuntimeError("Expected one engine link command from make -n")
    command = link_commands[0]
    replacements = {
        "obj/_bg_slidemove.o": home / "slide-live-test.o",
        "obj/opencj_stickywalls.o": home / "fixed-test.o",
        output: home / BINARY_NAME,
    }
    for original, replacement in replacements.items():
        if command.count(original) != 1:
            raise RuntimeError("Expected one link input: " + original)
        command[command.index(original)] = str(replacement)
    command.append(str(home / "trace.o"))
    object_hashes = {}
    for argument in command:
        if argument.endswith((".o", ".a")):
            path = (ENGINE / argument).resolve()
            object_hashes[path.relative_to(ROOT).as_posix()] = hashlib.sha256(
                path.read_bytes()
            ).hexdigest()
    subprocess.run(command, cwd=ENGINE, check=True, timeout=COMMAND_TIMEOUT_SECONDS)
    (home / "link-inputs.json").write_text(json.dumps(object_hashes, indent=2) + "\n")


def main():
    home = Path(sys.argv[1]).resolve()
    if not home.is_relative_to(ROOT / "dev-tools/local") or not home.is_dir():
        raise ValueError("Build output must be an existing private fixture directory")
    compile_instrumented_objects(home)
    link_private_engine(home)


if __name__ == "__main__":
    main()
