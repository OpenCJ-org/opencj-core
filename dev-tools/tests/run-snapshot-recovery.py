#!/usr/bin/env python3
"""Build/run isolated native protocol regressions in an ephemeral Compose build container.

Reads production C functions directly; no traffic is sent and no server is restarted.
Run on the authoritative host: python3 dev-tools/tests/run-snapshot-recovery.py
"""

import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LOCAL = ROOT / "dev-tools/local/snapshot-recovery"
LOCAL.mkdir(parents=True, exist_ok=True)


def function(source, signature, end_marker):
    text = (ROOT / "cod4x-server/src" / source).read_text()
    start = text.index(signature)
    return text[start : text.index(end_marker, start)]


netchan = (ROOT / "cod4x-server/src/netchan.c").read_text()
fragment_bit = next(
    line for line in netchan.splitlines() if line.startswith("#define FRAGMENT_BIT ")
)
(LOCAL / "packet-event-under-test.c").write_text(
    fragment_bit
    + '\nstatic const char *netsrcString[]={"client","server"};\n'
    + function("netchan.c", "qboolean Netchan_Process(", "\n\n//====")
    + "\n"
    + function("sv_main.c", "__optimize3 __regparm2 void SV_PacketEvent(", "\n\n/*")
)
flags = [
    "gcc",
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
    "-I../dev-tools/local/snapshot-recovery",
]
for test in ("packet-ack-recovery", "snapshot-recovery"):
    output = f"/workspace/dev-tools/local/snapshot-recovery/{test}"
    subprocess.run(
        [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "--workdir",
            "/workspace/cod4x-server",
            "--entrypoint",
            flags[0],
            "build",
        ]
        + flags[1:]
        + ["src/msg.c", f"../dev-tools/tests/{test}.c", "-Wl,--gc-sections", "-lm", "-o", output],
        cwd=ROOT / "dev-tools",
        check=True,
    )
    result = subprocess.run(
        ["docker", "compose", "run", "--rm", "--no-deps", "--entrypoint", output, "build"],
        cwd=ROOT / "dev-tools",
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    (LOCAL / f"{test}-results.txt").write_text(result.stdout)
    lines = result.stdout.splitlines()
    print(f"{test}: {sum(line.startswith('PASS:') for line in lines)} checks passed", flush=True)
    if result.returncode:
        print(result.stdout)
        raise SystemExit(result.returncode)
