#!/usr/bin/env python3
"""Create and restore-check a manual OpenCJ development backup; no scheduling."""
from pathlib import Path
from datetime import datetime
from zoneinfo import ZoneInfo
import argparse, gzip, hashlib, json, os, re, secrets, subprocess, tarfile, time, uuid, sys

ROOT = Path(__file__).resolve().parents[2]
DATABASES = []
SOURCES = []

def run(args, **kw):
    result = subprocess.run(args, capture_output=True, **kw)
    if result.returncode:
        if any("mysqlcheck" in arg for arg in args):
            print(result.stdout.decode(errors="replace")[-6000:], flush=True)
            print(result.stderr.decode(errors="replace")[-1500:], flush=True)
        raise RuntimeError("Backup command failed: " + args[0])
    return result.stdout

def main():
    global DATABASES, SOURCES
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", help="Database container to back up")
    parser.add_argument("--database", action="append", default=[], help="Repeat for each database")
    parser.add_argument("--source", action="append", type=Path, default=[], help="Private runtime/config path to archive")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dev-tools/local/backups")
    parser.add_argument("--timezone", default="UTC")
    parser.add_argument("--verify-existing", type=Path, help="Restore-check an existing backup directory")
    args = parser.parse_args()
    DATABASES = args.database
    SOURCES = [source.resolve() for source in args.source]
    resume = args.verify_existing is not None
    if resume:
        target = args.verify_existing.resolve()
        metadata = target / "backup-metadata.json"
        if metadata.is_file() and not DATABASES:
            DATABASES = json.loads(metadata.read_text())["databases"]
        if not (target / "databases.sql.gz").is_file():
            parser.error("Expected an existing backup containing databases.sql.gz")
    elif not args.container or not DATABASES or not SOURCES:
        parser.error("A new backup requires --container, --database and --source")
    if not DATABASES or any(not re.fullmatch(r"[A-Za-z0-9_]{1,64}", name) for name in DATABASES):
        parser.error("Supply valid database names (letters, numbers and underscores)")
    os.umask(0o077)
    stamp = datetime.now(ZoneInfo(args.timezone)).strftime("%Y-%m-%d_%Hh%Mm%Ss")
    if not resume:
        target = args.output_dir.resolve() / stamp
        target.mkdir(mode=0o700, parents=True, exist_ok=False)
        (target / "backup-metadata.json").write_text(json.dumps({
            "databases": DATABASES, "container": args.container,
            "sources": [str(source) for source in SOURCES], "timezone": args.timezone,
        }, indent=2) + "\n")
    else:
        stamp = target.name
    selected_schemas = "(" + ",".join("'" + name + "'" for name in DATABASES) + ")"
    checkdir = ROOT / "dev-tools/local" / ("backup-check-" + uuid.uuid4().hex[:8])
    checkdir.mkdir(mode=0o700)
    private = checkdir / "mysql.env"
    private.write_text("MYSQL_ROOT_PASSWORD=" + secrets.token_hex(24) + "\n")
    name = "opencj-" + checkdir.name
    started = False
    try:
        if resume:
            dump = gzip.decompress((target / "databases.sql.gz").read_bytes())
        else:
            dump = run(["docker", "exec", args.container, "sh", "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --single-transaction --hex-blob --routines --triggers --events --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 --databases ' + " ".join(DATABASES)])
            with gzip.open(target / "databases.sql.gz", "wb") as output:
                output.write(dump)
            print("Database snapshot created: " + stamp, flush=True)
            inventory = []
            with tarfile.open(target / "runtime-config-and-drafts.tar.gz", "w:gz", dereference=False) as archive:
                for source in SOURCES:
                    if not source.exists():
                        raise RuntimeError("Required backup source missing: " + str(source))
                    archive.add(source, arcname=str(source).lstrip("/"))
                for member in archive.getmembers():
                    inventory.append(f"{member.name}\t{member.size}\t{member.linkname}")
            (target / "runtime-file-inventory.txt").write_text("\n".join(inventory) + "\n")
        run(["docker", "run", "-d", "--name", name, "--network", "none",
             "--memory", "768m", "--env-file", str(private), "mysql:8.0",
             "--log-bin-trust-function-creators=1"])
        started = True
        mysql = ["docker", "exec", "-i", name, "sh", "-c",
                 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --protocol=TCP -h127.0.0.1 -N -u root']
        for attempt in range(90):
            result = subprocess.run(mysql, input=b"SELECT 1;", capture_output=True)
            if result.returncode == 0:
                break
            time.sleep(1)
        else:
            raise RuntimeError("Backup restore database did not start")
        # The dump deliberately excludes accounts; provision its runtime definer
        # only in this isolated restore, using a fresh unusable test credential.
        grants = "CREATE USER 'opencj'@'%' IDENTIFIED BY '" + secrets.token_hex(24) + "';"
        for database in DATABASES:
            grants += "GRANT ALL ON " + database + ".* TO 'opencj'@'%';"
        run(mysql, input=grants.encode())
        run(mysql, input=dump, timeout=180)
        verify_sql = (
            "SELECT TABLE_SCHEMA,COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA IN "
            + selected_schemas + " GROUP BY TABLE_SCHEMA; "
            "SELECT ROUTINE_SCHEMA,COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA IN "
            + selected_schemas + " GROUP BY ROUTINE_SCHEMA;"
        )
        verify = run(mysql, input=verify_sql.encode()).decode()
        table_sql = "SELECT TABLE_SCHEMA,TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA IN " + selected_schemas + ";"
        tables = run(mysql, input=table_sql.encode()).decode().splitlines()
        identifiers = [chr(96) + schema + chr(96) + "." + chr(96) + table + chr(96)
                       for schema, table in (line.split("\t") for line in tables)]
        checked = run(mysql, input=("CHECK TABLE " + ",".join(identifiers) + ";").encode(), timeout=180).decode().splitlines()
        if len(checked) != len(tables) or not all(line.endswith("\tstatus\tOK") for line in checked):
            (checkdir / "table-check.txt").write_text("\n".join(checked))
            raise RuntimeError("Restored table check failed; inspect " + str(checkdir / "table-check.txt"))
        (target / "restore-verification.txt").write_text(
            "Restore succeeded in isolated MySQL 8.0 with log_bin_trust_function_creators=1.\n"
            "All restored tables and views passed CHECK TABLE.\nTables then stored routines by database:\n" + verify)
        (target / "README.txt").write_text(
            f"OpenCJ backup: {stamp} ({args.timezone}).\n\n"
            "databases.sql.gz: consistent single-transaction snapshot of the databases listed in backup-metadata.json, including table data, schema, routines, triggers and events.\n"
            "runtime-config-and-drafts.tar.gz: the explicitly selected runtime/configuration paths. Symlinks are preserved, not followed. Configuration contains secrets; do not publish.\n"
            "Runtime files were copied while the server remained online; this is not an atomic snapshot with the SQL dump.\n"
            "Excluded: MySQL system databases/users/grants, deployed map binaries, other development/build files and Git repositories. Demo payloads in database tables ARE included.\n"
            "Restore: use MySQL 8.0, provision the application database account from saved configuration and the applicable runtime grants policy, enable log_bin_trust_function_creators=1 for OpenCJ routines, then decompress databases.sql.gz and import through mysql as an administrator. Review paths before restoring archive files. Never import over live data without an intentional recovery plan.\n"
            "See restore-verification.txt for the isolated import test and SHA256SUMS for integrity verification.\n")
        sums = [hashlib.sha256(f.read_bytes()).hexdigest() + "  " + f.name
                for f in sorted(target.iterdir()) if f.is_file() and f.name != "SHA256SUMS"]
        (target / "SHA256SUMS").write_text("\n".join(sums) + "\n")
        print("BACKUP_VERIFIED " + str(target), flush=True)
    finally:
        if started:
            run(["docker", "rm", "-f", "-v", name])
        private.unlink(missing_ok=True)

if __name__ == "__main__":
    main()
