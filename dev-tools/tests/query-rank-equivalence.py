"""Check current finish expectations and historical equivalence on competitive runs."""

import argparse
import json
import random
import runpy

from query_sql import MySQL
from query_sql import ROOT
from query_sql import query
from sql_run_fixture import RUN_COLUMNS
from sql_run_fixture import RunFixture
from sql_run_fixture import fixture_cte
from sql_run_fixture import prepend_fixture_tables

RANDOM_SEED = 160626
RANDOM_SCENARIOS = 300
RUNS_PER_SCENARIO = 40
CURRENT_PLAYER_ID = 10


def verify_current_expectations(database):
    """Include tutorial exclusions in independent current-behavior expectations."""
    checks = 0
    for filename in ("finish-sounds.py", "record-notices-72.py"):
        scenarios = runpy.run_path(str(ROOT / "dev-tools/tests" / filename))
        checks += scenarios["verify"](database.query)
    return checks


def randomized_runs(randomizer, scenario_index):
    """Use repeatable ties, missing finishes/statistics, modes and rival owners."""
    runs = []
    for run_id in range(1, RUNS_PER_SCENARIO + 1):
        is_current_run = run_id == RUNS_PER_SCENARIO
        player_id = CURRENT_PLAYER_ID if is_current_run else randomizer.randrange(1, 13)
        map_id = 1 if is_current_run or randomizer.random() < 0.9 else 2
        checkpoint_id = randomizer.choice((1, 1, 1, 2, 3, 4))
        finished = is_current_run or randomizer.random() < 0.9
        fps_mode = randomizer.choice(("125", "mix", "hax"))
        modes = [randomizer.randrange(2) for _ in range(4)]
        if scenario_index % 3 == 0:
            modes = [1] * 4 if is_current_run else [0] * 4
            fps_mode = "hax" if is_current_run else "mix"
            checkpoint_id = 1
        with_statistics = randomizer.random() < 0.97
        time_ms = 0
        rpg_count = 0
        if with_statistics:
            time_ms = randomizer.choice((100, 100, 200, 300))
            rpg_count = randomizer.randrange(3)
        used_elevators, any_percent, halfbeat, hard_tas = modes
        runs.append(
            RunFixture(
                run_id,
                player_id=player_id,
                map_id=map_id,
                checkpoint_id=checkpoint_id,
                finished=finished,
                fps_mode=fps_mode,
                used_elevators=used_elevators,
                any_percent=any_percent,
                halfbeat=halfbeat,
                hard_tas=hard_tas,
                time_ms=time_ms,
                rpg_count=rpg_count,
                with_statistics=with_statistics,
                tutorial=0,  # Frozen queries predate tutorial eligibility.
            )
        )
    return runs


def ranking_tables(runs):
    statistics = [run.statistics_row() for run in runs if run.with_statistics]
    return [
        fixture_cte(
            "playerRuns",
            RUN_COLUMNS,
            [run.player_run_row("2026-01-01 00:00:00") for run in runs],
        ),
        fixture_cte(
            "checkpoints",
            ["cpID", "finishRouteID", "retired"],
            [[1, 1, 0], [2, 1, 0], [3, 2, 0], [4, 1, 1]],
        ),
        fixture_cte("routes", ["routeID", "routeName"], [[1, "easy"], [2, "hard"]]),
        fixture_cte(
            "checkpointStatistics",
            ["runID", "cpID", "timePlayed", "explosiveJumps"],
            statistics,
        ),
        fixture_cte(
            "playerDisplayNames",
            ["playerID", "playerName"],
            [[player_id, "Synthetic " + str(player_id)] for player_id in range(1, 13)],
        ),
    ]


def verify(database):
    checks = verify_current_expectations(database)
    randomizer = random.Random(RANDOM_SEED)
    for scenario_index in range(RANDOM_SCENARIOS):
        tables = ranking_tables(randomized_runs(randomizer, scenario_index))
        for kind in ("sound", "notice"):
            historical_query = prepend_fixture_tables(
                query(kind, before=True, current=RUNS_PER_SCENARIO), tables
            )
            current_query = prepend_fixture_tables(
                query(kind, before=False, current=RUNS_PER_SCENARIO), tables
            )
            historical = database.query(historical_query)
            current = database.query(current_query)
            assert historical == current, (kind, scenario_index, historical, current)
            checks += 1
    return {
        "checks": checks,
        "passed": True,
        "randomSeed": RANDOM_SEED,
        "coverage": (
            "current expected categories including tutorials; 300 repeatable competitive corpora; "
            "exact ties, own repeats, opponent ranks, retired finishes, missing statistics, "
            "incomplete runs and mode/FPS eligibility"
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
