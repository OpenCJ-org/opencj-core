"""Run measurement regressions in an isolated server without gameplay SQL."""

from pathlib import Path

from gsc_fixture import parse_options, run_fixture


def main():
    options = parse_options(
        default_fixture=Path(__file__).with_name("measure.gsc"),
        completion_marker="MEASURE SELFTEST COMPLETE",
        default_maps=("mp_killhouse",),
    )
    for map_name in options.maps:
        run_fixture(options, map_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
