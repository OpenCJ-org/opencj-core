"""Run checkpoint draft listing on an isolated server without gameplay database callbacks."""

from gsc_fixture import ROOT, parse_options, run_fixture


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/checkpoint-list.gsc",
        completion_marker="LIST SELFTEST COMPLETE",
        default_maps=("mp_dark",),
    )
    for map_name in options.maps:
        run_fixture(options, map_name)


if __name__ == "__main__":
    main()
