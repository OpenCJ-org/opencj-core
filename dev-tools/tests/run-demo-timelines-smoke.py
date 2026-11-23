"""Run timeline and selection scenarios through the shared isolated GSC runner."""

from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def main():
    command = [
        sys.executable,
        "-B",
        str(ROOT / "dev-tools/tests/run-demo-viewing-24.py"),
        *sys.argv[1:],
        "--fixture",
        str(ROOT / "dev-tools/tests/demo-timelines.gsc"),
        "--completion-marker",
        "DEMO TIMELINE COMPLETE",
    ]
    return subprocess.run(command, cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
