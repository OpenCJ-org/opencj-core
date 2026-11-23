"""Provision a GeoIP-only SQL account. The generated password is never printed."""

import argparse
from pathlib import Path
import os
import re
import secrets
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from mysql_session import MySQL

TABLES = ("geoIPReleases", "geoIPRanges", "geoIPState")
TABLE_PRIVILEGES = ("SELECT", "INSERT", "UPDATE", "DELETE")


def private_secret_path(secret_file):
    """Refuse a repository path unless Git explicitly excludes the resolved secret file."""
    path = Path(secret_file).resolve()
    for parent in path.parents:
        if (parent / ".git").exists():
            ignored = subprocess.run(
                ["git", "-C", str(parent), "check-ignore", "-q", str(path)],
                capture_output=True,
                timeout=30,
            )
            if ignored.returncode:
                raise ValueError("Secret path is inside a repository and is not ignored")
            break
    return path


def read_or_create_secret(path, *, account_exists):
    """Keep an existing account's password; create a private file only for a new account."""
    if account_exists and not path.exists():
        raise ValueError("Existing account has no local secret; refusing a silent password reset")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists():
        if path.stat().st_mode & 0o077:
            raise ValueError("Secret file must have mode 0600")
        password = path.read_text().strip()
    else:
        password = secrets.token_urlsafe(36)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(password + "\n")
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", password):
        raise ValueError("Unexpected updater secret format")
    return password


def validate_updater_grants(db, database, principal):
    """Reject rights outside country-data updates, including transferable table grants."""
    grantee = "'" + principal.replace("'", "''") + "'"
    global_count = db.query(f"""
        SELECT COUNT(*)
        FROM information_schema.USER_PRIVILEGES
        WHERE GRANTEE = {grantee} AND PRIVILEGE_TYPE <> 'USAGE';
        """)
    if global_count != "0":
        raise ValueError("Updater account has unexpected global privileges")
    schema_count = db.query(f"""
        SELECT COUNT(*)
        FROM information_schema.SCHEMA_PRIVILEGES
        WHERE GRANTEE = {grantee};
        """)
    if schema_count != "0":
        raise ValueError("Updater account has unexpected schema-wide privileges")
    table_names = ",".join("'" + table + "'" for table in TABLES)
    privileges = ",".join("'" + privilege + "'" for privilege in TABLE_PRIVILEGES)
    unexpected_table_count = db.query(f"""
        SELECT COUNT(*)
        FROM information_schema.TABLE_PRIVILEGES
        WHERE GRANTEE = {grantee}
          AND (
              TABLE_SCHEMA <> '{database}'
              OR TABLE_NAME NOT IN ({table_names})
              OR PRIVILEGE_TYPE NOT IN ({privileges})
              OR IS_GRANTABLE = 'YES'
          );
        """)
    if unexpected_table_count != "0":
        raise ValueError("Updater account has unexpected table privileges")


def provision(container, database, secret_file, account="geoip_updater", gameplay_account=None):
    """Create or reuse the private identity, refusing unexpected existing permissions."""
    if not re.fullmatch(r"[A-Za-z0-9_]+", database):
        raise ValueError("Invalid database/updater identifier")
    if not re.fullmatch(r"geoip_[A-Za-z0-9_]+", account):
        raise ValueError("Invalid database/updater identifier")
    if gameplay_account and not re.fullmatch(r"[A-Za-z0-9_]+", gameplay_account):
        raise ValueError("Invalid gameplay account")
    path = private_secret_path(secret_file)
    with MySQL(container, database) as db:
        account_exists = (
            db.query(f"SELECT COUNT(*) FROM mysql.user WHERE User='{account}' AND Host='%';") == "1"
        )
        password = read_or_create_secret(path, account_exists=account_exists)
        principal = "'" + account + "'@'%'"
        if not account_exists:
            db.query("CREATE USER " + principal + " IDENTIFIED BY '" + password + "';")
        validate_updater_grants(db, database, principal)
        privileges = ",".join(TABLE_PRIVILEGES)
        for table in TABLES:
            db.query(f"GRANT {privileges} ON {database}.{table} TO {principal};")
        if gameplay_account:
            for function_name in ("geoIPLookupCode", "getCountry"):
                db.query(
                    f"GRANT EXECUTE ON FUNCTION {database}.{function_name}"
                    f" TO '{gameplay_account}'@'%';"
                )
    return path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="opencj-dev-db-1")
    parser.add_argument("--database", default="openCJ_cod4")
    parser.add_argument("--confirm-database", required=True)
    parser.add_argument("--secret-file", type=Path, required=True)
    parser.add_argument("--gameplay-account", default="opencj")
    args = parser.parse_args()
    if args.confirm_database != args.database:
        parser.error("Confirmation must match database")
    try:
        path = provision(
            args.container, args.database, args.secret_file, gameplay_account=args.gameplay_account
        )
    except Exception:
        print("GeoIP credential provisioning failed; no credential values logged.", file=sys.stderr)
        raise SystemExit(1)
    print("GeoIP-only account configured; secret file (mode 0600): " + str(path))


if __name__ == "__main__":
    main()
