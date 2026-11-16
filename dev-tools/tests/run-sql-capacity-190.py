"""#190: 32 engine clients, real demo persistence/cache and menu SQL.
Separate disposable MySQL container; schema-only production read; no live restart.
"""

from compose_environment import database_container, database_network
from pathlib import Path
import argparse
import hashlib
import json
import math
import re
import secrets
import shutil
import statistics
import struct
import subprocess
import time
import uuid
import zlib
import runpy

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--frames", type=int, default=12000)
parser.add_argument("--seconds", type=int, default=30)
parser.add_argument(
    "--load-batch",
    type=int,
    choices=(1, 2, 4, 8, 16, 32),
    default=32,
    help="Diagnostic change in isolated GSC copy only",
)
parser.add_argument(
    "--load-concurrency",
    type=int,
    default=0,
    help="Diagnostic cap in isolated copy; 0 preserves production",
)
parser.add_argument(
    "--fps-cache-limit",
    type=int,
    choices=(128, 256, 512),
    default=512,
    help="Diagnostic rendered-history cache cap in isolated copy",
)
parser.add_argument(
    "--db-cpus", type=int, default=0, help="0 matches uncapped development database"
)
parser.add_argument(
    "--workers",
    type=int,
    choices=(4, 5),
    default=4,
    help="Isolated comparison; five requires an explicit test binary",
)
parser.add_argument("--binary", type=Path, default=ROOT / "cod4x-server/bin/cod4x18_dedrun")
args = parser.parse_args()
args.binary = args.binary.resolve()
assert args.binary.is_relative_to(ROOT) and args.binary.is_file()
assert args.workers == 4 or args.binary != ROOT / "cod4x-server/bin/cod4x18_dedrun"
assert 0 <= args.load_concurrency <= 32 and 0 <= args.db_cpus <= 12
assert max(128, args.seconds * 40) <= args.frames <= 36000 and 5 <= args.seconds <= 120
token = uuid.uuid4().hex[:8]
tag = "sql-capacity-190-" + token
database = "opencj_verify_190_" + token + "_cod4"
home = ROOT / "dev-tools/local" / tag
mod = home / "mods/opencj"
mod.mkdir(parents=True)
dbname = "opencj-capacity-db-" + token
engine = "opencj-capacity-engine-" + token
password = secrets.token_hex(24)
private = home / "mysql.env"
cfg = mod / "capacity.cfg"
private.write_text("MYSQL_ROOT_PASSWORD=" + password + "\n")
private.chmod(0o600)
created = started = False
report = {
    "players": 32,
    "framesPerDemo": args.frames,
    "recordedMinutes": args.frames / 1200,
    "phaseSeconds": args.seconds,
    "workers": args.workers,
    "productionWrites": False,
    "separateDatabaseContainer": True,
    "loadBatch": args.load_batch,
    "loadConcurrency": args.load_concurrency,
    "databaseCpuLimit": args.db_cpus,
    "fpsCacheLimit": args.fps_cache_limit,
}
binary = args.binary
production_binary = ROOT / "cod4x-server/bin/cod4x18_dedrun"
production_binary_hash = hashlib.sha256(production_binary.read_bytes()).hexdigest()
report["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
report["revisions"] = {
    repo: subprocess.check_output(
        ["git", "-C", str(ROOT / repo), "rev-parse", "HEAD"], text=True
    ).strip()
    for repo in ("server-gsc", "server-ext", "cod4x-server", "dev-tools")
}
source_files = (
    "server-gsc/opencj/mysql.gsc",
    "server-gsc/opencj/demos.gsc",
    "server-gsc/opencj/demorecording.gsc",
)
report["sourceHashes"] = {
    rel: hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() for rel in source_files
}


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def db(sql, source=False):
    target = database_container() if source else dbname
    command = [
        "docker",
        "exec",
        "-i",
        target,
        "sh",
        "-c",
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --max_allowed_packet=64M -N -u root',
    ]
    p = run(command, input=sql, timeout=90)
    if p.returncode:
        (home / "sql-error.txt").write_text(p.stderr.replace(password, "<redacted>"))
        (home / "sql-error.txt").chmod(0o600)
        raise RuntimeError("SQL fixture error; see restricted sql-error.txt")
    return p.stdout.strip()


def target(sql):
    return db("USE " + database + ";\n" + sql)


def chunks(seed=0):
    result = []
    for start in range(0, args.frames, 64):
        count = min(64, args.frames - start)
        raw = bytearray(b"OCJ4" + struct.pack("<I", count))
        for j in range(count):
            f = start + j
            x = f * 0.6 + seed * 13
            y = math.sin(f * 0.07 + seed) * 500
            z = 700 + math.sin(f * 0.11 + seed) * 200
            flags = 517 if f % 40 < 20 else 518
            if f % 100 < 5:
                flags |= 8192
            if f % 100 == 60:
                flags |= 16384
            fps = 333 if f % 30 < 15 else 250
            raw += struct.pack("<fffHHHHHIB", x, y, z, 0, (f * 137) % 65536, 0, flags, fps, 1, 8)
            # Valid native presentation, unarmed, with changing velocity/bob.
            raw += struct.pack(
                "<HHHBBHBhhhhhhHHHBB",
                0,
                0,
                0,
                0,
                f % 256,
                60 * 256,
                0,
                400,
                200,
                int(math.cos(f * 0.11) * 800),
                0,
                0,
                0,
                0,
                0,
                0,
                0,
                0,
            )
            name = b"none" if j == 0 else b""
            raw += bytes([len(name)]) + name
        result.append(zlib.compress(bytes(raw), 6).hex())
    return result


def seed():
    target(
        "INSERT INTO mapids(mapID,mapname) VALUES(1,'mp_killhouse');"
        + "INSERT INTO checkpoints(cpID,mapID,ender) VALUES"
        + ",".join(f"({i},1,'capacity{i}')" for i in range(1, 33))
        + ";"
        + "INSERT INTO playerInformation(playerID,playerName) VALUES"
        + ",".join(f"({i},'Synthetic {i}')" for i in range(1, 513))
        + ";"
    )
    target(
        "INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,instanceNumber,FPSMode,hb) VALUES"
        + ",".join(
            f"({base+i},{i},1,{i if base!=2000 else 'NULL'},{'NOW()' if base!=2000 else 'NULL'},1,'mix',0)"
            for base in (1000, 2000, 3000)
            for i in range(1, 33)
        )
        + ";"
        + "INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) VALUES"
        + ",".join(
            f"({base+i},{i},{args.frames*50+i},1,0,0,0,0,'mix')"
            for base in (1000, 3000)
            for i in range(1, 33)
        )
        + ";"
    )
    # Moderate catalogue fixture: 10k finishes, 1k unfinished runs and 20k saves.
    for start in range(0, 10000, 500):
        target(
            "INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp,FPSMode) VALUES"
            + ",".join(f"({10000+i},{i%512+1},1,1,NOW(),'mix')" for i in range(start, start + 500))
            + ";"
            + "INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode) VALUES"
            + ",".join(
                f"({10000+i},1,{100000+i},20,2,{i%5},0,0,'mix')" for i in range(start, start + 500)
            )
            + ";"
        )
    for start in range(0, 1000, 100):
        target(
            "INSERT INTO playerRuns(runID,playerID,mapID,FPSMode) VALUES"
            + ",".join(f"({20000+i},{i%32+1},1,'mix')" for i in range(start, start + 100))
            + ";"
            + "INSERT INTO playerSaves(runID,saveNumber,alpha,beta,gamma,explosiveJumps,doubleExplosives,flags,FPSMode) VALUES"
            + ",".join(
                f"({20000+i},{j},0,0,0,0,0,0,'mix')"
                for i in range(start, start + 100)
                for j in range(1, 21)
            )
            + ";"
        )
    payloads = chunks()
    report["payloadBytesPerDemo"] = sum(len(x) // 2 for x in payloads)
    target(
        "INSERT INTO demoRuns(runID,mapID,routeName,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount,ready) VALUES"
        + ",".join(
            f"({3000+i},1,'capacity{i}','mix',0,{args.frames*50},0,{args.frames},1)"
            for i in range(1, 33)
        )
        + ";"
        + "INSERT INTO demoWinners VALUES"
        + ",".join(
            f"(1,'capacity{i}','mix',0,'{kind}',{3000+i})"
            for i in range(1, 33)
            for kind in ("speedrun", "lowrpg", "walkthrough")
        )
        + ";"
    )
    # Seed synthetic recordings on separate routes so publishing cannot retire them.
    target(
        "UPDATE demoRuns SET routeName=CONCAT('seed',runID) WHERE runID BETWEEN 3001 AND 3032;"
        + "DELETE FROM demoWinners WHERE runID BETWEEN 3001 AND 3032;"
        + "INSERT INTO demoWinners SELECT mapID,routeName,FPSMode,modeMask,'walkthrough',runID FROM demoRuns;"
    )
    for i in range(1, 33):
        payloads = chunks(i)
        target(
            "INSERT INTO demoChunks(runID,chunkNum,payload) VALUES"
            + ",".join(f"({3000+i},{j},UNHEX('{payload}'))" for j, payload in enumerate(payloads))
            + ";"
        )
    report["syntheticRows"] = {
        "finishedRuns": 10064,
        "unfinishedRuns": 1032,
        "saves": 20000,
        "players": 512,
    }


def quantiles(values):
    if not values:
        return {}
    x = sorted(values)
    return {
        "count": len(x),
        "median": statistics.median(x),
        "p95": x[math.ceil(0.95 * len(x)) - 1],
        "p99": x[math.ceil(0.99 * len(x)) - 1],
        "max": max(x),
    }


try:
    image = run(
        ["docker", "inspect", "-f", "{{.Config.Image}}", database_container()]
    ).stdout.strip()
    network = database_network()
    assert image == "mysql:8.0"
    p = run(
        ["docker", "run", "-d", "--name", dbname, "--network", network, "--memory", "1536m"]
        + (["--cpus", str(args.db_cpus)] if args.db_cpus else [])
        + ["--env-file", str(private), image, "--log-bin-trust-function-creators=1"]
    )
    assert p.returncode == 0, "Disposable database launch failed"
    created = True
    for _ in range(90):
        p = run(
            [
                "docker",
                "exec",
                dbname,
                "sh",
                "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h127.0.0.1 -N -u root -e "SELECT 1"',
            ]
        )
        if p.returncode == 0:
            break
        time.sleep(1)
    else:
        raise RuntimeError("Disposable database did not become ready")
    dump = run(
        [
            "docker",
            "exec",
            database_container(),
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --no-data --routines --triggers --skip-comments --skip-lock-tables --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4',
        ]
    )
    assert dump.returncode == 0 and not re.search(r"^INSERT INTO", dump.stdout, re.M)
    schema = dump.stdout.replace("openCJ_cod4", database)
    schema = re.sub(r"DEFINER=\S+\s", "DEFINER=CURRENT_USER ", schema)
    assert not re.search(r"^\s*(CREATE DATABASE|USE)\b", schema, re.I | re.M)
    report["sourceSchemaSha256"] = hashlib.sha256(dump.stdout.encode()).hexdigest()
    db("CREATE DATABASE " + database + " CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;")
    target(schema)
    migration = (ROOT / "server-db/migrations/018-demo-publication.sql").read_text()
    target(migration)
    report["publicationMigrationSha256"] = hashlib.sha256(migration.encode()).hexdigest()
    db(
        "CREATE USER 'capacity'@'%' IDENTIFIED BY '"
        + password
        + "'; GRANT ALL PRIVILEGES ON "
        + database
        + ".* TO 'capacity'@'%';"
    )
    print("CAPACITY isolated database ready; seeding synthetic records.", flush=True)
    seed()
    report["publicationSQL"] = runpy.run_path(
        str(ROOT / "dev-tools/tests/demo-publication-190.py")
    )["verify"](target)
    print(
        "CAPACITY publication concurrency/failure checks: "
        + str(report["publicationSQL"]["checks"]),
        flush=True,
    )
    for folder in ("opencj", "maps"):
        shutil.copytree(ROOT / "server-gsc" / folder, mod / folder)
    assert (
        args.load_batch == 32 and args.load_concurrency == 0 and args.fps_cache_limit == 512
    ), "Use unchanged production paths for acceptance"
    for asset in ("mod.ff", "z_opencj.iwd"):
        (mod / asset).symlink_to("/mod-assets/" + asset)
    (home / "plugins").mkdir()
    (home / "steamclient.so").symlink_to("/game/steamclient.so")

    shutil.copyfile(ROOT / "dev-tools/tests/sql-capacity-190.gsc", mod / "opencj/sqlcapacity.gsc")
    p = mod / "opencj/sqlcapacity.gsc"
    fixture = p.read_text()
    fixture = fixture.replace('stats[0]==4 &&', f'stats[0]=={args.workers} &&').replace(
        'four workers and empty completion backlog',
        'configured workers and empty completion backlog',
    )
    fixture = fixture.replace(
        "    clipTransfers();", r"    openCJ\publicationCapacity::run();" + "\n    clipTransfers();"
    )
    p.write_text(fixture)
    shutil.copyfile(
        ROOT / "dev-tools/tests/demo-publication-190.gsc", mod / "opencj/publicationcapacity.gsc"
    )
    (mod / "maps/mp/gametypes/cj.gsc").write_text('main(){level.script=getCvar("mapname");}\n')
    (mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
        'CodeCallback_StartGameType(){thread openCJ\\sqlCapacity::main();}\n'
        + "\n".join(
            "CodeCallback_" + c + "(){}"
            for c in (
                "PlayerConnect",
                "PlayerDisconnect",
                "PlayerDamage",
                "PlayerKilled",
                "PlayerLastStand",
            )
        )
    )
    (mod / "maps/mp/mp_killhouse.gsc").write_text("main(){}\n")
    p = mod / "opencj/mysql.gsc"
    s = p.read_text()
    initializer = 'level.database["port"], 4);'
    assert s.count(initializer) == 1
    s = s.replace(initializer, f'level.database["port"], {args.workers});')
    needle = '    id=mysql_async_submit(query, policy, key, scope, deadline, int(save));'
    assert s.count(needle) == 1
    s = s.replace(needle, '    capacityStarted=capacityClock();\n' + needle)
    needle = '    result.rows=rows;\n    result.status=outcome[0];'
    assert s.count(needle) == 1
    s = s.replace(
        needle, '    openCJ\\sqlCapacity::queryMetric(policy,capacityStarted,outcome);\n' + needle
    )
    needle = '    ret = mysql_query(level.mySQL, query);'
    assert s.count(needle) == 1
    s = s.replace(
        needle,
        '    capacityStarted=capacityClock();\n'
        + needle
        + '\n    printf("CAP SQL "+level.capStage+" 5 "+(capacityClock()-capacityStarted)+" "+ret+" 0 0\\n");',
    )
    needle = '    printf("CAP SQL "+level.capStage+" 5 "'
    assert s.count(needle) == 1
    s = s.replace(
        needle,
        '    printf("CAP SYNC "+level.capStage+" "+capacityStarted+" "+(capacityClock()-capacityStarted)+"\\n");'
        + chr(10)
        + needle,
    )
    declaration = "_request(query, policy, key, scope, deadline, save)\n{"
    assert s.count(declaration) == 1
    s = s.replace(declaration, "_capacityRealRequest(query, policy, key, scope, deadline, save)\n{")
    s += r"""
_request(query, policy, key, scope, deadline, save)
{
    return openCJ\publicationCapacity::request(query,policy,key,scope,deadline,save);
}
"""
    p.write_text(s)
    cfg.write_text(
        f'set db_host "{dbname}"\nset db_user "capacity"\nset db_pass "{password}"\nset db_base "{database[:-1]}"\nset db_port "3306"\nset capacity_database "{database}"\n'
    )
    cfg.chmod(0o600)
    relative = str(home.relative_to(ROOT))
    build = run(
        [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "build",
            "bash",
            "-lc",
            "g++ -m32 -std=c++11 -fPIC -shared /workspace/dev-tools/tests/sql-capacity-clock.cpp -o /workspace/"
            + relative
            + "/plugins/capacity_clock.so",
        ],
        cwd=ROOT / "dev-tools",
        timeout=90,
    )
    (home / "build.log").write_text(build.stdout + build.stderr)
    assert build.returncode == 0, "Clock plugin build failed"
    cmd = [
        "docker",
        "compose",
        "run",
        "-d",
        "--no-deps",
        "--name",
        engine,
        "--workdir",
        "/workspace/" + str(home.relative_to(ROOT)),
        "server",
        "/workspace/" + str(binary.relative_to(ROOT)),
    ]
    for key, value in [
        ("fs_basepath", "/game"),
        ("fs_homepath", "/workspace/" + relative),
        ("fs_game", "mods/opencj"),
        ("dedicated", 2),
        ("net_port", 28975),
        ("sv_maxclients", 32),
        ("sv_authorizemode", 0),
        ("com_hunkMegs", 1024),
        ("developer", 1),
        ("g_gametype", "cj"),
        ("capacity_frames", args.frames),
        ("capacity_ticks", args.seconds * 20),
    ]:
        cmd += ["+set", key, str(value)]
    cmd += ["+exec", "capacity.cfg", "+loadplugin", "capacity_clock", "+map", "mp_killhouse"]
    p = run(cmd, cwd=ROOT / "dev-tools")
    assert p.returncode == 0, "Isolated engine launch failed"
    started = True
    print("CAPACITY isolated engine started: " + str(home), flush=True)
    seen = 0
    log = ""
    for _ in range(600):
        time.sleep(1)
        p = run(["docker", "logs", engine])
        log = (p.stdout + p.stderr).replace(password, "<redacted>")
        lines = log.splitlines()
        for line in lines[seen:]:
            if line.startswith(("CAP BEGIN", "CAP END", "CAP COMPLETE", "CAP FAILURE")):
                print(line, flush=True)
        seen = len(lines)
        if any(
            v in log
            for v in (
                "CAP COMPLETE",
                "script compile error",
                "script runtime error",
                "Received signal:",
                "exceeded maximum number",
            )
        ):
            break
    (home / "console.log").write_text(log)
    (home / "console.log").chmod(0o600)
    if any(
        v in log
        for v in (
            "script compile error",
            "script runtime error",
            "Received signal:",
            "exceeded maximum number",
        )
    ):
        for marker in (
            "script compile error",
            "script runtime error",
            "Received signal:",
            "exceeded maximum number",
        ):
            if marker in log:
                print(log[max(0, log.index(marker) - 100) : log.index(marker) + 1600], flush=True)
    phases = {}
    for name in ("record32", "mixed16", "finish32_watch32", "shared32"):
        metrics = {}
        sql = [
            tuple(map(int, m))
            for m in re.findall(r"CAP SQL " + name + r" (\d+) (\d+) (\d+) (\d+) (\d+)", log)
        ]
        for policy, label in (
            (0, "progress"),
            (1, "read"),
            (2, "upload"),
            (3, "menu"),
            (4, "write"),
            (5, "synchronous"),
        ):
            values = [x for x in sql if x[0] == policy]
            if values:
                metrics[label] = {
                    "completionMs": quantiles([x[1] for x in values]),
                    "queueMs": quantiles([x[3] for x in values]),
                    "executionMs": quantiles([x[4] for x in values]),
                    "outcomes": {
                        str(o): sum(x[2] == o for x in values) for o in set(x[2] for x in values)
                    },
                }
        metrics["demoLoadMs"] = quantiles(
            [int(m) for m in re.findall(r"CAP LOAD " + name + r" \d+ (\d+)", log)]
        )
        metrics["demoUploadMs"] = quantiles(
            [int(m) for m in re.findall(r"CAP UPLOAD " + name + r" \d+ (\d+)", log)]
        )
        end = re.search(r"CAP END " + name + r" (\d+) (\d+) (\d+) (\d+)", log)
        if end:
            metrics.update(
                dict(zip(("wallMs", "ticks", "peakJobs", "peakQueryBytes"), map(int, end.groups())))
            )
        phases[name] = metrics
    report["frameIntervals"] = {
        name: dict(zip(("samples", "p95Ms", "p99Ms", "maxMs", "over75Ms"), map(int, m[1:])))
        for m in re.findall(r"CAP TICKS (\d+) (\d+) (\d+) (\d+) (\d+) (\d+)", log)
        for name in [("setup", "record32", "mixed16", "finish32_watch32", "shared32")[int(m[0])]]
    }
    report["hitches"] = [
        dict(zip(("stage", "endedAtMs", "intervalMs"), map(int, m)))
        for m in re.findall(r"CAP HITCH (\d+) (\d+) (\d+)", log)
    ]
    sync = [
        (stage, int(start), int(duration))
        for stage, start, duration in re.findall(r"CAP SYNC (\w+) (\d+) (\d+)", log)
    ]
    for hitch in report["hitches"]:
        start = hitch["endedAtMs"] - hitch["intervalMs"]
        end = hitch["endedAtMs"]
        calls = [duration for _, at, duration in sync if start <= at < end]
        hitch.update(synchronousCalls=len(calls), synchronousMs=sum(calls))
    report["phases"] = phases
    report["liveBinaryUnchanged"] = (
        production_binary_hash == hashlib.sha256(production_binary.read_bytes()).hexdigest()
    )
    complete = re.search(r"CAP COMPLETE (\d+) (\d+)", log)
    report["completed"] = bool(complete)
    report["failures"] = int(complete[1]) if complete else None
    report["checks"] = int(complete[2]) if complete else 0
    report["verificationPassed"] = bool(complete and int(complete[1]) == 0)
    report["binaryUnchanged"] = (
        hashlib.sha256(binary.read_bytes()).hexdigest() == report["binarySha256"]
    )
    print(
        json.dumps(
            {
                "verificationPassed": report["verificationPassed"],
                "checks": report["checks"],
                "frameIntervals": report["frameIntervals"],
                "phases": {
                    k: {
                        "wallMs": v.get("wallMs"),
                        "progressP95": v.get("progress", {}).get("completionMs", {}).get("p95"),
                        "menuP95": v.get("menu", {}).get("completionMs", {}).get("p95"),
                        "demoLoadMs": v["demoLoadMs"],
                        "demoUploadMs": v["demoUploadMs"],
                    }
                    for k, v in phases.items()
                },
            }
        ),
        flush=True,
    )
    assert report["verificationPassed"], "Capacity verification did not pass"
    assert report["liveBinaryUnchanged"], "Production executable changed during isolated comparison"
finally:
    report["binaryUnchanged"] = (
        hashlib.sha256(binary.read_bytes()).hexdigest() == report["binarySha256"]
    )
    report["productionSourcesUnchanged"] = all(
        hashlib.sha256((ROOT / rel).read_bytes()).hexdigest() == value
        for rel, value in report["sourceHashes"].items()
    )
    if started:
        p = run(["docker", "logs", engine])
        (home / "console.log").write_text((p.stdout + p.stderr).replace(password, "<redacted>"))
        (home / "console.log").chmod(0o600)
        p = run(["docker", "rm", "-f", engine])
        report["engineRemoved"] = p.returncode == 0
    if created:
        p = run(["docker", "rm", "-f", "-v", dbname])
        report["databaseContainerRemoved"] = p.returncode == 0
    private.unlink(missing_ok=True)
    cfg.unlink(missing_ok=True)
    report["credentialsRemoved"] = not private.exists() and not cfg.exists()
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        "CAPACITY evidence "
        + str(home)
        + "; cleanup "
        + str(report.get("engineRemoved"))
        + "/"
        + str(report.get("databaseContainerRemoved")),
        flush=True,
    )
