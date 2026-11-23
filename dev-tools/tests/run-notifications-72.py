"""Verify notification preferences, records and HUD lifetime with 32 synthetic players."""

import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import secrets
import subprocess
import time
import uuid

from compose_environment import database_container, database_network, workspace_file, workspace_path
import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
PLAYER_COUNT = 32
DATABASE_READY_TIMEOUT_SECONDS = 90
ENGINE_TIMEOUT_SECONDS = 100


def command_result(command, **kwargs):
    return subprocess.run(command, text=True, capture_output=True, **kwargs)


class NotificationVerification:
    """Own a disposable database container, private configuration and isolated engine."""

    def __init__(self, options, source_database, network, assets):
        self.options = options
        self.source_database = source_database
        self.network = network
        self.assets = assets
        token = uuid.uuid4().hex[:8]
        self.database = "opencj_verify_72_" + token + "_cod4"
        self.database_container = "opencj-notify-db-" + token
        self.home = ROOT / "dev-tools/local" / ("notifications-72-" + token)
        self.home.mkdir(mode=0o700)
        self.mod = self.home / "mods/opencj"
        self.password = secrets.token_hex(24)
        self.environment_file = self.home / "mysql.env"
        self.config_file = self.mod / "notify72.cfg"
        self.database_attempted = False
        self.binary_hash = hashlib.sha256(options.engine.read_bytes()).hexdigest()
        self.source_hashes = gsc_fixture.script_hashes(options.scripts)
        self.report = {
            "players": PLAYER_COUNT,
            "databaseWrites": "disposable fixture only",
            "passed": False,
        }

    def query_database(self, query, *, select_fixture=True):
        command = [
            "docker",
            "exec",
            "-i",
            self.database_container,
            "sh",
            "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -N -u root "$@"',
            "notifications",
        ]
        if select_fixture:
            command.append(self.database)
        result = command_result(command, input=query, timeout=60)
        if result.returncode:
            (self.home / "sql-error.txt").write_text(
                result.stderr.replace(self.password, "<redacted>")
            )
            raise RuntimeError("Fixture SQL failed; see private sql-error.txt")
        return result.stdout.strip()

    def start_database(self):
        self.environment_file.write_text("MYSQL_ROOT_PASSWORD=" + self.password + "\n")
        self.environment_file.chmod(0o600)
        # Cleanup also covers a launch that creates the container but returns an error.
        self.database_attempted = True
        result = command_result(
            [
                "docker",
                "run",
                "-d",
                "--name",
                self.database_container,
                "--network",
                self.network,
                "--memory",
                "1536m",
                "--env-file",
                str(self.environment_file),
                "mysql:8.0",
                "--log-bin-trust-function-creators=1",
            ]
        )
        if result.returncode:
            raise RuntimeError("Could not start the disposable notification database")
        deadline = time.monotonic() + DATABASE_READY_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            result = command_result(
                [
                    "docker",
                    "exec",
                    self.database_container,
                    "sh",
                    "-c",
                    'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h127.0.0.1'
                    ' -N -u root -e "SELECT 1"',
                ],
                timeout=10,
            )
            if result.returncode == 0:
                return
            time.sleep(1)
        raise RuntimeError("Disposable database did not become ready")

    def copy_schema(self):
        """Copy structure and routines only; player data never enters this fixture."""
        result = command_result(
            [
                "docker",
                "exec",
                self.source_database,
                "sh",
                "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root --no-data'
                " --routines --triggers --skip-comments --skip-lock-tables"
                " --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4",
            ],
            timeout=60,
        )
        # Stored procedures contain indented INSERT statements; top-level rows must be absent.
        if result.returncode or re.search(
            r"^(?:INSERT INTO|CREATE DATABASE|USE)\b", result.stdout, re.M | re.I
        ):
            raise RuntimeError("Expected a schema-only dump without database selection")
        self.report["sourceSchemaSha256"] = hashlib.sha256(result.stdout.encode()).hexdigest()
        schema = result.stdout.replace("openCJ_cod4", self.database)
        schema = re.sub(r"DEFINER=\S+\s", "DEFINER=CURRENT_USER ", schema)
        self.query_database(
            "CREATE DATABASE "
            + self.database
            + " CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;",
            select_fixture=False,
        )
        self.query_database(schema)
        self.query_database(
            "CREATE USER 'notification_fixture'@'%' IDENTIFIED BY '"
            + self.password
            + "'; GRANT ALL PRIVILEGES ON "
            + self.database
            + ".* TO 'notification_fixture'@'%';",
            select_fixture=False,
        )

    def seed_scenarios(self):
        players = ",".join(
            f"({player_id},'Notification fixture {player_id}')"
            for player_id in range(1, PLAYER_COUNT + 1)
        )
        self.query_database(
            """
            INSERT INTO mapids(mapID, mapname) VALUES(1, 'mp_killhouse');
            INSERT INTO routes(routeID, mapID, routeName) VALUES(1, 1, 'easy');
            INSERT INTO checkpoints(cpID, mapID, finishRouteID) VALUES(1, 1, 1);
            INSERT INTO playerInformation(playerID, playerName) VALUES """
            + players
            + """;
            INSERT INTO playerRuns(
                runID, playerID, mapID, instanceNumber, finishcpID,
                finishTimeStamp, FPSMode, hb, anyPct
            ) VALUES
                (1000, 1, 1, 1, 1, NOW(), 'mix', 0, 0),
                (1001, 2, 1, 1, 1, NOW(), 'mix', 0, 0),
                (1002, 1, 1, 1, 1, NOW(), 'mix', 0, 0),
                (2002, 1, 1, 1, 1, NOW(), 'mix', 0, 1);
            INSERT INTO checkpointStatistics(
                runID, cpID, timePlayed, saveCount, loadCount,
                explosiveJumps, explosiveLaunches, doubleExplosives
            ) VALUES
                (1000, 1, 9000, 1, 1, 8, 8, 0),
                (1001, 1, 610000, 1, 1, 9, 9, 0),
                (1002, 1, 8000, 1, 1, 7, 7, 0),
                (2002, 1, 1000, 1, 1, 0, 0, 0);
            INSERT INTO challenges(
                challengeKey, tier, points, mapID, routeLabel, routeHint, routeID
            ) VALUES ('notify-fixture', 1, 10, 1, 'Easy', 'easy', 1);
        """
        )

    def observe_messages(self):
        """Capture output at native print calls without changing message decisions."""
        for filename in ("recordnotices.gsc", "challenges.gsc"):
            path = self.mod / "opencj" / filename
            source, count = re.subn(
                r"\bself\s+iprintln\s*\(",
                lambda match: r"self openCJ\platformTest::capturePrivate(",
                path.read_text(),
            )
            if not count:
                raise RuntimeError("No private notification output in " + filename)
            if filename == "recordnotices.gsc":
                source, count = re.subn(
                    r"\biprintln\s*\(",
                    lambda match: r"openCJ\platformTest::capturePublic(",
                    source,
                )
                if count != 1:
                    raise RuntimeError("Expected one public record announcement")
            path.write_text(source)

    def observe_finish_sounds(self):
        path = self.mod / "opencj/finishsounds.gsc"
        source, count = re.subn(
            r"\bself\s+playLocalSound\s*\(",
            lambda match: r"self openCJ\platformTest::captureFinishSound(",
            path.read_text(),
        )
        if count != 1:
            raise RuntimeError("Expected one finish sound output boundary")
        path.write_text(source)

    def observe_sql_replies(self):
        path = self.mod / "opencj/mysql.gsc"
        source = path.read_text()
        function = re.search(r"(?ms)^_request\s*\([^)]*\)\s*\{.*?^\}", source)
        if not function:
            raise RuntimeError("SQL request function was not found")
        wait_pattern = (
            r'(?m)^[ \t]*level\s+waittill\(\s*"mysqlQueryDone"\s*\+\s*[A-Za-z_]\w*\s*,'
            r"\s*[A-Za-z_]\w*\s*,\s*[A-Za-z_]\w*\s*\)\s*;[ \t]*\n"
        )
        replacement, count = re.subn(
            wait_pattern,
            lambda match: match[0] + "    openCJ\\platformTest::observeSQLResult(query);\n",
            function[0],
        )
        if count != 1:
            raise RuntimeError("Expected one SQL result-delivery boundary")
        path.write_text(source[: function.start()] + replacement + source[function.end() :])

    def prepare_engine(self):
        source_hashes, _ = gsc_fixture.prepare_fixture(self.options, self.home)
        self.report["sourceHashes"] = source_hashes
        if self.assets:
            for asset, container_path in self.assets.items():
                target = self.mod / asset
                target.unlink()
                target.symlink_to(container_path)
        # Account login is outside this fixture; preference loading remains real.
        (self.mod / "opencj/events/playerlogin.gsc").write_text("main()\n{\n}\n")
        self.observe_messages()
        self.observe_finish_sounds()
        self.observe_sql_replies()
        settings = {
            "db_host": self.database_container,
            "db_user": "notification_fixture",
            "db_pass": self.password,
            "db_base": self.database[:-1],
            "db_port": "3306",
            "notify72_database": self.database,
        }
        self.config_file.write_text(
            "".join(f'set {key} "{value}"\n' for key, value in settings.items())
        )
        self.config_file.chmod(0o600)
        result = command_result(
            [
                "docker",
                "compose",
                "run",
                "--rm",
                "--no-deps",
                "--entrypoint",
                "g++",
                "build",
                "-m32",
                "-std=c++11",
                "-fPIC",
                "-shared",
                "-DCOD4",
                "/workspace/dev-tools/tests/notification-hud-audit-72.cpp",
                "-o",
                "/workspace/" + (self.home / "plugins/memory_audit.so").relative_to(ROOT).as_posix(),
            ],
            cwd=ROOT / "dev-tools",
            timeout=90,
        )
        (self.home / "build.log").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("HUD profiler build failed; see private build.log")

    def verify_hud_cleanup(self):
        log = (self.home / "console.log").read_text()
        huds = {
            label: int(count)
            for label, count in re.findall(
                r"MEM (\w+) values=\d+ objects=\d+ threads=\d+ huds=(\d+)", log
            )
        }
        assert {"text", "flashing", "expired"} <= huds.keys(), huds
        expected_overlays = PLAYER_COUNT * 2
        assert huds["flashing"] - huds["text"] == expected_overlays, huds
        assert huds["expired"] == huds["text"], huds
        self.report["huds"] = huds

    def execute(self):
        self.start_database()
        self.copy_schema()
        self.seed_scenarios()
        verify_sql = runpy.run_path(str(ROOT / "dev-tools/tests/record-notices-72.py"))["verify"]
        self.report["sqlChecks"] = verify_sql(self.query_database)
        print("N72 SQL cases passed: " + str(self.report["sqlChecks"]), flush=True)
        self.prepare_engine()
        engine_report = gsc_fixture.run_prepared_fixture(
            self.options,
            self.home,
            "mp_killhouse",
            self.report["sourceHashes"],
            plugin_names=("memory_audit",),
            timeout_seconds=ENGINE_TIMEOUT_SECONDS,
            extra_settings={"sv_maxclients": str(PLAYER_COUNT)},
            config_files=("notify72.cfg",),
        )
        self.report.update(engine_report)
        self.report["passed"] = False
        self.verify_hud_cleanup()
        self.report["passed"] = True

    def cleanup(self):
        """Always remove the temporary database and its only credential copies."""
        try:
            if self.database_attempted:
                result = command_result(["docker", "rm", "-f", "-v", self.database_container])
                self.report["databaseRemoved"] = result.returncode == 0
        finally:
            self.environment_file.unlink(missing_ok=True)
            self.config_file.unlink(missing_ok=True)
            self.report["credentialsRemoved"] = (
                not self.environment_file.exists() and not self.config_file.exists()
            )
            self.report["binaryUnchanged"] = (
                hashlib.sha256(self.options.engine.read_bytes()).hexdigest() == self.binary_hash
            )
            self.report["sourcesUnchanged"] = (
                gsc_fixture.script_hashes(self.options.scripts) == self.source_hashes
            )
            preserved = self.report["binaryUnchanged"] and self.report["sourcesUnchanged"]
            removed = self.report.get("databaseRemoved", not self.database_attempted)
            self.report["passed"] = self.report["passed"] and preserved and removed
            (self.home / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")
            print("Evidence: " + str(self.home), flush=True)


def main():
    options = gsc_fixture.parse_options(
        default_fixture=ROOT / "dev-tools/tests/notifications-72.gsc",
        completion_marker="N72 COMPLETE",
    )
    if options.maps != ["mp_killhouse"]:
        raise ValueError("The notification database fixture requires mp_killhouse")
    assets = {}
    if os.environ.get("OPENCJ_TEST_ASSET_DIR"):
        asset_directory = Path(os.environ["OPENCJ_TEST_ASSET_DIR"])
        for asset in ("mod.ff", "z_opencj.iwd"):
            assets[asset] = workspace_path(workspace_file(asset_directory / asset))
    # Resolve the selected installation before creating any resources.
    verification = NotificationVerification(
        options, database_container(), database_network(), assets
    )
    try:
        verification.execute()
    finally:
        verification.cleanup()
    if not verification.report["passed"]:
        raise RuntimeError("Notification verification or resource cleanup failed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
