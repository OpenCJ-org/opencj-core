#!/usr/bin/env python3
"""Exercise the permission and ban functions in a disposable, network-isolated MySQL.

Bootstraps an empty schema with every migration, seeds synthetic accounts, then calls
setPlayerPermissions, banPlayer, liftPlayerBan and resetPreferredNameByModerator
through the gameplay account, as the game does. Proves the database enforces the
rules in docs/reference/permissions.md even if the game's own checks are bypassed.
Does not run the engine or the GSC commands.
"""

from pathlib import Path
import os
import secrets
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "server-db/tools"))
from mysql_session import MySQL

READY_TIMEOUT_SECONDS = 90

# Permission bits from docs/reference/permissions.md.
UBER = 1 << 0
PERMS = 1 << 1
MUTE = 1 << 3
NAMES = 1 << 4
KICK = 1 << 7
TEMPBAN = 1 << 8
CPEDIT = 1 << 2
MOD_GROUP = MUTE | NAMES | KICK | TEMPBAN  # The "mod" group in permissions.gsc.

UBER_ADMIN = 1
MODERATOR = 2
PLAIN_PLAYER = 3
BANNED_PLAYER = 4
OTHER_UBER_ADMIN = 5
MISSING_PLAYER = 999
ONE_HOUR_SECONDS = 60 * 60
SEVEN_DAYS_SECONDS = 7 * 24 * 60 * 60


class Checks:
    def __init__(self):
        self.count = 0
        self.failures = 0

    def expect(self, actual, expected, scenario):
        self.count += 1
        passed = actual == expected
        if not passed:
            self.failures += 1
        print(f"PERMISSIONS SQL {int(passed)}: {scenario} (expected {expected!r}, got {actual!r})",
              flush=True)


def start_database(name, credentials):
    subprocess.run(
        ["docker", "run", "-d", "--name", name, "--network", "none", "--memory", "768m",
         "--env-file", str(credentials), "mysql:8.0", "--log-bin-trust-function-creators=1"],
        check=True, capture_output=True,
    )
    ping = ["docker", "exec", name, "sh", "-c",
            'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=TCP -h127.0.0.1 -u root -e "SELECT 1"']
    deadline = time.monotonic() + READY_TIMEOUT_SECONDS
    while subprocess.run(ping, capture_output=True).returncode != 0:
        if time.monotonic() > deadline:
            raise RuntimeError("Disposable database did not become ready")
        time.sleep(1)


def seed_accounts(admin):
    admin.query(f"""
        INSERT INTO playerInformation (playerID, playerName, permissions, lastIP, lastClientID)
        VALUES
            ({UBER_ADMIN}, 'UberAdmin', {UBER}, NULL, NULL),
            ({MODERATOR}, 'Moderator', {PERMS | MOD_GROUP}, NULL, NULL),
            ({PLAIN_PLAYER}, 'PlainPlayer', 0, NULL, NULL),
            ({BANNED_PLAYER}, 'BannedPlayer', 0, '203.0.113.7', '1234567890'),
            ({OTHER_UBER_ADMIN}, 'OtherUber', {UBER}, NULL, NULL);
        INSERT IGNORE INTO preferredNameWriteLock (singleton) VALUES (1);
    """)


def verify_permission_changes(game, checks):
    def change(actor, target, mask, grant):
        return int(game.query(f"SELECT setPlayerPermissions({actor}, {target}, {mask}, {grant});"))

    def logged_changes():
        return int(game.query("SELECT COUNT(*) FROM permissionChanges;"))

    checks.expect(change(MODERATOR, PLAIN_PLAYER, MUTE, 1), MUTE,
                  "perms holder grants a permission they hold")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, MUTE, 1), -8, "repeated grant is refused")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, CPEDIT, 1), -4,
                  "a permission the actor lacks cannot be granted")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, MUTE | CPEDIT, 1), -4,
                  "a set with one missing permission is refused as a whole")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, PERMS, 1), -5, "only uber grants perms")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, UBER, 1), -2, "uber is never grantable")
    checks.expect(change(UBER_ADMIN, PLAIN_PLAYER, UBER | MUTE, 1), -2,
                  "even an uber-admin cannot grant uber in game, not even inside a set")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, 1 << 31, 1), -1, "bit 31 is rejected")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, 0, 1), -1, "an empty set is rejected")
    checks.expect(change(PLAIN_PLAYER, MODERATOR, MUTE, 0), -3,
                  "an actor without perms changes nothing")
    checks.expect(change(MODERATOR, OTHER_UBER_ADMIN, MUTE, 0), -7,
                  "an uber-admin's permissions cannot be changed by others")
    checks.expect(change(MODERATOR, MISSING_PLAYER, MUTE, 1), -6, "missing target reported")
    checks.expect(logged_changes(), 1, "only the successful change is recorded")

    checks.expect(change(MODERATOR, PLAIN_PLAYER, MOD_GROUP, 1), MOD_GROUP,
                  "a moderator grants the whole mod group")
    checks.expect(logged_changes(), 4, "a group grant records only the bits that changed")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, MOD_GROUP, 1), -8,
                  "granting a fully held group changes nothing")
    checks.expect(change(UBER_ADMIN, PLAIN_PLAYER, PERMS | CPEDIT, 1), MOD_GROUP | PERMS | CPEDIT,
                  "uber-admin grants perms with another permission")
    checks.expect(change(MODERATOR, PLAIN_PLAYER, MOD_GROUP, 0), PERMS | CPEDIT,
                  "revoking the group clears every member")
    checks.expect(logged_changes(), 10, "each revoked member is recorded")


def verify_bans(game, checks):
    def ban(actor, target, seconds, reason_sql):
        return int(game.query(f"SELECT banPlayer({actor}, {target}, {seconds}, {reason_sql});"))

    def lift(actor, target, permanent):
        return int(game.query(f"SELECT liftPlayerBan({actor}, {target}, {permanent});"))

    temporary_ban = ban(MODERATOR, BANNED_PLAYER, ONE_HOUR_SECONDS, "'Spamming'")
    checks.expect(temporary_ban > 0, True, "tempban holder bans for an hour")
    checks.expect(
        game.query(f"SELECT CONCAT(bannedIP, ' ', bannedClientID) FROM playerBans"
                   f" WHERE banID = {temporary_ban};"),
        "203.0.113.7 1234567890", "ban covers the account's last IP and player ID")
    checks.expect(ban(MODERATOR, BANNED_PLAYER, SEVEN_DAYS_SECONDS + 1, "'x'"), -2,
                  "temporary bans longer than 7 days are refused")
    checks.expect(ban(MODERATOR, BANNED_PLAYER, 30, "'x'"), -2, "bans shorter than a minute refused")
    checks.expect(ban(MODERATOR, BANNED_PLAYER, ONE_HOUR_SECONDS, "'   '"), -3,
                  "a blank reason is refused")
    checks.expect(ban(MODERATOR, BANNED_PLAYER, ONE_HOUR_SECONDS, "NULL"), -3,
                  "a missing reason is refused")
    checks.expect(ban(MODERATOR, OTHER_UBER_ADMIN, ONE_HOUR_SECONDS, "'x'"), -5,
                  "uber-admins cannot be banned by others")
    checks.expect(ban(MODERATOR, MODERATOR, ONE_HOUR_SECONDS, "'x'"), -6, "nobody bans themselves")
    checks.expect(ban(MODERATOR, BANNED_PLAYER, "NULL", "'x'"), -1,
                  "permanent bans need uber")
    checks.expect(ban(PLAIN_PLAYER, BANNED_PLAYER, ONE_HOUR_SECONDS, "'x'"), -1,
                  "temporary bans need tempban")

    permanent_ban = ban(UBER_ADMIN, BANNED_PLAYER, "NULL", "'Cheating'")
    checks.expect(permanent_ban > temporary_ban, True, "uber-admin bans permanently")
    checks.expect(
        game.query(f"SELECT liftedByPlayerID FROM playerBans WHERE banID = {temporary_ban};"),
        str(UBER_ADMIN), "the new ban replaces the active temporary ban")
    checks.expect(ban(MODERATOR, BANNED_PLAYER, ONE_HOUR_SECONDS, "'x'"), -7,
                  "a temporary ban cannot replace a permanent ban")

    checks.expect(lift(MODERATOR, BANNED_PLAYER, 1), -1, "only uber lifts permanent bans")
    checks.expect(lift(MODERATOR, BANNED_PLAYER, 0), -8, "untempban ignores permanent bans")
    checks.expect(lift(UBER_ADMIN, BANNED_PLAYER, 1), 1, "uber-admin lifts the permanent ban")
    checks.expect(lift(UBER_ADMIN, BANNED_PLAYER, 1), -8, "nothing left to lift")
    checks.expect(lift(MODERATOR, MISSING_PLAYER, 0), -4, "missing target reported")


def verify_name_reset(game, checks):
    def reset(actor, target):
        return int(game.query(f"SELECT resetPreferredNameByModerator({actor}, {target});"))

    checks.expect(reset(MODERATOR, PLAIN_PLAYER), 0, "names holder resets a preferred name")
    checks.expect(reset(MODERATOR, OTHER_UBER_ADMIN), -6, "uber-admin names are protected")
    checks.expect(reset(PLAIN_PLAYER, MODERATOR), -6, "resetting needs the names permission")


def verify_direct_writes_denied(game, checks):
    try:
        game.query(f"INSERT INTO playerBans (bannedPlayerID, reason, bannedByPlayerID)"
                   f" VALUES ({PLAIN_PLAYER}, 'direct', {PLAIN_PLAYER});")
    except RuntimeError as error:
        checks.expect("denied" in str(error).lower(), True,
                      "gameplay cannot write bans except through banPlayer")
    else:
        checks.expect(False, True, "gameplay cannot write bans except through banPlayer")


def main():
    os.umask(0o077)
    name = "opencj-permissions-sql-" + uuid.uuid4().hex[:8]
    evidence = ROOT / "dev-tools/local" / name
    evidence.mkdir(parents=True)
    credentials = evidence / "mysql.env"
    credentials.write_text(
        "MYSQL_ROOT_PASSWORD=" + secrets.token_hex(24) + "\n"
        "MYSQL_DATABASE=openCJ_cod4\nMYSQL_USER=opencj\n"
        "MYSQL_PASSWORD=" + secrets.token_hex(24) + "\n"
    )
    checks = Checks()
    started = False
    try:
        start_database(name, credentials)
        started = True
        bootstrap = subprocess.run(
            [sys.executable, str(ROOT / "dev-tools/scripts/bootstrap-db.py"),
             "--container", name, "--confirm-empty"],
            capture_output=True, text=True,
        )
        (evidence / "bootstrap.log").write_text(bootstrap.stdout + bootstrap.stderr)
        if bootstrap.returncode:
            raise RuntimeError("Bootstrap failed; inspect " + str(evidence / "bootstrap.log"))
        with MySQL(name, "openCJ_cod4") as admin:
            seed_accounts(admin)
        with MySQL(name, "openCJ_cod4", runtime=True) as game:
            verify_permission_changes(game, checks)
            verify_bans(game, checks)
            verify_name_reset(game, checks)
        with MySQL(name, "openCJ_cod4", runtime=True) as game:
            verify_direct_writes_denied(game, checks)
    finally:
        if started:
            subprocess.run(["docker", "rm", "-f", "-v", name], check=True, capture_output=True)
        credentials.unlink(missing_ok=True)
    print(f"PERMISSIONS SQL COMPLETE: {checks.count} checks, {checks.failures} failures",
          flush=True)
    return 1 if checks.failures else 0


if __name__ == "__main__":
    sys.exit(main())
