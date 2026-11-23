"""Verify GeoIP publication and privileges in a temporary schema and account."""

import argparse
from pathlib import Path
import os
import subprocess
import sys
import uuid

from compose_environment import database_container, database_network

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL

sys.path.insert(0, str(ROOT / "server-db/tools/geoip"))
import provision


class GeoIPVerification:
    """Own the fixture schema, account, private secret and updater container."""

    def __init__(self, image, container, network):
        self.image = image
        self.container = container
        self.network = network
        tag = uuid.uuid4().hex[:8]
        self.schema = "opencj_geoip_test_" + tag
        self.account = "geoip_test_" + tag
        self.home = ROOT / "dev-tools/local" / ("geoip-integration-" + tag)
        self.secret = self.home / "test-password"
        self.updater = "opencj-geoip-fixture-" + tag
        self.owns_database_resources = False
        self.updater_attempted = False

    def prepare_schema(self):
        """Claim only unused fixture names; cleanup also covers an uncertain CREATE result."""
        self.home.mkdir(parents=True, mode=0o700)
        with MySQL(self.container, "openCJ_cod4") as admin:
            schema_count = admin.query(
                "SELECT COUNT(*) FROM information_schema.SCHEMATA"
                f" WHERE SCHEMA_NAME='{self.schema}';"
            )
            account_count = admin.query(
                f"SELECT COUNT(*) FROM mysql.user WHERE User='{self.account}' AND Host='%';"
            )
            if schema_count != "0" or account_count != "0":
                raise RuntimeError("GeoIP fixture names already exist; refusing to reuse them")
            self.owns_database_resources = True
            admin.query("CREATE DATABASE " + self.schema + ";")
        with MySQL(self.container, self.schema) as database:
            database.query("""
                CREATE TABLE longCountry(
                    country CHAR(2) PRIMARY KEY,
                    longCountry VARCHAR(128)
                );
                INSERT INTO longCountry VALUES('GB','United Kingdom');
                """)
            database.query((ROOT / "server-db/migrations/025-geoip-country.sql").read_text())

    def verify_provisioning(self):
        """Repeated setup keeps the secret and refuses broader table privileges."""
        provision.provision(self.container, self.schema, self.secret, account=self.account)
        original_secret = self.secret.read_bytes()
        provision.provision(self.container, self.schema, self.secret, account=self.account)
        assert (
            self.secret.read_bytes() == original_secret
        ), "repeated provisioning changed the secret"
        assert self.secret.stat().st_mode & 0o777 == 0o600, "fixture secret is not private"

        principal = "'" + self.account + "'@'%'"
        with MySQL(self.container, self.schema) as admin:
            qualified_table = self.schema + ".geoIPState"
            admin.query(f"GRANT DROP ON {qualified_table} TO {principal};")
            try:
                try:
                    provision.provision(
                        self.container, self.schema, self.secret, account=self.account
                    )
                except ValueError:
                    pass
                else:
                    raise AssertionError("provisioning accepted table DROP permission")
            finally:
                admin.query(f"REVOKE DROP ON {qualified_table} FROM {principal};")

            admin.query(f"GRANT SELECT ON {qualified_table} TO {principal} WITH GRANT OPTION;")
            try:
                try:
                    provision.provision(
                        self.container, self.schema, self.secret, account=self.account
                    )
                except ValueError:
                    pass
                else:
                    raise AssertionError("provisioning accepted transferable table permissions")
            finally:
                admin.query(f"REVOKE GRANT OPTION ON {qualified_table} FROM {principal};")

            for function_name in ("getCountry", "geoIPLookupCode"):
                admin.query(
                    f"GRANT EXECUTE ON FUNCTION {self.schema}.{function_name} TO {principal};"
                )
        assert self.secret.read_bytes() == original_secret, "rejected grants changed the secret"

    def verify_publication(self):
        command = [
            "docker",
            "run",
            "--rm",
            "--name",
            self.updater,
            "--network",
            self.network,
            "--user",
            str(os.getuid()) + ":" + str(os.getgid()),
            "--read-only",
            "--tmpfs",
            "/tmp:size=128m",
            "-e",
            "GEOIP_DB_HOST=db",
            "-e",
            "GEOIP_DB_NAME=" + self.schema,
            "-e",
            "GEOIP_DB_USER=" + self.account,
            "-e",
            "GEOIP_DB_PASSWORD_FILE=/run/secret",
            "-v",
            str(self.secret) + ":/run/secret:ro",
            "-v",
            str(ROOT / "server-db/tools/geoip") + ":/source:ro",
            "--entrypoint",
            "python",
            self.image,
            "/source/test_database.py",
        ]
        existing = subprocess.run(
            ["docker", "container", "inspect", self.updater], capture_output=True, timeout=30
        )
        if existing.returncode == 0:
            raise RuntimeError("GeoIP fixture container already exists; refusing to reuse it")
        self.updater_attempted = True
        result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        (self.home / "database-test-output.txt").write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError("Isolated GeoIP checks failed; see private database-test-output.txt")
        (self.home / "database-test-result.json").write_text(result.stdout)
        print(result.stdout, end="")

    def close(self):
        try:
            try:
                if self.updater_attempted:
                    subprocess.run(
                        ["docker", "rm", "-f", self.updater], capture_output=True, timeout=30
                    )
            finally:
                if self.owns_database_resources:
                    with MySQL(self.container, "openCJ_cod4") as admin:
                        admin.query(
                            f"DROP DATABASE IF EXISTS {self.schema};"
                            f" DROP USER IF EXISTS '{self.account}'@'%';"
                        )
        finally:
            self.secret.unlink(missing_ok=True)

    def run(self):
        try:
            self.prepare_schema()
            self.verify_provisioning()
            self.verify_publication()
            print("GeoIP provisioning: repeat secret preserved; excess table rights refused.")
            print("Evidence: " + str(self.home))
        finally:
            self.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--image", default="opencj-geoip-updater:latest", help="Locally built GeoIP updater image"
    )
    options = parser.parse_args()
    image = subprocess.run(
        ["docker", "image", "inspect", options.image], capture_output=True, timeout=30
    )
    if image.returncode:
        parser.error(
            "Build the updater image first: docker build -t "
            + options.image
            + " server-db/tools/geoip"
        )
    verification = GeoIPVerification(options.image, database_container(), database_network())
    verification.run()


if __name__ == "__main__":
    main()
