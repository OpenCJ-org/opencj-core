"""Synthetic run tables shared by finish-sound and record-notice SQL scenarios."""

from dataclasses import dataclass
from pathlib import Path
import re
import subprocess

from compose_environment import database_container
from query_sql import gsc_expression

ROOT = Path(__file__).resolve().parents[2]
RUN_COLUMNS = (
    "runID",
    "playerID",
    "mapID",
    "finishcpID",
    "finishTimeStamp",
    "FPSMode",
    "ele",
    "anyPct",
    "hb",
    "hardTAS",
    "tutorial",
)


@dataclass(frozen=True)
class RunFixture:
    run_id: int
    player_id: int | None = None
    time_ms: int = 1000
    rpg_count: int = 10
    checkpoint_id: int = 1
    map_id: int = 1
    fps_mode: str = "mix"
    used_elevators: int = 0
    any_percent: int = 0
    halfbeat: int = 0
    hard_tas: int = 0
    tutorial: int = 0
    finished: bool = True
    with_statistics: bool = True

    @property
    def owner_id(self):
        # Most podium scenarios give each run a different player.
        return self.run_id if self.player_id is None else self.player_id

    def player_run_row(self, finish_timestamp):
        return [
            self.run_id,
            self.owner_id,
            self.map_id,
            self.checkpoint_id,
            finish_timestamp if self.finished else None,
            self.fps_mode,
            self.used_elevators,
            self.any_percent,
            self.halfbeat,
            self.hard_tas,
            self.tutorial,
        ]

    def statistics_row(self):
        return [self.run_id, self.checkpoint_id, self.time_ms, self.rpg_count]


def sql_literal(value):
    if value is None:
        return "NULL"
    if isinstance(value, int):
        return str(value)
    return "'" + value.replace("'", "''") + "'"


def fixture_cte(table_name, columns, rows):
    """Shadow one production table with connection-local synthetic rows."""
    selects = []
    for row_index, row in enumerate(rows):
        if len(row) != len(columns):
            raise ValueError("Fixture row does not match its declared columns: " + table_name)
        fields = []
        for column, value in zip(columns, row):
            field = sql_literal(value)
            if row_index == 0:
                field += " AS " + column
            fields.append(field)
        selects.append("SELECT " + ",".join(fields))
    if not selects:
        raise ValueError("Fixture CTE needs at least one row: " + table_name)
    return table_name + " AS (" + " UNION ALL ".join(selects) + ")"


def read_run_query(relative_script, function_name, run_id):
    """Read a literal SQL concatenation from its public GSC query-builder boundary."""
    source = (ROOT / "server-gsc/opencj" / relative_script).read_text()
    builder = re.search(r"(?ms)^" + re.escape(function_name) + r"\s*\([^)]*\)\s*\{.*?^\}", source)
    if not builder:
        raise RuntimeError("Production query builder was not found: " + function_name)
    expression = re.search(r'\breturn\s+((?:"(?:[^"\\]|\\.)*"|[^;])+);', builder[0])
    if not expression:
        raise RuntimeError("Production query return was not found: " + function_name)
    return gsc_expression(expression[1], {"runID": run_id})


def prepend_fixture_tables(query, fixtures):
    if not query.startswith("WITH "):
        raise ValueError("The ranking fixture requires a production CTE query")
    return "WITH " + ",".join(fixtures) + "," + query[len("WITH ") :] + ";"


def query_runtime_database(query):
    """Execute an explicitly requested read-only scenario on the selected test installation."""
    result = subprocess.run(
        [
            "docker",
            "exec",
            "-i",
            database_container(),
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_PASSWORD" exec mysql -N -u opencj openCJ_cod4',
        ],
        input=query,
        text=True,
        capture_output=True,
        timeout=60,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()
