"""Check production download settings before clients and after a real map restart.

Only the isolated server's client defaults change; file hosting remains disabled.
"""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from textwrap import dedent
import uuid

import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
GIT_TIMEOUT_SECONDS = 30


def historical_cvars(revision):
    """Accept a commit, then find the script before or after the core import."""
    commit = subprocess.check_output(
        ["git", "rev-parse", "--verify", "--end-of-options", revision + "^{commit}"],
        cwd=ROOT,
        text=True,
        timeout=GIT_TIMEOUT_SECONDS,
    ).strip()
    for path in ("server-gsc/opencj/cvars.gsc", "opencj/cvars.gsc"):
        object_name = commit + ":" + path
        exists = subprocess.run(
            ["git", "cat-file", "-e", object_name],
            cwd=ROOT,
            capture_output=True,
            timeout=GIT_TIMEOUT_SECONDS,
        )
        if exists.returncode == 0:
            source = subprocess.check_output(
                ["git", "show", object_name], cwd=ROOT, text=True, timeout=GIT_TIMEOUT_SECONDS
            )
            return commit, source
    raise ValueError("The selected revision does not contain the cvar script.")


def parse_options():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cvars-revision", help="Optional Git commit for a negative baseline")
    parser.add_argument("--binary", default="cod4x-server/bin/cod4x18_dedrun")
    parser.add_argument("--scripts", type=Path, default=ROOT / "server-gsc")
    options = parser.parse_args()
    options.maps = ["mp_killhouse"]
    options.fixture = ROOT / "dev-tools/tests/download-cvars.gsc"
    options.completion_marker = "DOWNLOAD TEST COMPLETE"
    options.baseline = False
    return gsc_fixture.validate_options(parser, options)


def install_startup_callbacks(home):
    """Run the real cvar initializer before the fixture, with no account/DB callbacks."""
    mod = home / "mods/opencj"
    (mod / "maps/mp/gametypes/cj.gsc").write_text(dedent(r"""
        main()
        {
            level.script = getCvar("mapname");
        }
    """).lstrip())
    callbacks = dedent(r"""
        CodeCallback_StartGameType()
        {
            level.downloadConnections = 0;
            openCJ\cvars::onInit();
            level.downloadInitRan = true;
            thread openCJ\platformTest::main();
        }

        CodeCallback_PlayerConnect()
        {
            level.downloadConnections++;
        }
    """).lstrip()
    for name in ("PlayerDisconnect", "PlayerDamage", "PlayerKilled", "PlayerLastStand"):
        callbacks += "\nCodeCallback_" + name + "()\n{\n}\n"
    (mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(callbacks)
    (mod / "maps/mp/mp_killhouse.gsc").write_text("main()\n{\n}\n")


def main():
    options = parse_options()
    cvars_commit = None
    cvars_source = None
    if options.cvars_revision:
        cvars_commit, cvars_source = historical_cvars(options.cvars_revision)

    home = ROOT / "dev-tools/local" / ("download-cvars-" + uuid.uuid4().hex[:8])
    source_hashes, _ = gsc_fixture.prepare_fixture(options, home, retained_callbacks=())
    install_startup_callbacks(home)
    cvars_path = home / "mods/opencj/opencj/cvars.gsc"
    if cvars_source is not None:
        cvars_path.write_text(cvars_source)
    selection = {
        "cvarsRevision": cvars_commit,
        "cvarsSha256": hashlib.sha256(cvars_path.read_bytes()).hexdigest(),
    }
    (home / "source-selection.json").write_text(json.dumps(selection, indent=2) + "\n")

    report = gsc_fixture.run_prepared_fixture(
        options,
        home,
        "mp_killhouse",
        source_hashes,
        extra_completion_markers=("DOWNLOAD TEST STAGE COMPLETE 0",),
        extra_settings={
            "sv_maxclients": "1",
            "cl_allowDownload": "0",
            "cl_wwwDownload": "0",
            "sv_allowDownload": "0",
            "sv_wwwDownload": "0",
            "sv_wwwBaseURL": "",
        },
    )
    checks = sum(line.startswith("DOWNLOAD TEST 1:") for line in report["summary"])
    if checks == 0:
        raise RuntimeError("Download fixture completed without executing a check.")
    report.update(
        checks=checks,
        **selection,
        coverage="Production initialization/systeminfo before clients and after map_restart.",
    )
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS:", checks, "checks across both initializations", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
