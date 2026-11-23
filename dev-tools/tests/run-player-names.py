"""Verify preferred names and regular-name policy with private disposable resources."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import uuid

from compose_environment import database_container
import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
PREFERRED_COOLDOWN_SECONDS = 60 * 60
# Separate CLI queries may cross several clock ticks during the cooldown checks.
QUERY_TIMING_ALLOWANCE_SECONDS = 10
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL


class PlayerNameVerification:
    """Own the synthetic schema, account, configuration and isolated engine fixture."""

    def __init__(self, options):
        self.options = options
        self.database_container = database_container()
        suffix = uuid.uuid4().hex[:8]
        self.database = "opencj_verify_names_" + suffix + "_cod4"
        self.account = "names_fixture_" + suffix
        self.password = secrets.token_urlsafe(32)
        self.home = ROOT / "dev-tools/local" / ("player-names-" + suffix)
        self.config = self.home / "mods/opencj/names-fixture.cfg"
        self.owns_database_resources = False
        self.report = {"productionWrites": False, "checks": 0, "failures": 0}

    def query_database(self, query, target=None):
        if target is not None and target != self.database:
            raise ValueError("Player-name fixture can query only its own schema")
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
            raise RuntimeError("Player-name fixture identities already exist")
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

    def check(self, condition, scenario):
        self.report["checks"] += 1
        if not condition:
            self.report["failures"] += 1
        print("NAME SQL CHECK " + str(int(bool(condition))) + ": " + scenario, flush=True)

    def set_preferred_name(self, player_id, preferred_name_sql):
        return self.query_database(
            f"SELECT setPreferredName({player_id},{preferred_name_sql});", self.database
        )

    def claim_race_name(self, player_id):
        return self.set_preferred_name(player_id, "'RaceHandle'")

    def seed_players_and_rules(self):
        """Keep all policy terms and account records synthetic inside the fixture."""
        # A schema-only export omits this singleton, which serializes preferred-name writes.
        self.query_database(
            "INSERT INTO preferredNameWriteLock(singleton) VALUES(1);", self.database
        )
        self.query_database(
            """
            INSERT INTO playerInformation(playerID,playerName,adminLevel) VALUES
                (1,'FixtureOne',0),
                (2,'FixtureTwo',0),
                (3,'Moderator',40),
                (4,'RaceOne',0),
                (5,'RaceTwo',0);
            """,
            self.database,
        )
        self.query_database(
            """
            INSERT INTO nameModerationRules(
                nameHash,normalizedLength,matchMode,source
            ) VALUES(
                SHA2(normalizeModeratedName('FixtureToken'),256),
                LENGTH(normalizeModeratedName('FixtureToken')),'contains','test'
            );
            INSERT INTO nameModerationExceptions
            SELECT ruleID,SHA2(normalizeModeratedName('OkFixtureToken'),256)
            FROM nameModerationRules WHERE source='test';
            """,
            self.database,
        )

    def verify_claims_and_policy(self):
        minimum_remaining_seconds = PREFERRED_COOLDOWN_SECONDS - QUERY_TIMING_ALLOWANCE_SECONDS
        self.check(
            self.set_preferred_name(1, "'RecordName'") == "0", "first preferred name accepted"
        )
        self.check(
            self.set_preferred_name(2, "'recordname'") == "-3", "case-insensitive unique constraint"
        )
        self.check(
            self.set_preferred_name(1, "'RecordName'") == "-1", "no-op does not consume cooldown"
        )
        self.check(
            int(self.set_preferred_name(1, "'NextName'")) >= minimum_remaining_seconds,
            "second change requires one hour",
        )
        self.check(
            int(self.set_preferred_name(1, "NULL")) >= minimum_remaining_seconds,
            "reset shares cooldown",
        )
        self.check(self.set_preferred_name(2, "'^1Color'") == "-2", "database rejects color codes")
        self.check(
            self.set_preferred_name(2, "'FixtureToken'") == "-5",
            "database rechecks private moderation",
        )
        self.check(
            self.set_preferred_name(2, "'1234567890123456'") == "-2",
            "database enforces visible name length",
        )
        self.check(
            self.query_database(
                "SELECT normalizeModeratedName('^1F1x.tuure Token');", self.database
            )
            == "fixturetoken",
            "normalization semantics",
        )
        self.check(
            self.query_database(
                "SELECT blockedNameRule('xF1x.tuureTokenx')>0,blockedNameRule('OkFixtureToken');",
                self.database,
            )
            == "1\t0",
            "obfuscation and exception",
        )

    def verify_cooldown_and_moderation(self):
        self.query_database(
            f"""
            UPDATE playerNamePreferences
            SET changedAt=UTC_TIMESTAMP(6)-INTERVAL {PREFERRED_COOLDOWN_SECONDS} SECOND
            WHERE playerID=1;
            """,
            self.database,
        )
        self.check(
            self.set_preferred_name(1, "'NextName'") == "0", "one-hour boundary allows change"
        )
        self.check(
            self.set_preferred_name(2, "'RecordName'") == "0",
            "released preferred name becomes available",
        )
        self.check(
            self.query_database("SELECT resetPreferredNameByModerator(1,2);", self.database)
            == "-6",
            "ordinary account cannot moderate",
        )
        self.check(
            self.query_database("SELECT resetPreferredNameByModerator(3,2);", self.database) == "0",
            "moderator reset succeeds",
        )
        minimum_remaining_seconds = PREFERRED_COOLDOWN_SECONDS - QUERY_TIMING_ALLOWANCE_SECONDS
        self.check(
            int(self.set_preferred_name(2, "'Immediate'")) >= minimum_remaining_seconds,
            "moderator reset starts cooldown",
        )

    def verify_concurrent_claims(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.claim_race_name, (4, 5)))
        self.check(sorted(results) == ["-3", "0"], "concurrent claim has exactly one winner")
        self.check(
            self.query_database(
                "SELECT COUNT(*) FROM playerNamePreferences WHERE preferredName='RaceHandle';",
                self.database,
            )
            == "1",
            "unique name survives concurrent requests",
        )

    def verify_sql(self):
        self.seed_players_and_rules()
        self.verify_claims_and_policy()
        self.verify_cooldown_and_moderation()
        self.verify_concurrent_claims()

    def prepare_engine(self):
        self.query_database("DELETE FROM playerNamePreferences;", self.database)
        source_hashes, _ = gsc_fixture.prepare_fixture(
            self.options, self.home, retained_callbacks=()
        )
        settings = {
            "db_host": "db",
            "db_user": self.account,
            "db_pass": self.password,
            "db_base": self.database[:-1],
            "db_port": "3306",
        }
        descriptor = os.open(self.config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            for key, value in settings.items():
                stream.write(f'set {key} "{value}"\n')
        return source_hashes

    def execute(self):
        self.home.mkdir(mode=0o700)
        try:
            self.prepare_database()
            self.verify_sql()
            if self.report["failures"]:
                raise RuntimeError("Player-name SQL scenarios failed")
            source_hashes = self.prepare_engine()
            engine = gsc_fixture.run_prepared_fixture(
                self.options,
                self.home,
                "mp_killhouse",
                source_hashes,
                extra_settings={"sv_maxclients": "2"},
                config_files=(self.config.name,),
            )
            self.report["engine"] = engine
            (self.home / "result.json").write_text(json.dumps(self.report, indent=2) + "\n")
        finally:
            try:
                if self.owns_database_resources:
                    self.query_database(
                        f"DROP DATABASE IF EXISTS {self.database};"
                        f" DROP USER IF EXISTS '{self.account}'@'%';"
                    )
            finally:
                self.config.unlink(missing_ok=True)
            print("Evidence: " + str(self.home), flush=True)


def main():
    options = gsc_fixture.parse_options(
        default_fixture=ROOT / "dev-tools/tests/player-names.gsc",
        completion_marker="NAME SELFTEST COMPLETE",
    )
    if options.maps != ["mp_killhouse"]:
        raise ValueError("Player-name scenarios require their mp_killhouse fixture")
    PlayerNameVerification(options).execute()


if __name__ == "__main__":
    main()
