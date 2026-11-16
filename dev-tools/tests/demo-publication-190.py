"""SQL publication concurrency/failure checks; callable only in disposable fixture."""

from concurrent.futures import ThreadPoolExecutor
import time


def verify(sql):
    checks = 0
    serial = 80000

    def check(value, message):
        nonlocal checks
        assert value, message
        checks += 1

    def candidate(mapid, elapsed=1000, rpgs=2, mask=0, fps="mix", frames=65):
        nonlocal serial
        serial += 1
        run = serial
        sql(
            f"INSERT INTO playerRuns(runID,playerID,mapID,FPSMode) VALUES({run},1,{mapid},'{fps}');"
            f"INSERT INTO demoRuns(runID,mapID,routeName,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount) "
            f"VALUES({run},{mapid},'test','{fps}',{mask},{elapsed},{rpgs},{frames});"
            f"INSERT INTO demoChunks VALUES({run},0,X'01'),({run},1,X'01');"
        )
        return run

    def call(run):
        return sql(f"CALL publishDemo({run});")

    def winner(mapid, kind):
        return int(
            sql(f"SELECT runID FROM demoWinners WHERE mapID={mapid} AND kind='{kind}' LIMIT 1;")
        )

    def succeeds(result):
        return result.startswith("1\t")

    def fails(action):
        try:
            action()
        except RuntimeError:
            return True
        return False

    def marker(name):
        for _ in range(100):
            owner = sql(f"SELECT IS_USED_LOCK('{name}');")
            if owner and owner != "NULL":
                return int(owner)
            time.sleep(0.01)
        raise AssertionError("SQL synchronization marker not reached")

    def receipt(run):
        return int(sql(f"SELECT COUNT(*) FROM demoPublications WHERE runID={run};"))

    check(
        sql("SELECT COUNT(*) FROM mapids WHERE mapID BETWEEN 7101 AND 7112;") == "0",
        "fixture map IDs unused",
    )
    sql(
        "INSERT INTO mapids(mapID,mapname) VALUES"
        + ",".join(f"({i},'publication_test_{i}')" for i in range(7101, 7113))
        + ";"
    )
    with ThreadPoolExecutor(max_workers=12) as pool:
        first = candidate(7101, 1000, 4)
        check(succeeds(call(first)), "initial publication")
        second = candidate(7101, 1000, 3)
        check(succeeds(call(second)), "equal time lower RPG publication")
        check(winner(7101, "speedrun") == second, "speedrun breaks ties by RPG count")
        check(winner(7101, "lowrpg") == second, "lowrpg selects fewer RPGs")
        check(winner(7101, "walkthrough") == first, "walkthrough keeps equal-time incumbent")
        check(call(second) == "1\talready_published", "duplicate committed call is idempotent")

        runs = [(candidate(7102, 2000 + i, i % 5), 2000 + i, i % 5) for i in range(32)]
        results = list(pool.map(lambda r: call(r[0]), reversed(runs)))
        check(all(succeeds(x) for x in results), "32 competing independent connections")
        check(
            winner(7102, "speedrun") == min(runs, key=lambda r: (r[1], r[2]))[0],
            "concurrent speedrun winner",
        )
        check(
            winner(7102, "lowrpg") == min(runs, key=lambda r: (r[2], r[1]))[0],
            "concurrent lowrpg winner",
        )
        check(
            winner(7102, "walkthrough") == min(runs, key=lambda r: r[1])[0],
            "concurrent walkthrough winner",
        )
        check(
            sql(
                "SELECT COUNT(*) FROM demoPublications p JOIN playerRuns r USING(runID) WHERE r.mapID=7102;"
            )
            == "32",
            "all contenders retain receipts",
        )
        loser = runs[-1][0]
        check(
            sql(f"SELECT COUNT(*) FROM demoRuns WHERE runID={loser};") == "0",
            "losing payload reclaimed",
        )
        check(
            all(succeeds(x) for x in pool.map(lambda _: call(loser), range(8))),
            "duplicate loser calls after payload cleanup",
        )
        check(receipt(loser) == 1, "exactly one receipt for repeated loser")

        for mutation, label in [
            ("DELETE FROM demoChunks WHERE runID={run} AND chunkNum=1", "missing chunk"),
            ("UPDATE demoChunks SET chunkNum=2 WHERE runID={run} AND chunkNum=1", "chunk gap"),
            ("UPDATE demoChunks SET payload=X'' WHERE runID={run} AND chunkNum=1", "empty chunk"),
        ]:
            run = candidate(7103)
            sql(mutation.format(run=run) + ";")
            check(call(run) == "0\tincomplete", label + " rejected")
            check(receipt(run) == 0, label + " has no success receipt")
        check(
            sql("SELECT COUNT(*) FROM demoWinners WHERE mapID=7103;") == "0",
            "invalid candidates never replace winners",
        )
        check(call(999999) == "0\tmissing", "missing run rejected")
        for fps, mask in [("hax", 0), ("mix", 1)]:
            run = candidate(7112, fps=fps, mask=mask)
            check(succeeds(call(run)), "restricted candidate published")
            check(
                sql(f"SELECT COUNT(*) FROM demoWinners WHERE runID={run} AND kind='walkthrough';")
                == "0",
                "walkthrough eligibility retained",
            )

        renamed = candidate(7104)
        hold = pool.submit(
            sql,
            f"START TRANSACTION; SELECT mapID FROM mapids WHERE mapID=7104 FOR UPDATE;"
            f"DO GET_LOCK('pub_rename',0); DO SLEEP(.4); UPDATE demoRuns SET routeName='renamed' WHERE runID={renamed}; COMMIT;",
        )
        marker("pub_rename")
        pending = pool.submit(call, renamed)
        time.sleep(0.05)
        check(not pending.done(), "publication waits for route edit lock")
        hold.result()
        check(succeeds(pending.result()), "publication after route rename")
        check(
            sql(f"SELECT DISTINCT routeName FROM demoWinners WHERE runID={renamed};") == "renamed",
            "fresh route metadata after lock",
        )

        retired = candidate(7105)
        hold = pool.submit(
            sql,
            f"START TRANSACTION; SELECT mapID FROM mapids WHERE mapID=7105 FOR UPDATE;"
            f"DO GET_LOCK('pub_retire',0); DO SLEEP(.3); UPDATE demoRuns SET ready=2 WHERE runID={retired}; COMMIT;",
        )
        marker("pub_retire")
        pending = pool.submit(call, retired)
        hold.result()
        check(pending.result() == "0\tretired", "retirement wins before publication")
        check(receipt(retired) == 0, "retired candidate not published")

        incumbent = candidate(7106, 2000)
        call(incumbent)
        broken = candidate(7106, 1000)
        sql(
            f"DELIMITER //\nCREATE TRIGGER publication_fail BEFORE UPDATE ON demoRuns FOR EACH ROW "
            f"BEGIN IF NEW.runID={broken} AND NEW.ready=1 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='fixture failure'; END IF; END//\nDELIMITER ;\n"
        )
        check(fails(lambda: call(broken)), "forced mid-transaction failure reported")
        check(
            winner(7106, "speedrun") == incumbent and receipt(broken) == 0,
            "winner and receipt rolled back",
        )
        check(
            sql(f"SELECT ready FROM demoRuns WHERE runID={broken};") == "0",
            "candidate readiness rolled back",
        )
        sql("DROP TRIGGER publication_fail;")
        check(succeeds(call(broken)), "known rolled-back publication safely retries")

        incumbent = candidate(7107, 2000)
        call(incumbent)
        dropped = candidate(7107, 1000)
        sql(
            f"DELIMITER //\nCREATE TRIGGER publication_pause BEFORE UPDATE ON demoRuns FOR EACH ROW "
            f"BEGIN IF NEW.runID={dropped} AND NEW.ready=1 THEN DO GET_LOCK('pub_before_commit',0); DO SLEEP(5); END IF; END//\nDELIMITER ;\n"
        )
        pending = pool.submit(call, dropped)
        connection = marker("pub_before_commit")
        check(winner(7107, "speedrun") == incumbent, "uncommitted winner changes are invisible")
        sql(f"KILL CONNECTION {connection};")
        check(fails(pending.result), "connection loss before commit reported")
        sql("DROP TRIGGER publication_pause;")
        check(
            winner(7107, "speedrun") == incumbent and receipt(dropped) == 0,
            "connection loss rolls back",
        )
        check(succeeds(call(dropped)), "retry after pre-commit disconnect")

        acknowledged = candidate(7108)
        pending = pool.submit(
            sql,
            f"CALL publishDemo({acknowledged}); DO GET_LOCK('pub_after_commit',0); DO SLEEP(5);",
        )
        connection = marker("pub_after_commit")
        sql(f"KILL CONNECTION {connection};")
        check(fails(pending.result), "connection loss after commit simulated")
        check(receipt(acknowledged) == 1, "durable receipt resolves lost acknowledgement")
        check(
            call(acknowledged) == "1\talready_published",
            "retry after committed disconnect is idempotent",
        )

        timeout = candidate(7109)
        hold = pool.submit(
            sql,
            "START TRANSACTION; SELECT mapID FROM mapids WHERE mapID=7109 FOR UPDATE;"
            "DO GET_LOCK('pub_timeout',0); DO SLEEP(2); COMMIT;",
        )
        marker("pub_timeout")
        check(
            fails(lambda: sql(f"SET innodb_lock_wait_timeout=1; CALL publishDemo({timeout});")),
            "lock timeout reported",
        )
        check(receipt(timeout) == 0, "lock timeout has no partial commit")
        hold.result()
        check(succeeds(call(timeout)), "retry after lock timeout")

        independent = candidate(7111)
        hold = pool.submit(
            sql,
            "START TRANSACTION; SELECT mapID FROM mapids WHERE mapID=7110 FOR UPDATE;"
            "DO GET_LOCK('pub_other_map',0); DO SLEEP(.6); COMMIT;",
        )
        marker("pub_other_map")
        check(succeeds(call(independent)), "different map can publish concurrently")
        check(
            sql("SELECT IS_USED_LOCK('pub_other_map');") != "NULL",
            "other-map publication did not wait for map lock",
        )
        hold.result()
    sql(
        "DELETE FROM demoWinners WHERE mapID BETWEEN 7101 AND 7112;"
        "DELETE FROM demoRuns WHERE mapID BETWEEN 7101 AND 7112;"
        "DELETE FROM playerRuns WHERE mapID BETWEEN 7101 AND 7112;"
        "DELETE FROM mapids WHERE mapID BETWEEN 7101 AND 7112;"
    )
    check(
        sql("SELECT COUNT(*) FROM demoPublications WHERE runID>80000;") == "0",
        "fixture receipts cascade with deleted test runs",
    )
    return {
        "checks": checks,
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
