"""Exercise route publication and migration against synthetic records only."""

import json
from pathlib import Path

import gsc_fixture
from isolated_database import IsolatedDatabase

ROOT = Path(__file__).resolve().parents[2]


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
            INSERT INTO playerInformation(playerID,playerName) VALUES(1,'RouteFixture');
            """,
            fixture.database,
        )
        source_hashes, _ = gsc_fixture.prepare_fixture(options, fixture.home, retained_callbacks=())
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
