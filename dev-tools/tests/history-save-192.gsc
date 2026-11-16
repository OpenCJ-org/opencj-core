// #192 verification only. Runner supplies a disposable schema and observes warnings.
main()
{
    level.history192Checks = 0;
    level.history192Failures = 0;
    expected = getCvar("history192_database");
    if (getSubStr(expected, 0, 18) != "opencj_verify_192_") return;
    // A refused connection must leave a clean, retryable pool.
    failedPool = mysql_async_initializer(getCvar("db_host"), getCvar("db_user"), getCvar("db_pass"), expected, 1, 4);
    check(!isDefined(failedPool), "failed pool initialization returns undefined without crashing");
    check(!isDefined(mysql_async_create_query("SELECT 1")), "query without an initialized pool fails immediately");
    openCJ\mySQL::onInit();
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT DATABASE()");
    check(isDefined(rows) && rows[0][0] == expected, "connected only to disposable verification database");
    openCJ\statistics::onInit();
    openCJ\demoRecording::onInit();
    wait 1;
    wrapperChecks();

    a = addTestClient();
    b = addTestClient();
    wait 0.2;
    check(isDefined(a) && isDefined(b), "two isolated test clients connected");
    if (!isDefined(a) || !isDefined(b)) { finish(); return; }
    a initialize();
    b initialize();
    run = newRun();
    instance = scalar("SELECT createRunInstance(" + run + ")");
    a selectRun(run, instance);
    a save(1, 1000);
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 1 && a.history192Warnings == 0, "normal save persists without ownership warning");
    a save(2, 2000);
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 2 && a.history192Warnings == 0, "second normal save persists");
    resumed = scalar("SELECT historyLoad(1,1," + run + ")");
    check(resumed == instance + 1, "resume advances ownership generation");
    a selectRun(run, resumed);
    a save(3, 3000);
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 3 && a.history192Warnings == 0, "resumed session saves normally");
    check(!isDefined(scalar("SELECT historyLoad(1,2," + run + ")")), "different account cannot claim run");
    check(!isDefined(scalar("SELECT historyLoad(2,1," + run + ")")), "different map cannot claim run");

    taken = scalar("SELECT historyLoad(1,1," + run + ")");
    b selectRun(run, taken);
    a save(4, 4000);
    check(a.history192Warnings == 1 && scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 3, "stale session write blocked after real takeover");
    b save(4, 4000);
    check(b.history192Warnings == 0 && scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 4, "new owner remains able to save");
    check(scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + run) == taken, "rejected stale write does not change current ownership");

    // A repeated identical request is not another session, but SQL ROW_COUNT is zero.
    b save(4, 4000);
    check(b.history192Warnings == 0 &&
        scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + run) == taken &&
        scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 4, "replayed save succeeds without duplicate or false ownership warning");

    // Force an actual storage error, without any ownership change.
    sql("CREATE TRIGGER history192_fail BEFORE INSERT ON playerSaves FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='history192 injected failure'");
    b.history192Warnings = 0;
    b save(5, 5000);
    check(b.history192Warnings == 1 && isSubStr(b.history192WarningMessage, "Database error") &&
        scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + run) == taken, "storage failure is reported as database error, not ownership conflict");
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 4, "failed storage write adds no save");
    sql("DROP TRIGGER history192_fail");
    b.history192Warnings = 0;
    b save(5, 5000);
    check(b.history192Warnings == 0 && scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 5, "same owner can save after storage failure clears");

    // Delay only result delivery in the test copy; the SQL operation is real.
    fresh = newRun();
    freshInstance = scalar("SELECT createRunInstance(" + fresh + ")");
    a.history192Warnings = 0;
    level.history192Delay = true;
    a thread delayedSave();
    a waittill("history192_result_ready");
    a selectRun(fresh, freshInstance);
    a waittill("history192_save_done");
    level.history192Delay = false;
    check(a.history192Warnings == 0 &&
        scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + fresh) == freshInstance, "old run response is ignored after switching runs");
    a.history192Warnings = 0;
    a save(1, 1000);
    check(a.history192Warnings == 0 && scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + fresh) == 1, "new run remains savable after delayed response");

    // Finish/publish an actual native demo through the current production path.
    cp = spawnStruct(); cp.id = 1;
    a.history192Warnings = 0;
    sql("INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode,ele,anyPct,hardTAS) VALUES(" + fresh + ",1,1000,1,0,0,0,0,'125',0,0,0)");
    finished = a openCJ\playerRuns::onRunFinished(cp, "'125',0,0,0,0");
    check(finished && scalar("SELECT COUNT(*) FROM playerRuns WHERE runID=" + fresh + " AND finishTimeStamp IS NOT NULL") == 1, "normal finish stored by current owner");
    a makeDemo(fresh);
    a openCJ\demoRecording::onRunFinished();
    for (i = 0; i < 200; i++)
    {
        if (isDefined(level.demoPersisting) && level.demoPersisting == 0) break;
        wait 0.05;
    }
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + fresh + " AND ready=1") == 1, "finished demo published successfully");
    check(scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + fresh) == 2, "all native demo chunks persisted");
    check(scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + fresh) == 3, "published demo receives category references");
    check(a.history192Warnings == 0, "normal demo publication does not produce profile-conflict warning");

    // Failed publication must preserve the already-recorded finish.
    failedDemo = newRun();
    failedInstance = scalar("SELECT createRunInstance(" + failedDemo + ")");
    a selectRun(failedDemo, failedInstance);
    sql("INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives,FPSMode,ele,anyPct,hardTAS) VALUES(" + failedDemo + ",1,900,1,0,0,0,0,'125',0,0,0)");
    check(a openCJ\playerRuns::onRunFinished(cp, "'125',0,0,0,0"), "second demo fixture finish stored");
    sql("CREATE TRIGGER history192_demo_fail BEFORE INSERT ON demoChunks FOR EACH ROW SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='history192 injected demo failure'");
    a makeDemo(failedDemo);
    a openCJ\demoRecording::onRunFinished();
    for (i = 0; i < 200; i++)
    {
        if (isDefined(level.demoPersisting) && level.demoPersisting == 0) break;
        wait 0.05;
    }
    check(scalar("SELECT COUNT(*) FROM playerRuns WHERE runID=" + failedDemo + " AND finishTimeStamp IS NOT NULL") == 1, "failed demo publication retains leaderboard finish");
    check(a.history192Warnings == 0, "failed demo publication does not blame another profile");
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + failedDemo) == 0 &&
        scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + failedDemo) == 0, "failed candidate is removed instead of published");
    check(scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + failedDemo) == 0, "failed candidate receives no winner references");
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + fresh + " AND ready=1") == 1 &&
        scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + fresh) == 2 &&
        scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + fresh) == 3, "working demo and category references survive failed upload");
    sql("DROP TRIGGER history192_demo_fail");
    incompleteDemoChecks(failedDemo, fresh);
    a extraSaveChecks();
    finish();
}

initialize()
{
    self.login_playerID = 1;
    self.cheating = false;
    self.sessionState = "spectator";
    self.playerRuns_runFinished = false;
    self.history192Warnings = 0;
    self openCJ\statistics::onPlayerConnect();
}

selectRun(run, instance)
{
    self openCJ\playerRuns::setRunIDAndInstanceNumber(run, instance);
    self.playerRuns_runFinished = false;
}

save(count, played)
{
    self openCJ\statistics::setSaveCount(count);
    self openCJ\statistics::setLoadCount(0);
    self openCJ\statistics::setExplosiveLaunches(0);
    self.startTime = 0;
    self.stopTime = played;
    self openCJ\historySave::saveToDatabase((10,20,30),(0,90,0),undefined,undefined,0,0,1,"125",0);
}

delayedSave()
{
    self save(6, 6000);
    self notify("history192_save_done");
}

recordWarning(message)
{
    self.history192Warnings++;
    self.history192WarningMessage = message;
    self.history192WarningRun = self openCJ\playerRuns::getRunID();
}

newRun() { return scalar("SELECT createRunID(1,1)"); }
sql(query) { return openCJ\mySQL::mysqlAsyncQuery(query); }
scalar(query)
{
    rows = sql(query);
    if (!isDefined(rows) || rows.size == 0 || !isDefined(rows[0][0])) return undefined;
    return int(rows[0][0]);
}

makeDemo(id)
{
    check(createDemo(id) == id, "native demo buffer created");
    for (i = 0; i < 70; i++)
        addFrameToDemo(id,(i*1.0,20,30),(0,90,0),1,8192,0,0,0,125,1,self getEntityNumber());
    self.demoRecordings = [];
    rec = spawnStruct(); rec.id = id; rec.failed = false; rec.finishing = false;
    self.demoRecordings["" + id] = rec;
}

check(ok, label)
{
    level.history192Checks++;
    if (!ok) level.history192Failures++;
    printf("HISTORY192 CHECK " + ok + ": " + label + "\n");
}
observation(label, reproduced)
{
    printf("HISTORY192 OBSERVATION " + label + "=" + int(reproduced) + "\n");
}
finish()
{
    printf("HISTORY192 COMPLETE failures=" + level.history192Failures + " checks=" + level.history192Checks + "\n");
}


wrapperChecks()
{
    ok = sql("CREATE TABLE history192_probe(id INT PRIMARY KEY) ENGINE=InnoDB");
    check(isDefined(ok) && ok.size == 0, "successful async DDL returns empty success");
    rows = sql("SELECT id FROM history192_probe");
    check(isDefined(rows) && rows.size == 0, "empty SELECT remains a successful result");
    check(!isDefined(sql("SELECT id FROM history192_missing")), "SQL error returns undefined");
    rows = openCJ\mySQL::mysqlAsyncQueryNosave("INSERT INTO history192_probe VALUES(1)");
    check(isDefined(rows) && rows.size == 0, "no-result wrapper reports successful write");
    check(!isDefined(openCJ\mySQL::mysqlAsyncQueryNosave("INSERT INTO history192_probe VALUES(1)")), "no-result wrapper propagates duplicate-key error");
    sql("CREATE PROCEDURE history192_multi() BEGIN SELECT 17; SELECT 18; END");
    rows = sql("CALL history192_multi()");
    check(isDefined(rows) && rows.size == 1 && int(rows[0][0]) == 17, "CALL retains first rowset and drains following results");
    sql("CREATE PROCEDURE history192_late_error() BEGIN SELECT 19; SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='injected trailing failure'; END");
    check(!isDefined(sql("CALL history192_late_error()")), "error after first CALL rowset is not accepted as success");
    check(scalar("SELECT 20") == 20, "worker remains usable after trailing CALL failure");
    check(!isDefined(openCJ\mySQL::mysqlSyncQuery("CALL history192_late_error()")), "sync CALL also propagates trailing error");
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT 21");
    check(isDefined(rows) && int(rows[0][0]) == 21, "sync connection remains usable after trailing CALL failure");

    id = scalar("SELECT CONNECTION_ID()");
    openCJ\mySQL::mysqlSyncQuery("KILL " + id);
    check(scalar("SELECT 22") == 22, "worker reconnects before the next new statement");

    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    openCJ\mySQL::mysqlSyncQuery("INSERT INTO history192_probe VALUES(3)");
    syncId = openCJ\mySQL::mysqlSyncQuery("SELECT CONNECTION_ID()");
    sql("KILL " + syncId[0][0]);
    check(!isDefined(openCJ\mySQL::mysqlSyncQuery("INSERT INTO history192_probe VALUES(4)")), "lost transaction connection cannot reconnect and continue writing");
    check(!isDefined(openCJ\mySQL::mysqlSyncQuery("COMMIT")), "broken transaction cannot report a successful commit");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM history192_probe WHERE id IN (3,4)");
    check(isDefined(rows) && int(rows[0][0]) == 0, "next sync operation reconnects with both transaction writes absent");

    handle = openCJ\mySQL::mysqlAsyncLongQuerySetup();
    openCJ\mySQL::mysqlAsyncLongQueryAppend(handle, "SELECT 7");
    pad = "";
    for (i = 0; i < 250; i++) pad += " ";
    for (i = 0; i < 40; i++) openCJ\mySQL::mysqlAsyncLongQueryAppend(handle, pad);
    openCJ\mySQL::mysqlAsyncLongQueryAppend(handle, getSubStr(pad, 0, 232));
    rows = openCJ\mySQL::mysqlAsyncLongQueryExecuteSave(handle);
    check(isDefined(rows) && int(rows[0][0]) == 7, "query at exact 10 KiB boundary succeeds");

    handle = openCJ\mySQL::mysqlAsyncLongQuerySetup();
    openCJ\mySQL::mysqlAsyncLongQueryAppend(handle, "INSERT INTO history192_probe VALUES(2)");
    accepted = true;
    for (i = 0; i < 41; i++) accepted = openCJ\mySQL::mysqlAsyncLongQueryAppend(handle, pad);
    check(!accepted, "oversized append is rejected");
    check(!isDefined(openCJ\mySQL::mysqlAsyncLongQueryExecuteSave(handle)), "overflowed query returns immediately without executing its prefix");
    check(scalar("SELECT COUNT(*) FROM history192_probe WHERE id=2") == 0, "rejected long query has no write side effect");

    level.history192Parallel = 0;
    for (i = 0; i < 40; i++) thread parallelQuery(i);
    for (i = 0; i < 200 && level.history192Parallel < 40; i++) wait 0.05;
    check(level.history192Parallel == 40, "all concurrent query waiters completed");
}
parallelQuery(value)
{
    rows = sql("SELECT " + value + ",SLEEP(0.01)");
    check(isDefined(rows) && int(rows[0][0]) == value, "parallel query returns its own result");
    level.history192Parallel++;
}
extraSaveChecks()
{
    run = newRun();
    instance = scalar("SELECT createRunInstance(" + run + ")");
    query = "SELECT savePosition(" + run + "," + instance + ",1,2,3,0,90,0,1000,1,0,0,0,0,NULL,'125',0,NULL,NULL)";
    level.history192DuplicateDone = 0;
    for (i = 0; i < 8; i++) thread duplicateSave(query, instance);
    for (i = 0; i < 200 && level.history192DuplicateDone < 8; i++) wait 0.05;
    check(level.history192DuplicateDone == 8 && scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 1, "concurrent identical saves store exactly one position");
    changed = "SELECT savePosition(" + run + "," + instance + ",99,2,3,0,90,0,1000,1,0,0,0,0,NULL,'125',0,NULL,NULL)";
    check(scalar(changed) == instance && scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + run) == 2, "equal run counters do not discard a different position");
    messageRows = []; messageRows[0] = []; messageRows[0][0] = undefined;
    client = self;
    client selectRun(run, instance);
    msg = client openCJ\runStorage::resultMessage(run, instance, messageRows, "Checkpoint progress");
    check(isSubStr(msg, "Database error"), "NULL checkpoint result with unchanged owner is a storage error");
    sql("SELECT createRunInstance(" + run + ")");
    msg = client openCJ\runStorage::resultMessage(run, instance, messageRows, "Checkpoint progress");
    check(isSubStr(msg, "another session"), "checkpoint warning requires confirmed ownership change");
    client selectRun(run, instance + 1);
    msg = client openCJ\runStorage::resultMessage(run, instance, messageRows, "Checkpoint progress");
    check(msg == "", "checkpoint response from previous instance is ignored");
}
duplicateSave(query, instance)
{
    rows = sql(query);
    check(isDefined(rows) && isDefined(rows[0][0]) && int(rows[0][0]) == instance, "concurrent duplicate confirms current ownership");
    level.history192DuplicateDone++;
}


incompleteDemoChecks(candidate, winner)
{
    // Recreate only a disposable candidate; exercise the promotion gate directly.
    sql("INSERT INTO demoRuns SELECT " + candidate + ",mapID,routeName,FPSMode,modeMask,900,explosiveJumps,70,0,createdAt FROM demoRuns WHERE runID=" + winner);
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + candidate + " AND ready=0") == 1, "incomplete demo candidate fixture exists");
    check(!openCJ\demoRecording::promote(candidate), "promotion rejects a candidate with no chunks");
    sql("INSERT INTO demoChunks VALUES(" + candidate + ",0,'a')");
    check(!openCJ\demoRecording::promote(candidate), "promotion rejects a missing final chunk");
    sql("INSERT INTO demoChunks VALUES(" + candidate + ",2,'b')");
    check(!openCJ\demoRecording::promote(candidate), "promotion rejects a gap despite matching chunk count");
    sql("UPDATE demoChunks SET chunkNum=1,payload='' WHERE runID=" + candidate + " AND chunkNum=2");
    check(!openCJ\demoRecording::promote(candidate), "promotion rejects an empty chunk");
    check(scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + winner) == 3 &&
        scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + winner) == 2, "all incomplete candidates preserve the current demo");
    sql("DELETE FROM demoRuns WHERE runID=" + candidate);
}
