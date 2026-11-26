"""Check which finished runs earn challenges, using the production award query.

The query is read from challenges.gsc (awardSQL) and its INSERT target is dropped,
so only the SELECT runs; synthetic rows shadow the tables through CTEs. Nothing
is written. This proves the database-side rule, not the in-game finish flow.
"""

import importlib.util
from pathlib import Path

from sql_run_fixture import RUN_COLUMNS
from sql_run_fixture import RunFixture
from sql_run_fixture import fixture_cte
from sql_run_fixture import query_runtime_database

ROOT = Path(__file__).resolve().parents[2]
AWARD_TARGET = "INSERT IGNORE INTO challengeCompletions(playerID,challengeKey,runID,pointsAwarded)"
CHALLENGE_COLUMNS = ("challengeKey", "points", "mapID", "routeID", "active", "fpsModes",
                     "allowedModes", "requiredModes", "maxTimeMs", "maxRPG")
ALL_RUN_MODES = 15  # Any%, elevators, halfbeat and hard TAS may all be used.


def award_select(run_filter):
    """The production award SELECT for the runs that run_filter keeps."""
    spec = importlib.util.spec_from_file_location(
        "challenge_route_link", Path(__file__).with_name("challenge-route-link.py"))
    route_link = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(route_link)
    source = (ROOT / "server-gsc/opencj/challenges.gsc").read_text()
    statement = route_link.build_sql(source, "awardSQL", [run_filter])
    if not statement.startswith(AWARD_TARGET):
        raise ValueError("awardSQL no longer starts with the expected INSERT target")
    return statement[len(AWARD_TARGET):]


def awarded_runs(runs):
    """Run IDs that would earn the fixture challenge, as one SQL statement."""
    challenge = ["fixture.easy", 10, 1, 7, 1, "125,mix,hax", ALL_RUN_MODES, 0, 0, -1]
    tables = [
        fixture_cte("challenges", CHALLENGE_COLUMNS, [challenge]),
        fixture_cte("playerRuns", RUN_COLUMNS,
                    [run.player_run_row("2026-11-26 12:00:00") for run in runs]),
        fixture_cte("checkpoints", ["cpID", "finishRouteID"], [[1, 7]]),
        fixture_cte("checkpointStatistics", ["runID", "cpID", "timePlayed", "explosiveJumps"],
                    [run.statistics_row() for run in runs]),
    ]
    run_ids = ",".join(str(run.run_id) for run in runs)
    select = award_select("AND r.runID IN (" + run_ids + ")")
    return ("WITH " + ",".join(tables) +
            # The award's run column is unnamed in production, so MySQL names it MIN(r.runID).
            " SELECT COALESCE(GROUP_CONCAT(a.`MIN(r.runID)` ORDER BY 1), 'none')"
            " FROM (" + select + ") a;")


def scenarios():
    return [
        ("a normal finish earns the challenge",
         [RunFixture(1, player_id=10)], "1"),
        ("a tutorial finish never earns it",
         [RunFixture(2, player_id=10, tutorial=1)], "none"),
        ("only the player's normal finish counts beside a tutorial one",
         [RunFixture(3, player_id=10, tutorial=1), RunFixture(4, player_id=10)], "4"),
        ("an earlier tutorial finish does not take the award's run",
         [RunFixture(5, player_id=11, tutorial=1), RunFixture(6, player_id=11)], "6"),
        ("an unfinished run earns nothing",
         [RunFixture(7, player_id=12, finished=False)], "none"),
    ]


def main():
    cases = scenarios()
    output = query_runtime_database("\n".join(awarded_runs(runs) for _, runs, _ in cases))
    results = output.splitlines()
    assert len(results) == len(cases), ("result count", len(results), len(cases))
    for (name, _, expected), actual in zip(cases, results):
        assert actual == expected, (name, "expected", expected, "got", actual)
    print("CHALLENGE AWARD SQL PASS:", len(cases), "read-only scenarios")


if __name__ == "__main__":
    main()

