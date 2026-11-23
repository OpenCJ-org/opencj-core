"""Verify preferred names and regular-name policy with private disposable resources."""

from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re

from isolated_database import IsolatedDatabase
import gsc_fixture

ROOT = Path(__file__).resolve().parents[2]
PREFERRED_COOLDOWN_SECONDS = 60 * 60
# Separate CLI queries may cross several clock ticks during the cooldown checks.
QUERY_TIMING_ALLOWANCE_SECONDS = 10


class PlayerNameVerification(IsolatedDatabase):
    """Own the synthetic schema, account, configuration and isolated engine fixture."""

    def __init__(self, options):
        self.options = options
        super().__init__("player-names")
        self.report = {"productionWrites": False, "checks": 0, "failures": 0}

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

    def install_record_observers(self):
        """Hold actual SQL replies only in this fixture copy to exercise stale callbacks."""
        scripts = self.home / "mods/opencj/opencj"
        records = scripts / "showrecords.gsc"
        source, count = re.subn(
            r"(?m)^recordQuery\s*\(", "_fixtureOriginalRecordQuery(", records.read_text()
        )
        if count != 1:
            raise RuntimeError("Expected one record-query builder in the fixture")
        source += r"""
recordQuery(checkpoints)
{
    return "/* name-record-fixture */ " + self _fixtureOriginalRecordQuery(checkpoints);
}
"""
        records.write_text(source)
        mysql = scripts / "mysql.gsc"
        source, count = re.subn(
            r"(?m)^_request\s*\(", "_fixtureOriginalRequest(", mysql.read_text()
        )
        if count != 1:
            raise RuntimeError("Expected one SQL request entry point in the fixture")
        source += r"""
_request(query, policy, key, scope, queueWaitMs, retainRows)
{
    result = self _fixtureOriginalRequest(query, policy, key, scope, queueWaitMs, retainRows);
    if(isSubStr(query, "/* name-record-fixture */"))
    {
        self.nameTestRecordReplyReady = true;
        self.nameTestRecordOutcome = result.status;
        if(isDefined(level.nameTestHoldRecordReplies) && level.nameTestHoldRecordReplies)
        {
            deadlineMs = getTime() + 5000;
            while(!level.nameTestReleaseRecordReply && getTime() < deadlineMs)
            {
                wait .05;
            }
        }
    }
    return result;
}
"""
        mysql.write_text(source)

    def prepare_engine(self):
        self.query_database("DELETE FROM playerNamePreferences;", self.database)
        source_hashes, _ = gsc_fixture.prepare_fixture(
            self.options, self.home, retained_callbacks=()
        )
        self.install_record_observers()
        self.write_engine_config()
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
            self.cleanup()
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
