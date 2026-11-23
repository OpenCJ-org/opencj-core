"""Verify persistence with a disposable schema and isolated game-server fixture."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import runpy
import shutil
import socket
import subprocess
import time
from textwrap import dedent
from textwrap import indent
import uuid

from compose_environment import database_container

ROOT = Path(__file__).resolve().parents[2]
ENGINE_POLL_COUNT = 100
ENGINE_POLL_INTERVAL_SECONDS = 1
POOL_TIMEOUT_SECONDS = 90


def parse_engine_path():
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
        engine_path.relative_to(ROOT)
    except ValueError:
        parser.error(
            "The selected engine must be inside the core checkout for the Compose mount"
        )
    return engine_path


class HistoryVerification:
    """Own one temporary schema, its grants, private credentials, and engine container."""

    def __init__(self, engine_path, with_adapter):
        self.engine_path = engine_path
        self.engine_container_path = (
            "/workspace/" + engine_path.relative_to(ROOT).as_posix()
        )
        self.with_adapter = with_adapter
        self.map_changed = False
        token = uuid.uuid4().hex[:8]
        self.tag = "history-save-192-" + token
        self.database_name = "opencj_verify_192_" + token + "_cod4"
        assert re.fullmatch(r"opencj_verify_192_[0-9a-f]{8}_cod4", self.database_name)
        self.home = ROOT / "dev-tools/local" / self.tag
        self.mod = self.home / "mods/opencj"
        self.home.mkdir(mode=0o700)
        self.mod.mkdir(parents=True)
        self.container_name = "opencj-" + self.tag
        self.database_created = False
        self.database_granted = False
        self.container_started = False
        self.config_path = self.mod / "history192.cfg"
        self.secret_values = []
        self.pool_config_path = self.home / "pool.cfg"
        self.report = {
            "database": self.database_name,
            "schemaOnly": True,
            "productionWrites": False,
        }

    def query_database(self, query, target=None):
        """Run SQL against server metadata or this temporary schema."""
        command = [
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
            assert target == self.database_name
            command.append(target)
        result = subprocess.run(command, input=query, text=True, capture_output=True)
        if result.returncode:
            (self.home / "sql-error.txt").write_text(result.stderr)
            (self.home / "sql-error.txt").chmod(0o600)
            raise RuntimeError("Verification SQL failed; see restricted sql-error.txt")
        return result.stdout.strip()

    def redact_text(self, text):
        for value in self.secret_values:
            if value:
                text = text.replace(value, "<redacted>")
        return text

    def prepare_database(self):
        """Copy schema and routines only, then add synthetic records."""
        assert (
            self.query_database(
                "SELECT COUNT(*) FROM information_schema.SCHEMATA"
                " WHERE SCHEMA_NAME='" + self.database_name + "';"
            )
            == "0"
        )
        assert (
            self.query_database(
                "SELECT COUNT(*) FROM mysql.user WHERE User='opencj' AND Host='%';"
            )
            == "1"
        )
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
        schema = dump.stdout.replace("openCJ_cod4", self.database_name)
        assert not re.search(
            r"^\s*(?:CREATE DATABASE|USE)\b", schema, re.I | re.M
        ), "Unexpected schema selection"
        (self.home / "schema.sql").write_text(schema)
        (self.home / "schema.sql").chmod(0o600)
        self.report["sourceSchemaSha256"] = hashlib.sha256(
            dump.stdout.encode()
        ).hexdigest()
        metadata = self.query_database(
            "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME"
            " FROM information_schema.SCHEMATA"
            " WHERE SCHEMA_NAME = 'openCJ_cod4';"
        ).split("\t")
        assert len(metadata) == 2 and all(
            re.fullmatch(r"[a-zA-Z0-9_]+", v) for v in metadata
        )
        character_set, collation = metadata
        self.query_database(
            "CREATE DATABASE "
            + self.database_name
            + " CHARACTER SET "
            + character_set
            + " COLLATE "
            + collation
            + ";"
        )
        self.database_created = True
        self.query_database(schema, self.database_name)
        self.query_database(
            "GRANT ALL PRIVILEGES ON " + self.database_name + ".* TO 'opencj'@'%';"
        )
        self.database_granted = True
        assert (
            self.query_database("SELECT COUNT(*) FROM playerRuns;", self.database_name)
            == "0"
        )
        self.query_database(
            "INSERT INTO playerInformation(playerID, playerName)"
            " VALUES(1, 'Verification A'), (2, 'Verification B');"
            "INSERT INTO mapids(mapID, mapname)"
            " VALUES(1, 'history192_fixture'), (2, 'history192_other');"
            "INSERT INTO checkpoints(cpID,mapID) VALUES(1,1);"
            "INSERT INTO routes(routeID,mapID,cpID,routeName) VALUES(1,1,1,'verification');"
            "UPDATE checkpoints SET finishRouteID=1 WHERE cpID=1;",
            self.database_name,
        )
        print("Prepared empty schema/routine copy and isolated fixtures.", flush=True)

    def verify_publication_sql(self):
        publication_checks = runpy.run_path(
            str(ROOT / "dev-tools/tests/demo-publication-190.py")
        )["verify"]
        self.report["publicationSQL"] = publication_checks(
            lambda query: self.query_database(query, self.database_name)
        )
        print(
            "PUBLICATION SQL COMPLETE checks="
            + str(self.report["publicationSQL"]["checks"]),
            flush=True,
        )

    def prepare_script_tree(self):
        """Copy production scripts and isolate the fixture from account callbacks."""
        for folder in ("opencj", "maps"):
            shutil.copytree(ROOT / "server-gsc" / folder, self.mod / folder)
        for asset in ("mod.ff", "z_opencj.iwd"):
            (self.mod / asset).symlink_to("/mod-assets/" + asset)
        (self.home / "plugins").mkdir()

        (self.home / "steamclient.so").symlink_to("/game/steamclient.so")
        shutil.copyfile(
            ROOT / "dev-tools/tests/history-save-192.gsc",
            self.mod / "opencj/history192test.gsc",
        )
        gametype_source = """main()
{
    level.script = getCvar("mapname");
}
"""
        (self.mod / "maps/mp/gametypes/cj.gsc").write_text(gametype_source)
        (self.mod / "maps/mp/gametypes/_callbacksetup.gsc").write_text(
            "CodeCallback_StartGameType()\n"
            "{\n"
            "    thread openCJ\\history192Test::main();\n"
            "}\n"
            + "\n".join(
                "CodeCallback_" + callback + "()\n{\n}\n"
                for callback in [
                    "PlayerConnect",
                    "PlayerDisconnect",
                    "PlayerDamage",
                    "PlayerKilled",
                    "PlayerLastStand",
                ]
            )
        )
        (self.mod / "maps/mp/mp_killhouse.gsc").write_text("main()\n{\n}\n")

    def observe_history_warnings(self):
        # Observe production warning decisions without requiring a human client.
        history_script = self.mod / "opencj/historysave.gsc"
        source = history_script.read_text()
        warning = "self iPrintLnBold(message);"
        assert source.count(warning) == 1
        history_script.write_text(
            source.replace(
                warning, "self openCJ\\history192Test::recordWarning(message);"
            )
        )

    def delay_sql_replies(self):
        """Pause test replies after the real SQL operation completes."""
        # Delay delivery of one real SQL result; do not stub the database operation.
        sql_script = self.mod / "opencj/mysql.gsc"
        source = sql_script.read_text()
        # Delay only the result-delivery boundary; tolerate ordinary GSC layout changes.
        request_match = re.search(r"(?ms)^_request\s*\([^)]*\)\s*\{.*?^\}", source)
        assert request_match, "SQL request function was not found"
        request_function = request_match.group(0)
        result_wait = re.compile(
            r'(?m)^[ \t]*level\s+waittill\(\s*"mysqlQueryDone"\s*\+\s*[A-Za-z_]\w*\s*,'
            r"\s*[A-Za-z_]\w*\s*,\s*[A-Za-z_]\w*\s*\)\s*;[ \t]*\n"
        )
        delay = "    openCJ\\history192Test::observeSQLResult(query);\n"
        request_function, replacements = result_wait.subn(
            lambda match: match.group(0) + delay, request_function
        )
        assert replacements == 1, "Expected one SQL completion wait"
        sql_script.write_text(
            source[: request_match.start()]
            + request_function
            + source[request_match.end() :]
        )

    def observe_run_events(self):
        # Run identity changes remain real; omit HUD callbacks that need a human client.
        (self.mod / "opencj/events/onrunstopped.gsc").write_text(
            "main()\n{\n    self.history192Stopped = true;\n}\n"
        )
        (self.mod / "opencj/events/onruncreated.gsc").write_text(
            "main()\n{\n    self.history192CreatedEvents++;\n}\n"
        )

    def write_database_config(self):
        """Keep credentials private and force the disposable schema name."""
        runtime_config = (
            ROOT / "dev-tools/local/runtime/mods/opencj/opencj-dev.cfg"
        ).read_text()
        lines = [
            line
            for line in runtime_config.splitlines()
            if re.match(r"\s*set(?:a)?\s+db_", line)
        ]
        for line in lines:
            match = re.match(r'\s*set(?:a)?\s+db_pass\s+"([^"]*)"', line)
            if match:
                self.secret_values.append(match.group(1))
        lines = [
            re.sub(
                r"(db_base\s+).*",
                lambda m: m.group(1) + '"' + self.database_name[:-1] + '"',
                line,
            )
            for line in lines
        ]
        assert any(self.database_name[:-1] in line for line in lines)
        self.config_path.write_text(
            "\n".join(lines)
            + '\nset history192_database "'
            + self.database_name
            + '"\n'
        )
        self.config_path.chmod(0o600)
        self.database_setting_lines = lines

    def prepare_adapter_scripts(self):
        """Attach publication and map-transition suites through their fixture hooks."""
        shutil.copyfile(
            ROOT / "dev-tools/tests/sql-adapter.gsc",
            self.mod / "opencj/sqladaptertest.gsc",
        )
        fixture = self.mod / "opencj/history192test.gsc"
        shutil.copyfile(
            ROOT / "dev-tools/tests/demo-publication-190.gsc",
            self.mod / "opencj/publicationcapacity.gsc",
        )
        sql_script = self.mod / "opencj/mysql.gsc"
        sql_source, replacements = re.subn(
            r"(?m)^_request(?=\s*\()", "_capacityRealRequest", sql_script.read_text()
        )
        assert replacements == 1, "Expected one production SQL request entry"
        sql_source += dedent(r"""
        _request(query, policy, key, scope, queueWaitMs, retainRows)
        {
            return openCJ\publicationCapacity::request(query, policy, key, scope, queueWaitMs, retainRows);
        }
        """)
        sql_script.write_text(sql_source)
        test_source = fixture.read_text()
        extra_suites = dedent(r"""
        additionalSuites(firstPlayer, secondPlayer)
        {
            check(openCJ\publicationCapacity::run(), "publication retry and receipt recovery");
            openCJ\sqlAdapterTest::run(firstPlayer, secondPlayer);
            openCJ\sqlAdapterTest::queueForMapChange();
        }
        """).strip()
        test_source, replacements = re.subn(
            r"(?ms)^additionalSuites\s*\([^)]*\)\s*\{.*?^\}",
            lambda match: extra_suites,
            test_source,
        )
        assert replacements == 1, "Expected one additional-suite entry point"
        map_resume = indent(
            dedent(r"""
            if(getCvarInt("sql_adapter_stage") == 1)
            {
        openCJ\sqlAdapterTest::afterMap();
        return;
            }
        """),
            "    ",
        )
        test_source, replacements = re.subn(
            r"(?m)^(main\s*\(\s*\)\s*\{)",
            lambda match: match.group(0) + map_resume,
            test_source,
        )
        assert replacements == 1, "Expected one fixture main function"
        fixture.write_text(test_source)

    def write_pool_config(self):
        lines = self.database_setting_lines
        values = {}
        for line in lines:
            match = re.match(r'\s*set(?:a)?\s+(db_\w+)\s+"?([^"]*)"?', line)
            if match:
                values[match.group(1)] = match.group(2).strip()
        self.pool_config_path.write_text(
            "\n".join(
                [
                    values["db_host"],
                    values["db_user"],
                    values["db_pass"],
                    self.database_name,
                    values["db_port"],
                ]
            )
            + "\n"
        )
        self.pool_config_path.chmod(0o600)
        self.pool_binary_container_path = (
            "/workspace/" + str(self.home.relative_to(ROOT)) + "/pool-test"
        )

    def compile_pool_test(self):
        command = [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            "g++",
            "server",
            "-m32",
            "-std=c++11",
            "-O0",
            "-g",
            "-pthread",
            "/workspace/dev-tools/tests/sql-adapter.cpp",
            "/workspace/server-ext/mysql_async_pool.cpp",
            "-lmysqlclient",
            "-o",
            self.pool_binary_container_path,
        ]
        result = subprocess.run(
            command, cwd=ROOT / "dev-tools", capture_output=True, text=True
        )
        (self.home / "pool-build.log").write_text(result.stdout + result.stderr)
        assert result.returncode == 0, "Pool test compile failed"

    def run_pool_test(self):
        command = [
            "docker",
            "compose",
            "run",
            "--rm",
            "--no-deps",
            "--entrypoint",
            self.pool_binary_container_path,
            "server",
            "/workspace/dev-tools/local/" + self.tag + "/pool.cfg",
        ]
        pool = subprocess.run(
            command,
            cwd=ROOT / "dev-tools",
            capture_output=True,
            text=True,
            timeout=POOL_TIMEOUT_SECONDS,
        )
        (self.home / "pool.log").write_text(self.redact_text(pool.stdout + pool.stderr))
        (self.home / "pool.log").chmod(0o600)
        for line in pool.stdout.splitlines():
            if line.startswith(
                (
                    "SQLPOOL METRIC",
                    "SQLPOOL COMPLETE",
                    "SQLPOOL FAILURE",
                    "SQLPOOL CHECK 0:",
                )
            ):
                print(line, flush=True)
        assert pool.returncode == 0, "Pool regression failed; inspect pool.log"
        self.report["poolCompleted"] = True

    def start_engine(self):
        command = [
            "docker",
            "compose",
            "run",
            "-d",
            "--no-deps",
            "--name",
            self.container_name,
            "--workdir",
            "/workspace/" + str(self.home.relative_to(ROOT)),
            "server",
            self.engine_container_path,
        ]
        for key, value in [
            ("fs_basepath", "/game"),
            ("fs_homepath", "/workspace/dev-tools/local/" + self.tag),
            ("fs_game", "mods/opencj"),
            ("dedicated", "2"),
            ("net_port", "28972"),
            ("sv_maxclients", "2"),
            ("sv_authorizemode", "0"),
            ("com_hunkMegs", "1024"),
            ("developer", "1"),
            ("g_gametype", "cj"),
        ]:
            command += ["+set", key, value]
        command += ["+exec", "history192.cfg", "+map", "mp_killhouse"]
        subprocess.run(
            command, cwd=ROOT / "dev-tools", check=True, capture_output=True, text=True
        )
        self.container_started = True

    def wait_for_engine(self):
        """Poll the isolated server and perform its requested map transition."""
        log = ""
        self.map_changed = False
        for _ in range(ENGINE_POLL_COUNT):
            time.sleep(ENGINE_POLL_INTERVAL_SECONDS)
            result = subprocess.run(
                ["docker", "logs", self.container_name], capture_output=True, text=True
            )
            log = self.redact_text(result.stdout + result.stderr)
            if (
                self.with_adapter
                and "SQLPOOL_MAP_READY" in log
                and not self.map_changed
            ):
                self.change_map()
                self.map_changed = True
            if any(
                word in log
                for word in (
                    "HISTORY192 COMPLETE",
                    "script compile error",
                    "script runtime error",
                )
            ):
                break
        return log

    def change_map(self):
        """Send a console command only to this fixture container."""
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(2)
        sock.connect("/var/run/docker.sock")
        sock.sendall(
            (
                "POST /containers/"
                + self.container_name
                + "/attach?stream=1&stdin=1&stdout=1&stderr=1 HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Length: 0\r\n\r\n"
            ).encode()
        )
        header = b""
        while b"\r\n\r\n" not in header:
            header += sock.recv(4096)
        assert (
            b"101" in header.split(b"\r\n", 1)[0]
            or b"200" in header.split(b"\r\n", 1)[0]
        )
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

    def record_results(self, log):
        for line in log.splitlines():
            if line.startswith(
                (
                    "HISTORY192 COMPLETE",
                    "HISTORY192 CHECK 0:",
                    "CAP PUBLICATION RECOVERY COMPLETE",
                    "CAP PUBLICATION FAIL",
                )
            ):
                print(line, flush=True)
        for error in ("script compile error", "script runtime error"):
            if error in log:
                print(log[log.index(error) : log.index(error) + 900], flush=True)
        self.report["revisions"] = {
            repo: subprocess.check_output(
                ["git", "-C", str(ROOT / repo), "rev-parse", "HEAD"], text=True
            ).strip()
            for repo in ("server-ext", "server-gsc", "server-db", "dev-tools")
        }
        self.report["binarySha256"] = hashlib.sha256(
            self.engine_path.read_bytes()
        ).hexdigest()
        self.report["reconnectWarnings"] = log.count("MYSQL_OPT_RECONNECT")
        assert (
            self.report["reconnectWarnings"] <= 5
        ), "Reconnect options changed during healthy queries"
        self.report["actualMapTransition"] = (
            self.map_changed
            and "HISTORY192 CHECK 1: accepted write persists through an actual engine map change"
            in log
        )
        self.report["checks"] = sum(
            line.startswith("HISTORY192 CHECK 1:") for line in log.splitlines()
        )
        self.report["observations"] = {
            match.group(1): bool(int(match.group(2)))
            for match in re.finditer(r"HISTORY192 OBSERVATION (\w+)=(\d+)", log)
        }
        self.report["verificationCompleted"] = (
            "HISTORY192 COMPLETE failures=0" in log
            and not any(
                word in log
                for word in (
                    "script compile error",
                    "script runtime error",
                    "HISTORY192 CHECK 0:",
                )
            )
        )
        self.report["fixtureCounts"] = self.query_database(
            "SELECT (SELECT COUNT(*) FROM playerRuns),"
            " (SELECT COUNT(*) FROM playerSaves),"
            " (SELECT COUNT(*) FROM demoRuns),"
            " (SELECT COUNT(*) FROM demoChunks);",
            self.database_name,
        ).split("\t")
        assert self.report[
            "verificationCompleted"
        ], "Verification incomplete; inspect restricted console.log"

    def cleanup(self):
        """Remove all owned resources and retain private evidence."""
        if self.container_started:
            result = subprocess.run(
                ["docker", "logs", self.container_name], capture_output=True, text=True
            )
            (self.home / "console.log").write_text(
                self.redact_text(result.stdout + result.stderr)
            )
            (self.home / "console.log").chmod(0o600)
            subprocess.run(
                ["docker", "rm", "-f", self.container_name],
                check=True,
                capture_output=True,
            )
        self.config_path.unlink(missing_ok=True)
        self.pool_config_path.unlink(missing_ok=True)
        if self.database_granted:
            self.query_database(
                "REVOKE ALL PRIVILEGES ON "
                + self.database_name
                + ".* FROM 'opencj'@'%';"
            )
        if self.database_created:
            self.query_database("DROP DATABASE " + self.database_name + ";")
        self.report["disposableDatabaseRemoved"] = (
            self.query_database(
                "SELECT COUNT(*) FROM information_schema.SCHEMATA"
                " WHERE SCHEMA_NAME='" + self.database_name + "';"
            )
            == "0"
        )
        self.report["testContainerRemoved"] = not subprocess.check_output(
            [
                "docker",
                "ps",
                "-a",
                "--filter",
                "name=^/" + self.container_name + "$",
                "--format",
                "{{.Names}}",
            ],
            text=True,
        ).strip()
        (self.home / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")
        print(
            "Cleanup:",
            self.report["disposableDatabaseRemoved"],
            self.report["testContainerRemoved"],
            flush=True,
        )
        print("Evidence:", self.home, flush=True)


def main(*, with_adapter=False):
    engine_path = parse_engine_path()
    verification = HistoryVerification(engine_path, with_adapter)
    try:
        verification.prepare_database()
        if with_adapter:
            verification.verify_publication_sql()
        verification.prepare_script_tree()
        verification.observe_history_warnings()
        verification.delay_sql_replies()
        verification.observe_run_events()
        verification.write_database_config()
        if with_adapter:
            verification.prepare_adapter_scripts()
            verification.write_pool_config()
            verification.compile_pool_test()
            verification.run_pool_test()
        verification.start_engine()
        log = verification.wait_for_engine()
        verification.record_results(log)
    finally:
        verification.cleanup()


if __name__ == "__main__":
    main(with_adapter=bool(globals().get("SQL_ADAPTER_VERIFY")))
