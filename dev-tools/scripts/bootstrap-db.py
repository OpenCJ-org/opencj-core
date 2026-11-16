#!/usr/bin/env python3
"""Initialize an empty CoD4 development database from the versioned schema."""

import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL
import migrate
import runtime_access

DATABASE = "openCJ_cod4"


def check(db):
    migrations = migrate.files()
    rows = migrate.ledger(db)
    migrate.validate(rows, migrations)
    if set(rows) != set(migrations):
        raise RuntimeError(
            "Database migrations are incomplete; bootstrap an empty database or follow the upgrade procedure."
        )
    return len(rows)


def bootstrap(db):
    """Refuse existing data; a partial failure requires deliberate recovery."""
    occupied = db.query(
        "SELECT (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE())"
        "+(SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema=DATABASE())"
        "+(SELECT COUNT(*) FROM information_schema.events WHERE event_schema=DATABASE());"
    )
    if occupied != "0":
        raise RuntimeError("Bootstrap requires an empty database; existing data was preserved.")
    if db.query("SELECT COUNT(*) FROM mysql.user WHERE User='opencj' AND Host='%';") != "1":
        raise RuntimeError(
            "Create the opencj runtime account through the development Compose setup first."
        )
    db.query((ROOT / "server-db/exports/openCJ_cod4.sql").read_text())
    # The historical schema export already includes this later addition.
    # Only this freshly imported, empty schema is normalized before replaying
    # migration 008. Existing databases never enter this bootstrap path.
    db.query("ALTER TABLE checkpoints DROP COLUMN allowSave;")
    db.query(migrate.LEDGER)
    migrate.apply(db, migrate.files(), allow_empty=True)
    runtime_access.apply_policy(db, DATABASE)
    return check(db)


def compose_database_container():
    """Select this installation's running database, including custom projects."""
    directory = ROOT / "dev-tools"
    env_file = directory / ".env"
    if not env_file.is_file():
        raise RuntimeError("Run dev.py init first, or supply an explicit --container.")
    containers = subprocess.check_output(
        [
            "docker",
            "compose",
            "--env-file",
            str(env_file),
            "ps",
            "--status",
            "running",
            "--quiet",
            "db",
        ],
        cwd=directory,
        text=True,
    ).split()
    if len(containers) != 1:
        raise RuntimeError(
            "Expected one running db service in the selected Compose project. "
            "Start it with docker compose up -d --wait db."
        )
    return containers[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--container",
        help="Explicit database container; otherwise use the selected Compose project",
    )
    parser.add_argument("--confirm-empty", action="store_true")
    parser.add_argument(
        "--check", action="store_true", help="Only validate the existing migration ledger"
    )
    args = parser.parse_args()
    if not args.check and not args.confirm_empty:
        parser.error(
            "Creation requires --confirm-empty; this command never replaces an existing schema."
        )
    container = args.container or compose_database_container()
    with MySQL(container, DATABASE) as db:
        migrate.lock(db, DATABASE)
        count = check(db) if args.check else bootstrap(db)
    print(f"Database verified: {count} recorded migrations.")


if __name__ == "__main__":
    main()
