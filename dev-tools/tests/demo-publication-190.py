"""Exercise real publication transactions in a caller-owned disposable schema."""

from concurrent.futures import ThreadPoolExecutor
from textwrap import dedent
import time
import uuid

FIRST_MAP_ID = 7101
LAST_MAP_ID = 7112
FIRST_RUN_ID = 80000
LOCK_WAIT_TIMEOUT_SECONDS = 5


class PublicationFixture:
    """Own synthetic candidates, assertion counts, and unique lock names for one run."""

    def __init__(self, sql):
        self.sql = sql
        self.checks = 0
        self.next_run_id = FIRST_RUN_ID
        self.lock_prefix = "publication_" + uuid.uuid4().hex[:12] + "_"

    def expect(self, passed, description):
        assert passed, description
        self.checks += 1

    def create_candidate(
        self, map_id, elapsed_ms=1000, rpg_jumps=2, mode_mask=0, fps_mode="mix"
    ):
        self.next_run_id += 1
        run_id = self.next_run_id
        # Sixty-five frames require two chunks, including the final partial chunk.
        self.sql(f"""
            INSERT INTO playerRuns(runID,playerID,mapID,FPSMode)
                VALUES({run_id},1,{map_id},'{fps_mode}');
            INSERT INTO demoRuns(
                runID,mapID,routeID,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount)
                VALUES({run_id},{map_id},{map_id},'{fps_mode}',{mode_mask},{elapsed_ms},{rpg_jumps},65);
            INSERT INTO demoChunks(runID,chunkNum,payload)
                VALUES({run_id},0,X'01'),({run_id},1,X'01');
        """)
        return run_id

    def publish(self, run_id):
        return self.sql(f"CALL publishDemo({run_id});")

    def winner(self, map_id, kind):
        return int(self.sql(f"""
            SELECT runID FROM demoWinners
            WHERE mapID={map_id} AND kind='{kind}'
            LIMIT 1;
        """))

    def receipt_count(self, run_id):
        return int(
            self.sql(f"SELECT COUNT(*) FROM demoPublications WHERE runID={run_id};")
        )

    def lock_name(self, scenario):
        return self.lock_prefix + scenario

    def wait_for_lock(self, scenario):
        """Return only this fixture's connection ID, suitable for intentional disconnect tests."""
        name = self.lock_name(scenario)
        deadline = time.monotonic() + LOCK_WAIT_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            owner = self.sql(f"SELECT IS_USED_LOCK('{name}');")
            if owner and owner != "NULL":
                return int(owner)
            time.sleep(0.01)
        raise AssertionError("SQL synchronization marker was not reached: " + scenario)

    def seed_maps(self):
        self.expect(
            self.sql(
                f"SELECT COUNT(*) FROM mapids WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};"
            )
            == "0",
            "fixture map IDs are unused",
        )
        for map_id in range(FIRST_MAP_ID, LAST_MAP_ID + 1):
            self.sql(f"""
                INSERT INTO mapids(mapID,mapname) VALUES({map_id},'publication_test_{map_id}');
                INSERT INTO checkpoints(cpID,mapID) VALUES({map_id},{map_id});
                INSERT INTO routes(routeID,mapID,cpID,routeName)
                    VALUES({map_id},{map_id},{map_id},'test');
                UPDATE checkpoints SET finishRouteID={map_id} WHERE cpID={map_id};
            """)

    def clean_records(self):
        # Route and checkpoint history uses restrictive links; detach the finish edge first.
        self.sql(f"""
            DELETE FROM demoWinners WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};
            DELETE FROM demoRuns WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};
            DELETE FROM playerRuns WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};
            UPDATE checkpoints SET finishRouteID=NULL
                WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};
            DELETE FROM routes WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};
            DELETE FROM checkpoints WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};
            DELETE FROM mapids WHERE mapID BETWEEN {FIRST_MAP_ID} AND {LAST_MAP_ID};
        """)
        self.expect(
            self.sql(
                f"SELECT COUNT(*) FROM demoPublications WHERE runID>{FIRST_RUN_ID};"
            )
            == "0",
            "fixture receipts cascade with deleted runs",
        )


def succeeds(result):
    return result.startswith("1\t")


def fails(action):
    try:
        action()
    except RuntimeError:
        return True
    return False


def verify_winner_rules(fixture, connections):
    """Equal-time rules differ by category; competing publications must retain every receipt."""
    first = fixture.create_candidate(7101, elapsed_ms=1000, rpg_jumps=4)
    fixture.expect(succeeds(fixture.publish(first)), "initial publication")
    second = fixture.create_candidate(7101, elapsed_ms=1000, rpg_jumps=3)
    fixture.expect(
        succeeds(fixture.publish(second)), "equal time lower RPG publication"
    )
    fixture.expect(
        fixture.winner(7101, "speedrun") == second, "speedrun breaks ties by RPG count"
    )
    fixture.expect(
        fixture.winner(7101, "lowrpg") == second, "lowrpg selects fewer RPGs"
    )
    fixture.expect(
        fixture.winner(7101, "walkthrough") == first,
        "walkthrough keeps equal-time incumbent",
    )
    fixture.expect(
        fixture.publish(second) == "1\talready_published",
        "committed retry is idempotent",
    )

    runs = []
    for index in range(32):
        runs.append(
            fixture.create_candidate(7102, elapsed_ms=2000 + index, rpg_jumps=index % 5)
        )
    results = list(connections.map(fixture.publish, reversed(runs)))
    fixture.expect(
        all(succeeds(result) for result in results), "32 competing publications"
    )
    # The first candidate has the lowest time and zero RPG jumps, regardless of arrival order.
    for kind in ("speedrun", "lowrpg", "walkthrough"):
        fixture.expect(
            fixture.winner(7102, kind) == runs[0], "concurrent " + kind + " winner"
        )
    fixture.expect(
        fixture.sql("""
        SELECT COUNT(*) FROM demoPublications p
        JOIN playerRuns r USING(runID)
        WHERE r.mapID=7102;
    """) == "32",
        "all contenders retain receipts",
    )

    loser = runs[-1]
    fixture.expect(
        fixture.sql(f"SELECT COUNT(*) FROM demoRuns WHERE runID={loser};") == "0",
        "losing payload is reclaimed",
    )
    results = list(connections.map(fixture.publish, [loser] * 8))
    fixture.expect(
        all(succeeds(result) for result in results),
        "duplicate loser calls succeed after payload cleanup",
    )
    fixture.expect(
        fixture.receipt_count(loser) == 1, "repeated loser has exactly one receipt"
    )


def verify_incomplete_payloads(fixture):
    """Bad chunk sets and ineligible modes must never become walkthrough winners."""
    mutations = [
        ("DELETE FROM demoChunks WHERE runID={run_id} AND chunkNum=1", "missing chunk"),
        (
            "UPDATE demoChunks SET chunkNum=2 WHERE runID={run_id} AND chunkNum=1",
            "chunk gap",
        ),
        (
            "UPDATE demoChunks SET payload=X'' WHERE runID={run_id} AND chunkNum=1",
            "empty chunk",
        ),
    ]
    for mutation, description in mutations:
        run_id = fixture.create_candidate(7103)
        fixture.sql(mutation.format(run_id=run_id) + ";")
        fixture.expect(
            fixture.publish(run_id) == "0\tincomplete", description + " rejected"
        )
        fixture.expect(
            fixture.receipt_count(run_id) == 0, description + " has no success receipt"
        )
    fixture.expect(
        fixture.sql("SELECT COUNT(*) FROM demoWinners WHERE mapID=7103;") == "0",
        "invalid candidates never replace winners",
    )
    fixture.expect(fixture.publish(999999) == "0\tmissing", "missing run rejected")
    for fps_mode, mode_mask in [("hax", 0), ("mix", 1)]:
        run_id = fixture.create_candidate(7112, fps_mode=fps_mode, mode_mask=mode_mask)
        fixture.expect(
            succeeds(fixture.publish(run_id)), "restricted candidate published"
        )
        fixture.expect(
            fixture.sql(f"""
            SELECT COUNT(*) FROM demoWinners
            WHERE runID={run_id} AND kind='walkthrough';
        """) == "0",
            "walkthrough eligibility retained",
        )


def verify_route_changes(fixture, connections):
    """Map locking orders route edits and retirement before publication reads mutable state."""
    renamed = fixture.create_candidate(7104)
    rename_lock = fixture.lock_name("rename")
    held_lock = connections.submit(
        fixture.sql,
        f"""
        START TRANSACTION;
        SELECT mapID FROM mapids WHERE mapID=7104 FOR UPDATE;
        DO GET_LOCK('{rename_lock}',0);
        DO SLEEP(.4);
        UPDATE routes SET routeName='renamed' WHERE routeID=7104;
        COMMIT;
    """,
    )
    fixture.wait_for_lock("rename")
    pending = connections.submit(fixture.publish, renamed)
    time.sleep(0.05)
    fixture.expect(not pending.done(), "publication waits for route edit lock")
    held_lock.result()
    fixture.expect(succeeds(pending.result()), "publication after route rename")
    fixture.expect(
        fixture.sql(f"""
        SELECT DISTINCT r.routeName FROM demoWinners w
        JOIN routes r ON r.routeID=w.routeID
        WHERE w.runID={renamed};
    """) == "renamed",
        "winner retains stable route identity after rename",
    )

    retired = fixture.create_candidate(7105)
    retire_lock = fixture.lock_name("retire")
    held_lock = connections.submit(
        fixture.sql,
        f"""
        START TRANSACTION;
        SELECT mapID FROM mapids WHERE mapID=7105 FOR UPDATE;
        DO GET_LOCK('{retire_lock}',0);
        DO SLEEP(.3);
        UPDATE demoRuns SET ready=2 WHERE runID={retired};
        COMMIT;
    """,
    )
    fixture.wait_for_lock("retire")
    pending = connections.submit(fixture.publish, retired)
    held_lock.result()
    fixture.expect(
        pending.result() == "0\tretired", "retirement wins before publication"
    )
    fixture.expect(
        fixture.receipt_count(retired) == 0, "retired candidate has no publication"
    )


def verify_transaction_rollback(fixture):
    incumbent = fixture.create_candidate(7106, elapsed_ms=2000)
    fixture.publish(incumbent)
    broken = fixture.create_candidate(7106, elapsed_ms=1000)
    fixture.sql(dedent(f"""
        DELIMITER //
        CREATE TRIGGER publication_fail BEFORE UPDATE ON demoRuns FOR EACH ROW
        BEGIN
            IF NEW.runID={broken} AND NEW.ready=1 THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='fixture failure';
            END IF;
        END//
        DELIMITER ;
    """))
    fixture.expect(
        fails(lambda: fixture.publish(broken)), "mid-transaction failure reported"
    )
    fixture.expect(
        fixture.winner(7106, "speedrun") == incumbent
        and fixture.receipt_count(broken) == 0,
        "winner and receipt roll back together",
    )
    fixture.expect(
        fixture.sql(f"SELECT ready FROM demoRuns WHERE runID={broken};") == "0",
        "candidate readiness rolls back",
    )
    fixture.sql("DROP TRIGGER publication_fail;")
    fixture.expect(
        succeeds(fixture.publish(broken)),
        "known rolled-back publication safely retries",
    )


def verify_lost_connections(fixture, connections):
    """Disconnect the fixture's own connection on each side of the commit boundary."""
    incumbent = fixture.create_candidate(7107, elapsed_ms=2000)
    fixture.publish(incumbent)
    dropped = fixture.create_candidate(7107, elapsed_ms=1000)
    before_commit = fixture.lock_name("before_commit")
    fixture.sql(dedent(f"""
        DELIMITER //
        CREATE TRIGGER publication_pause BEFORE UPDATE ON demoRuns FOR EACH ROW
        BEGIN
            IF NEW.runID={dropped} AND NEW.ready=1 THEN
                DO GET_LOCK('{before_commit}',0);
                DO SLEEP(5);
            END IF;
        END//
        DELIMITER ;
    """))
    pending = connections.submit(fixture.publish, dropped)
    connection_id = fixture.wait_for_lock("before_commit")
    fixture.expect(
        fixture.winner(7107, "speedrun") == incumbent, "uncommitted winner is invisible"
    )
    fixture.sql(f"KILL CONNECTION {connection_id};")
    fixture.expect(fails(pending.result), "connection loss before commit reported")
    fixture.sql("DROP TRIGGER publication_pause;")
    fixture.expect(
        fixture.winner(7107, "speedrun") == incumbent
        and fixture.receipt_count(dropped) == 0,
        "connection loss rolls back winner and receipt",
    )
    fixture.expect(
        succeeds(fixture.publish(dropped)), "retry after pre-commit disconnect"
    )

    acknowledged = fixture.create_candidate(7108)
    after_commit = fixture.lock_name("after_commit")
    pending = connections.submit(
        fixture.sql,
        f"""
        CALL publishDemo({acknowledged});
        DO GET_LOCK('{after_commit}',0);
        DO SLEEP(5);
    """,
    )
    connection_id = fixture.wait_for_lock("after_commit")
    fixture.sql(f"KILL CONNECTION {connection_id};")
    fixture.expect(fails(pending.result), "connection loss after commit simulated")
    fixture.expect(
        fixture.receipt_count(acknowledged) == 1,
        "receipt resolves lost acknowledgement",
    )
    fixture.expect(
        fixture.publish(acknowledged) == "1\talready_published",
        "retry after committed disconnect is idempotent",
    )


def verify_lock_boundaries(fixture, connections):
    """A same-map timeout leaves no partial publication; a different map remains independent."""
    timed_out = fixture.create_candidate(7109)
    timeout_lock = fixture.lock_name("timeout")
    held_lock = connections.submit(
        fixture.sql,
        f"""
        START TRANSACTION;
        SELECT mapID FROM mapids WHERE mapID=7109 FOR UPDATE;
        DO GET_LOCK('{timeout_lock}',0);
        DO SLEEP(2);
        COMMIT;
    """,
    )
    fixture.wait_for_lock("timeout")
    fixture.expect(
        fails(
            lambda: fixture.sql(
                f"SET innodb_lock_wait_timeout=1; CALL publishDemo({timed_out});"
            )
        ),
        "lock timeout reported",
    )
    fixture.expect(
        fixture.receipt_count(timed_out) == 0, "lock timeout has no partial commit"
    )
    held_lock.result()
    fixture.expect(succeeds(fixture.publish(timed_out)), "retry after lock timeout")

    independent = fixture.create_candidate(7111)
    other_map_lock = fixture.lock_name("other_map")
    held_lock = connections.submit(
        fixture.sql,
        f"""
        START TRANSACTION;
        SELECT mapID FROM mapids WHERE mapID=7110 FOR UPDATE;
        DO GET_LOCK('{other_map_lock}',0);
        DO SLEEP(1);
        COMMIT;
    """,
    )
    fixture.wait_for_lock("other_map")
    fixture.expect(
        succeeds(fixture.publish(independent)), "different map publishes concurrently"
    )
    fixture.expect(
        fixture.sql(f"SELECT IS_USED_LOCK('{other_map_lock}');") != "NULL",
        "other-map publication did not wait for the held map lock",
    )
    held_lock.result()


def verify(sql):
    """Run only against a disposable schema seeded with fixture player 1."""
    fixture = PublicationFixture(sql)
    fixture.seed_maps()
    with ThreadPoolExecutor(max_workers=12) as connections:
        verify_winner_rules(fixture, connections)
        verify_incomplete_payloads(fixture)
        verify_route_changes(fixture, connections)
        verify_transaction_rollback(fixture)
        verify_lost_connections(fixture, connections)
        verify_lock_boundaries(fixture, connections)
    fixture.clean_records()
    return {
        "checks": fixture.checks,
        "passed": True,
        "competingConnections": 32,
        "duplicates": 8,
        "coverage": [
            "winner rules",
            "duplicate loser after cleanup",
            "invalid payloads",
            "route rename",
            "route retirement",
            "transaction rollback",
            "disconnect before commit",
            "lost acknowledgement after commit",
            "lock timeout",
            "independent maps",
            "receipt cleanup",
        ],
    }
