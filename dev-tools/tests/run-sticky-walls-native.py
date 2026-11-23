#!/usr/bin/env python3
"""Build and verify native sticky-wall recovery without restarting the live server."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

from sticky_wall_fixture import parse_options, run_probe

ROOT = Path(__file__).resolve().parents[2]
BUILD_TIMEOUT_SECONDS = 120
ALTERNATING_CASES = 1728
ORDINARY_COLLISION_CASES = 40
COMMAND_CASES_PER_MODE = 700


def build_engine(home):
    """Bound the private build and remove its container even if compilation times out."""
    container_name = "opencj-" + home.name + "-build"
    container_home = "/workspace/" + home.relative_to(ROOT).as_posix()
    command = [
        "docker",
        "compose",
        "run",
        "--rm",
        "--no-deps",
        "--name",
        container_name,
        "--entrypoint",
        "python3",
        "build",
        "/workspace/dev-tools/tests/sticky_wall_build.py",
        container_home,
    ]
    log_path = home / "build.log"
    try:
        with log_path.open("w") as log:
            result = subprocess.run(
                command,
                cwd=ROOT / "dev-tools",
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=BUILD_TIMEOUT_SECONDS,
            )
        if result.returncode:
            raise RuntimeError("Sticky-wall build failed; see " + str(log_path))
    finally:
        subprocess.run(
            ["docker", "rm", "-f", container_name], capture_output=True, timeout=30
        )
    return container_home + "/cod4x18_sticky_live_test"


def verify_native_results(log, recovery):
    """Require the original failure and the corrected result, plus unchanged ordinary motion."""
    alternating = [line for line in log.splitlines() if "NATIVE ALTERNATE " in line]
    assert (
        len(alternating) == ALTERNATING_CASES
    ), f"Alternating scenarios: expected {ALTERNATING_CASES}, got {len(alternating)}"
    stalled = [line for line in alternating if not re.search(r"\bstalls=0\s", line)]
    if recovery:
        assert (
            not stalled
        ), f"Corrected alternating motion stalled in {len(stalled)} cases"
    else:
        assert stalled, "Baseline no longer reproduces sticky-wall stalls"
    completion = (
        f"NATIVE REGRESSION COMPLETE cases={ORDINARY_COLLISION_CASES} failures=0"
    )
    assert completion in log, "Ordinary collision histories changed or did not finish"
    for mode in (0, 1):
        commands = [
            line for line in log.splitlines() if f"NATIVE COMMAND mode={mode} " in line
        ]
        assert len(commands) == COMMAND_CASES_PER_MODE, (
            f"Command scenarios for mode {mode}: expected {COMMAND_CASES_PER_MODE}, "
            f"got {len(commands)}"
        )
        if mode:
            failures = [
                line for line in commands if not re.search(r"\bstalls=0\s", line)
            ]
            assert not failures, f"Corrected commands stalled in {len(failures)} cases"
    return {
        "recovery": recovery,
        "alternating": len(alternating),
        "stalled": len(stalled),
        "ordinaryParity": ORDINARY_COLLISION_CASES,
        "fullCommandSequences": COMMAND_CASES_PER_MODE * 2,
    }


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    home = ROOT / "dev-tools/local" / ("sticky-walls-" + uuid.uuid4().hex[:8])
    home.mkdir(parents=True)
    installed_engine = ROOT / "cod4x-server/bin/cod4x18_dedrun"
    installed_hash = hashlib.sha256(installed_engine.read_bytes()).hexdigest()
    source_paths = (
        "cod4x-server/src/asmsource/_bg_slidemove.asm",
        "cod4x-server/src/opencj_stickywalls.c",
        "cod4x-server/src/bg_public.h",
        "cod4x-server/src/player.h",
        "cod4x-server/src/cm_public.h",
        "dev-tools/tests/sticky-walls-native.c",
        "dev-tools/tests/sticky-walls.gsc",
    )
    source_hashes = {
        path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
        for path in source_paths
    }
    binary = build_engine(home)
    results = []
    for recovery in (0, 1):
        options = parse_options(["--binary", binary, "--recovery", str(recovery)])
        log = run_probe(options, "mp_galaxy", home=home / ("mode-" + str(recovery)))
        result = verify_native_results(log, recovery)
        results.append(result)
        print("PASS: " + json.dumps(result), flush=True)
    assert (
        installed_hash == hashlib.sha256(installed_engine.read_bytes()).hexdigest()
    ), "Installed engine changed during the fixture"
    for path, original_hash in source_hashes.items():
        assert (
            original_hash == hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
        ), ("Fixture source changed during the run: " + path)
    report = {
        "results": results,
        "sourceHashes": source_hashes,
        "installedEngineUnchanged": True,
        "sourcesUnchanged": True,
    }
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Evidence: " + str(home), flush=True)


if __name__ == "__main__":
    main()
