#!/usr/bin/env python3
"""Initialize an empty CoD4 database from the versioned schema."""

import argparse
import re
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
    """Verify that every source migration has a matching completed ledger entry."""
    migrations = migrate.load_migrations()
    rows = migrate.read_ledger(db)
    migrate.validate_history(rows, migrations)
    if set(rows) != set(migrations):
        raise RuntimeError(
            "Database migrations are incomplete; bootstrap an empty database or follow the upgrade procedure."
        )
    return len(rows)


def baseline_sql():
    """Keep the legacy export intact while importing into the selected empty schema."""
    sql = (ROOT / "server-db/exports/openCJ_cod4.sql").read_text()
    for statement in (r"^CREATE DATABASE IF NOT EXISTS `openCJ_cod4`.*;\n",
                      r"^USE `openCJ_cod4`;\n"):
        sql, count = re.subn(statement, "", sql, flags=re.MULTILINE)
        if count != 1:
            raise RuntimeError("Unexpected baseline database selection; import refused")
    return sql


def bootstrap(db, database=DATABASE, runtime_account="opencj"):
    """Refuse existing data; a partial failure requires deliberate recovery."""
    if not re.fullmatch(r"[A-Za-z0-9_]+", database + runtime_account):
        raise ValueError("Invalid database or runtime account")
    if db.query("SELECT DATABASE();") != database:
        raise RuntimeError("Selected database differs from bootstrap target")
    existing_object_count = db.query(
        """
        SELECT
            (SELECT COUNT(*)
             FROM information_schema.tables
             WHERE table_schema = DATABASE())
          + (SELECT COUNT(*)
             FROM information_schema.routines
             WHERE routine_schema = DATABASE())
          + (SELECT COUNT(*)
             FROM information_schema.events
             WHERE event_schema = DATABASE());
        """
    )
    if existing_object_count != "0":
        raise RuntimeError("Bootstrap requires an empty database; existing data was preserved.")
    if db.query(
        "SELECT COUNT(*) FROM mysql.user WHERE User="
        + runtime_access.quote_literal(runtime_account) + " AND Host='%';"
    ) != "1":
        raise RuntimeError(
            f"Create the {runtime_account} runtime account through Compose setup first."
        )
    db.query(baseline_sql())
    # The historical schema export already includes this later addition.
    # Only this freshly imported, empty schema is normalized before replaying
    # migration 008. Existing databases never enter this bootstrap path.
    db.query("ALTER TABLE checkpoints DROP COLUMN allowSave;")
    db.query(migrate.LEDGER)
    migrate.apply_migrations(db, migrate.load_migrations(), allow_empty=True)
    runtime_access.apply_policy(db, database, account=runtime_account)
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
    options = parser.parse_args()
    if not options.check and not options.confirm_empty:
        parser.error(
            "Creation requires --confirm-empty; this command never replaces an existing schema."
        )
    container = options.container or compose_database_container()
    with MySQL(container, DATABASE) as db:
        migrate.lock_database(db, DATABASE)
        migration_count = check(db) if options.check else bootstrap(db)
    print(f"Database verified: {migration_count} recorded migrations.")


if __name__ == "__main__":
    main()
