"""#192 verification with a disposable schema/engine and test-only fault injection."""

from compose_environment import database_container
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--engine",
    type=Path,
    default=ROOT / "cod4x-server/bin/cod4x18_dedrun",
    help="Built engine inside the core checkout; defaults to cod4x-server/bin/cod4x18_dedrun",
)
options = parser.parse_args()
engine_path = options.engine.resolve()
if not engine_path.is_file():
    parser.error("The selected engine does not exist: " + str(engine_path))
try:
    engine_relative_path = engine_path.relative_to(ROOT)
except ValueError:
    parser.error("The selected engine must be inside the core checkout for the Compose mount")
engine_container_path = "/workspace/" + engine_relative_path.as_posix()
token = uuid.uuid4().hex[:8]
tag = "history-save-192-" + token
database = "opencj_verify_192_" + token + "_cod4"
assert re.fullmatch(r"opencj_verify_192_[0-9a-f]{8}_cod4", database)
home = ROOT / "dev-tools/local" / tag
mod = home / "mods/opencj"
mod.mkdir(parents=True)
name = "opencj-" + tag
created = granted = started = False
private = mod / "history192.cfg"
secrets = []
pool_private = home / "pool.cfg"
report = {"database": database, "schemaOnly": True, "productionWrites": False}


def db(q, target=None):
    cmd = [
        "docker",
        "exec",
        "-i",
        database_container(),
        "sh",
        "-c",
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root "$@"',
        "history192",
    ]
    if target:
        assert target == database
        cmd.append(target)
    proc = subprocess.run(cmd, input=q, text=True, capture_output=True)
    if proc.returncode:
        (home / "sql-error.txt").write_text(proc.stderr)
        (home / "sql-error.txt").chmod(0o600)
        raise RuntimeError("Verification SQL failed; see restricted sql-error.txt")
    return proc.stdout.strip()


def redact(text):
    for value in secrets:
        if value:
            text = text.replace(value, "<redacted>")
    return text


try:
    assert (
        db("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='" + database + "';")
        == "0"
    )
    assert db("SELECT COUNT(*) FROM mysql.user WHERE User='opencj' AND Host='%';") == "1"
    dump = subprocess.run(
        [
            "docker",
            "exec",
            database_container(),
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --no-data --routines --triggers --skip-comments --skip-lock-tables --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4',
        ],
        capture_output=True,
        text=True,
    )
    assert dump.returncode == 0, "Schema-only export failed"
    assert not re.search(
        r"^INSERT INTO", dump.stdout, re.M
    ), "Unexpected data in schema-only export"
    schema = dump.stdout.replace("openCJ_cod4", database)
    assert not re.search(
        r"^\s*(?:CREATE DATABASE|USE)\b", schema, re.I | re.M
    ), "Unexpected schema selection"
    (home / "schema.sql").write_text(schema)
    (home / "schema.sql").chmod(0o600)
    report["sourceSchemaSha256"] = hashlib.sha256(dump.stdout.encode()).hexdigest()
    metadata = db(
        "SELECT DEFAULT_CHARACTER_SET_NAME,DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='openCJ_cod4';"
    ).split("\t")
    assert len(metadata) == 2 and all(re.fullmatch(r"[a-zA-Z0-9_]+", v) for v in metadata)
    db(
        "CREATE DATABASE "
        + database
        + " CHARACTER SET "
        + metadata[0]
        + " COLLATE "
        + metadata[1]
        + ";"
    )
    created = True
    db(schema, database)
    db("GRANT ALL PRIVILEGES ON " + database + ".* TO 'opencj'@'%';")
    granted = True
    assert db("SELECT COUNT(*) FROM playerRuns;", database) == "0"
    db(
        "INSERT INTO playerInformation(playerID,playerName) VALUES(1,'Verification A'),(2,'Verification B');"
        "INSERT INTO mapids(mapID,mapname) VALUES(1,'history192_fixture'),(2,'history192_other');"
        "INSERT INTO checkpoints(cpID,mapID) VALUES(1,1);"
        "INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES(1,1,1,'verification');"
        "UPDATE checkpoints SET finishRouteID=1 WHERE cpID=1;",
        database,
    )
    print("Prepared empty schema/routine copy and isolated fixtures.", flush=True)
    for folder in ("opencj", "maps"):
        shutil.copytree(ROOT / "server-gsc" / folder, mod / folder)
    for asset in ("mod.ff", "z_opencj.iwd"):
        (mod / asset).symlink_to("/mod-assets/" + asset)
    (home / "plugins").mkdir()

    (home / "steamclient.so").symlink_to("/game/steamclient.so")
    shutil.copyfile(
        ROOT / "dev-tools/tests/history-save-192.gsc", mod / "opencj/history192test.gsc"
    )
    (mod / "maps/mp/gametypes/cj.gsc").write_text('main() { level.script = getCvar("mapname"); }\n')
    (mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
        'CodeCallback_StartGameType() { thread openCJ\\history192Test::main(); }\n'
        + "\n".join(
            "CodeCallback_" + callback + "() {}"
            for callback in [
                "PlayerConnect",
                "PlayerDisconnect",
                "PlayerDamage",
                "PlayerKilled",
                "PlayerLastStand",
            ]
        )
    )
    (mod / "maps/mp/mp_killhouse.gsc").write_text("main() {}\n")
    # Observe production warning decisions without requiring a human client.
    p = mod / "opencj/historysave.gsc"
    source = p.read_text()
    warning = 'self iPrintLnBold(message);'
    assert source.count(warning) == 1
    p.write_text(source.replace(warning, "self openCJ\\history192Test::recordWarning(message);"))
    # Delay delivery of one real SQL result; do not stub the database operation.
    p = mod / "opencj/mysql.gsc"
    source = p.read_text()
    first = source.index("_request(query, policy, key, scope, deadline, save)\n")
    last = source.index("\n_reportFailure", first)
    function = source[first:last]
    needle = '    level waittill("mysqlQueryDone"+id, rows, outcome);\n'
    assert function.count(needle) == 1
    delay = '    if (isDefined(level.history192Delay) && level.history192Delay && isSubStr(query, "SELECT savePosition("))\n    {\n        self notify("history192_result_ready");\n        wait 0.2;\n    }\n'
    function = function.replace(needle, needle + delay)
    p.write_text(source[:first] + function + source[last:])
    cfg = (ROOT / "dev-tools/local/runtime/mods/opencj/opencj-dev.cfg").read_text()
    lines = [line for line in cfg.splitlines() if re.match(r"\s*set(?:a)?\s+db_", line)]
    for line in lines:
        match = re.match(r'\s*set(?:a)?\s+db_pass\s+"([^"]*)"', line)
        if match:
            secrets.append(match.group(1))
    lines = [
        re.sub(r'(db_base\s+).*', lambda m: m.group(1) + '"' + database[:-1] + '"', line)
        for line in lines
    ]
    assert any(database[:-1] in line for line in lines)
    private.write_text("\n".join(lines) + '\nset history192_database "' + database + '"\n')
    private.chmod(0o600)
    if globals().get("SQL_ADAPTER_VERIFY"):
        shutil.copyfile(ROOT / "dev-tools/tests/sql-adapter.gsc", mod / "opencj/sqladaptertest.gsc")
        fixture = mod / "opencj/history192test.gsc"
        fixture.write_text(
            fixture.read_text().replace("    extraSaveChecks();", "    extraSaveChecks();")
        )
        test_source = fixture.read_text()
        assert "    a extraSaveChecks();" in test_source
        test_source = test_source.replace(
            "    a extraSaveChecks();",
            "    a extraSaveChecks();\n    openCJ\\sqlAdapterTest::run(a,b);\n    openCJ\\sqlAdapterTest::queueForMapChange();",
        )
        test_source = test_source.replace(
            "main()\n{",
            'main()\n{\n    if(getCvarInt("sql_adapter_stage")==1){openCJ\\sqlAdapterTest::afterMap();return;}',
        )
        fixture.write_text(test_source)
        values = {}
        for line in lines:
            match = re.match(r'\s*set(?:a)?\s+(db_\w+)\s+"?([^"]*)"?', line)
            if match:
                values[match.group(1)] = match.group(2).strip()
        pool_private.write_text(
            "\n".join(
                [
                    values["db_host"],
                    values["db_user"],
                    values["db_pass"],
                    database,
                    values["db_port"],
                ]
            )
            + "\n"
        )
        pool_private.chmod(0o600)
        pool_binary = "/workspace/" + str(home.relative_to(ROOT)) + "/pool-test"
        build = [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            "bash",
            "server",
            "-lc",
            "g++ -m32 -std=c++11 -O0 -g -pthread /workspace/dev-tools/tests/sql-adapter.cpp /workspace/server-ext/mysql_async_pool.cpp -lmysqlclient -o "
            + pool_binary,
        ]
        compiled = subprocess.run(build, cwd=ROOT / "dev-tools", capture_output=True, text=True)
        (home / "pool-build.log").write_text(compiled.stdout + compiled.stderr)
        assert compiled.returncode == 0, "Pool test compile failed"
        command = [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            pool_binary,
            "server",
            "/workspace/dev-tools/local/" + tag + "/pool.cfg",
        ]
        pool = subprocess.run(
            command, cwd=ROOT / "dev-tools", capture_output=True, text=True, timeout=90
        )
        (home / "pool.log").write_text(redact(pool.stdout + pool.stderr))
        (home / "pool.log").chmod(0o600)
        for line in pool.stdout.splitlines():
            if line.startswith(
                ("SQLPOOL METRIC", "SQLPOOL COMPLETE", "SQLPOOL FAILURE", "SQLPOOL CHECK 0:")
            ):
                print(line, flush=True)
        assert pool.returncode == 0, "Pool regression failed; inspect pool.log"
        report["poolCompleted"] = True
    cmd = [
        "docker",
        "compose",
        "run",
        "-d",
        "--no-deps",
        "--name",
        name,
        "--workdir",
        "/workspace/" + str(home.relative_to(ROOT)),
        "server",
        engine_container_path,
    ]
    for key, val in [
        ("fs_basepath", "/game"),
        ("fs_homepath", "/workspace/dev-tools/local/" + tag),
        ("fs_game", "mods/opencj"),
        ("dedicated", "2"),
        ("net_port", "28972"),
        ("sv_maxclients", "2"),
        ("sv_authorizemode", "0"),
        ("com_hunkMegs", "1024"),
        ("developer", "1"),
        ("g_gametype", "cj"),
    ]:
        cmd += ["+set", key, val]
    cmd += ["+exec", "history192.cfg", "+map", "mp_killhouse"]
    subprocess.run(cmd, cwd=ROOT / "dev-tools", check=True, capture_output=True, text=True)
    started = True
    log = ""
    map_changed = False
    for _ in range(100):
        time.sleep(1)
        proc = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
        log = redact(proc.stdout + proc.stderr)
        if globals().get("SQL_ADAPTER_VERIFY") and "SQLPOOL_MAP_READY" in log and not map_changed:
            import socket

            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.settimeout(2)
            sock.connect("/var/run/docker.sock")
            sock.sendall(
                (
                    "POST /containers/"
                    + name
                    + "/attach?stream=1&stdin=1&stdout=1&stderr=1 HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n"
                ).encode()
            )
            header = b""
            while b"\r\n\r\n" not in header:
                header += sock.recv(4096)
            assert b"101" in header.split(b"\r\n", 1)[0] or b"200" in header.split(b"\r\n", 1)[0]
            sock.sendall(b"map mp_killhouse\n")
            # Docker attach can discard buffered stdin if closed immediately.
            # Keep the upgraded connection alive long enough to consume output.
            deadline = time.monotonic() + 2
            try:
                while time.monotonic() < deadline:
                    sock.settimeout(max(0.01, deadline - time.monotonic()))
                    if not sock.recv(65536):
                        break
            except socket.timeout:
                pass
            finally:
                sock.close()
            map_changed = True
        if any(
            word in log
            for word in ("HISTORY192 COMPLETE", "script compile error", "script runtime error")
        ):
            break
    for line in log.splitlines():
        if line.startswith(("HISTORY192 COMPLETE", "HISTORY192 CHECK 0:")):
            print(line, flush=True)
    for error in ("script compile error", "script runtime error"):
        if error in log:
            print(log[log.index(error) : log.index(error) + 900], flush=True)
    report["revisions"] = {
        repo: subprocess.check_output(
            ["git", "-C", str(ROOT / repo), "rev-parse", "HEAD"], text=True
        ).strip()
        for repo in ("server-ext", "server-gsc", "server-db", "dev-tools")
    }
    report["binarySha256"] = hashlib.sha256(
        (ROOT / "cod4x-server/bin/cod4x18_dedrun").read_bytes()
    ).hexdigest()
    report["reconnectWarnings"] = log.count("MYSQL_OPT_RECONNECT")
    assert report["reconnectWarnings"] <= 5, "Reconnect options changed during healthy queries"
    report["actualMapTransition"] = (
        map_changed
        and "HISTORY192 CHECK 1: accepted write persists through an actual engine map change" in log
    )
    report["checks"] = sum(line.startswith("HISTORY192 CHECK 1:") for line in log.splitlines())
    report["observations"] = {
        match.group(1): bool(int(match.group(2)))
        for match in re.finditer(r"HISTORY192 OBSERVATION (\w+)=(\d+)", log)
    }
    report["verificationCompleted"] = "HISTORY192 COMPLETE failures=0" in log and not any(
        word in log
        for word in ("script compile error", "script runtime error", "HISTORY192 CHECK 0:")
    )
    report["fixtureCounts"] = db(
        "SELECT (SELECT COUNT(*) FROM playerRuns),(SELECT COUNT(*) FROM playerSaves),(SELECT COUNT(*) FROM demoRuns),(SELECT COUNT(*) FROM demoChunks);",
        database,
    ).split("\t")
    assert report[
        "verificationCompleted"
    ], "Verification incomplete; inspect restricted console.log"
finally:
    if started:
        proc = subprocess.run(["docker", "logs", name], capture_output=True, text=True)
        (home / "console.log").write_text(redact(proc.stdout + proc.stderr))
        (home / "console.log").chmod(0o600)
        subprocess.run(["docker", "rm", "-f", name], check=True, capture_output=True)
    private.unlink(missing_ok=True)
    pool_private.unlink(missing_ok=True)
    if granted:
        db("REVOKE ALL PRIVILEGES ON " + database + ".* FROM 'opencj'@'%';")
    if created:
        db("DROP DATABASE " + database + ";")
    report["disposableDatabaseRemoved"] = (
        db("SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='" + database + "';")
        == "0"
    )
    report["testContainerRemoved"] = not subprocess.check_output(
        ["docker", "ps", "-a", "--filter", "name=^/" + name + "$", "--format", "{{.Names}}"],
        text=True,
    ).strip()
    (home / "result.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        "Cleanup:", report["disposableDatabaseRemoved"], report["testContainerRemoved"], flush=True
    )
    print("Evidence:", home, flush=True)
