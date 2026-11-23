"""Run the current stress or query workload on owned engine and MySQL containers."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import uuid

from capacity_data import seed_capacity_data
from capacity_metrics import ResourceMonitor, workload_metrics
from capacity_observers import install_menu, install_sql_observers
from compose_environment import capacity_cpu_set
from disposable_mysql import DisposableMySQL
import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
PLAYER_COUNT = 32
ENGINE_TIMEOUT_SECONDS = 600
COMMAND_TIMEOUT_SECONDS = 60
PHYSICS_TICKS_PER_SECOND = 20


def parse_options(profile):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--frames", type=int, default=12000)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--binary", default="cod4x-server/bin/cod4x18_dedrun")
    parser.add_argument("--scripts", type=Path, default=ROOT / "server-gsc")
    parser.add_argument("--workers", type=int, choices=(4, 5), default=4)
    parser.add_argument("--db-cpus", type=int, default=0)
    parser.add_argument("--cpu-set", help="Two available cores for the query profile")
    parser.add_argument("--mature", action="store_true")
    parser.add_argument("--extended-reads", action="store_true")
    parser.add_argument("--baseline-queries", action="store_true")
    # Retain old command lines, but reject inactive experiments before allocating resources.
    parser.add_argument("--load-batch", type=int, default=32)
    parser.add_argument("--load-concurrency", type=int, default=0)
    parser.add_argument("--fps-cache-limit", type=int, default=512)
    options = parser.parse_args()
    if not 5 <= options.seconds <= 120:
        parser.error("--seconds must be between 5 and 120")
    if not max(128, options.seconds * 40) <= options.frames <= 36000:
        parser.error("--frames must cover both recording phases and be at most 36000")
    if not 0 <= options.db_cpus <= 12:
        parser.error("--db-cpus must be between 0 and 12")
    if (options.load_batch, options.load_concurrency, options.fps_cache_limit) != (32, 0, 512):
        parser.error(
            "Acceptance checks use the current production batch, concurrency and cache limits."
        )
    options.profile = profile
    if profile == "query":
        try:
            options.cpu_set = capacity_cpu_set(options.cpu_set)
        except ValueError as error:
            parser.error(str(error))
    elif options.cpu_set:
        parser.error("--cpu-set belongs to the query profile")
    options.maps = ["mp_killhouse"]
    options.fixture = ROOT / "dev-tools/tests/sql-capacity-190.gsc"
    options.completion_marker = "CAP COMPLETE"
    options.baseline = False
    gsc_fixture.validate_options(parser, options)
    installed_engine = (ROOT / "cod4x-server/bin/cod4x18_dedrun").resolve()
    if options.workers != 4 and options.engine == installed_engine:
        parser.error("A five-worker comparison requires an explicit matching candidate engine.")
    return options


def database_for(home, options):
    container_options = []
    if options.db_cpus:
        container_options += ["--cpus", str(options.db_cpus)]
    server_options = []
    if options.profile == "query":
        container_options += ["--cpuset-cpus", options.cpu_set, "--memory-swap", "1536m"]
        server_options = [
            "--innodb-buffer-pool-size=536870912",
            "--temptable-max-ram=67108864",
            "--max-connections=40",
        ]
    return DisposableMySQL(
        home, "capacity", container_options=container_options, server_options=server_options
    )


def validate_ranking_schema(database):
    """The source schema must already contain the current covering indexes."""
    for index_name, expected in (
        ("checkpoint_time", "cpID,timePlayed,explosiveJumps,runID,loadCount,saveCount"),
        ("checkpoint_rpg", "cpID,explosiveJumps,timePlayed,runID"),
    ):
        columns = database.sql(
            "SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX)"
            " FROM information_schema.STATISTICS"
            " WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='checkpointStatistics'"
            f" AND INDEX_NAME='{index_name}';"
        )
        if columns != expected:
            raise RuntimeError(
                "Capacity source schema needs the current ranking index " + index_name
            )


def prepare_scripts(options, home):
    source_hashes, _ = gsc_fixture.prepare_fixture(options, home, retained_callbacks=())
    mod = home / "mods/opencj"
    install_sql_observers(mod, options.workers)
    # Both profiles use current query builders; only request cadence/resource limits differ.
    install_menu(mod, options)
    (mod / "maps/mp/gametypes/cj.gsc").write_text(
        'main()\n{\n    level.script = getCvar("mapname");\n'
        "    thread openCJ\\platformTest::main();\n}\n"
    )
    (mod / "maps/mp/mp_killhouse.gsc").write_text("main()\n{\n}\n")
    return source_hashes


def build_clock(home):
    output = "/workspace/" + home.relative_to(ROOT).as_posix() + "/plugins/capacity_clock.so"
    container = "opencj-" + home.name + "-build"
    try:
        result = subprocess.run(
            [
                "docker",
                "compose",
                "run",
                "--rm",
                "--no-deps",
                "--name",
                container,
                "build",
                "g++",
                "-m32",
                "-std=c++11",
                "-fPIC",
                "-shared",
                "/workspace/dev-tools/tests/sql-capacity-clock.cpp",
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
            raise RuntimeError("Capacity clock build failed; see " + str(home / "build.log"))
    finally:
        subprocess.run(["docker", "rm", "-f", container], capture_output=True, timeout=30)


def engine_command(options, home, container):
    settings = {
        "sv_maxclients": str(PLAYER_COUNT),
        "capacity_frames": str(options.frames),
        "capacity_ticks": str(options.seconds * PHYSICS_TICKS_PER_SECOND),
        "capacity_workers": str(options.workers),
        "capacity_query_profile": str(int(options.profile == "query")),
        "capacity_extended_reads": str(int(options.extended_reads)),
    }
    command = gsc_fixture.server_command(
        options,
        home,
        container,
        "mp_killhouse",
        ("capacity_clock",),
        extra_settings=settings,
        config_files=("capacity.cfg",),
    )
    if options.profile == "query":
        override = home / "limits.yaml"
        override.write_text(
            "services:\n  server:\n    mem_limit: 1024m\n    memswap_limit: 1024m\n"
            f'    cpuset: "{options.cpu_set}"\n    cpus: 2.0\n'
        )
        command[2:2] = ["-f", str(ROOT / "dev-tools/compose.yaml"), "-f", str(override)]
    return command


def verify_log(log):
    completion = re.search(r"CAP COMPLETE failures=(\d+) checks=(\d+)", log)
    errors = (*gsc_fixture.SCRIPT_ERRORS, "Received signal:", "exceeded maximum number")
    for line in log.splitlines():
        if line.startswith(("CAP BEGIN", "CAP END", "CAP COMPLETE", "CAP FAILURE")):
            print(line, flush=True)
    for error in errors:
        if error in log:
            position = log.index(error)
            print(log[max(0, position - 100) : position + 1600], flush=True)
    if completion is None or int(completion[1]) or any(error in log for error in errors):
        raise AssertionError("Capacity fixture did not pass; see its private console log")
    return int(completion[2])


def cleanup_resources(home, monitor, database, engine_container):
    """Attempt every independent cleanup and return errors after recording ownership."""
    errors = []
    cleanup = {}
    try:
        monitor.finish(home)
    except Exception as error:
        errors.append(error)
    if engine_container is not None:
        try:
            removed = subprocess.run(
                ["docker", "rm", "-f", engine_container], capture_output=True, timeout=30
            )
            cleanup["engineRemoved"] = removed.returncode == 0
            if removed.returncode:
                raise RuntimeError("Could not remove the owned capacity engine")
        except Exception as error:
            errors.append(error)
    try:
        database.cleanup()
    except Exception as error:
        errors.append(error)
    cleanup["databaseContainerRemoved"] = not database.owns_container
    cleanup["credentialsRemoved"] = not database.environment_file.exists() and all(
        not path.exists() for path in database.config_files
    )
    return cleanup, errors


def run_capacity(options):
    home = ROOT / "dev-tools/local" / ("capacity-" + uuid.uuid4().hex[:8])
    source_hashes = prepare_scripts(options, home)
    database = database_for(home, options)
    monitor = ResourceMonitor(options.profile + ("-extended" if options.extended_reads else ""))
    engine_container = "opencj-" + home.name + "-engine"
    engine_owned = False
    config = home / "mods/opencj/capacity.cfg"
    installed_engine = ROOT / "cod4x-server/bin/cod4x18_dedrun"
    selected_hash = hashlib.sha256(options.engine.read_bytes()).hexdigest()
    installed_hash = hashlib.sha256(installed_engine.read_bytes()).hexdigest()
    report = {
        "profile": options.profile,
        "players": PLAYER_COUNT,
        "framesPerDemo": options.frames,
        "phaseSeconds": options.seconds,
        "workers": options.workers,
        "sourceHashes": source_hashes,
        "binarySha256": selected_hash,
        "mature": options.mature,
        "extendedReads": options.extended_reads,
        "baselineQueries": options.baseline_queries,
        "productionWrites": False,
        "separateDatabaseContainer": True,
        "verificationPassed": False,
    }
    report["revisions"] = {
        name: subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=path, text=True).strip()
        for name, path in (("opencj-core", ROOT), ("cod4x-server", ROOT / "cod4x-server"))
    }
    fixture_names = (
        "capacity_fixture.py",
        "capacity_data.py",
        "capacity_metrics.py",
        "capacity_observers.py",
        "sql-capacity-190.gsc",
        "query-capacity-menu.gsc",
        "sql-capacity-clock.cpp",
        "disposable_mysql.py",
        "gsc_fixture.py",
    )
    report["testSourceHashes"] = {
        name: hashlib.sha256((ROOT / "dev-tools/tests" / name).read_bytes()).hexdigest()
        for name in fixture_names
    }
    monitor.start()
    try:
        database.prepare()
        monitor.add(database.container)
        validate_ranking_schema(database)
        print("CAPACITY seeding synthetic data in the owned database.", flush=True)
        report.update(seed_capacity_data(database, options.frames, options.mature))
        report["sourceSchemaSha256"] = database.schema_sha256
        database.write_engine_config(config, {"capacity_database": database.database})
        build_clock(home)
        report["clockPluginSha256"] = hashlib.sha256(
            (home / "plugins/capacity_clock.so").read_bytes()
        ).hexdigest()
        report["fixtureHashes"] = gsc_fixture.script_hashes(home / "mods/opencj")
        engine_owned = True
        subprocess.run(
            engine_command(options, home, engine_container),
            cwd=ROOT / "dev-tools",
            check=True,
            capture_output=True,
            timeout=COMMAND_TIMEOUT_SECONDS,
        )
        monitor.add(engine_container)
        log = gsc_fixture.wait_for_fixture(
            engine_container, ("CAP COMPLETE",), timeout_seconds=ENGINE_TIMEOUT_SECONDS
        ).replace(database.password, "<redacted>")
        console = home / "console.log"
        console.write_text(log)
        console.chmod(0o600)
        report["checks"] = verify_log(log)
        report.update(workload_metrics(log))
        if gsc_fixture.has_libcod_mapping(engine_container):
            raise AssertionError("Capacity engine unexpectedly loaded libcod")
        report["verificationPassed"] = True
    finally:
        cleanup, cleanup_errors = cleanup_resources(
            home, monitor, database, engine_container if engine_owned else None
        )
        report.update(cleanup)
        report["binaryUnchanged"] = (
            selected_hash == hashlib.sha256(options.engine.read_bytes()).hexdigest()
        )
        report["liveBinaryUnchanged"] = (
            installed_hash == hashlib.sha256(installed_engine.read_bytes()).hexdigest()
        )
        report["productionSourcesUnchanged"] = source_hashes == gsc_fixture.script_hashes(
            options.scripts
        )
        (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
        print("CAPACITY evidence: " + str(home), flush=True)
        if cleanup_errors:
            raise RuntimeError("Capacity cleanup failed: " + "; ".join(map(str, cleanup_errors)))

    if not all(
        report[name]
        for name in ("binaryUnchanged", "liveBinaryUnchanged", "productionSourcesUnchanged")
    ):
        raise AssertionError("Production code changed during the capacity comparison")
    print(f"PASS: {report['checks']} capacity checks", flush=True)


def main(profile):
    run_capacity(parse_options(profile))
