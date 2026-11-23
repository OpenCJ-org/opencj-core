"""Run camera and legacy animation scenarios on an isolated engine with no live clients."""

import argparse
from enum import IntFlag
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import uuid
import zlib

from compose_environment import workspace_file, workspace_path
import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
BUILD_TIMEOUT_SECONDS = 120
MAX_CHUNK_FRAMES = 64
VISUAL_BYTES = 31
VIEW_HEIGHT_OFFSET = 8
VELOCITY_OFFSET = 11
VIEW_HEIGHT_SCALE = 256
VELOCITY_SCALE = 4
HAS_VISUALS_EVENT = 8
FRAME_FIELDS = struct.Struct("<3f3HHHiB")


class LegacyFlag(IntFlag):
    LEFT = 1
    RIGHT = 2
    FORWARD = 4
    BACKWARD = 8
    SPRINT = 64
    LADDER = 256
    STANDING = 512
    CROUCHED = 1024
    PRONE = 2048
    GROUNDED = 8192


def movement_cases():
    """Eleven movements followed by stable running, prone and standing segments."""
    grounded = LegacyFlag.GROUNDED
    standing = LegacyFlag.STANDING
    forward = LegacyFlag.FORWARD
    cases = [
        (grounded | standing, (0, 0, 0)),
        (grounded | standing | forward, (90, 0, 0)),
        (grounded | standing | forward, (190, 0, 0)),
        (grounded | standing | forward | LegacyFlag.SPRINT, (280, 0, 0)),
        (grounded | standing | LegacyFlag.BACKWARD, (-190, 0, 0)),
        (grounded | standing | LegacyFlag.LEFT, (0, 190, 0)),
        (grounded | standing | LegacyFlag.RIGHT, (0, -190, 0)),
        (grounded | LegacyFlag.CROUCHED | forward, (60, 0, 0)),
        (grounded | LegacyFlag.PRONE | forward, (25, 0, 0)),
        (standing | LegacyFlag.LADDER | forward, (0, 0, 90)),
        (standing | forward, (190, 0, 120)),
    ]
    steady_segment_frames = 32
    cases += [(grounded | standing | forward, (190, 0, 0))] * steady_segment_frames
    cases += [(grounded | LegacyFlag.PRONE | forward, (25, 0, 0))] * steady_segment_frames
    cases += [(grounded | standing, (0, 0, 0))] * steady_segment_frames
    return cases


def legacy_payloads():
    """Encode actual OCJ4 bytes, without the newer stored animation metadata."""
    frames = []
    origin = (0, 0, 100)
    angles = (0, 0, 0)
    recorded_fps = 125
    checkpoint_id = 17
    view_height_units = 60
    weapon_name = b"rpg_mp"
    for flags, velocity in movement_cases():
        base = FRAME_FIELDS.pack(
            *origin, *angles, flags, recorded_fps, checkpoint_id, HAS_VISUALS_EVENT
        )
        visual = bytearray(VISUAL_BYTES)
        struct.pack_into("<h", visual, VIEW_HEIGHT_OFFSET, view_height_units * VIEW_HEIGHT_SCALE)
        quantized_velocity = [component * VELOCITY_SCALE for component in velocity]
        struct.pack_into("<3h", visual, VELOCITY_OFFSET, *quantized_velocity)
        frames.append(base + visual + bytes([len(weapon_name)]) + weapon_name)

    payloads = []
    for start in range(0, len(frames), MAX_CHUNK_FRAMES):
        chunk = frames[start : start + MAX_CHUNK_FRAMES]
        raw = b"OCJ4" + struct.pack("<I", len(chunk)) + b"".join(chunk)
        payloads.append(zlib.compress(raw).hex())
    return payloads


def install_recording(mod):
    fixture = mod / "opencj/platformtest.gsc"
    payloads = legacy_payloads()

    def decode_chunks(match):
        demo_id = match.group(1)
        return " + ".join(
            "demoDecodeChunk(" + demo_id + ', "' + payload + '")' for payload in payloads
        )

    source, count = re.subn(
        r'\bdemoDecodeChunk\s*\(\s*(\w+)\s*,\s*"BODY_FIXTURE_HEX"\s*\)',
        decode_chunks,
        fixture.read_text(),
    )
    if count != 1:
        raise RuntimeError("Expected one camera recording fixture placeholder")
    fixture.write_text(source)


def install_settings_observers(mod):
    """Keep the real SQL builders, replacing only database and account boundaries."""
    path = mod / "opencj/settings.gsc"
    source = path.read_text()
    replacements = (
        (
            r"openCJ\\mySQL::mysqlAsyncQueryNosave\s*\(",
            r"openCJ\platformTest::recordSettingWrite(",
        ),
        (
            r"openCJ\\mySQL::mysqlAsyncQuery\s*\(",
            r"openCJ\platformTest::readStoredSettings(",
        ),
        (
            r"\bself\s+openCJ\\events\\playerLogin::main\s*\(\s*\)\s*;",
            "// Account callbacks are outside this isolated settings fixture.",
        ),
    )
    for pattern, replacement in replacements:
        source, count = re.subn(pattern, lambda match: replacement, source)
        if count == 0:
            raise RuntimeError("Camera fixture boundary was not found: " + pattern)
    path.write_text(source)


def build_probe(home):
    destination = home / "plugins/camera_engine.so"
    container_path = "/workspace/" + destination.relative_to(ROOT).as_posix()
    command = [
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
        "/workspace/dev-tools/tests/camera-engine.cpp",
        "-o",
        container_path,
    ]
    result = subprocess.run(
        command,
        cwd=ROOT / "dev-tools",
        text=True,
        capture_output=True,
        timeout=BUILD_TIMEOUT_SECONDS,
    )
    (home / "probe-build.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Camera probe build failed; inspect " + str(home / "probe-build.log"))
    return destination


def parse_options():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("maps", nargs="*", default=["mp_killhouse"])
    parser.add_argument("--binary", default="cod4x-server/bin/cod4x18_dedrun")
    parser.add_argument("--scripts", type=Path, default=ROOT / "server-gsc")
    parser.add_argument("--plugin", help="Optional matching probe inside the checkout")
    options = parser.parse_args()
    options.fixture = ROOT / "dev-tools/tests/camera.gsc"
    options.completion_marker = "CAMERA TEST COMPLETE"
    options.baseline = False
    gsc_fixture.validate_options(parser, options)
    if options.plugin:
        try:
            options.plugin = workspace_file(options.plugin)
        except ValueError as error:
            parser.error(str(error))
    return options


def run_camera(options, map_name):
    home = ROOT / "dev-tools/local" / ("camera-" + uuid.uuid4().hex[:8])
    source_hashes, _ = gsc_fixture.prepare_fixture(options, home)
    mod = home / "mods/opencj"
    install_recording(mod)
    install_settings_observers(mod)
    if options.plugin:
        probe = options.plugin
        (home / "plugins/camera_engine.so").symlink_to(workspace_path(probe))
    else:
        probe = build_probe(home)
    (home / "probe-source.json").write_text(
        json.dumps(
            {
                "pluginSha256": hashlib.sha256(probe.read_bytes()).hexdigest(),
                "sourceSha256": (
                    hashlib.sha256(
                        (ROOT / "dev-tools/tests/camera-engine.cpp").read_bytes()
                    ).hexdigest()
                    if options.plugin is None
                    else None
                ),
                "builtFromSource": options.plugin is None,
            },
            indent=2,
        )
        + "\n"
    )
    report = gsc_fixture.run_prepared_fixture(
        options,
        home,
        map_name,
        source_hashes,
        plugin_names=("camera_engine",),
        extra_completion_markers=("CAMERA NATIVE COMPLETE",),
        extra_settings={"opencj_isolated_camera_test": "1", "cg_thirdPerson": "1"},
    )
    log = (home / "console.log").read_text()
    script_checks = sum(line.startswith("CAMERA TEST 1:") for line in log.splitlines())
    native_checks = sum(line.startswith("CAMERA NATIVE 1:") for line in log.splitlines())
    if script_checks == 0 or native_checks == 0:
        raise RuntimeError("Camera fixture completed without both script and native checks.")
    report.update(scriptChecks=script_checks, nativeChecks=native_checks)
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"PASS: {script_checks} script and {native_checks} native camera checks", flush=True)


def main():
    options = parse_options()
    for map_name in options.maps:
        run_camera(options, map_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
