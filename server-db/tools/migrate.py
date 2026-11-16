#!/usr/bin/env python3
"""Tracked OpenCJ migrations. Stop gameplay writers and back up before apply/adopt."""
from pathlib import Path
import argparse, hashlib, json, re
from mysql_session import MySQL

ROOT = Path(__file__).resolve().parents[1]
LEDGER = """CREATE TABLE IF NOT EXISTS schemaMigrations(
 version INT NOT NULL PRIMARY KEY,
 filename VARCHAR(160) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 state ENUM('adopted','applying','applied') NOT NULL,
 appliedAt TIMESTAMP NULL,
 schemaSha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
 CHECK(version>0)
) ENGINE=InnoDB;"""

def files():
    result = {}
    for p in sorted((ROOT / "migrations").glob("[0-9][0-9][0-9]-*.sql")):
        version = int(p.name[:3])
        if version in result:
            raise RuntimeError("Duplicate migration number")
        result[version] = (p.name, hashlib.sha256(p.read_bytes()).hexdigest(), p.read_text())
    if list(result) != list(range(1, max(result) + 1)):
        raise RuntimeError("Migration sequence has a gap")
    return result

def lock(db, database):
    if db.query("SELECT GET_LOCK('opencj:migrate:" + database + "',0);") != "1":
        raise RuntimeError("Another migration session is active")

def ledger(db):
    exists = db.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='schemaMigrations';")
    if exists == "0":
        return {}
    return {int(parts[0]): parts[1:] for parts in
            (line.split("\t") for line in db.query("SELECT version,filename,sha256,state FROM schemaMigrations ORDER BY version;").splitlines())}

def validate(rows, migrations):
    for version, (name, checksum, state) in rows.items():
        if version not in migrations or (name, checksum) != migrations[version][:2]:
            raise RuntimeError("Applied migration differs from source: " + str(version))
        if state not in ("applied", "adopted"):
            raise RuntimeError("Migration " + str(version) + " was interrupted; inspect/restore before continuing")
    if rows and sorted(rows) != list(range(1, max(rows) + 1)):
        raise RuntimeError("Applied migration history has a gap")

def schema_hash(db):
    statements = []
    for table in db.query("SELECT table_name FROM information_schema.tables WHERE table_schema=DATABASE() AND table_type='BASE TABLE' AND table_name<>'schemaMigrations' ORDER BY table_name;").splitlines():
        create = db.query("SHOW CREATE TABLE " + chr(96) + table + chr(96) + ";")
        statements.append(re.sub(r" AUTO_INCREMENT=\d+", "", create))
    return hashlib.sha256("\n".join(statements).encode()).hexdigest()

def adopt020(db, migrations):
    # Deliberately adopt the known, manually migrated development schema.
    required = {
        "routes": ["routeID", "mapID", "colorRGB"],
        "checkpoints": ["retired", "finishRouteID"],
        "checkpointAreas": ["draftName", "platformRef", "heightAbove"],
        "checkpointRoutes": ["cpID", "routeID"],
        "challenges": ["mapID", "routeID", "routeHint"],
        "demoPublications": ["runID"],
        "playerNamePreferences": ["preferredName"],
        "shopEquipped": ["slot"], "runLabels": ["runLabel"],
    }
    for table, columns in required.items():
        found = db.query("SELECT column_name FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='" + table + "';").splitlines()
        if not set(columns).issubset(found):
            raise RuntimeError("Database is not the expected post-020 schema: " + table)
    if db.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name IN ('playerRecordings','playerSaves_test','demoEvents');") != "0":
        raise RuntimeError("Legacy tables still exist; this is not post-020")
    if db.query("SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND ((table_name='playerRuns' AND column_name='runLabel') OR (table_name='challenges' AND column_name='mapName') OR (table_name='shopEquipped' AND column_name='category'));") != "0":
        raise RuntimeError("Legacy duplicate fields still exist; this is not post-020")
    if db.query("SELECT COUNT(*) FROM information_schema.referential_constraints WHERE constraint_schema=DATABASE() AND constraint_name IN ('area_checkpoint_map_fk','winner_demo_category_fk','equipped_catalog_slot_fk');") != "3":
        raise RuntimeError("Post-020 constraints are missing")
    fingerprint = schema_hash(db)
    db.query(LEDGER)
    if ledger(db):
        raise RuntimeError("Migration history already exists; adoption refused")
    values = []
    for version in range(1, 21):
        name, checksum, _ = migrations[version]
        values.append(f"({version},'{name}','{checksum}','adopted',NOW(),'{fingerprint}')")
    db.query("INSERT INTO schemaMigrations VALUES " + ",".join(values) + ";")
    return fingerprint

def apply(db, migrations, *, allow_empty=False):
    rows = ledger(db)
    validate(rows, migrations)
    if not rows and not allow_empty:
        raise RuntimeError("Untracked database: explicitly adopt the verified post-020 baseline first")
    done = []
    for version, (name, checksum, sql) in migrations.items():
        if version in rows:
            continue
        db.query(f"INSERT INTO schemaMigrations(version,filename,sha256,state) VALUES({version},'{name}','{checksum}','applying');")
        # DDL commits implicitly. Failure leaves 'applying', refusing replay.
        db.query(sql)
        db.query(f"UPDATE schemaMigrations SET state='applied',appliedAt=NOW() WHERE version={version};")
        done.append(version)
    return done

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["status", "adopt-020", "apply"])
    parser.add_argument("--container", default="opencj-dev-db-1")
    parser.add_argument("--database", default="openCJ_cod4")
    parser.add_argument("--confirm-database", help="Required for writes; must exactly match --database")
    args = parser.parse_args()
    if args.action != "status" and args.confirm_database != args.database:
        parser.error("Write actions require --confirm-database matching --database")
    with MySQL(args.container, args.database) as db:
        migrations = files()
        lock(db, args.database)
        rows = ledger(db)
        validate(rows, migrations)
        if args.action == "status":
            print(json.dumps({"recorded": rows, "pending": [v for v in migrations if v not in rows]}, indent=2))
        elif args.action == "adopt-020":
            print("Adopted verified post-020 schema: " + adopt020(db, migrations))
        else:
            print("Applied migrations: " + ", ".join(map(str, apply(db, migrations))))

if __name__ == "__main__":
    main()
