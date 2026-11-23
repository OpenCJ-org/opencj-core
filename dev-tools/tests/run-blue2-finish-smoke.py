"""Exercise Blue2 finish flags and disabled weapon pickups with isolated clients."""

from gsc_fixture import ROOT, parse_options, run_fixture


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/blue2-finish.gsc",
        completion_marker="BLUE2 TEST COMPLETE",
        default_maps=("mp_blue2",),
    )
    if options.maps != ["mp_blue2"]:
        raise SystemExit("This fixture requires mp_blue2 and its map triggers.")
    run_fixture(options, "mp_blue2")


if __name__ == "__main__":
    main()
