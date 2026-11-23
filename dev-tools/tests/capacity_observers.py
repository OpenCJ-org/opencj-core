"""Observe SQL function boundaries only in the capacity runner's private script copy."""

import json
from pathlib import Path
import re

from query_sql import query

ROOT = Path(__file__).resolve().parents[2]
PLAYER_PLACEHOLDER = 987654321


def rename_function(source, name, replacement, parameter_count):
    pattern = re.compile(r"(?m)^" + re.escape(name) + r"\s*\(([^)]*)\)\s*\{")
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise RuntimeError("Expected one production function: " + name)
    parameters = [value.strip() for value in matches[0][1].split(",") if value.strip()]
    if len(parameters) != parameter_count:
        raise RuntimeError("Production function parameters changed: " + name)
    match = matches[0]
    declaration = replacement + "(" + ", ".join(parameters) + ")\n{"
    return source[: match.start()] + declaration + source[match.end() :]


def install_sql_observers(mod, worker_count):
    """Time whole requests, preserving admission failures and the original result shape."""
    path = mod / "opencj/mysql.gsc"
    source = rename_function(path.read_text(), "_request", "_capacityRealRequest", 6)
    source = rename_function(source, "mysqlSyncQuery", "_capacityRealSyncQuery", 1)
    if worker_count != 4:
        source, changed = re.subn(
            r"level\.sqlConstants\.workerCount\s*=\s*4\s*;",
            f"level.sqlConstants.workerCount = {worker_count};",
            source,
        )
        if changed != 1:
            raise RuntimeError("Worker comparison needs one known worker-count setting")
    source += r"""
// Capacity observation changes no arguments or results of the production request.
_request(query, policy, key, scope, queueWaitMs, retainRows)
{
    startedAtMs = capacityClock();
    result = _capacityRealRequest(query, policy, key, scope, queueWaitMs, retainRows);
    if(isDefined(result))
    {
        openCJ\platformTest::queryMetric(policy, startedAtMs, result);
    }
    return result;
}

mysqlSyncQuery(query)
{
    startedAtMs = capacityClock();
    rows = _capacityRealSyncQuery(query);
    elapsedMs = capacityClock() - startedAtMs;
    outcome = int(!isDefined(rows));
    synchronousPolicy = 5;
    printf("CAP SQL " + level.capStage + " " + synchronousPolicy + " " +
           elapsedMs + " " + outcome + " 0 " + elapsedMs + "\n");
    printf("CAP SYNC " + level.capStage + " " + startedAtMs + " " + elapsedMs + "\n");
    return rows;
}
"""
    path.write_text(source)


def render_menu(options):
    """Bind real production queries to each synthetic player in the GSC workload."""
    template = (ROOT / "dev-tools/tests/query-capacity-menu.gsc").read_text()
    settings = {"before": options.baseline_queries, "script_root": options.scripts}
    queries = {
        "LBQUERY": query("leaderboard", **settings),
        "RNQUERY": query(
            "runs",
            player=PLAYER_PLACEHOLDER,
            sort="timePlayed ASC, timePlayed ASC, explosiveJumps ASC, loadCount ASC, "
            "saveCount ASC, startTimeStamp ASC",
            **settings,
        ),
        "HUDQUERY": query("hud", current=PLAYER_PLACEHOLDER, **settings),
    }
    for placeholder, statement in queries.items():
        if placeholder != "LBQUERY" and str(PLAYER_PLACEHOLDER) not in statement:
            raise RuntimeError("Capacity query lost its player binding: " + placeholder)
        expression = "(10000 + playerIndex)" if placeholder == "HUDQUERY" else "(playerIndex + 1)"
        pieces = [json.dumps(piece) for piece in statement.split(str(PLAYER_PLACEHOLDER))]
        replacement = (" + " + expression + " + ").join(pieces)
        template, changed = re.subn(
            r"\b" + placeholder + r"\b", lambda match: replacement, template
        )
        if changed != 1:
            raise RuntimeError("Expected one capacity query placeholder: " + placeholder)
    return template


def install_menu(mod, options):
    path = mod / "opencj/platformtest.gsc"
    source = path.read_text()
    pattern = re.compile(r"(?ms)^menu\s*\([^)]*\)\s*\{.*?^\}")
    source, changed = pattern.subn(lambda match: render_menu(options), source)
    if changed != 1:
        raise RuntimeError("Expected one capacity menu scenario")
    path.write_text(source)
