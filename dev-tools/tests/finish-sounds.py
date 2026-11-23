"""Exercise finish-ranking SQL with connection-local synthetic run fixtures."""

from sql_run_fixture import RUN_COLUMNS
from sql_run_fixture import RunFixture
from sql_run_fixture import fixture_cte
from sql_run_fixture import prepend_fixture_tables
from sql_run_fixture import query_runtime_database
from sql_run_fixture import read_run_query


def finish_tables(runs, checkpoints):
    statistics = []
    for run in runs:
        if run.with_statistics:
            statistics.append(run.statistics_row())
    return [
        fixture_cte(
            "playerRuns",
            RUN_COLUMNS,
            [run.player_run_row("2026-10-05 12:00:00") for run in runs],
        ),
        fixture_cte(
            "checkpoints",
            ["cpID", "finishRouteID"],
            checkpoints or [[1, "easy"], [2, "easy"], [3, "hard"]],
        ),
        fixture_cte(
            "checkpointStatistics",
            ["runID", "cpID", "timePlayed", "explosiveJumps"],
            statistics or [[0, 0, 0, 0]],
        ),
    ]


def cases():
    production_query = read_run_query("finishsounds.gsc", "recordQuery", 100)
    scenarios = []

    def add_scenario(name, others=(), current=None, expected=1, checkpoints=None):
        if current is None:
            current = RunFixture(100, player_id=10)
        runs = [current] + list(others)
        query = prepend_fixture_tables(production_query, finish_tables(runs, checkpoints))
        scenarios.append((name, query, expected))

    better = [RunFixture(i, time_ms=i * 100, rpg_count=i) for i in (1, 2, 3)]
    add_scenario("first finish")
    add_scenario("fourth on both boards", better, expected=0)
    add_scenario(
        "third on time only",
        [
            RunFixture(1, time_ms=100, rpg_count=1),
            RunFixture(2, time_ms=200, rpg_count=2),
            RunFixture(3, time_ms=2000, rpg_count=3),
        ],
    )
    add_scenario(
        "third on low RPG only",
        [
            RunFixture(1, time_ms=100, rpg_count=1),
            RunFixture(2, time_ms=200, rpg_count=2),
            RunFixture(3, time_ms=300, rpg_count=20),
        ],
    )
    add_scenario(
        "first time but fourth low RPG",
        [RunFixture(i, time_ms=2000 + i, rpg_count=i) for i in (1, 2, 3)],
    )
    add_scenario(
        "first low RPG but fourth time",
        [RunFixture(i, time_ms=i * 100, rpg_count=20) for i in (1, 2, 3)],
    )
    add_scenario(
        "slower repeat of own record",
        [RunFixture(1, player_id=10, time_ms=500, rpg_count=5)],
        expected=0,
    )
    add_scenario("exact repeat of own record", [RunFixture(1, player_id=10)], expected=0)
    add_scenario("new own time record", [RunFixture(1, player_id=10, time_ms=2000, rpg_count=5)])
    add_scenario("new own low RPG record", [RunFixture(1, player_id=10, time_ms=500, rpg_count=20)])
    add_scenario(
        "one position per opponent",
        [RunFixture(i, player_id=1, time_ms=100 + i, rpg_count=1) for i in range(1, 8)],
    )
    add_scenario(
        "equal times use fewer RPGs",
        better,
        current=RunFixture(100, player_id=10, time_ms=300, rpg_count=2),
    )
    add_scenario(
        "equal RPGs use faster time",
        better,
        current=RunFixture(100, player_id=10, time_ms=250, rpg_count=3),
    )
    add_scenario("exact ties retain older places", [RunFixture(i) for i in (1, 2, 3)], expected=0)
    add_scenario(
        "same route alternative finish",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, checkpoint_id=2) for i in (1, 2, 3)],
        expected=0,
    )
    add_scenario(
        "other routes excluded",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, checkpoint_id=3) for i in (1, 2, 3)],
    )
    add_scenario(
        "other maps excluded",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, map_id=2) for i in (1, 2, 3)],
    )
    add_scenario(
        "unfinished excluded",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, finished=False) for i in (1, 2, 3)],
    )
    add_scenario(
        "missing finish stats excluded",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, with_statistics=False) for i in (1, 2, 3)],
    )
    add_scenario(
        "current unfinished", current=RunFixture(100, player_id=10, finished=False), expected=0
    )
    add_scenario(
        "current missing stats",
        current=RunFixture(100, player_id=10, with_statistics=False),
        expected=0,
    )
    add_scenario(
        "hax excluded from mix",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, fps_mode="hax") for i in (1, 2, 3)],
    )
    add_scenario(
        "125 included in mix",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, fps_mode="125") for i in (1, 2, 3)],
        expected=0,
    )
    add_scenario(
        "mix excluded from 125", better, current=RunFixture(100, player_id=10, fps_mode="125")
    )
    add_scenario(
        "mix included in hax",
        better,
        current=RunFixture(100, player_id=10, fps_mode="hax"),
        expected=0,
    )
    add_scenario(
        "125 included in hax",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, fps_mode="125") for i in (1, 2, 3)],
        current=RunFixture(100, player_id=10, fps_mode="hax"),
        expected=0,
    )
    for mode, attribute in [
        ("ele", "used_elevators"),
        ("anyPct", "any_percent"),
        ("hb", "halfbeat"),
        ("tas", "hard_tas"),
    ]:
        add_scenario(
            mode + " disallowed runs excluded",
            [RunFixture(i, time_ms=i * 100, rpg_count=i, **{attribute: 1}) for i in (1, 2, 3)],
        )
        add_scenario(
            mode + " includes clean runs",
            better,
            current=RunFixture(100, player_id=10, **{attribute: 1}),
            expected=0,
        )

    add_scenario(
        "tutorial prior runs excluded",
        [RunFixture(i, time_ms=i * 100, rpg_count=i, tutorial=1) for i in (1, 2, 3)],
    )
    add_scenario(
        "current tutorial gives ordinary completion",
        current=RunFixture(100, player_id=10, tutorial=1),
        expected=0,
    )
    return scenarios


def verify(sql):
    scenarios = cases()
    output = sql("\n".join(query for _, query, _ in scenarios))
    results = output.splitlines()
    assert len(results) == len(scenarios), ("ranking result count", len(results), len(scenarios))
    for (name, _, expected), result in zip(scenarios, results):
        assert result == str(expected), (name, result, expected)
    return len(scenarios)


if __name__ == "__main__":
    print("FINISH SOUND SQL PASS:", verify(query_runtime_database), "read-only MySQL cases")
