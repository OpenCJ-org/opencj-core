#!/usr/bin/env python3
"""Create and restore-check a manual OpenCJ development backup; no scheduling."""

from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import argparse
import gzip
import hashlib
import json
import os
import re
import secrets
import subprocess
import tarfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
# Match the supported database version without exposing the restore to a network.
RESTORE_IMAGE = "mysql:8.0"
RESTORE_MEMORY_LIMIT = "768m"
DATABASE_READY_ATTEMPTS = 90
DATABASE_READY_INTERVAL_SECONDS = 1
RESTORE_TIMEOUT_SECONDS = 180
CREDENTIAL_BYTES = 24


def run_command(command, **options):
    """Return command output as bytes; keep credentials out of failure messages."""
    result = subprocess.run(command, capture_output=True, **options)
    if result.returncode:
        raise RuntimeError("Backup command failed: " + command[0])
    return result.stdout


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", help="Database container to back up")
    parser.add_argument("--database", action="append", default=[], help="Repeat for each database")
    parser.add_argument(
        "--source",
        action="append",
        type=Path,
        default=[],
        help="Private runtime/config path to archive",
    )
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dev-tools/local/backups")
    parser.add_argument("--timezone", default="UTC")
    parser.add_argument(
        "--verify-existing", type=Path, help="Restore-check an existing backup directory"
    )
    return parser, parser.parse_args()


def create_snapshot(target, container, database_names, sources):
    """Save a consistent SQL dump and a separate archive of the selected files.

    Runtime files remain live during copying; they are not an atomic snapshot
    with the database. Preserve symlinks instead of archiving their targets.
    """
    dump = run_command(
        [
            "docker",
            "exec",
            container,
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root '
            '--single-transaction --hex-blob --routines --triggers --events '
            '--no-tablespaces --set-gtid-purged=OFF --column-statistics=0 --databases '
            + " ".join(database_names),
        ]
    )
    with gzip.open(target / "databases.sql.gz", "wb") as output:
        output.write(dump)
    print("Database snapshot created: " + target.name, flush=True)

    inventory = []
    with tarfile.open(
        target / "runtime-config-and-drafts.tar.gz", "w:gz", dereference=False
    ) as archive:
        for source in sources:
            if not source.exists():
                raise RuntimeError("Required backup source missing: " + str(source))
            archive.add(source, arcname=str(source).lstrip("/"))
        for member in archive.getmembers():
            inventory.append(f"{member.name}\t{member.size}\t{member.linkname}")
    (target / "runtime-file-inventory.txt").write_text("\n".join(inventory) + "\n")
    return dump


def wait_for_database(mysql_command):
    """Poll the isolated server until it accepts SQL or the startup budget expires."""
    for attempt in range(DATABASE_READY_ATTEMPTS):
        result = subprocess.run(mysql_command, input=b"SELECT 1;", capture_output=True)
        if result.returncode == 0:
            return
        time.sleep(DATABASE_READY_INTERVAL_SECONDS)
    raise RuntimeError("Backup restore database did not start")


def check_restored_tables(mysql_command, database_names, check_directory):
    """Check every restored table and view, returning counts for the backup report."""
    selected_schemas = "(" + ",".join("'" + name + "'" for name in database_names) + ")"
    counts_sql = f"""
        SELECT TABLE_SCHEMA, COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA IN {selected_schemas}
        GROUP BY TABLE_SCHEMA;

        SELECT ROUTINE_SCHEMA, COUNT(*)
        FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA IN {selected_schemas}
        GROUP BY ROUTINE_SCHEMA;
    """
    counts = run_command(mysql_command, input=counts_sql.encode()).decode()
    tables_sql = f"""
        SELECT TABLE_SCHEMA, TABLE_NAME
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA IN {selected_schemas};
    """
    tables = run_command(mysql_command, input=tables_sql.encode()).decode().splitlines()
    identifiers = []
    for table_row in tables:
        schema_name, table_name = table_row.split("\t")
        identifiers.append("`" + schema_name + "`.`" + table_name + "`")

    check_sql = "CHECK TABLE " + ",".join(identifiers) + ";"
    table_results = (
        run_command(mysql_command, input=check_sql.encode(), timeout=RESTORE_TIMEOUT_SECONDS)
        .decode()
        .splitlines()
    )
    if len(table_results) != len(tables) or not all(
        result.endswith("\tstatus\tOK") for result in table_results
    ):
        result_path = check_directory / "table-check.txt"
        result_path.write_text("\n".join(table_results))
        raise RuntimeError("Restored table check failed; inspect " + str(result_path))
    return counts


def verify_snapshot(dump, database_names, check_directory, credentials):
    """Restore into a private MySQL container and remove it after verification.

    The dump excludes accounts. Create its runtime definer only in this
    isolated restore, with a fresh credential that no gameplay client uses.
    """
    container_name = "opencj-" + check_directory.name
    started = False
    try:
        run_command(
            [
                "docker",
                "run",
                "-d",
                "--name",
                container_name,
                "--network",
                "none",
                "--memory",
                RESTORE_MEMORY_LIMIT,
                "--env-file",
                str(credentials),
                RESTORE_IMAGE,
                "--log-bin-trust-function-creators=1",
            ]
        )
        started = True
        mysql_command = [
            "docker",
            "exec",
            "-i",
            container_name,
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql ' '--protocol=TCP -h127.0.0.1 -N -u root',
        ]
        wait_for_database(mysql_command)
        grants = "CREATE USER 'opencj'@'%' IDENTIFIED BY '"
        grants += secrets.token_hex(CREDENTIAL_BYTES) + "';"
        for database_name in database_names:
            grants += "GRANT ALL ON " + database_name + ".* TO 'opencj'@'%';"
        run_command(mysql_command, input=grants.encode())
        run_command(mysql_command, input=dump, timeout=RESTORE_TIMEOUT_SECONDS)
        return check_restored_tables(mysql_command, database_names, check_directory)
    finally:
        if started:
            run_command(["docker", "rm", "-f", "-v", container_name])


def write_backup_report(target, stamp, timezone, restored_counts):
    """Record successful restore verification and hashes of the completed backup."""
    (target / "restore-verification.txt").write_text(
        "Restore succeeded in isolated MySQL 8.0 with log_bin_trust_function_creators=1.\n"
        "All restored tables and views passed CHECK TABLE.\nTables then stored routines by database:\n"
        + restored_counts
    )
    (target / "README.txt").write_text(
        f"OpenCJ backup: {stamp} ({timezone}).\n\n"
        "databases.sql.gz: consistent single-transaction snapshot of the databases listed "
        "in backup-metadata.json, including table data, schema, routines, triggers and "
        "events.\n"
        "runtime-config-and-drafts.tar.gz: the explicitly selected runtime/configuration "
        "paths. Symlinks are preserved, not followed. Configuration contains secrets; do "
        "not publish.\n"
        "Runtime files were copied while the server remained online; this is not an "
        "atomic snapshot with the SQL dump.\n"
        "Excluded: MySQL system databases/users/grants, deployed map binaries, other "
        "development/build files and Git repositories. Demo payloads in database tables "
        "ARE included.\n"
        "Restore: use MySQL 8.0, provision the application database account from saved "
        "configuration and the applicable runtime grants policy, enable "
        "log_bin_trust_function_creators=1 for OpenCJ routines, then decompress "
        "databases.sql.gz and import through mysql as an administrator. Review paths "
        "before restoring archive files. Never import over live data without an "
        "intentional recovery plan.\n"
        "See restore-verification.txt for the isolated import test and SHA256SUMS for "
        "integrity verification.\n"
    )

    checksums = [
        hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name
        for path in sorted(target.iterdir())
        if path.is_file() and path.name != "SHA256SUMS"
    ]
    (target / "SHA256SUMS").write_text("\n".join(checksums) + "\n")
    print("BACKUP_VERIFIED " + str(target), flush=True)


def main():
    """Create or reopen a backup, then verify it without touching the source database."""
    parser, args = parse_args()
    database_names = args.database
    sources = [source.resolve() for source in args.source]
    verify_existing = args.verify_existing is not None
    if verify_existing:
        target = args.verify_existing.resolve()
        metadata = target / "backup-metadata.json"
        if metadata.is_file() and not database_names:
            database_names = json.loads(metadata.read_text())["databases"]
        if not (target / "databases.sql.gz").is_file():
            parser.error("Expected an existing backup containing databases.sql.gz")
    elif not args.container or not database_names or not sources:
        parser.error("A new backup requires --container, --database and --source")
    if not database_names or any(
        not re.fullmatch(r"[A-Za-z0-9_]{1,64}", name) for name in database_names
    ):
        parser.error("Supply valid database names (letters, numbers and underscores)")

    os.umask(0o077)
    stamp = datetime.now(ZoneInfo(args.timezone)).strftime("%Y-%m-%d_%Hh%Mm%Ss")
    if not verify_existing:
        target = args.output_dir.resolve() / stamp
        target.mkdir(mode=0o700, parents=True, exist_ok=False)
        (target / "backup-metadata.json").write_text(
            json.dumps(
                {
                    "databases": database_names,
                    "container": args.container,
                    "sources": [str(source) for source in sources],
                    "timezone": args.timezone,
                },
                indent=2,
            )
            + "\n"
        )
    else:
        stamp = target.name

    check_directory = ROOT / "dev-tools/local" / ("backup-check-" + uuid.uuid4().hex[:8])
    check_directory.mkdir(mode=0o700)
    credentials = check_directory / "mysql.env"
    credentials.write_text("MYSQL_ROOT_PASSWORD=" + secrets.token_hex(CREDENTIAL_BYTES) + "\n")
    try:
        if verify_existing:
            dump = gzip.decompress((target / "databases.sql.gz").read_bytes())
        else:
            dump = create_snapshot(target, args.container, database_names, sources)
        restored_counts = verify_snapshot(dump, database_names, check_directory, credentials)
        write_backup_report(target, stamp, args.timezone, restored_counts)
    finally:
        credentials.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
