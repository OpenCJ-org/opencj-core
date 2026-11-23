"""Measure production HUD and history allocations in a database-free isolated engine."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
BUILD_TIMEOUT_SECONDS = 90
NATIVE_SOURCE = ROOT / "dev-tools/tests/player-memory-audit.cpp"


def build_probe(home):
    """Build the read-only counter plugin inside the fixture's own directory."""
    output = "/workspace/" + home.relative_to(ROOT).as_posix() + "/plugins/memory_audit.so"
    result = subprocess.run(
        [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "build",
            "g++",
            "-m32",
            "-std=c++11",
            "-fPIC",
            "-shared",
            "-DCOD4",
            "/workspace/dev-tools/tests/player-memory-audit.cpp",
            "-o",
            output,
        ],
        cwd=ROOT / "dev-tools",
        capture_output=True,
        text=True,
        timeout=BUILD_TIMEOUT_SECONDS,
    )
    (home / "build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Memory probe build failed; see " + str(home / "build.log"))


def measurements(log):
    result = {}
    for line in log.splitlines():
        match = re.fullmatch(r"MEM (\w+) (.*)", line)
        if match:
            result[match[1]] = {
                name: int(value) for name, value in re.findall(r"(\w+)=(\d+)", match[2])
            }
    return result


def verify_allocations(metrics):
    """Compare meaningful stage differences, not incidental VM allocation totals."""
    checks = (
        (
            metrics["cache_512_unchanged"]["reachableChildren"]
            == metrics["cache_empty"]["reachableChildren"],
            "unchanged history adds no script children",
        ),
        (
            metrics["cache_512_unchanged"]["reachableObjects"]
            == metrics["cache_empty"]["reachableObjects"],
            "unchanged history adds no script objects",
        ),
        (
            metrics["cache_cleared"]["reachableChildren"]
            == metrics["cache_empty"]["reachableChildren"],
            "cache reset restores child count",
        ),
        (
            metrics["speed_duplicate"]["huds"] == metrics["progress"]["huds"],
            "duplicate speedometer initialization adds no HUDs",
        ),
        (
            metrics["NATIVE"]["changes"] == 1 and metrics["NATIVE"]["samples"] == 512,
            "native cache records 512 samples with one change",
        ),
        (
            metrics["position_enabled"]["huds"] - metrics["connect_huds"]["huds"] == 4,
            "position display creates four HUDs",
        ),
        (
            metrics["position_disabled"]["huds"] == metrics["connect_huds"]["huds"],
            "disabling position display removes its HUDs",
        ),
    )
    for passed, message in checks:
        if not passed:
            raise AssertionError(message)
    return len(checks)


def audit(options, map_name):
    home = ROOT / "dev-tools/local" / ("player-memory-" + uuid.uuid4().hex[:8])
    source_hashes, _ = gsc_fixture.prepare_fixture(options, home, retained_callbacks=())
    # Exclude unrelated map threads from the VM allocation totals.
    mod = home / "mods/opencj"
    (mod / "maps/mp/gametypes/cj.gsc").write_text(
        'main()\n{\n    level.script = getCvar("mapname");\n    thread openCJ\\platformTest::main();\n}\n'
    )
    (mod / "maps/mp" / (map_name + ".gsc")).write_text("main()\n{\n}\n")
    engine_hash = hashlib.sha256(options.engine.read_bytes()).hexdigest()
    probe_source_hash = hashlib.sha256(NATIVE_SOURCE.read_bytes()).hexdigest()
    build_probe(home)
    report = gsc_fixture.run_prepared_fixture(
        options, home, map_name, source_hashes, plugin_names=("memory_audit",)
    )
    metrics = measurements((home / "console.log").read_text())
    check_count = verify_allocations(metrics)
    if source_hashes != gsc_fixture.script_hashes(options.scripts):
        raise AssertionError("Selected production scripts changed during the audit")
    if engine_hash != hashlib.sha256(options.engine.read_bytes()).hexdigest():
        raise AssertionError("Selected engine changed during the audit")
    report.update(
        measurements=metrics,
        checksPassed=check_count + 2,
        probeSourceSha256=probe_source_hash,
        probeSha256=hashlib.sha256((home / "plugins/memory_audit.so").read_bytes()).hexdigest(),
        productionUnchanged=True,
        databaseAccess=False,
        liveRestart=False,
    )
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {check_count + 2} allocation and source-preservation checks", flush=True)


def main():
    parser = gsc_fixture.create_parser(
        default_fixture=ROOT / "dev-tools/tests/player-memory-audit.gsc",
        completion_marker="MEM COMPLETE",
    )
    options = gsc_fixture.validate_options(parser, parser.parse_args())
    if options.baseline:
        parser.error("The memory audit measures the selected script tree; use --scripts.")
    for map_name in options.maps:
        audit(options, map_name)


if __name__ == "__main__":
    main()
