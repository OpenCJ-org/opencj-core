"""Run scoreboard connection lifecycle scenarios in an isolated GSC VM."""

from pathlib import Path
import re
import uuid

from gsc_fixture import parse_options, prepare_fixture, run_prepared_fixture

ROOT = Path(__file__).resolve().parents[2]


def retain_scoreboard_connection_hook(mod):
    """Exercise the real connection hook without starting unrelated player services."""
    callback = mod / "maps/mp/gametypes/_callbacksetup.gsc"
    source, count = re.subn(
        r"(?m)^CodeCallback_PlayerConnect\s*\([^)]*\)\s*\{",
        lambda match: match.group(0) + "\n    self openCJ\\scoreboard::onPlayerConnecting();",
        callback.read_text(),
    )
    if count != 1:
        raise RuntimeError("Expected one engine player-connect callback")
    callback.write_text(source)


def main():
    options = parse_options(
        default_fixture=ROOT / "dev-tools/tests/scoreboard-connecting.gsc",
        completion_marker="CONNECTING SELFTEST COMPLETE",
    )
    for map_name in options.maps:
        home = ROOT / "dev-tools/local" / ("scoreboard-connecting-" + uuid.uuid4().hex[:8])
        source_hashes, _ = prepare_fixture(options, home, retained_callbacks=())
        retain_scoreboard_connection_hook(home / "mods/opencj")
        run_prepared_fixture(options, home, map_name, source_hashes)


if __name__ == "__main__":
    main()
