"""Run the wall geometry probe through the shared isolated GSC runner."""

import json
import uuid

from gsc_fixture import (
    ROOT,
    create_parser,
    prepare_fixture,
    run_prepared_fixture,
    validate_options,
)


def parse_options(arguments=None):
    parser = create_parser(
        default_fixture=ROOT / "dev-tools/tests/sticky-walls.gsc",
        completion_marker="STICKY SELFTEST COMPLETE",
        default_maps=("mp_galaxy",),
    )
    parser.add_argument("--recovery", type=int, choices=(0, 1), default=1)
    parser.add_argument(
        "--print-native",
        action="store_true",
        help="Print the complete native scenario results",
    )
    return validate_options(parser, parser.parse_args(arguments))


def run_probe(options, map_name, *, home=None):
    """Keep engine logs and hashes with this run; shared cleanup owns its container."""
    if home is None:
        home = ROOT / "dev-tools/local" / ("sticky-probe-" + uuid.uuid4().hex[:8])
    source_hashes, _ = prepare_fixture(options, home, retained_callbacks=())
    report = run_prepared_fixture(
        options,
        home,
        map_name,
        source_hashes,
        extra_settings={
            "sv_maxclients": "1",
            "opencj_stickyWalls": str(options.recovery),
        },
    )
    log = (home / "console.log").read_text()
    if options.print_native:
        for line in log.splitlines():
            if "NATIVE " in line or "SUPPORT FACE" in line:
                print(line)
    report["recovery"] = options.recovery
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    return log
