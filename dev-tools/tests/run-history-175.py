"""Exercise 32-player save history using a separate synthetic MySQL container."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

from disposable_mysql import DisposableMySQL
import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
PLAYER_COUNT = 32
HISTORY_LIMIT = 100
INITIAL_SAVE_COUNT = 160
FIRST_RUN_ID = 1001
MISSING_SAVE_PERIOD = 17
MAX_TEMPORARY_SCRIPT_VALUES = 5000


def seed_history(database):
    """Store numbered coordinates and regular gaps so paging order is observable."""
    database.sql("""
        INSERT INTO mapids(mapID, mapname) VALUES(1, 'mp_killhouse');
        INSERT INTO checkpoints(cpID, mapID) VALUES(1, 1);
        INSERT INTO routes(routeID, mapID, cpID, routeName) VALUES(1, 1, 1, 'history175');
        UPDATE checkpoints SET finishRouteID=1 WHERE cpID=1;
    """)
    players = ",".join(
        f"({player_id}, 'History fixture {player_id}')" for player_id in range(1, PLAYER_COUNT + 1)
    )
    database.sql("INSERT INTO playerInformation(playerID, playerName) VALUES " + players + ";")
    runs = ",".join(
        f"({FIRST_RUN_ID + player_index}, {player_index + 1}, 1, 1, {INITIAL_SAVE_COUNT}, 'mix')"
        for player_index in range(PLAYER_COUNT)
    )
    database.sql(
        "INSERT INTO playerRuns(runID, playerID, mapID, instanceNumber, saveCount, FPSMode)"
        " VALUES " + runs + ";"
    )
    for player_index in range(PLAYER_COUNT):
        run_id = FIRST_RUN_ID + player_index
        saves = ",".join(
            f"({run_id}, {number}, {number}, 0, 700, 0, 0, 0, 0, 0, 1, 0, 'mix')"
            for number in range(1, INITIAL_SAVE_COUNT + 1)
            if number % MISSING_SAVE_PERIOD
        )
        database.sql(
            "INSERT INTO playerSaves(runID, saveNumber, x, y, z, alpha, beta, gamma,"
            " explosiveJumps, doubleExplosives, checkpointID, flags, FPSMode) VALUES " + saves + ";"
        )


def install_history_observers(mod):
    """Measure page admission and delay real SQL replies at the persistence boundary."""
    path = mod / "opencj/historysave.gsc"
    source = path.read_text()
    restore_function = re.compile(
        r"(?ms)^(_restoreRunState\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*\w+\s*\))" r"\s*\{.*?^\}"
    )
    restore_match = restore_function.search(source)
    if restore_match is None:
        raise RuntimeError("Run-state restoration function was not found")
    # Preserve real SQL/native loading; unrelated HUD/session effects are excluded.
    restore_stub = (
        restore_match[1]
        + "\n{\n    self openCJ\\playerRuns::setRunIDAndInstanceNumber("
        + restore_match[2]
        + ", "
        + restore_match[3]
        + ");\n}"
    )
    source = source[: restore_match.start()] + restore_stub + source[restore_match.end() :]
    active_page_increment = re.compile(r"(?m)^[ \t]*level\.historySavesActive\s*\+\+\s*;[ \t]*$")
    source, replacements = active_page_increment.subn(
        lambda match: match.group(0)
        + "\n    if(level.historySavesActive > level.history175Peak)"
        + "\n    {\n        level.history175Peak = level.historySavesActive;\n    }",
        source,
    )
    if replacements != 1:
        raise RuntimeError("Expected one page-admission observation point")
    page_query = re.compile(
        r"(?m)^[ \t]*rows\s*=\s*openCJ\\mySQL::mysqlAsyncRead\(\s*query\s*\);[ \t]*$"
    )
    query_observation = r"""        level.history175Queries++;
        if(isDefined(level.history175FailOwner) && state.owner == level.history175FailOwner)
        {
            rows = undefined;
        }
        else
        {
            rows = openCJ\mySQL::mysqlAsyncRead(query);
        }
        memoryAudit("page", level);
        if(isDefined(level.history175DelayOwner) && state.owner == level.history175DelayOwner)
        {
            player notify("history175_result_ready");
            wait 0.2;
        }"""
    source, replacements = page_query.subn(lambda match: query_observation, source)
    if replacements != 1:
        raise RuntimeError("Expected one history-page query observation point")
    path.write_text(source)


def build_memory_probe(home):
    output = "/workspace/" + home.relative_to(ROOT).as_posix() + "/plugins/memory_audit.so"
    name = "opencj-" + home.name + "-build"
    try:
        result = subprocess.run(
            [
                "docker",
                "compose",
                "run",
                "--rm",
                "--no-deps",
                "--name",
                name,
                "build",
                "g++",
                "-m32",
                "-std=c++11",
                "-fPIC",
                "-shared",
                "-DCOD4",
                "/workspace/dev-tools/tests/player-memory-audit.cpp",
                "-o",
                output,
            ],
            cwd=ROOT / "dev-tools",
            capture_output=True,
            text=True,
            timeout=90,
        )
        (home / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("Memory probe build failed; see " + str(home / "build.log"))
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)


def history_measurements(log):
    completion = re.search(
        r"H175 COMPLETE failures=(\d+) checks=(\d+) peak=(\d+) queries=(\d+)", log
    )
    if completion is None:
        raise AssertionError("History measurements are missing")
    values = [(label, int(count)) for label, count in re.findall(r"MEM (\w+) values=(\d+)", log)]
    baseline = next((count for label, count in values if label == "baseline"), None)
    peak = max((count for label, count in values if label == "page"), default=0)
    if baseline is None:
        raise AssertionError("History memory baseline is missing")
    increase = peak - baseline
    failures, checks, active_pages, queries = map(int, completion.groups())
    if failures or active_pages > 2:
        raise AssertionError("History behavior or page admission checks failed")
    if not 0 < increase < MAX_TEMPORARY_SCRIPT_VALUES:
        raise AssertionError("Unexpected temporary script allocation")
    return {
        "failures": failures,
        "checks": checks,
        "maxActivePages": active_pages,
        "queries": queries,
        "scriptValuesBaseline": baseline,
        "scriptValuesPeak": peak,
        "scriptValueIncrease": increase,
    }


def main():
    parser = gsc_fixture.create_parser(
        default_fixture=ROOT / "dev-tools/tests/history-175.gsc",
        completion_marker="H175 COMPLETE",
    )
    options = gsc_fixture.validate_options(parser, parser.parse_args())
    if options.maps != ["mp_killhouse"] or options.baseline:
        parser.error("History uses the synthetic mp_killhouse fixture; select code with --scripts.")
    home = ROOT / "dev-tools/local" / ("history-175-" + uuid.uuid4().hex[:8])
    source_hashes, _ = gsc_fixture.prepare_fixture(options, home, retained_callbacks=())
    engine_hash = hashlib.sha256(options.engine.read_bytes()).hexdigest()
    database = DisposableMySQL(home, "history")
    report = {"players": PLAYER_COUNT, "limitPerPlayer": HISTORY_LIMIT, "passed": False}
    config = home / "mods/opencj/history175.cfg"
    try:
        database.prepare()
        seed_history(database)
        mod = home / "mods/opencj"
        install_history_observers(mod)
        # Only the explicitly selected initializers may affect VM allocation totals.
        (mod / "maps/mp/gametypes/cj.gsc").write_text(
            'main()\n{\n    level.script = getCvar("mapname");\n'
            "    thread openCJ\\platformTest::main();\n}\n"
        )
        (mod / "maps/mp/mp_killhouse.gsc").write_text("main()\n{\n}\n")
        database.write_engine_config(config, {"history175_database": database.database})
        build_memory_probe(home)
        report.update(
            gsc_fixture.run_prepared_fixture(
                options,
                home,
                "mp_killhouse",
                source_hashes,
                plugin_names=("memory_audit",),
                config_files=("history175.cfg",),
                timeout_seconds=100,
                extra_settings={"sv_maxclients": str(PLAYER_COUNT)},
            )
        )
        report.update(history_measurements((home / "console.log").read_text()))
        report["sourceSchemaSha256"] = database.schema_sha256
        report["databaseWrites"] = "separate disposable container only"
        report["binaryUnchanged"] = (
            engine_hash == hashlib.sha256(options.engine.read_bytes()).hexdigest()
        )
        report["sourcesUnchanged"] = source_hashes == gsc_fixture.script_hashes(options.scripts)
        if not report["binaryUnchanged"] or not report["sourcesUnchanged"]:
            raise AssertionError("Selected production code changed during history verification")
        print(
            f"H175 PASS: {report['checks']} checks; peak {report['maxActivePages']} SQL pages",
            flush=True,
        )
    finally:
        try:
            database.cleanup()
        finally:
            console = home / "console.log"
            if console.exists():
                console.write_text(console.read_text().replace(database.password, "<redacted>"))
                console.chmod(0o600)
            report["databaseRemoved"] = not database.owns_container
            report["credentialsRemoved"] = (
                not config.exists() and not database.environment_file.exists()
            )
            (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
