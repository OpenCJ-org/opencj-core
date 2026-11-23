"""Replay validated camera writes into connection-local temporary tables."""

import argparse
import json
from pathlib import Path
import re
import subprocess

from compose_environment import database_container

EXPECTED_WRITE_COUNT = 6
SQL_TIMEOUT_SECONDS = 30
CAMERA_WRITE = re.compile(
    r"CALL\s+setPlayerSetting\s*\(\s*7\s*,\s*"
    r"'(thirdpersondistance|thirdpersonangle)'\s*,\s*'(-?\d+)'\s*\)"
)


def recorded_writes(log_path):
    """Only the six synthetic player's camera-geometry calls may be replayed."""
    writes = []
    for line in log_path.read_text().splitlines():
        if not line.startswith("CAMERA SQL "):
            continue
        statement = line.removeprefix("CAMERA SQL ")
        if not CAMERA_WRITE.fullmatch(statement):
            raise ValueError("Camera log contains an unexpected SQL statement.")
        writes.append(statement)
    if len(writes) != EXPECTED_WRITE_COUNT:
        raise ValueError(f"Expected {EXPECTED_WRITE_COUNT} camera writes, found {len(writes)}.")
    return writes


def replay_sql(writes):
    """Shadow both tables used by setPlayerSetting for this one connection."""
    setup = """
        CREATE TEMPORARY TABLE settings (
            settingID INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
            settingName VARCHAR(256) NOT NULL UNIQUE
        );
        CREATE TEMPORARY TABLE playerSettings (
            playerID INT NOT NULL,
            settingID INT NOT NULL,
            value VARCHAR(256),
            PRIMARY KEY(playerID, settingID)
        );
    """
    # This is the same result shape read by settings::loadSettingsFromDatabase.
    verification = """
        SELECT a.settingName, b.value
        FROM settings a
        INNER JOIN playerSettings b ON a.settingID = b.settingID
        WHERE b.playerID = 7
        ORDER BY a.settingName;
        SELECT COUNT(*) FROM playerSettings;
    """
    return setup + "\n".join(statement + ";" for statement in writes) + verification


def run(log_path):
    writes = recorded_writes(log_path)
    result = subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            database_container(),
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root openCJ_cod4',
        ],
        input=replay_sql(writes),
        text=True,
        capture_output=True,
        timeout=SQL_TIMEOUT_SECONDS,
    )
    if result.returncode:
        raise RuntimeError("Temporary-table camera replay failed: " + result.stderr.strip())
    rows = [line.split("\t") for line in result.stdout.strip().splitlines()]
    expected = [["thirdpersonangle", "90"], ["thirdpersondistance", "180"], ["2"]]
    if rows != expected:
        raise AssertionError(f"Stored camera geometry: expected {expected}, got {rows}")
    report = {
        "checks": 3,
        "failures": 0,
        "capturedWrites": len(writes),
        "storedValues": dict(rows[:-1]),
        "productionWrites": False,
    }
    (log_path.parent / "settings-sql.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    run(parser.parse_args().log)


if __name__ == "__main__":
    main()
