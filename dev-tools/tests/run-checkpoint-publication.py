"""Exercise route publication and migration against synthetic records only."""

import json
from pathlib import Path
import re

import gsc_fixture
from isolated_database import IsolatedDatabase

ROOT = Path(__file__).resolve().parents[2]


def install_commit_observer(home, script_name):
    """Hide a real COMMIT reply only in the fixture copy, leaving its SQL effects intact."""
    path = home / "mods/opencj/opencj" / script_name
    source, count = re.subn(
        r"openCJ\\mySQL::mysqlSyncQuery\s*\(",
        lambda match: r"openCJ\platformTest::publicationQuery(",
        path.read_text(),
    )
    if count == 0:
        raise RuntimeError("Publication SQL boundary was not found")
    path.write_text(source)


def install_network_navigation_observers(home):
    """Keep real files/SQL while replacing HUD and player-navigation side effects."""
    path = home / "mods/opencj/opencj/checkpointnetwork.gsc"
    source = path.read_text()
    replacements = (
        (r"openCJ\\checkpointCreation::_close\s*\(", r"openCJ\platformTest::closeEditor("),
        (r"openCJ\\checkpointCreation::_start\s*\(", r"openCJ\platformTest::openEditor("),
        (r"openCJ\\checkpointPublish::activate\s*\(", r"openCJ\platformTest::recordActivation("),
    )
    for pattern, replacement in replacements:
        source, count = re.subn(pattern, lambda match: replacement, source)
        if count == 0:
            raise RuntimeError("Network navigation boundary was not found: " + pattern)
    path.write_text(source)


def install_network_file_observers(home):
    """Inject an open failure for one selected fixture path; delegate every other file operation."""
    for script_name in ("checkpointcreation.gsc", "checkpointnetwork.gsc"):
        path = home / "mods/opencj/opencj" / script_name
        source, count = re.subn(
            r"\bFS_FOpen\s*\(",
            lambda match: r"openCJ\platformTest::draftFileOpen(",
            path.read_text(),
        )
        if count == 0:
            raise RuntimeError("Draft file boundary was not found: " + script_name)
        path.write_text(source)


def main():
    options = gsc_fixture.parse_options(
        default_fixture=ROOT / "dev-tools/tests/checkpoint-publication.gsc",
        completion_marker="PUBLICATION SELFTEST COMPLETE",
    )
    if options.maps != ["mp_killhouse"]:
        raise ValueError("Publication scenarios require their mp_killhouse fixture")
    fixture = IsolatedDatabase("checkpoint-publish")
    fixture.home.mkdir(mode=0o700)
    try:
        fixture.prepare_database()
        fixture.query_database(
            """
            INSERT INTO mapids(mapID,mapname) VALUES(1,'mp_killhouse');
            INSERT INTO playerInformation(playerID,playerName)
            VALUES(1,'RouteFixture'),(2,'EditorFixture');
            """,
            fixture.database,
        )
        source_hashes, _ = gsc_fixture.prepare_fixture(options, fixture.home, retained_callbacks=())
        if options.fixture.name == "checkpoint-publication.gsc":
            install_commit_observer(fixture.home, "checkpointpublish.gsc")
        elif options.fixture.name == "checkpoint-network.gsc":
            install_commit_observer(fixture.home, "checkpointnetwork.gsc")
            install_network_navigation_observers(fixture.home)
            install_network_file_observers(fixture.home)
        fixture.write_engine_config()
        result = gsc_fixture.run_prepared_fixture(
            options,
            fixture.home,
            "mp_killhouse",
            source_hashes,
            config_files=(fixture.config.name,),
        )
        (fixture.home / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    finally:
        fixture.cleanup()
        print("Evidence: " + str(fixture.home), flush=True)


if __name__ == "__main__":
    main()
