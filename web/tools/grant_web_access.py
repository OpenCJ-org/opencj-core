#!/usr/bin/env python3
"""Create or update the website's database account so it can only read the tables the site uses."""

import argparse
import re
import secrets
import sys
from pathlib import Path

WEB_DIR = Path(__file__).resolve().parents[1]
CORE_ROOT = WEB_DIR.parent
sys.path.insert(0, str(CORE_ROOT / "server-db" / "tools"))

from mysql_session import MySQL  # noqa: E402  (shared helper from server-db/tools)

# Everything the site reads. playerDisplayNames is a view over the player table
# that exposes only IDs and display names; the account cannot read the player
# table itself, logins, IP addresses or settings.
WEB_READABLE_TABLES = (
    "challengeCompletions",
    "challenges",
    "checkpointStatistics",
    "checkpoints",
    "mapids",
    "mapMappers",
    "mapPlays",
    "mappers",
    "playerDisplayNames",
    "playerRuns",
    "routes",
)
ACCOUNT_NAME_PATTERN = re.compile(r"[A-Za-z0-9_]{1,32}")
PASSWORD_SETTING = "WEB_DB_PASSWORD"
GENERATED_PASSWORD_BYTES = 24
# Bounds the damage of a stolen password: the site needs very few connections.
MAX_ACCOUNT_CONNECTIONS = 4


def quote_identifier(name):
    return "`" + name.replace("`", "``") + "`"


def quote_literal(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def read_env_value(env_path, setting_name):
    if not env_path.is_file():
        return ""
    for line in env_path.read_text().splitlines():
        if line.startswith(setting_name + "="):
            return line[len(setting_name) + 1:].strip()
    return ""


def store_env_value(env_path, setting_name, value):
    """Set one KEY=value line in the private .env file, keeping all other lines."""
    lines = env_path.read_text().splitlines() if env_path.is_file() else []
    replaced = False
    for index, line in enumerate(lines):
        if line.startswith(setting_name + "="):
            lines[index] = setting_name + "=" + value
            replaced = True
    if not replaced:
        lines.append(setting_name + "=" + value)
    env_path.write_text("\n".join(lines) + "\n")
    env_path.chmod(0o600)


def grant_statements(database, principal, table_names):
    """Replace every privilege of the account with SELECT on the given tables only."""
    statements = [
        "REVOKE ALL PRIVILEGES, GRANT OPTION FROM " + principal + ";",
    ]
    for table_name in table_names:
        statements.append(
            "GRANT SELECT ON " + quote_identifier(database) + "." + quote_identifier(table_name)
            + " TO " + principal + ";")
    return statements


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True, help="Running MySQL container of the installation")
    parser.add_argument("--confirm-database", required=True, help="Database the site reads, e.g. openCJ_cod4")
    parser.add_argument("--account", default="opencj_web")
    parser.add_argument("--env-file", type=Path, default=WEB_DIR / ".env")
    options = parser.parse_args()

    if not ACCOUNT_NAME_PATTERN.fullmatch(options.account):
        parser.error("Account names may only use letters, digits and underscores")

    password = read_env_value(options.env_file, PASSWORD_SETTING)
    if password == "":
        password = secrets.token_urlsafe(GENERATED_PASSWORD_BYTES)
        store_env_value(options.env_file, PASSWORD_SETTING, password)
        print("Generated a new password in " + str(options.env_file))

    principal = quote_literal(options.account) + "@'%'"
    session = MySQL(options.container, options.confirm_database)
    try:
        table_list_text = session.query(
            "SELECT TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE();")
        existing_tables = set(table_list_text.splitlines())
        readable_tables = [name for name in WEB_READABLE_TABLES if name in existing_tables]
        absent_tables = [name for name in WEB_READABLE_TABLES if name not in existing_tables]
        if absent_tables:
            # The site shows such data as unavailable. Run this tool again after the
            # pending migration so the account can read the new table.
            print("Not granted, table does not exist yet: " + ", ".join(absent_tables), file=sys.stderr)

        session.query(
            "CREATE USER IF NOT EXISTS " + principal + " IDENTIFIED BY " + quote_literal(password)
            + " WITH MAX_USER_CONNECTIONS " + str(MAX_ACCOUNT_CONNECTIONS) + ";")
        # Keep the stored password and the account in step when the account already existed.
        session.query(
            "ALTER USER " + principal + " IDENTIFIED BY " + quote_literal(password)
            + " WITH MAX_USER_CONNECTIONS " + str(MAX_ACCOUNT_CONNECTIONS) + ";")
        session.query("\n".join(grant_statements(options.confirm_database, principal, readable_tables)))
        granted = session.query("SHOW GRANTS FOR " + principal + ";")
    finally:
        session.close()

    print("Grants for " + options.account + ":")
    print(granted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
