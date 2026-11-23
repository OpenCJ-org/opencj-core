"""Replay a stored run, clip:<id>, or exported JSON through the FPS history HUD.

The optional database export uses SELECT only. Replays run in an isolated server,
and recordings, console output and trace JSON remain in ignored local evidence.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

from compose_environment import database_container, workspace_file, workspace_path
from gsc_fixture import ROOT, prepare_fixture, run_prepared_fixture

MAX_NATIVE_ID = 2**31 - 1
MAX_PACKED_CHUNK_BYTES = 8192  # Matches DemoWire::BUFFER_SIZE.
CHUNK_LINE_CHARACTERS = 700  # Leave room below the engine's file-line buffer.
PLAYBACK_STYLES = (0, 1, 2)
ACTION_MARKER = "FPS LIVE ACTION\t"
DETAILED_MARKER = "FPS DETAILED HUD\t"
COMPACT_MARKER = "FPS COMPACT HUD\t"


def parse_options():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", help="Run ID, clip:<id>, or an exported JSON file")
    parser.add_argument("label", help="Short label for the private evidence directory")
    parser.add_argument("--binary", default="/workspace/cod4x-server/bin/cod4x18_dedrun")
    options = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9_-]+", options.label):
        parser.error("The label must contain lowercase letters, numbers, underscores or hyphens")
    binary_input = options.binary
    if binary_input.startswith("/workspace/"):
        binary_input = ROOT / binary_input.removeprefix("/workspace/")
    try:
        options.engine = workspace_file(binary_input)
        options.binary = workspace_path(options.engine)
    except ValueError as error:
        parser.error(str(error))
    options.baseline = False
    options.scripts = ROOT / "server-gsc"
    options.completion_marker = "FPS LIVE TRACE COMPLETE"
    return options


def export_recording(recording_id, *, is_clip):
    """Read only the requested recording from this installation's selected database."""
    table = "demoClipChunks" if is_clip else "demoChunks"
    id_column = "clipID" if is_clip else "runID"
    query = f"""
        SELECT chunkNum, HEX(payload)
        FROM {table}
        WHERE {id_column} = {recording_id}
        ORDER BY chunkNum;
    """
    result = subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            database_container(),
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4',
        ],
        input=query,
        text=True,
        capture_output=True,
        timeout=30,
    )
    if result.returncode:
        # Do not echo database command output, which may contain installation details.
        raise RuntimeError("Read-only demo export failed")
    recording = {
        "runID": recording_id,
        "chunks": [line.split("\t") for line in result.stdout.splitlines()],
        "style": 0 if is_clip else 2,
    }
    if is_clip:
        recording["clipID"] = recording_id
    return recording


def positive_native_id(value):
    if isinstance(value, bool) or not re.fullmatch(r"[0-9]+", str(value)):
        raise ValueError("Recording IDs must be positive integers")
    recording_id = int(value)
    if not 1 <= recording_id <= MAX_NATIVE_ID:
        raise ValueError("Recording ID exceeds the native signed integer range")
    return recording_id


def validate_recording(recording):
    """Check the complete export before writing files or starting a replay."""
    if not isinstance(recording, dict):
        raise ValueError("The recording must be a JSON object")
    recording_id = positive_native_id(recording.get("runID"))
    style = recording.get("style", 2)
    if type(style) is not int or style not in PLAYBACK_STYLES:
        raise ValueError("Playback style must be 0 (raw), 1 (speedrun), or 2 (walkthrough)")
    chunks = recording.get("chunks")
    if not isinstance(chunks, list) or not chunks:
        raise ValueError("The recording must contain at least one chunk")
    validated_chunks = []
    for expected_number, chunk in enumerate(chunks):
        if not isinstance(chunk, (list, tuple)) or len(chunk) != 2:
            raise ValueError("Each chunk must contain its number and hexadecimal payload")
        chunk_number, payload = chunk
        if str(chunk_number) != str(expected_number):
            raise ValueError("Chunks must be consecutive and ordered from zero")
        if (
            not isinstance(payload, str)
            or not re.fullmatch(r"(?:[0-9a-fA-F]{2})+", payload)
            or len(payload) > MAX_PACKED_CHUNK_BYTES * 2
        ):
            raise ValueError(f"Chunk {expected_number} has an invalid hexadecimal payload")
        validated_chunks.append([expected_number, payload])
    validated = {"runID": recording_id, "style": style, "chunks": validated_chunks}
    if "clipID" in recording:
        validated["clipID"] = positive_native_id(recording["clipID"])
    return validated


def read_recording(source):
    is_clip = source.startswith("clip:")
    if source.isdigit() or is_clip:
        recording_id = positive_native_id(source[5:] if is_clip else source)
        recording = export_recording(recording_id, is_clip=is_clip)
    else:
        recording = json.loads(Path(source).read_text())
    return validate_recording(recording)


def install_trace_hooks(mod):
    """Observe completed actions at the function boundary, independent of body layout."""
    hud = mod / "opencj/huds/hudfpshistory.gsc"
    original = hud.read_text()
    source, action_count = re.subn(r"(?m)^_action(?=\s*\()", "_traceOriginalAction", original)
    source, clock_count = re.subn(r"\bgetTime\s*\(\s*\)", "level.fpsTraceTime", source)
    if action_count != 1 or clock_count == 0:
        raise RuntimeError("The FPS history action/clock observation boundary was not found")
    source += r"""
// Trace only the private fixture copy; production callbacks remain unchanged.
_action(kind, fps, switched, inputTime, firstFPSChange)
{
    self _traceOriginalAction(kind, fps, switched, inputTime, firstFPSChange);
    event = self.fpsHistoryEvents[self.fpsHistoryEvents.size - 1];
    printf("FPS LIVE ACTION\t" + level.fpsTraceFrame + "\t" + level.fpsTraceTime +
           "\t" + kind + "\t" + event.keys + "\t" + fps + "\t" + switched + "\n");
}
"""
    hud.write_text(source)
    return hashlib.sha256(original.encode()).hexdigest()


def prepare_trace(options, recording, home):
    """Keep the export private and feed payloads as data, never generated GSC source."""
    home.mkdir(parents=True, mode=0o700)
    recording_path = home / "recording.json"
    recording_path.write_text(json.dumps(recording) + "\n")
    recording_path.chmod(0o600)
    template = (ROOT / "dev-tools/tests/fps-demo-trace.gsc").read_text()
    options.fixture = home / "trace.gsc"
    options.fixture.write_text(
        template.replace("TRACE_RECORDING_ID", str(recording["runID"])).replace(
            "TRACE_PLAYBACK_STYLE", str(recording["style"])
        )
    )
    source_hashes, _ = prepare_fixture(options, home)
    mod = home / "mods/opencj"
    source_hash = install_trace_hooks(mod)
    with (mod / "trace-chunks.txt").open("w") as output:
        for _, payload in recording["chunks"]:
            for start in range(0, len(payload), CHUNK_LINE_CHARACTERS):
                output.write(payload[start : start + CHUNK_LINE_CHARACTERS] + "\n")
            output.write("END\n")
    return source_hashes, source_hash


def parse_trace(log):
    """Decode stable output fields, preserving the original trace JSON interface."""
    actions = []
    detailed = []
    compact = []
    for line in log.splitlines():
        if ACTION_MARKER in line:
            fields = line[line.index(ACTION_MARKER) :].split("\t")
            _, frame, elapsed_ms, kind, keys, fps, switched = fields
            actions.append(
                {
                    "frame": int(frame),
                    "ms": int(elapsed_ms),
                    "kind": kind,
                    "keys": keys,
                    "fps": fps,
                    "switch": int(switched),
                }
            )
        for marker, changes in ((DETAILED_MARKER, detailed), (COMPACT_MARKER, compact)):
            if marker in line:
                _, frame, elapsed_ms, text = line[line.index(marker) :].split("\t", 3)
                changes.append({"frame": int(frame), "ms": int(elapsed_ms), "text": text})
    return actions, detailed, compact


def main():
    options = parse_options()
    recording = read_recording(options.recording)
    home = (
        ROOT / "dev-tools/local" / ("fps-live-trace-" + options.label + "-" + uuid.uuid4().hex[:8])
    )
    source_hashes, source_hash = prepare_trace(options, recording, home)
    run_prepared_fixture(options, home, "mp_killhouse", source_hashes)
    actions, detailed, compact = parse_trace((home / "console.log").read_text())
    result = {
        "runID": recording["runID"],
        "label": options.label,
        "sourceSha256": source_hash,
        "actions": actions,
        "detailedChanges": detailed,
        "compactChanges": compact,
    }
    trace_path = home / "trace.json"
    trace_path.write_text(json.dumps(result, indent=2) + "\n")
    print(
        json.dumps(
            {
                "path": str(trace_path),
                "actions": len(actions),
                "detailedChanges": len(detailed),
                "switches": sum(action["switch"] for action in actions),
                "rawNeutralActions": sum(
                    action["keys"] == "None" and action["kind"] == "move" for action in actions
                ),
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
