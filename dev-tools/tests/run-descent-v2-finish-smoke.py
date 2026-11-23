"""Exercise Descent finish eligibility with isolated clients."""

from gsc_fixture import ROOT, parse_options, run_fixture


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/descent-v2-finish.gsc",
        completion_marker="DESCENT TEST COMPLETE",
        default_maps=("mp_descent_v2",),
    )
    if options.maps != ["mp_descent_v2"]:
        raise SystemExit("This fixture requires mp_descent_v2 and its map triggers.")
    run_fixture(options, "mp_descent_v2")


if __name__ == "__main__":
    main()
