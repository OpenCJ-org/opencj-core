"""#72: disposable 32-player notification, preference and record-message checks."""

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
import importlib.util
import os

ROOT = Path(__file__).resolve().parents[2]
token = uuid.uuid4().hex[:8]
tag = "notifications-72-" + token
database = "opencj_verify_72_" + token + "_cod4"
dbname = "opencj-notify-db-" + token
engine = "opencj-notify-engine-" + token
home = ROOT / "dev-tools/local" / tag
mod = home / "mods/opencj"
mod.mkdir(parents=True)
password = secrets.token_hex(24)
private = home / "mysql.env"
cfg = mod / "notify72.cfg"
private.write_text("MYSQL_ROOT_PASSWORD=" + password + "\n")
private.chmod(0o600)
report = {"players": 32, "databaseWrites": "disposable fixture only"}
created = started = False
binary = ROOT / "cod4x-server/bin/cod4x18_dedrun"
report["binarySha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
sources = [
    "server-gsc/opencj/" + p
    for p in [
        "notifications.gsc",
        "recordnotices.gsc",
        "events/runfinished.gsc",
        "challenges.gsc",
        "demos.gsc",
        "saveposition.gsc",
    ]
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
        "INSERT INTO checkpoints(cpID,mapID,ender) VALUES(1,1,'easy');"
        + "INSERT INTO playerInformation(playerID,playerName) VALUES"
        + ",".join(f"({i},'Notification fixture {i}')" for i in range(1, 33))
        + ";"
        "INSERT INTO playerRuns(runID,playerID,mapID,instanceNumber,finishcpID,finishTimeStamp,FPSMode,hb,anyPct) VALUES "
        "(1000,1,1,1,1,NOW(),'mix',0,0),(1001,2,1,1,1,NOW(),'mix',0,0),(1002,1,1,1,1,NOW(),'mix',0,0),(2002,1,1,1,1,NOW(),'mix',0,1);"
        "INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives) VALUES "
        "(1000,1,9000,1,1,8,8,0),(1001,1,610000,1,1,9,9,0),(1002,1,8000,1,1,7,7,0),(2002,1,1000,1,1,0,0,0);"
    )
    sql(
        "INSERT INTO challenges(challengeKey,tier,points,mapName,routeLabel,routeName) VALUES ('notify-fixture',1,10,'mp_killhouse','Easy','easy');"
    )
    spec = importlib.util.spec_from_file_location(
        "record72", ROOT / "dev-tools/tests/record-notices-72.py"
    )
    checks = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checks)
    report["sqlChecks"] = checks.verify(sql)
    print("N72 SQL cases passed: " + str(report["sqlChecks"]), flush=True)
    for folder in ["opencj", "maps"]:
        shutil.copytree(ROOT / "server-gsc" / folder, mod / folder)
    assetDirectory = "/mod-assets"
    if os.environ.get("OPENCJ_TEST_ASSET_DIR"):
        assetPath = Path(os.environ["OPENCJ_TEST_ASSET_DIR"]).resolve()
        assetDirectory = "/workspace/" + str(assetPath.relative_to(ROOT))
    for asset in ["mod.ff", "z_opencj.iwd"]:
        (mod / asset).symlink_to(assetDirectory + "/" + asset)
    (home / "plugins").mkdir()
    (home / "steamclient.so").symlink_to("/game/steamclient.so")

    shutil.copyfile(ROOT / "dev-tools/tests/notifications-72.gsc", mod / "opencj/notify72test.gsc")
    (mod / "maps/mp/gametypes/cj.gsc").write_text('main(){level.script=getCvar("mapname");}\n')
    (mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
        'CodeCallback_StartGameType(){thread openCJ\\notify72Test::main();}\n'
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
    # Keep real preference loading; omit unrelated login/run creation.
    (mod / "opencj/events/playerlogin.gsc").write_text("main(){}\n")
    p = mod / "opencj/recordnotices.gsc"
    source = p.read_text()
    needle = 'if(server!="")iprintln('
    assert source.count(needle) == 1
    source = source.replace(needle, 'if(server!="")openCJ\\notify72Test::capturePublic(')
    needle = 'self iprintln(route+'
    assert source.count(needle) == 1
    source = source.replace(needle, 'self openCJ\\notify72Test::capturePrivate(route+')
    needle = '    self iprintln(message);'
    assert source.count(needle) == 1
    source = source.replace(needle, '    self openCJ\\notify72Test::capturePrivate(message);')
    needle = '    rows=self openCJ\\mySQL::mysqlAsyncRead(checkpointQuery(runID,cpID,fps,ele,any,hb,tas,metric));'
    assert source.count(needle) == 1
    source = source.replace(
        needle,
        needle
        + '\n    if(isDefined(level.n72DelayCheckpoint) && level.n72DelayCheckpoint){level.n72CheckpointWaiting=true;wait .20;}',
    )
    p.write_text(source)
    p = mod / "opencj/challenges.gsc"
    source = p.read_text()
    needle = 'self iprintln("Challenge complete!'
    assert source.count(needle) == 1
    source = source.replace(
        needle, 'self openCJ\\notify72Test::capturePrivate("Challenge complete!'
    )
    p.write_text(source)
    cfg.write_text(
        f'set db_host "{dbname}"\nset db_user "history"\nset db_pass "{password}"\nset db_base "{database[:-1]}"\nset db_port "3306"\nset notify72_database "{database}"\n'
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
            "g++ -m32 -std=c++11 -fPIC -shared -DCOD4 /workspace/dev-tools/tests/notification-hud-audit-72.cpp -o /workspace/"
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
        ("net_port", 28979),
        ("sv_maxclients", 32),
        ("sv_authorizemode", 0),
        ("com_hunkMegs", 1024),
        ("developer", 1),
        ("g_gametype", "cj"),
    ]:
        command += ["+set", key, str(value)]
    command += ["+exec", "notify72.cfg", "+loadplugin", "memory_audit", "+map", "mp_killhouse"]
    p = run(command, cwd=ROOT / "dev-tools")
    assert p.returncode == 0
    started = True
    print("N72 isolated engine: " + str(home), flush=True)
    log = ""
    for _ in range(100):
        time.sleep(1)
        p = run(["docker", "logs", engine])
        log = (p.stdout + p.stderr).replace(password, "<redacted>")
        if any(
            x in log
            for x in [
                "N72 COMPLETE",
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
        if line.startswith(("N72", "MEM text", "MEM flashing", "MEM expired")):
            print(line, flush=True)
    done = re.search(r"N72 COMPLETE failures=(\d+) checks=(\d+)", log)
    huds = {
        label: int(value)
        for label, value in re.findall(
            r"MEM (\w+) values=\d+ objects=\d+ threads=\d+ huds=(\d+)", log
        )
    }
    report.update(
        completed=bool(done),
        failures=int(done[1]) if done else None,
        checks=int(done[2]) if done else 0,
        huds=huds,
    )
    if not done:
        for marker in ["script compile error", "script runtime error", "Received signal:"]:
            if marker in log:
                print(log[max(0, log.index(marker) - 100) : log.index(marker) + 1600], flush=True)
        raise RuntimeError("Notification fixture did not complete")
    assert report["failures"] == 0
    assert huds["flashing"] - huds["text"] == 64 and huds["expired"] == huds["text"], huds
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
