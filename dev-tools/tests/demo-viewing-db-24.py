"""Verify concurrent clip-view counting in a fresh, network-isolated database."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import secrets
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL

DATABASE_NAME = "openCJ_cod4"
STARTUP_TIMEOUT_SECONDS = 90


def start_database(container_name, environment_file):
    subprocess.run(
        [
            "docker",
            "run",
            "-d",
            "--name",
            container_name,
            "--network",
            "none",
            "--memory",
            "1024m",
            "--env-file",
            str(environment_file),
            "mysql:8.0",
            "--log-bin-trust-function-creators=1",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        try:
            with MySQL(container_name, DATABASE_NAME) as database:
                database.query("SELECT 1;")
            return
        except RuntimeError:
            time.sleep(1)
    raise RuntimeError("Disposable database did not become ready")


def seed_clips(container_name):
    """Use real schema/grants, with synthetic clips and a runtime account that cannot write tables."""
    subprocess.run(
        [
            sys.executable,
            "-B",
            str(ROOT / "dev-tools/scripts/bootstrap-db.py"),
            "--container",
            container_name,
            "--confirm-empty",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    with MySQL(container_name, DATABASE_NAME) as database:
        database.query("""
            INSERT INTO mapids(mapID,mapname) VALUES(810001,'viewing_fixture');
            INSERT INTO playerInformation(playerID,playerName)
                VALUES(1,'Fixture A'),(2,'Fixture B'),(3,'Fixture C');
            INSERT INTO demoClipSessions(sessionID) VALUES('session-a'),('session-b');
            INSERT INTO demoClips(
                clipID,uploadToken,mapID,playerID,description,scopeKey,sessionID,slot,
                originX,originY,originZ,frameCount)
            VALUES
                (1,'upload-a',810001,1,'Original clip','permanent',NULL,1,0,0,0,20),
                (2,'upload-b',810001,1,'Unpublished','permanent',NULL,2,0,0,0,20);
            UPDATE demoClips SET ready=1 WHERE clipID=1;
        """)
        database.query("REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'opencj'@'%';")
        database.query("""
            GRANT SELECT ON openCJ_cod4.* TO 'opencj'@'%';
            GRANT EXECUTE ON PROCEDURE openCJ_cod4.countClipView TO 'opencj'@'%';
        """)


def count_view(container_name, *, viewer_id=2, clip_id=1, session_id="session-a"):
    with MySQL(container_name, DATABASE_NAME, runtime=True) as database:
        database.query(f"CALL countClipView('{session_id}',{clip_id},{viewer_id});")


def concurrent_views(container_name, viewer_ids):
    """Use independent runtime connections so duplicate-receipt contention is real."""
    with ThreadPoolExecutor(max_workers=8) as connections:
        pending = [
            connections.submit(count_view, container_name, viewer_id=viewer_id)
            for viewer_id in viewer_ids
        ]
        for completed in pending:
            completed.result()


def expect_equal(checks, actual, expected, description):
    assert actual == expected, (description, {"expected": expected, "actual": actual})
    checks.append(description)
    print("VIEWING DB PASS " + description, flush=True)


def verify_views(container_name):
    checks = []
    concurrent_views(container_name, [2] * 32)
    with MySQL(container_name, DATABASE_NAME) as database:
        expect_equal(
            checks,
            database.query("SELECT viewCount FROM demoClips WHERE clipID=1;"),
            "1",
            "32 simultaneous duplicate calls count once",
        )

    count_view(container_name, viewer_id=1)
    count_view(container_name, clip_id=2)
    count_view(container_name, clip_id=999)
    count_view(container_name, session_id="missing")
    with MySQL(container_name, DATABASE_NAME) as database:
        expect_equal(
            checks,
            database.query("SELECT viewCount FROM demoClips WHERE clipID=1;"),
            "1",
            "owner, unpublished, missing clip and missing session do not count",
        )

    concurrent_views(container_name, [2, 3] * 16)
    count_view(container_name, session_id="session-b")
    with MySQL(container_name, DATABASE_NAME) as database:
        expect_equal(
            checks,
            database.query("SELECT viewCount FROM demoClips WHERE clipID=1;"),
            "3",
            "different viewer and new server session each count",
        )
        expect_equal(
            checks,
            database.query("SELECT COUNT(*) FROM demoClipViews;"),
            "3",
            "one receipt per accepted view",
        )

        database.query("DELETE FROM demoClipSessions WHERE sessionID='session-a';")
        receipt_count = database.query("SELECT COUNT(*) FROM demoClipViews;")
        total_views = database.query("SELECT viewCount FROM demoClips WHERE clipID=1;")
        expect_equal(
            checks,
            (receipt_count, total_views),
            ("1", "3"),
            "session expiry removes receipts and retains total views",
        )
        database.query("DELETE FROM demoClips WHERE clipID=1;")
        expect_equal(
            checks,
            database.query("SELECT COUNT(*) FROM demoClipViews;"),
            "0",
            "clip deletion removes its receipts",
        )
    return checks


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    tag = "demo-viewing-db-24-" + uuid.uuid4().hex[:8]
    evidence_dir = ROOT / "dev-tools/local" / tag
    evidence_dir.mkdir(mode=0o700)
    container_name = "opencj-" + tag
    environment_file = evidence_dir / "mysql.env"
    password = secrets.token_hex(24)
    environment_file.write_text(
        "MYSQL_ROOT_PASSWORD="
        + password
        + "\nMYSQL_DATABASE="
        + DATABASE_NAME
        + "\nMYSQL_USER=opencj\nMYSQL_PASSWORD="
        + password
        + "\n"
    )
    environment_file.chmod(0o600)
    try:
        start_database(container_name, environment_file)
        seed_clips(container_name)
        checks = verify_views(container_name)
        (evidence_dir / "result.json").write_text(
            json.dumps({"liveDatabaseWrites": False, "checks": checks}, indent=2) + "\n"
        )
        print(
            "VIEWING DB COMPLETE checks="
            + str(len(checks))
            + " failures=0\nEvidence: "
            + str(evidence_dir),
            flush=True,
        )
    finally:
        subprocess.run(
            ["docker", "rm", "-f", "-v", container_name], capture_output=True
        )
        environment_file.unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
