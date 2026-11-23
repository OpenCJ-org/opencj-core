"""Exercise finish-sound result selection in an isolated GSC VM."""

from pathlib import Path

from gsc_fixture import parse_options, run_fixture

ROOT = Path(__file__).resolve().parents[2]


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/finish-sounds.gsc",
        completion_marker="FINISH SOUND SELFTEST COMPLETE",
    )
    for map_name in options.maps:
        run_fixture(options, map_name)


if __name__ == "__main__":
    main()
