#!/usr/bin/env python3
"""Apply reviewed gameplay privileges; migrations continue using the admin account."""

import argparse
import re
from mysql_session import MySQL

WRITABLE_TABLES = {
    "checkpointAreas",
    "checkpointBrothers",
    "checkpointConnections",
    "checkpointRoutes",
    "checkpointSectionColors",
    "checkpointStatistics",
    "checkpoints",
    "routes",
    "mapids",
    "mapMappers",
    "mappers",
    "demoRuns",
    "demoChunks",
    "demoClipSessions",
    "demoClips",
    "demoClipChunks",
    "playerInformation",
    "playerLogin",
    "playerRuns",
    "playerSaves",
    "playerSettings",
    "playerIgnore",
    "playerNamePreferences",
    "runLabels",
    "challenges",
    "shopCatalog",
    "messages",
}
INSERT_ONLY_TABLES = {"challengeCompletions"}
DELETABLE_TABLES = {
    "checkpointAreas",
    "checkpointBrothers",
    "checkpointConnections",
    "checkpointRoutes",
    "demoRuns",
    "demoClips",
    "demoClipSessions",
    "playerSettings",
    "playerIgnore",
}



def quote_identifier(value):
    return chr(96) + value.replace(chr(96), chr(96) * 2) + chr(96)


def quote_literal(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"


def validate_account_privileges(db, account, grantee):
    """Refuse accounts whose broader rights would bypass the reviewed table policy."""
    global_privileges = db.query(f"""
        SELECT PRIVILEGE_TYPE
        FROM information_schema.USER_PRIVILEGES
        WHERE GRANTEE = {grantee} AND PRIVILEGE_TYPE <> 'USAGE';
        """)
    if global_privileges:
        raise RuntimeError(
            "Runtime account has global permissions; review them before narrowing schema permissions"
        )
    unsafe_routines = db.query(f"""
        SELECT ROUTINE_NAME
        FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE()
          AND (SECURITY_TYPE <> 'DEFINER' OR DEFINER = {quote_literal(account + '@%')});
        """)
    if unsafe_routines:
        raise RuntimeError("Review routine definers before narrowing runtime permissions")


def revoke_existing_grants(db, databases, account, principal, grantee):
    """Remove old schema, table and routine grants before rebuilding the current policy."""
    schema_patterns = db.query(f"""
        SELECT DISTINCT TABLE_SCHEMA
        FROM information_schema.SCHEMA_PRIVILEGES
        WHERE GRANTEE = {grantee};
        """).splitlines()
    for pattern in schema_patterns:
        database_name = pattern.replace("\\_", "_").replace("\\%", "%")
        if database_name in databases:
            db.query(
                f"REVOKE ALL PRIVILEGES ON {quote_identifier(pattern)}.* FROM {principal};"
            )

    # Removing table/routine grants too prevents obsolete permissions from surviving a rerun.
    for database in databases:
        table_names = db.query(f"""
            SELECT DISTINCT TABLE_NAME
            FROM information_schema.TABLE_PRIVILEGES
            WHERE TABLE_SCHEMA = {quote_literal(database)} AND GRANTEE = {grantee};
            """).splitlines()
        for table_name in table_names:
            qualified_table = quote_identifier(database) + "." + quote_identifier(table_name)
            db.query(f"REVOKE ALL PRIVILEGES ON {qualified_table} FROM {principal};")

        routine_rows = db.query(f"""
            SELECT Routine_name, Routine_type
            FROM mysql.procs_priv
            WHERE Db = {quote_literal(database)}
              AND User = {quote_literal(account)} AND Host = '%';
            """).splitlines()
        for row in routine_rows:
            routine_name, routine_kind = row.split("\t")
            qualified_routine = quote_identifier(database) + "." + quote_identifier(routine_name)
            db.query(
                f"REVOKE ALL PRIVILEGES ON {routine_kind} {qualified_routine} FROM {principal};"
            )


def grant_gameplay_permissions(db, database, principal):
    """Give gameplay its reviewed write rights and access to administrator-owned routines."""
    # Schema grants treat underscores as wildcards unless escaped; table grants use exact names.
    schema_pattern = quote_identifier(database.replace("_", "\\_"))
    db.query(f"GRANT SELECT ON {schema_pattern}.* TO {principal};")
    for table_name in sorted(WRITABLE_TABLES | INSERT_ONLY_TABLES):
        privileges = "INSERT,UPDATE" if table_name in WRITABLE_TABLES else "INSERT"
        qualified_table = quote_identifier(database) + "." + quote_identifier(table_name)
        db.query(f"GRANT {privileges} ON {qualified_table} TO {principal};")
    for table_name in sorted(DELETABLE_TABLES):
        qualified_table = quote_identifier(database) + "." + quote_identifier(table_name)
        db.query(f"GRANT DELETE ON {qualified_table} TO {principal};")

    routine_rows = db.query("""
        SELECT ROUTINE_NAME, ROUTINE_TYPE
        FROM information_schema.ROUTINES
        WHERE ROUTINE_SCHEMA = DATABASE();
        """).splitlines()
    for row in routine_rows:
        routine_name, routine_kind = row.split("\t")
        qualified_routine = quote_identifier(database) + "." + quote_identifier(routine_name)
        db.query(f"GRANT EXECUTE ON {routine_kind} {qualified_routine} TO {principal};")


def apply_policy(db, database, account="opencj", readonly_database=None):
    """Replace runtime grants while holding the maintenance lock until this session closes.

    Grant statements do not roll back together. A failure stops this operation;
    correct its cause and reapply the complete policy before resuming gameplay.
    """
    if not re.fullmatch(r"[A-Za-z0-9_]+", account):
        raise ValueError("Invalid runtime account")
    principal = quote_literal(account) + "@'%'"
    grantee = quote_literal("'" + account + "'@'%'")
    validate_account_privileges(db, account, grantee)
    if db.query("SELECT GET_LOCK('opencj:migrate:" + database + "',0);") != "1":
        raise RuntimeError("Another database maintenance session is active")

    databases = {database}
    if readonly_database:
        databases.add(readonly_database)
    revoke_existing_grants(db, databases, account, principal, grantee)
    grant_gameplay_permissions(db, database, principal)
    if readonly_database:
        schema_pattern = quote_identifier(readonly_database.replace("_", "\\_"))
        db.query(f"GRANT SELECT ON {schema_pattern}.* TO {principal};")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="opencj-dev-db-1")
    parser.add_argument("--database", default="openCJ_cod4")
    parser.add_argument("--readonly-database")
    parser.add_argument("--confirm-database", required=True)
    args = parser.parse_args()
    if args.confirm_database != args.database:
        parser.error("Confirmation must match database")
    with MySQL(args.container, args.database) as db:
        apply_policy(db, args.database, readonly_database=args.readonly_database)
    print("Runtime permissions applied; no credentials changed.")


if __name__ == "__main__":
    main()
