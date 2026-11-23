"""Compare historical and current GSC SQL against varied synthetic tables."""

import argparse
import itertools
import json
import re
import time

from query_sql import MySQL
from query_sql import checkpoint_query
from query_sql import query
from sql_run_fixture import sql_literal

MODE_COMBINATIONS = tuple(itertools.product((0, 1), repeat=4))
FPS_FILTERS = ("('125')", "('125','mix')", "('125','mix','hax')")
SAVE_MODE_BITS = (32, 64, 128, 256)  # Elevate, any%, halfbeat and hard TAS.
TABLE_SCHEMAS = {
    "playerRuns": """
        runID INT PRIMARY KEY,
        playerID INT,
        mapID INT,
        finishcpID INT,
        finishTimeStamp DATETIME,
        archived INT,
        timePlayed INT,
        loadCount INT,
        saveCount INT,
        startTimeStamp DATETIME,
        FPSMode VARCHAR(3),
        ele INT,
        anyPct INT,
        hb INT,
        hardTAS INT,
        tutorial INT
    """,
    "playerSaves": """
        runID INT,
        saveNumber INT,
        explosiveJumps INT,
        FPSMode VARCHAR(3),
        flags INT,
        UNIQUE(runID, saveNumber)
    """,
    "runLabels": "runID INT PRIMARY KEY, runLabel VARCHAR(100)",
    "checkpointStatistics": """
        runID INT,
        cpID INT,
        timePlayed INT,
        explosiveJumps INT,
        loadCount INT,
        saveCount INT,
        UNIQUE(runID, cpID),
        INDEX checkpoint_time(cpID, timePlayed, explosiveJumps, runID, loadCount, saveCount)
    """,
    "playerDisplayNames": "playerID INT PRIMARY KEY, playerName VARCHAR(100)",
}


def synthetic_rows():
    """Vary owners, modes, missing saves and finish state without copying player data."""
    tables = {name: [] for name in TABLE_SCHEMAS}
    fps_modes = ("125", "mix", "hax")
    run_count = 240
    finished_run_start = 120
    finish_checkpoint_column = 3
    finish_date_column = 4
    all_mode_flags = sum(SAVE_MODE_BITS)
    for i in range(run_count):
        player_id = i % 3 + 1
        mode_flags = MODE_COMBINATIONS[i % len(MODE_COMBINATIONS)]
        fps_mode = fps_modes[i % len(fps_modes)]
        finished = i >= finished_run_start
        timestamp = "2026-01-%02d 00:%02d:%02d" % (i % 28 + 1, i // 60, i % 60)
        run = [
            i + 1,
            player_id,
            7 if i % 17 else 8,  # Include another map.
            71 if finished else None,
            timestamp if finished else None,
            int(i % 29 == 0),  # Include archived runs.
            i * 41 + 100,
            i % 13,
            i % 19,
            timestamp,
            fps_mode,
            *mode_flags,
            0,  # The historical oracle predates tutorial mode.
        ]
        # A finish ID alone, or a timestamp alone, must not count as a valid finish.
        if i in (5, 6):
            run[finish_checkpoint_column] = 71 if i == 5 else None
            run[finish_date_column] = None if i == 5 else timestamp
        tables["playerRuns"].append(run)

        if i % 11:
            current_flags = sum(bit * enabled for bit, enabled in zip(SAVE_MODE_BITS, mode_flags))
            saves = ((0, "125", 0), (4, "hax", all_mode_flags), (19, fps_mode, current_flags))
            for save_number, saved_fps, flags in saves:
                tables["playerSaves"].append([i + 1, save_number, i % 7, saved_fps, flags])
        if i % 2:
            tables["runLabels"].append([i + 1, "label " + str(i)])
        tables["checkpointStatistics"].append([i + 1, 71, i * 41 + 123, i % 7, i % 13, i % 19])
        if i % 5 == 0:
            tables["checkpointStatistics"].append([i + 1, 72, i * 41 + 124, i % 7, i % 13, i % 19])

    tables["playerDisplayNames"] = [[1, "Preferred name"], [2, "Account name"], [3, "Third"]]
    return tables


def create_fixture_tables(database):
    """Replace only the qa_ tables inside the caller's disposable schema."""
    rows_by_table = synthetic_rows()
    for table_name, columns in TABLE_SCHEMAS.items():
        fixture_name = "qa_" + table_name
        database.query("DROP TABLE IF EXISTS " + fixture_name + ";")
        database.query("CREATE TABLE " + fixture_name + " (" + columns + ");")
        values = []
        for row in rows_by_table[table_name]:
            values.append("(" + ",".join(sql_literal(value) for value in row) + ")")
        database.query("INSERT INTO " + fixture_name + " VALUES " + ",".join(values) + ";")


def fixture_query(database, sql):
    for table_name in TABLE_SCHEMAS:
        sql = re.sub(r"\b" + table_name + r"\b", "qa_" + table_name, sql)
    return database.query(sql + ";")


def compare_query(database, kind, options):
    """Return the current result after checking it against the historical query."""
    historical = fixture_query(database, query(kind, before=True, **options))
    current = fixture_query(database, query(kind, before=False, **options))
    assert historical == current, (kind, options, "historical", historical, "current", current)
    return current


def verify_board_queries(database):
    checks = 0
    for kind in ("runs", "leaderboard", "hud"):
        sort_columns = [
            "timePlayed",
            "explosiveJumps",
            "loadCount",
            "saveCount",
            "startTimeStamp" if kind == "runs" else "finishTimeStamp",
        ]
        combinations = itertools.product(
            MODE_COMBINATIONS, FPS_FILTERS, sort_columns, ("ASC", "DESC"), (0, 2)
        )
        for modes, fps_filter, primary_sort, direction, offset in combinations:
            sort_fields = [primary_sort, "timePlayed", "explosiveJumps"]
            if kind == "runs":
                sort_fields += ["loadCount", "saveCount", "startTimeStamp"]
            sort_clause = ", ".join(column + " " + direction for column in sort_fields)
            options = dict(
                player=1,
                mapid=7,
                current=10,
                cp="(71,72)",
                sort=sort_clause,
                fps=fps_filter,
                mode=modes,
                offset=offset,
                limit=2,
            )
            compare_query(database, kind, options)
            checks += 1

        for player_id, map_id, checkpoints, current_run in [
            (99, 7, "(71)", 0),
            (1, 99, "(NULL)", 0),
            (2, 7, "(72)", 125),
            (3, 8, "(71,72)", 10),
        ]:
            compare_query(
                database,
                kind,
                dict(player=player_id, mapid=map_id, cp=checkpoints, current=current_run),
            )
            checks += 1
        print("EQUIVALENCE", kind, checks, flush=True)
    return checks


def verify_checkpoint_queries(database):
    checks = 0
    for modes, fps_mode, metric, checkpoint_id in itertools.product(
        MODE_COMBINATIONS, ("125", "mix", "hax"), ("time", "rpgs"), (71, 72)
    ):
        options = dict(runid=10, cp=checkpoint_id, fps=fps_mode, mode=modes, metric=metric)
        historical = fixture_query(database, checkpoint_query(True, **options))
        current = fixture_query(database, checkpoint_query(False, **options))
        assert historical == current, (options, historical, current)
        checks += 1
    return checks


def verify_tied_records(database):
    """Different loads/dates expose choosing a newer run or the wrong tied checkpoint."""
    database.query(
        "UPDATE qa_checkpointStatistics SET timePlayed=100, explosiveJumps=2 WHERE runID>=121;"
    )
    database.query("UPDATE qa_checkpointStatistics SET loadCount=99 WHERE cpID=72;")
    checks = 0
    total_column = 0
    leaderboard_run_id_column = 11
    hud_player_id_column = 5
    hud_load_count_column = 4
    for kind in ("leaderboard", "hud"):
        for sort_clause, checkpoints in itertools.product(
            ("timePlayed ASC, explosiveJumps ASC", "explosiveJumps DESC, timePlayed DESC"),
            ("(71)", "(71,72)"),
        ):
            options = dict(cp=checkpoints, current=130, sort=sort_clause, limit=999)
            result = compare_query(database, kind, options)
            checks += 1
            rows = [row.split("\t") for row in result.splitlines()]
            if kind == "leaderboard":
                run_ids = [int(row[leaderboard_run_id_column]) for row in rows]
                assert run_ids == [121, 122, 123], ("oldest tied runs", run_ids)
            else:
                player_ids = [int(row[hud_player_id_column]) for row in rows]
                load_counts = [int(row[hud_load_count_column]) for row in rows]
                assert player_ids == [1, 2, 3] and load_counts == [3, 4, 5], (
                    "oldest run and lowest tied checkpoint",
                    player_ids,
                    load_counts,
                )
            assert all(int(row[total_column]) == 3 for row in rows), ("tied total", rows)
            checks += 1
    return checks


def verify_latest_save_filter(database):
    # Run 3 has an older Classic save and a latest Any save. Do not fall back.
    result = fixture_query(
        database, query("runs", False, player=3, mapid=7, fps="('125')", limit=999)
    )
    run_id_column = 1
    assert all(row.split("\t")[run_id_column] != "3" for row in result.splitlines()), result
    return 1


def verify(database):
    started_at = time.monotonic()
    create_fixture_tables(database)
    checks = verify_board_queries(database)
    checks += verify_checkpoint_queries(database)
    checks += verify_tied_records(database)
    checks += verify_latest_save_filter(database)
    return {
        "checks": checks,
        "passed": True,
        "seconds": round(time.monotonic() - started_at, 2),
        "coverage": (
            "exact GSC SQL; 16 mode masks; FPS inclusion sets; five sorts both ways; pages; "
            "multiple checkpoints; owners/maps; invalid/archived/finished runs; latest-save filtering"
        ),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", required=True)
    parser.add_argument("--database", required=True)
    options = parser.parse_args()
    if not options.container.startswith(("opencj-capacity-db-", "opencj-query-")):
        parser.error("Select the capacity runner's disposable query container.")
    if not options.database.startswith(("opencj_verify_190_", "opencj_query_")):
        parser.error("Select the capacity runner's disposable query schema.")
    with MySQL(options.container, options.database) as database:
        print(json.dumps(verify(database)), flush=True)


if __name__ == "__main__":
    main()
