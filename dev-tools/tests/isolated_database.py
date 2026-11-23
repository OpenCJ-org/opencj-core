"""Own a schema-only database copy and a restricted account for engine fixtures."""

import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import uuid

from compose_environment import database_container

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL


class IsolatedDatabase:
    """Create unique resources; cleanup never targets an existing schema or account."""

    def __init__(self, fixture_name):
        if not re.fullmatch(r"[a-z][a-z-]{0,19}", fixture_name):
            raise ValueError("Fixture name must be a short lowercase label")
        self.database_container = database_container()
        suffix = uuid.uuid4().hex[:8]
        self.database = "opencj_verify_" + fixture_name.replace("-", "_") + "_" + suffix + "_cod4"
        self.account = "fixture_" + suffix
        self.password = secrets.token_urlsafe(32)
        self.home = ROOT / "dev-tools/local" / (fixture_name + "-" + suffix)
        self.config = self.home / "mods/opencj/database-fixture.cfg"
        self.owns_database_resources = False

    def query_database(self, query, target=None):
        if target is not None and target != self.database:
            raise ValueError("SQL fixture can query only its own schema")
        try:
            with MySQL(self.database_container, target or "mysql") as database:
                return database.query(query, timeout=60)
        except Exception as error:
            path = self.home / "sql-error.txt"
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(descriptor, "w") as stream:
                stream.write(str(error).replace(self.password, "<redacted>"))
            raise RuntimeError("SQL fixture failed; see private sql-error.txt") from None

    def prepare_database(self):
        schema_count = self.query_database(
            "SELECT COUNT(*) FROM information_schema.SCHEMATA"
            f" WHERE SCHEMA_NAME='{self.database}';"
        )
        account_count = self.query_database(
            f"SELECT COUNT(*) FROM mysql.user WHERE User='{self.account}' AND Host='%';"
        )
        if schema_count != "0" or account_count != "0":
            raise RuntimeError("SQL fixture identities already exist")
        dump = subprocess.run(
            [
                "docker",
                "exec",
                self.database_container,
                "sh",
                "-c",
                'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysqldump -u root'
                " --no-data --routines --triggers --skip-comments --skip-lock-tables"
                " --no-tablespaces --set-gtid-purged=OFF --column-statistics=0 openCJ_cod4",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if dump.returncode or re.search(r"^INSERT INTO", dump.stdout, re.M):
            raise RuntimeError("Expected a schema-only fixture export")
        # The fresh names were checked above; cleanup also covers a lost CREATE reply.
        self.owns_database_resources = True
        self.query_database(
            f"CREATE DATABASE {self.database} CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;"
        )
        self.query_database(dump.stdout.replace("openCJ_cod4", self.database), self.database)
        self.query_database(
            f"CREATE USER '{self.account}'@'%' IDENTIFIED BY '{self.password}';"
            f" GRANT ALL PRIVILEGES ON {self.database}.* TO '{self.account}'@'%';"
        )

    def write_engine_config(self):
        """Give the isolated engine access only to this fixture's disposable schema."""
        settings = {
            "db_host": "db",
            "db_user": self.account,
            "db_pass": self.password,
            # mysql.gsc appends the current game's version number.
            "db_base": self.database[:-1],
            "db_port": "3306",
        }
        descriptor = os.open(self.config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            for key, value in settings.items():
                stream.write(f'set {key} "{value}"\n')

    def cleanup(self):
        """Remove owned SQL resources and erase credentials even if cleanup fails."""
        try:
            if self.owns_database_resources:
                self.query_database(
                    f"DROP DATABASE IF EXISTS {self.database};"
                    f" DROP USER IF EXISTS '{self.account}'@'%';"
                )
                self.owns_database_resources = False
        finally:
            self.config.unlink(missing_ok=True)
