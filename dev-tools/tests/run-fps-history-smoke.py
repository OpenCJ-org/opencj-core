"""Run FPS history and native movement checks in an isolated server."""

import hashlib
import json
import subprocess
import uuid

from gsc_fixture import ROOT, parse_options, prepare_fixture, run_prepared_fixture


def build_movement_plugin(home):
    """Build a private test plugin for this run, avoiding shared mutable binaries."""
    plugin = home / "plugins/strafe_engine.so"
    container_plugin = "/workspace/" + plugin.relative_to(ROOT).as_posix()
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
            "-msse2",
            "-mfpmath=sse",
            "-fPIC",
            "-shared",
            "-DCOD4",
            "/workspace/dev-tools/tests/strafe-engine.cpp",
            "-o",
            container_plugin,
        ],
        cwd=ROOT / "dev-tools",
        capture_output=True,
        text=True,
    )
    (home / "build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Movement test plugin build failed; see " + str(home / "build.log"))
    return plugin


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/fps-history.gsc",
        completion_marker="FPS HISTORY SELFTEST COMPLETE",
    )
    for map_name in options.maps:
        home = ROOT / "dev-tools/local" / ("fps-history-" + uuid.uuid4().hex[:8])
        source_hashes, _ = prepare_fixture(
            options,
            home,
            retained_callbacks=("CodeCallback_FragButton", "CodeCallback_MovementState"),
        )
        plugin = build_movement_plugin(home)
        report = run_prepared_fixture(
            options,
            home,
            map_name,
            source_hashes,
            plugin_names=("strafe_engine",),
            extra_completion_markers=("STRAFE NATIVE COMPLETE",),
        )
        report["movementPluginSha256"] = hashlib.sha256(plugin.read_bytes()).hexdigest()
        (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
