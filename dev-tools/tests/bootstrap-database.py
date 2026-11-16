#!/usr/bin/env python3
"""Test fresh database setup using only a disposable, network-isolated MySQL."""
from pathlib import Path
import json
import os
import secrets
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL


def main():
    os.umask(0o077)
    name = "opencj-core-bootstrap-" + uuid.uuid4().hex[:8]
    evidence = ROOT / "dev-tools/local" / name
    evidence.mkdir(parents=True)
    credentials = evidence / "mysql.env"
    credentials.write_text(
        "MYSQL_ROOT_PASSWORD=" + secrets.token_hex(24) + "\n"
        "MYSQL_DATABASE=openCJ_cod4\nMYSQL_USER=opencj\n"
        "MYSQL_PASSWORD=" + secrets.token_hex(24) + "\n"
    )
    started = False
    try:
        subprocess.run([
            "docker", "run", "-d", "--name", name, "--network", "none",
            "--memory", "768m", "--env-file", str(credentials), "mysql:8.0",
            "--log-bin-trust-function-creators=1",
        ], check=True, capture_output=True)
        started = True
        ping = ["docker", "exec", name, "sh", "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h127.0.0.1 -u root -e "SELECT 1"']
        for attempt in range(90):
            if subprocess.run(ping, capture_output=True).returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Disposable database did not become ready")
        command = [sys.executable, str(ROOT / "dev-tools/scripts/bootstrap-db.py"),
                   "--container", name, "--confirm-empty"]
        first = subprocess.run(command, capture_output=True, text=True)
        (evidence / "bootstrap.log").write_text(first.stdout + first.stderr)
        if first.returncode:
            raise RuntimeError("Fresh bootstrap failed; inspect " + str(evidence / "bootstrap.log"))
        with MySQL(name, "openCJ_cod4") as db:
            migration_count = int(db.query("SELECT COUNT(*) FROM schemaMigrations WHERE state='applied';"))
            expected = len(list((ROOT / "server-db/migrations").glob("[0-9][0-9][0-9]-*.sql")))
            assert migration_count == expected, (migration_count, expected)
            assert db.query("SELECT COUNT(*) FROM playerInformation;") == "0"
            db.query("CREATE TABLE migrationSentinel(value INT NOT NULL); INSERT INTO migrationSentinel VALUES(42);")
        repeated = subprocess.run(command, capture_output=True, text=True)
        assert repeated.returncode != 0 and "requires an empty database" in repeated.stderr
        with MySQL(name, "openCJ_cod4") as db:
            assert db.query("SELECT value FROM migrationSentinel;") == "42"
            assert int(db.query("SELECT COUNT(*) FROM schemaMigrations;")) == expected
        with MySQL(name, "openCJ_cod4", runtime=True) as db:
            assert db.query("SELECT COUNT(*) FROM playerInformation;") == "0"
            try:
                db.query("DROP TABLE migrationSentinel;")
            except RuntimeError as error:
                assert "denied" in str(error).lower(), str(error)
            else:
                raise AssertionError("Gameplay account could drop a table")
        source = evidence / "synthetic-backup-source.txt"
        source.write_text("Synthetic backup fixture; no private installation data.\n")
        backup_output = evidence / "backups"
        backup_command = [sys.executable, str(ROOT / "dev-tools/scripts/backup.py"),
                          "--container", name, "--database", "openCJ_cod4",
                          "--source", str(source), "--output-dir", str(backup_output)]
        backed_up = subprocess.run(backup_command, capture_output=True, text=True)
        (evidence / "backup-test.log").write_text(backed_up.stdout + backed_up.stderr)
        if backed_up.returncode:
            raise RuntimeError("Synthetic backup/restore check failed; inspect " + str(evidence / "backup-test.log"))
        snapshots = list(backup_output.iterdir())
        assert len(snapshots) == 1
        assert (snapshots[0] / "restore-verification.txt").is_file()
        result = {"passed":True,"migrations":expected,"repeat_refused":True,
                  "existing_data_preserved":True,"runtime_ddl_denied":True,"synthetic_backup_restored":True}
        (evidence / "result.json").write_text(json.dumps(result,indent=2)+"\n")
        print(json.dumps(result), flush=True)
        print("Evidence: " + str(evidence), flush=True)
    finally:
        if started:
            subprocess.run(["docker", "rm", "-f", "-v", name], check=True, capture_output=True)
        credentials.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
