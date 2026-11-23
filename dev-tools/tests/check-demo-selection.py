"""Execute engine-generated selection queries against connection-local SQL fixtures."""

import argparse
import json
from pathlib import Path
import re
import subprocess

from compose_environment import database_container

QUERY_KINDS = {"walkthrough", "speedrun", "lowrpg", "nearby"}
EXPECTED_RUN_IDS = {
    "walkthrough": [2, 10, 1],
    "speedrun": [3, 2, 10, 8, 1],
    "lowrpg": [1, 8, 2, 10],
    "nearby": [5, 2, 10, 8, 1],
}


def read_queries(log_path):
    queries = dict(
        re.findall(r"DEMO SELECTION QUERY (\w+) (SELECT[^\n]+)", log_path.read_text())
    )
    if set(queries) != QUERY_KINDS:
        raise ValueError(
            "Expected all four queries from the demo-selection engine fixture"
        )
    return queries


def build_fixture_sql():
    """Shadow the real tables only on this connection; route IDs match the GSC fixture."""
    statements = ["""
        CREATE TEMPORARY TABLE demoRuns(
            runID INT, modeMask INT, frameCount INT, ready INT,
            timePlayed INT, explosiveJumps INT, FPSMode VARCHAR(8)
        );
        CREATE TEMPORARY TABLE demoWinners(
            runID INT, mapID INT, routeID INT, kind VARCHAR(20),
            modeMask INT, FPSMode VARCHAR(8)
        );
    """]
    # run ID, map ID, route ID, mode mask, FPS mode, readiness, time, and RPG shots.
    # Routes 11/12 share the checkpoint; 13 is an unrelated route.
    records = [
        (1, 7, 11, 0, "mix", 1, 100, 0),
        (2, 7, 12, 0, "mix", 1, 90, 2),
        (3, 7, 11, 4, "mix", 1, 80, 0),
        (4, 7, 11, 2, "mix", 1, 70, 0),
        (5, 7, 13, 0, "mix", 1, 60, 0),
        (6, 8, 11, 0, "mix", 1, 50, 0),
        (7, 7, 11, 0, "hax", 1, 40, 0),
        (8, 7, 11, 0, "125", 1, 95, 1),
        (9, 7, 12, 0, "125", 0, 30, 0),
        (10, 7, 12, 0, "mix", 1, 90, 2),
        (11, 7, 12, 1, "mix", 1, 20, 0),
    ]
    for (
        run_id,
        map_id,
        route_id,
        mode_mask,
        fps_mode,
        ready,
        elapsed_ms,
        rpg_shots,
    ) in records:
        statements.append(f"""
            INSERT INTO demoRuns
            VALUES({run_id},{mode_mask},100,{ready},{elapsed_ms},{rpg_shots},'{fps_mode}');
        """)
        for kind in ("walkthrough", "speedrun", "lowrpg"):
            statements.append(f"""
                INSERT INTO demoWinners
                VALUES({run_id},{map_id},{route_id},'{kind}',{mode_mask},'{fps_mode}');
            """)
    return "\n".join(statements)


def execute_queries(queries):
    statements = [build_fixture_sql()]
    for kind, query in queries.items():
        statements.append(f"SELECT '{kind}';\n{query};")
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
        input="\n".join(statements),
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError("Selection SQL failed: " + result.stderr)
    selected_runs = {}
    kind = None
    for line in result.stdout.splitlines():
        if line in QUERY_KINDS:
            kind = line
            selected_runs[kind] = []
        elif kind is not None:
            selected_runs[kind].append(int(line.split("\t")[0]))
        else:
            raise RuntimeError("Unexpected SQL output before a query label: " + line)
    return selected_runs


def verify(log_path):
    selected_runs = execute_queries(read_queries(log_path))
    assert selected_runs == EXPECTED_RUN_IDS, (selected_runs, EXPECTED_RUN_IDS)
    report = {
        "failures": 0,
        "queryChecks": len(EXPECTED_RUN_IDS),
        "selectedRunIDs": selected_runs,
        "covers": [
            "shared routes",
            "mode subsets",
            "walkthrough clean modes",
            "hax walkthrough uses mix",
            "compatible FPS",
            "readiness",
            "same map",
            "stable ties",
            "speedrun time order",
            "low-RPG order",
            "no stale route in spatial fallback",
        ],
        "productionWrites": False,
    }
    (log_path.parent / "selection-sql.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(report), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    options = parser.parse_args()
    if not options.log.is_file():
        parser.error("The captured fixture log does not exist")
    verify(options.log)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
