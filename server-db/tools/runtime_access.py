#!/usr/bin/env python3
"""Apply reviewed gameplay privileges; migrations continue using the admin account."""
import argparse, re
from mysql_session import MySQL

WRITABLE = {
    "checkpointAreas", "checkpointBrothers", "checkpointConnections",
    "checkpointRoutes", "checkpointSectionColors", "checkpointStatistics",
    "checkpoints", "routes", "mapids", "mapMappers", "mappers",
    "demoRuns", "demoChunks", "demoClipSessions", "demoClips", "demoClipChunks",
    "playerInformation", "playerLogin", "playerRuns", "playerSaves",
    "playerSettings", "playerIgnore", "playerNamePreferences", "runLabels",
    "challenges", "shopCatalog", "messages",
}
INSERT_ONLY = {"challengeCompletions"}
DELETABLE = {
    "checkpointAreas", "checkpointBrothers", "checkpointConnections", "checkpointRoutes",
    "demoRuns", "demoClips", "demoClipSessions", "playerSettings", "playerIgnore",
}

def ident(value):
    return chr(96) + value.replace(chr(96), chr(96)*2) + chr(96)

def literal(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "''") + "'"

def apply_policy(db, database, account="opencj", readonly_database=None):
    if not re.fullmatch(r"[A-Za-z0-9_]+", account):
        raise ValueError("Invalid runtime account")
    principal = literal(account) + "@'%'"
    grantee = literal("'" + account + "'@'%'")
    global_privs = db.query("SELECT PRIVILEGE_TYPE FROM information_schema.USER_PRIVILEGES WHERE GRANTEE=" + grantee + " AND PRIVILEGE_TYPE<>'USAGE';")
    if global_privs:
        raise RuntimeError("Runtime account has global permissions; review them before narrowing schema permissions")
    unsafe = db.query("SELECT ROUTINE_NAME FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=DATABASE() AND (SECURITY_TYPE<>'DEFINER' OR DEFINER=" + literal(account+"@%") + ");")
    if unsafe:
        raise RuntimeError("Review routine definers before narrowing runtime permissions")
    if db.query("SELECT GET_LOCK('opencj:migrate:" + database + "',0);") != "1":
        raise RuntimeError("Another database maintenance session is active")
    targets = {database}
    if readonly_database:
        targets.add(readonly_database)
    patterns = db.query("SELECT DISTINCT TABLE_SCHEMA FROM information_schema.SCHEMA_PRIVILEGES WHERE GRANTEE=" + grantee + ";").splitlines()
    for pattern in patterns:
        if pattern.replace("\\_", "_").replace("\\%", "%") in targets:
            db.query("REVOKE ALL PRIVILEGES ON " + ident(pattern) + ".* FROM " + principal + ";")
    # Remove old table/routine grants too, so repeated application cannot retain
    # privileges removed from this policy.
    for target in targets:
        tables = db.query("SELECT DISTINCT TABLE_NAME FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA=" + literal(target) + " AND GRANTEE=" + grantee + ";").splitlines()
        for table in tables:
            db.query("REVOKE ALL PRIVILEGES ON " + ident(target) + "." + ident(table) + " FROM " + principal + ";")
        routines = db.query("SELECT Routine_name,Routine_type FROM mysql.procs_priv WHERE Db=" + literal(target) + " AND User=" + literal(account) + " AND Host='%';").splitlines()
        for row in routines:
            name, kind = row.split("\t")
            db.query("REVOKE ALL PRIVILEGES ON " + kind + " " + ident(target) + "." + ident(name) + " FROM " + principal + ";")
    escaped = database.replace("_", "\\_")
    db.query("GRANT SELECT ON " + ident(escaped) + ".* TO " + principal + ";")
    for table in sorted(WRITABLE | INSERT_ONLY):
        privileges = "INSERT,UPDATE" if table in WRITABLE else "INSERT"
        db.query("GRANT " + privileges + " ON " + ident(database) + "." + ident(table) + " TO " + principal + ";")
    for table in sorted(DELETABLE):
        db.query("GRANT DELETE ON " + ident(database) + "." + ident(table) + " TO " + principal + ";")
    for row in db.query("SELECT ROUTINE_NAME,ROUTINE_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA=DATABASE();").splitlines():
        name, kind = row.split("\t")
        db.query("GRANT EXECUTE ON " + kind + " " + ident(database) + "." + ident(name) + " TO " + principal + ";")
    if readonly_database:
        db.query("GRANT SELECT ON " + ident(readonly_database.replace("_","\\_")) + ".* TO " + principal + ";")

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--container",default="opencj-dev-db-1")
    p.add_argument("--database",default="openCJ_cod4")
    p.add_argument("--readonly-database")
    p.add_argument("--confirm-database",required=True)
    a=p.parse_args()
    if a.confirm_database!=a.database:p.error("Confirmation must match database")
    with MySQL(a.container,a.database) as db:
        apply_policy(db,a.database,readonly_database=a.readonly_database)
    print("Runtime permissions applied; no credentials changed.")

if __name__=="__main__":main()
