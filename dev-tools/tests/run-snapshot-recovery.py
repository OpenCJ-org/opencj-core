#!/usr/bin/env python3
"""Exercise production packet and snapshot code without network traffic or a live server."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[2]
BUILD_TIMEOUT_SECONDS = 120
TEST_TIMEOUT_SECONDS = 30
C_TOKENS = re.compile(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[{}]')


def extract_function(source, name):
    """Read a whole production function while ignoring braces in comments and strings."""
    signature = re.search(r"(?m)^[^\n;{}]*\b" + re.escape(name) + r"\s*\([^;{}]*\)\s*\{", source)
    if signature is None:
        raise ValueError("Production function not found: " + name)
    depth = 1
    for token in C_TOKENS.finditer(source, signature.end()):
        if token.group() == "{":
            depth += 1
        elif token.group() == "}":
            depth -= 1
            if depth == 0:
                return source[signature.start() : token.end()]
    raise ValueError("Unclosed production function: " + name)


def prepare_packet_source(home):
    """Include real parser code; fixtures replace only external engine services."""
    source_paths = ("netchan.c", "sv_main.c", "msg.c")
    sources = {name: (ROOT / "cod4x-server/src" / name).read_text() for name in source_paths}
    fragment_flag = re.search(r"(?m)^#define\s+FRAGMENT_BIT\s+[^\n]+", sources["netchan.c"])
    if fragment_flag is None:
        raise ValueError("Production fragment flag not found")
    extracted = (
        fragment_flag.group() + "\n"
        'static const char *netsrcString[] = {"client", "server"};\n'
        + extract_function(sources["netchan.c"], "Netchan_Process")
        + "\n"
        + extract_function(sources["sv_main.c"], "SV_PacketEvent")
        + "\n"
    )
    (home / "packet-event-under-test.c").write_text(extracted)
    return {
        name: hashlib.sha256((ROOT / "cod4x-server/src" / name).read_bytes()).hexdigest()
        for name in source_paths
    }


def isolated_command(home, name, entrypoint, arguments, timeout_seconds):
    """Always remove this invocation's container, including after a subprocess timeout."""
    command = [
        "docker",
        "compose",
        "run",
        "--rm",
        "--no-deps",
        "--name",
        name,
        "--workdir",
        "/workspace/cod4x-server",
        "--entrypoint",
        entrypoint,
        "build",
        *arguments,
    ]
    log_path = home / (name + ".log")
    try:
        with log_path.open("w") as log:
            result = subprocess.run(
                command,
                cwd=ROOT / "dev-tools",
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=timeout_seconds,
            )
        if result.returncode:
            raise RuntimeError("Protocol fixture command failed; see " + str(log_path))
        return log_path.read_text()
    finally:
        subprocess.run(
            ["docker", "rm", "-f", name],
            capture_output=True,
            timeout=TEST_TIMEOUT_SECONDS,
        )


def main():
    home = ROOT / "dev-tools/local" / ("snapshot-recovery-" + uuid.uuid4().hex[:8])
    home.mkdir(parents=True)
    source_hashes = prepare_packet_source(home)
    relative_home = home.relative_to(ROOT).as_posix()
    flags = [
        "-m32",
        "-msse2",
        "-mfpmath=sse",
        "-O0",
        "-g",
        "-fcommon",
        "-fno-pie",
        "-no-pie",
        "-ffunction-sections",
        "-fdata-sections",
        "-DCOD4",
        "-D_GNU_SOURCE",
        "-Isrc",
        "-I../" + relative_home,
    ]
    counts = {}
    for test_name in ("packet-ack-recovery", "snapshot-recovery"):
        output = "/workspace/" + relative_home + "/" + test_name
        prefix = "opencj-" + home.name + "-" + test_name
        isolated_command(
            home,
            prefix + "-build",
            "gcc",
            flags
            + [
                "src/msg.c",
                "../dev-tools/tests/" + test_name + ".c",
                "-Wl,--gc-sections",
                "-lm",
                "-o",
                output,
            ],
            BUILD_TIMEOUT_SECONDS,
        )
        log = isolated_command(home, prefix + "-test", output, [], TEST_TIMEOUT_SECONDS)
        (home / (test_name + "-results.txt")).write_text(log)
        counts[test_name] = sum(line.startswith("PASS:") for line in log.splitlines())
        if not counts[test_name] or any(line.startswith("FAIL:") for line in log.splitlines()):
            raise AssertionError("Protocol fixture did not pass: " + test_name)
        print(f"{test_name}: {counts[test_name]} checks passed", flush=True)
    report = {"checks": counts, "sourceHashes": source_hashes, "liveRestart": False}
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Evidence: " + str(home), flush=True)


if __name__ == "__main__":
    main()
