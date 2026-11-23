"""Read-only exact-category record scenarios using the production ranking SQL."""

from dataclasses import replace

from sql_run_fixture import RUN_COLUMNS
from sql_run_fixture import RunFixture
from sql_run_fixture import fixture_cte
from sql_run_fixture import prepend_fixture_tables
from sql_run_fixture import query_runtime_database
from sql_run_fixture import read_run_query


def run_fixture(run_id, **overrides):
    """Use one prior owner and a ten-second finish unless a scenario says otherwise."""
    return replace(RunFixture(run_id, player_id=1, time_ms=10000), **overrides)


def record_tables(runs):
    statistics = []
    player_ids = set()
    for run in runs:
        player_ids.add(run.owner_id)
        if run.with_statistics:
            statistics.append(run.statistics_row())
    return [
        fixture_cte(
            "playerRuns",
            RUN_COLUMNS,
            [run.player_run_row("2026-11-13 12:00:00") for run in runs],
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
            statistics or [[0, 0, 0, 0]],
        ),
        fixture_cte(
            "playerDisplayNames",
            ["playerID", "playerName"],
            [[player_id, "Fixture " + str(player_id)] for player_id in sorted(player_ids)],
        ),
    ]


def cases():
    production_query = read_run_query("recordnotices.gsc", "finishQuery", 100)
    scenarios = []

    def add_scenario(name, others=(), current=None, server=None, personal=None, empty=False):
        if current is None:
            current = run_fixture(100, player_id=10, time_ms=8000, rpg_count=8)
        runs = [current] + list(others)
        query = prepend_fixture_tables(production_query, record_tables(runs))
        scenarios.append((name, query, server, personal, empty))

    add_scenario("first category finish has no prior record")
    add_scenario("ordinary comparable finish", [run_fixture(1)], server=[(10000, 10)] * 2)
    add_scenario(
        "own previous best",
        [run_fixture(1, player_id=10)],
        server=[(10000, 10)] * 2,
        personal=[(10000, 10)] * 2,
    )
    add_scenario(
        "separate time and RPG leaders",
        [run_fixture(1, time_ms=6000, rpg_count=12), run_fixture(2, time_ms=12000, rpg_count=6)],
        server=[(6000, 12), (12000, 6)],
    )
    add_scenario(
        "personal baseline differs from server",
        [
            run_fixture(1, time_ms=6000, rpg_count=6),
            run_fixture(2, player_id=10, time_ms=9000, rpg_count=9),
        ],
        server=[(6000, 6)] * 2,
        personal=[(9000, 9)] * 2,
    )
    add_scenario(
        "time tie uses RPG tiebreak",
        [run_fixture(1, time_ms=6000, rpg_count=12), run_fixture(2, time_ms=6000, rpg_count=10)],
        server=[(6000, 10)] * 2,
    )
    add_scenario(
        "RPG tie uses time tiebreak",
        [run_fixture(1, time_ms=9000, rpg_count=6), run_fixture(2, time_ms=6000, rpg_count=6)],
        server=[(6000, 6)] * 2,
    )
    add_scenario(
        "alternate end on same route", [run_fixture(1, checkpoint_id=2)], server=[(10000, 10)] * 2
    )
    for name, other in [
        ("other route", run_fixture(1, checkpoint_id=3)),
        ("other map", run_fixture(1, map_id=2)),
        ("retired finish", run_fixture(1, checkpoint_id=4)),
        ("unfinished", run_fixture(1, finished=False)),
        ("missing stats", run_fixture(1, with_statistics=False)),
    ]:
        add_scenario(name + " excluded", [other])
    for mode, attribute in [
        ("ele", "used_elevators"),
        ("anyPct", "any_percent"),
        ("hb", "halfbeat"),
        ("tas", "hard_tas"),
    ]:
        add_scenario(
            mode + " relaxed cannot beat strict baseline",
            [run_fixture(1)],
            current=run_fixture(100, player_id=10, time_ms=1, **{attribute: 1}),
        )
        add_scenario(
            mode + " strict does not compare to relaxed baseline",
            [run_fixture(1, **{attribute: 1})],
        )
        add_scenario(
            mode + " matching mode compares",
            [run_fixture(1, **{attribute: 1})],
            current=run_fixture(100, player_id=10, **{attribute: 1}),
            server=[(10000, 10)] * 2,
        )
    for prior_fps, current_fps in [
        ("125", "mix"),
        ("mix", "125"),
        ("125", "hax"),
        ("hax", "125"),
        ("mix", "hax"),
        ("hax", "mix"),
    ]:
        add_scenario(
            prior_fps + " vs " + current_fps + " separate FPS categories",
            [run_fixture(1, fps_mode=prior_fps)],
            current=run_fixture(100, player_id=10, fps_mode=current_fps),
        )
    add_scenario(
        "combined mode exact match",
        [run_fixture(1, any_percent=1, halfbeat=1)],
        current=run_fixture(100, player_id=10, any_percent=1, halfbeat=1),
        server=[(10000, 10)] * 2,
    )
    add_scenario(
        "combined mode partial overlap excluded",
        [run_fixture(1, any_percent=1)],
        current=run_fixture(100, player_id=10, any_percent=1, halfbeat=1),
    )
    add_scenario(
        "current unfinished gives no announcement",
        current=run_fixture(100, player_id=10, finished=False),
        empty=True,
    )
    add_scenario(
        "current missing stats gives no announcement",
        current=run_fixture(100, player_id=10, with_statistics=False),
        empty=True,
    )
    add_scenario(
        "current retired finish gives no announcement",
        current=run_fixture(100, player_id=10, checkpoint_id=4),
        empty=True,
    )
    add_scenario("tutorial prior finish excluded", [run_fixture(1, tutorial=1)])
    add_scenario(
        "current tutorial gives no announcement",
        current=run_fixture(100, player_id=10, tutorial=1),
        empty=True,
    )
    return scenarios


def verify(sql):
    """Compare the prior time/RPG leaders; the VM checks audience and message text."""
    checks = 0
    # The production query returns two server boards followed by two personal boards.
    board_count = 4
    prior_time_column = 10
    prior_rpg_column = 11
    for name, query, server, personal, empty in cases():
        output = sql(query)
        rows = [line.split("\t") for line in output.splitlines()] if output else []
        expected_rows = 0 if empty else board_count
        assert len(rows) == expected_rows, (name, "row count", len(rows), expected_rows)
        if not empty:
            expected = (server or [(None, None)] * 2) + (personal or [(None, None)] * 2)
            actual = []
            for row in rows:
                prior_values = []
                for column in (prior_time_column, prior_rpg_column):
                    value = row[column]
                    prior_values.append(None if value == "NULL" else int(value))
                actual.append(tuple(prior_values))
            assert actual == expected, (name, actual, expected)
        checks += 1
    return checks


if __name__ == "__main__":
    print("NOTIFICATION SQL PASS", verify(query_runtime_database))
