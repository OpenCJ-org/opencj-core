"""#175: disposable 32-player save-history and temporary script-memory checks."""

from compose_environment import database_container, database_network
from pathlib import Path
import subprocess
import json
import re
import secrets
import uuid
import time
import shutil
import hashlib

ROOT = Path(__file__).resolve().parents[2]
token = uuid.uuid4().hex[:8]
tag = "history-175-" + token
database = "opencj_verify_175_" + token + "_cod4"
dbname = "opencj-history-db-" + token
engine = "opencj-history-engine-" + token
home = ROOT / "dev-tools/local" / tag
mod = home / "mods/opencj"
mod.mkdir(parents=True)
password = secrets.token_hex(24)
private = home / "mysql.env"
cfg = mod / "history175.cfg"
private.write_text("MYSQL_ROOT_PASSWORD=" + password + "\n")
private.chmod(0o600)
report = {"players": 32, "limitPerPlayer": 100, "databaseWrites": "disposable fixture only"}
created = started = False
binary = ROOT / "cod4x-server/bin/cod4x18_dedrun"
report["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
sources = [
    "server-ext/gsc_saveposition.cpp",
    "server-gsc/opencj/historysave.gsc",
    "server-gsc/opencj/saveposition.gsc",
]
report["sourceHashes"] = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sources}


def run(command, **kw):
    return subprocess.run(command, text=True, capture_output=True, **kw)


def db(query, source=False):
    target = database_container() if source else dbname
    p = run(
        [
            "docker",
            "exec",
            "-i",
            target,
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root',
        ],
        input=query,
        timeout=60,
    )
    if p.returncode:
        (home / "sql-error.txt").write_text(p.stderr.replace(password, "<redacted>"))
        (home / "sql-error.txt").chmod(0o600)
        raise RuntimeError("Fixture SQL failed; see restricted sql-error.txt")
    return p.stdout.strip()


def sql(query):
    return db("USE " + database + ";\n" + query)


try:
    network = database_network()
    p = run(
        [
            "docker",
            "run",
            "-d",
            "--name",
            dbname,
            "--network",
            network,
            "--memory",
            "1536m",
            "--env-file",
            str(private),
            "mysql:8.0",
            "--log-bin-trust-function-creators=1",
        ]
    )
    assert p.returncode == 0
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
    schema = re.sub(
        r"DEFINER=\S+\s", "DEFINER=CURRENT_USER ", dump.stdout.replace("openCJ_cod4", database)
    )
    db("CREATE DATABASE " + database + " CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;")
    sql(schema)
    db(
        "CREATE USER 'history'@'%' IDENTIFIED BY '"
        + password
        + "'; GRANT ALL PRIVILEGES ON "
        + database
        + ".* TO 'history'@'%';"
    )
    sql(
        "INSERT INTO mapids(mapID,mapname) VALUES(1,'mp_killhouse');"
        "INSERT INTO checkpoints(cpID,mapID) VALUES(1,1);"
        "INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES(1,1,1,'history175');"
        "UPDATE checkpoints SET finishRouteID=1 WHERE cpID=1;"
        + "INSERT INTO playerInformation(playerID,playerName) VALUES"
        + ",".join(f"({i},'History fixture {i}')" for i in range(1, 33))
        + ";"
        + "INSERT INTO playerRuns(runID,playerID,mapID,instanceNumber,saveCount,FPSMode) VALUES"
        + ",".join(f"({1000+i},{i},1,1,160,'mix')" for i in range(1, 33))
        + ";"
    )
    for i in range(1, 33):
        sql(
            "INSERT INTO playerSaves(runID,saveNumber,x,y,z,alpha,beta,gamma,explosiveJumps,doubleExplosives,checkpointID,flags,FPSMode) VALUES"
            + ",".join(
                f"({1000+i},{n},{n},0,700,0,0,0,0,0,1,0,'mix')" for n in range(1, 161) if n % 17
            )
            + ";"
        )
    for folder in ["opencj", "maps"]:
        shutil.copytree(ROOT / "server-gsc" / folder, mod / folder)
    for asset in ["mod.ff", "z_opencj.iwd"]:
        (mod / asset).symlink_to("/mod-assets/" + asset)
    (home / "plugins").mkdir()
    (home / "steamclient.so").symlink_to("/game/steamclient.so")

    shutil.copyfile(ROOT / "dev-tools/tests/history-175.gsc", mod / "opencj/history175test.gsc")
    (mod / "maps/mp/gametypes/cj.gsc").write_text('main(){level.script=getCvar("mapname");}\n')
    (mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
        'CodeCallback_StartGameType(){thread openCJ\\history175Test::main();}\n'
        + "\n".join(
            "CodeCallback_" + c + "(){}"
            for c in [
                "PlayerConnect",
                "PlayerDisconnect",
                "PlayerDamage",
                "PlayerKilled",
                "PlayerLastStand",
            ]
        )
    )
    (mod / "maps/mp/mp_killhouse.gsc").write_text("main(){}\n")
    p = mod / "opencj/historysave.gsc"
    s = p.read_text()
    restore_function = re.compile(
        r"(?ms)^(_restoreRunState\s*\(\s*(\w+)\s*,\s*(\w+)\s*,\s*\w+\s*\))"
        r"\s*\{.*?^\}"
    )
    restore_match = restore_function.search(s)
    assert restore_match, "Run-state restoration function was not found"
    # Preserve real SQL/native loading; unrelated HUD/session effects are excluded.
    restore_stub = (
        restore_match[1]
        + "\n{\n    self openCJ\\playerRuns::setRunIDAndInstanceNumber("
        + restore_match[2]
        + ", "
        + restore_match[3]
        + ");\n}"
    )
    s = s[: restore_match.start()] + restore_stub + s[restore_match.end() :]
    active_page_increment = re.compile(
        r"(?m)^[ \t]*level\.historySavesActive\s*\+\+\s*;[ \t]*$"
    )
    s, replacements = active_page_increment.subn(
        lambda match: match.group(0)
        + "\n    if(level.historySavesActive > level.history175Peak)"
        + "\n    {\n        level.history175Peak = level.historySavesActive;\n    }",
        s,
    )
    assert replacements == 1, "Expected one page-admission observation point"
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
    s, replacements = page_query.subn(lambda match: query_observation, s)
    assert replacements == 1, "Expected one history-page query observation point"
    p.write_text(s)
    cfg.write_text(
        f'set db_host "{dbname}"\nset db_user "history"\nset db_pass "{password}"\nset db_base "{database[:-1]}"\nset db_port "3306"\nset history175_database "{database}"\n'
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
            "g++ -m32 -std=c++11 -fPIC -shared -DCOD4 /workspace/dev-tools/tests/player-memory-audit.cpp -o /workspace/"
            + relative
            + "/plugins/memory_audit.so",
        ],
        cwd=ROOT / "dev-tools",
        timeout=90,
    )
    (home / "build.log").write_text(build.stdout + build.stderr)
    assert build.returncode == 0, "Profiler build failed"
    command = [
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
        "/workspace/cod4x-server/bin/cod4x18_dedrun",
    ]
    for key, value in [
        ("fs_basepath", "/game"),
        ("fs_homepath", "/workspace/" + relative),
        ("fs_game", "mods/opencj"),
        ("dedicated", 2),
        ("net_port", 28976),
        ("sv_maxclients", 32),
        ("sv_authorizemode", 0),
        ("com_hunkMegs", 1024),
        ("developer", 1),
        ("g_gametype", "cj"),
    ]:
        command += ["+set", key, str(value)]
    command += ["+exec", "history175.cfg", "+loadplugin", "memory_audit", "+map", "mp_killhouse"]
    p = run(command, cwd=ROOT / "dev-tools")
    assert p.returncode == 0
    started = True
    print("H175 isolated engine: " + str(home), flush=True)
    log = ""
    for _ in range(100):
        time.sleep(1)
        p = run(["docker", "logs", engine])
        log = (p.stdout + p.stderr).replace(password, "<redacted>")
        if any(
            x in log
            for x in [
                "H175 COMPLETE",
                "script compile error",
                "script runtime error",
                "Received signal:",
                "exceeded maximum number",
            ]
        ):
            break
    (home / "console.log").write_text(log)
    (home / "console.log").chmod(0o600)
    for line in log.splitlines():
        if line.startswith(("H175", "MEM baseline", "MEM loaded", "MEM released")):
            print(line, flush=True)
    done = re.search(r"H175 COMPLETE (\d+) (\d+) (\d+) (\d+)", log)
    memory = [
        (label, int(values), int(objects))
        for label, values, objects in re.findall(r"MEM (\w+) values=(\d+) objects=(\d+)", log)
    ]
    baseline = next((v for label, v, _ in memory if label == "baseline"), 0)
    peak = max((v for label, v, _ in memory if label == "page"), default=0)
    report.update(
        completed=bool(done),
        failures=int(done[1]) if done else None,
        checks=int(done[2]) if done else 0,
        maxActivePages=int(done[3]) if done else None,
        queries=int(done[4]) if done else None,
        scriptValuesBaseline=baseline,
        scriptValuesPeak=peak,
        scriptValueIncrease=peak - baseline,
    )
    if not done:
        for marker in ["script compile error", "script runtime error", "Received signal:"]:
            if marker in log:
                print(log[max(0, log.index(marker) - 100) : log.index(marker) + 1900], flush=True)
        raise RuntimeError("History fixture did not complete")
    assert report["failures"] == 0 and report["maxActivePages"] <= 2
    assert 0 < report["scriptValueIncrease"] < 5000, "Unexpected temporary GSC allocation"
    report["passed"] = True
finally:
    report["binaryUnchanged"] = (
        hashlib.sha256(binary.read_bytes()).hexdigest() == report["binarySha256"]
    )
    report["sourcesUnchanged"] = all(
        hashlib.sha256((ROOT / p).read_bytes()).hexdigest() == sha
        for p, sha in report["sourceHashes"].items()
    )
    if started:
        report["engineRemoved"] = run(["docker", "rm", "-f", engine]).returncode == 0
    if created:
        report["databaseRemoved"] = run(["docker", "rm", "-f", "-v", dbname]).returncode == 0
    private.unlink(missing_ok=True)
    cfg.unlink(missing_ok=True)
    report["credentialsRemoved"] = not private.exists() and not cfg.exists()
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report), flush=True)
