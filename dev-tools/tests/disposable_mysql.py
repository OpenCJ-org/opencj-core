"""Own a temporary MySQL container populated only with schema and synthetic rows."""

import hashlib
import os
from pathlib import Path
import re
import secrets
import subprocess
import time
import uuid

from compose_environment import database_container, database_network

ROOT = Path(__file__).resolve().parents[2]
COMMAND_TIMEOUT_SECONDS = 60
SQL_TIMEOUT_SECONDS = 90
READY_TIMEOUT_SECONDS = 90


class DisposableMySQL:
    """Keep resource limits and load tests separate from the gameplay database."""

    def __init__(self, home, label, *, memory="1536m", container_options=(), server_options=()):
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,23}", label):
            raise ValueError("Disposable database label is invalid")
        self.home = Path(home).resolve()
        if not self.home.is_relative_to(ROOT / "dev-tools/local"):
            raise ValueError("Database evidence must stay under ignored dev-tools/local")
        token = uuid.uuid4().hex[:8]
        self.container = "opencj-" + label + "-db-" + token
        self.database = "opencj_verify_" + label.replace("-", "_") + "_" + token + "_cod4"
        self.account = "fixture"
        self.password = secrets.token_hex(24)
        self.environment_file = self.home / "mysql.env"
        self.config_files = []
        self.memory = memory
        self.container_options = tuple(container_options)
        self.server_options = tuple(server_options)
        self.owns_container = False
        self.schema_sha256 = None

    def command(self, arguments, **kwargs):
        kwargs.setdefault("timeout", COMMAND_TIMEOUT_SECONDS)
        return subprocess.run(arguments, capture_output=True, text=True, **kwargs)

    def private_file(self, path, text):
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(text)

    def admin_sql(self, statement):
        result = self.command(
            [
                "docker",
                "exec",
                "-i",
                self.container,
                "sh",
                "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --max_allowed_packet=64M -N -u root',
            ],
            input=statement,
            timeout=SQL_TIMEOUT_SECONDS,
        )
        if result.returncode:
            error_path = self.home / "sql-error.txt"
            descriptor = os.open(error_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                stream.write(result.stderr.replace(self.password, "<redacted>"))
            raise RuntimeError("Disposable SQL failed; see " + str(error_path))
        return result.stdout.strip()

    def sql(self, statement):
        return self.admin_sql("USE " + self.database + ";\n" + statement)

    def wait_until_ready(self):
        deadline = time.monotonic() + READY_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            try:
                result = self.command(
                    [
                        "docker",
                        "exec",
                        self.container,
                        "sh",
                        "-c",
                        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP'
                        ' -h127.0.0.1 -N -u root -e "SELECT 1"',
                    ],
                    timeout=5,
                )
                if result.returncode == 0:
                    return
            except subprocess.TimeoutExpired:
                pass
            time.sleep(1)
        raise TimeoutError("Disposable MySQL did not become ready")

    def prepare(self):
        """Launch a uniquely named container, then copy definitions without player rows."""
        self.home.mkdir(parents=True, exist_ok=True)
        existing = self.command(
            [
                "docker",
                "ps",
                "-a",
                "--filter",
                "name=^/" + self.container + "$",
                "--format",
                "{{.Names}}",
            ]
        )
        if existing.returncode or existing.stdout.strip():
            raise RuntimeError("Could not establish ownership of disposable container")
        network = database_network()
        self.private_file(self.environment_file, "MYSQL_ROOT_PASSWORD=" + self.password + "\n")
        # Mark ownership before launch so a lost Docker reply is still cleaned up.
        self.owns_container = True
        result = self.command(
            [
                "docker",
                "run",
                "-d",
                "--name",
                self.container,
                "--network",
                network,
                "--memory",
                self.memory,
                *self.container_options,
                "--env-file",
                str(self.environment_file),
                "mysql:8.0",
                "--log-bin-trust-function-creators=1",
                *self.server_options,
            ]
        )
        if result.returncode:
            raise RuntimeError("Disposable MySQL launch failed")
        self.wait_until_ready()
        self.copy_schema()

    def copy_schema(self):
        """The source connection exports definitions only; all writes target this container."""
        dump = self.command(
            [
                "docker",
                "exec",
                database_container(),
                "sh",
                "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root'
                " --no-data --routines --triggers --skip-comments --skip-lock-tables"
                " --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4",
            ]
        )
        if dump.returncode or re.search(r"^INSERT INTO", dump.stdout, re.M):
            raise RuntimeError("Expected a successful schema-only export")
        schema = dump.stdout.replace("openCJ_cod4", self.database)
        schema = re.sub(r"DEFINER=\S+\s", "DEFINER=CURRENT_USER ", schema)
        if re.search(r"^\s*(CREATE DATABASE|USE)\b", schema, re.I | re.M):
            raise RuntimeError("Schema export unexpectedly selects a database")
        self.schema_sha256 = hashlib.sha256(dump.stdout.encode()).hexdigest()
        self.admin_sql(
            f"CREATE DATABASE {self.database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
        )
        self.sql(schema)
        self.admin_sql(
            f"CREATE USER '{self.account}'@'%' IDENTIFIED BY '{self.password}';"
            f" GRANT ALL PRIVILEGES ON {self.database}.* TO '{self.account}'@'%';"
        )

    def write_engine_config(self, path, extra_settings=None):
        path = Path(path)
        if not path.resolve().is_relative_to(self.home):
            raise ValueError("Engine credentials must stay in the owned fixture directory")
        settings = {
            "db_host": self.container,
            "db_user": self.account,
            "db_pass": self.password,
            # The production GSC appends the current game number.
            "db_base": self.database[:-1],
            "db_port": "3306",
        }
        settings.update(extra_settings or {})
        self.private_file(
            path, "".join(f'set {name} "{value}"\n' for name, value in settings.items())
        )
        self.config_files.append(path)

    def cleanup(self):
        """Remove only the owned container and erase temporary credentials even on failure."""
        try:
            if self.owns_container:
                result = self.command(["docker", "rm", "-f", "-v", self.container])
                if result.returncode:
                    raise RuntimeError("Could not remove disposable database " + self.container)
                self.owns_container = False
        finally:
            self.environment_file.unlink(missing_ok=True)
            for path in self.config_files:
                path.unlink(missing_ok=True)
