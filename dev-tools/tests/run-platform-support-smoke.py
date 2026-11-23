"""Run collision fixtures in isolated servers without gameplay database callbacks."""

from gsc_fixture import ROOT, create_parser, run_fixture, validate_options

BRUSH_MAPS = (
    "mp_to_the_moon",
    "mp_mystic_v3",
    "mp_mystic_v2",
    "mp_galaxy",
    "mp_dark",
    "mp_futile_fixed",
    "mp_blue2",
)
VARIANTS = {
    "moving": ("platform-moving.gsc", ("mp_qube",)),
    "alternatives": ("checkpoint-alternatives.gsc", ("mp_dark",)),
    "height": ("checkpoint-height.gsc", ("mp_dark",)),
    "insert": ("checkpoint-insert.gsc", ("mp_dark",)),
}


def main():
    parser = create_parser(
        default_fixture=ROOT / "dev-tools/tests/platform-brushes.gsc",
        completion_marker="BRUSH SELFTEST COMPLETE",
        default_maps=(),
    )
    variants = parser.add_mutually_exclusive_group()
    for variant in VARIANTS:
        variants.add_argument(
            "--" + variant, dest="variant", action="store_const", const=variant
        )
    options = parser.parse_args()
    default_maps = BRUSH_MAPS
    if options.variant is not None:
        fixture_name, default_maps = VARIANTS[options.variant]
        options.fixture = ROOT / "dev-tools/tests" / fixture_name
    if not options.maps:
        options.maps = list(default_maps)
    options = validate_options(parser, options)

    for map_name in options.maps:
        run_fixture(options, map_name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
