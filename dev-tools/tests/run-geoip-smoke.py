"""Exercise country/flag behavior using selected source scripts and compiled assets."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import uuid

from compose_environment import workspace_file, workspace_path
from gsc_fixture import prepare_fixture, run_prepared_fixture

ROOT = Path(__file__).resolve().parents[2]
COMPILED_ASSETS = ("mod.ff", "z_opencj.iwd")


def parse_options():
    """Validate all operator inputs before copying assets or creating a fixture."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("maps", nargs="*", default=["mp_killhouse"])
    parser.add_argument(
        "--asset-dir",
        type=Path,
        required=True,
        help="Matching compiled mod.ff and z_opencj.iwd directory",
    )
    parser.add_argument(
        "--scripts",
        type=Path,
        default=ROOT / "server-gsc",
        help="Complete script tree containing opencj and maps; defaults to working source",
    )
    options = parser.parse_args()
    options.asset_dir = options.asset_dir.expanduser().resolve()
    options.scripts = options.scripts.expanduser().resolve()
    for asset_name in COMPILED_ASSETS:
        if not (options.asset_dir / asset_name).is_file():
            parser.error("--asset-dir must contain mod.ff and z_opencj.iwd")
    for folder in ("opencj", "maps"):
        if not (options.scripts / folder).is_dir():
            parser.error("--scripts must contain opencj and maps directories")
    for map_name in options.maps:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", map_name):
            parser.error("Map names must contain only letters, numbers, underscores or hyphens")
    try:
        options.engine = workspace_file(ROOT / "cod4x-server/bin/cod4x18_dedrun")
    except ValueError as error:
        parser.error(str(error))
    options.binary = workspace_path(options.engine)
    options.fixture = ROOT / "dev-tools/tests/geoip.gsc"
    options.baseline = False
    options.completion_marker = "GEOIP SELFTEST COMPLETE"
    return options


def copy_selected_assets(options, home):
    """Keep a private snapshot of the exact compiled inputs exercised by the test."""
    mod = home / "mods/opencj"
    asset_hashes = {}
    for asset_name in COMPILED_ASSETS:
        target = mod / asset_name
        # prepare_fixture creates these links in this run's new private directory.
        # Replace the links, never their shared targets.
        target.unlink()
        shutil.copy2(options.asset_dir / asset_name, target)
        asset_hashes[asset_name] = hashlib.sha256(target.read_bytes()).hexdigest()
    binary = home / "cod4x18_geoip_smoke"
    shutil.copy2(options.engine, binary)
    binary.chmod(0o755)
    return binary, asset_hashes


def main():
    options = parse_options()
    for map_name in options.maps:
        home = ROOT / "dev-tools/local" / ("geoip-smoke-" + uuid.uuid4().hex[:8])
        source_hashes, _ = prepare_fixture(options, home, retained_callbacks=())
        binary, asset_hashes = copy_selected_assets(options, home)
        fixture_options = argparse.Namespace(**vars(options))
        fixture_options.engine = binary
        fixture_options.binary = workspace_path(binary)
        report = run_prepared_fixture(
            fixture_options,
            home,
            map_name,
            source_hashes,
            timeout_seconds=50,
            extra_settings={"sv_maxclients": "1", "developer_script": "1"},
        )
        report["assetHashes"] = asset_hashes
        (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
