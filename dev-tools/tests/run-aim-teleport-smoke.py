"""Exercise aim teleport on mp_dark using an isolated engine and synthetic player."""

import argparse
from pathlib import Path
import subprocess
import sys

from compose_environment import workspace_path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "map",
        nargs="?",
        default="mp_dark",
        choices=["mp_dark"],
        help="The fixture uses measured platform and wall positions on mp_dark.",
    )
    parser.add_argument(
        "--engine",
        type=Path,
        default=ROOT / "cod4x-server/bin/cod4x18_dedrun",
        help="Existing candidate engine inside this checkout.",
    )
    options = parser.parse_args()
    try:
        engine = workspace_path(options.engine)
    except ValueError as error:
        parser.error(str(error))
    # The shared runner owns the temporary server, script copy and cleanup.
    command = [
        sys.executable,
        "-B",
        str(ROOT / "dev-tools/tests/run-demo-viewing-24.py"),
        options.map,
        "--binary",
        engine,
        "--fixture",
        str(ROOT / "dev-tools/tests/aim-teleport.gsc"),
        "--completion-marker",
        "TELEPORT SELFTEST COMPLETE",
    ]
    return subprocess.run(command, cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
