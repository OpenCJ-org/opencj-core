// Isolated persistence regression. The runner supplies a disposable schema and observes warnings.
main()
{
    level.history192Checks = 0;
    level.history192Failures = 0;
    if(!initializeDatabase())
    {
        return;
    }

    firstPlayer = addTestClient();
    secondPlayer = addTestClient();
    wait 0.2;
    check(isDefined(firstPlayer) && isDefined(secondPlayer),
          "two isolated test clients connected");
    if(!isDefined(firstPlayer) || !isDefined(secondPlayer))
    {
        finish();
        return;
    }
    firstPlayer initialize();
    secondPlayer initialize();

    verifySaveOwnership(firstPlayer, secondPlayer);
    publishedRunID = firstPlayer verifyLatePositionReply();
    firstPlayer verifySuccessfulPublication(publishedRunID);
    failedRunID = firstPlayer verifyFailedPublication(publishedRunID);
    incompleteDemoChecks(failedRunID, publishedRunID);
    firstPlayer verifyDelayedRunReplies();
    firstPlayer extraSaveChecks();
    additionalSuites(firstPlayer, secondPlayer);
    finish();
}

// The SQL-adapter runner replaces this hook in its private copy to run extra suites
// and the final map-change scenario. The standalone history suite ends normally.
additionalSuites(firstPlayer, secondPlayer)
{
}

// Reject any schema outside the disposable namespace before submitting test writes.
initializeDatabase()
{
    databaseName = getCvar("history192_database");
    databasePrefix = "opencj_verify_192_";
    if(getSubStr(databaseName, 0, databasePrefix.size) != databasePrefix)
    {
        return false;
    }
    // A refused connection must leave a clean, retryable pool.
    unavailablePort = 1;
    workerCount = 4;
    failedPool = mysql_async_initializer(getCvar("db_host"), getCvar("db_user"), getCvar("db_pass"),
                                         databaseName, unavailablePort, workerCount);
    check(!isDefined(failedPool), "failed pool initialization returns undefined without crashing");
    check(!isDefined(mysql_async_create_query("SELECT 1")),
          "query without an initialized pool fails immediately");
    openCJ\mySQL::onInit();
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT DATABASE()");
    check(isDefined(rows) && rows[0][0] == databaseName,
          "connected only to disposable verification database");
    openCJ\statistics::onInit();
    openCJ\demoRecording::onInit();
    wait 1;
    verifyQueryResults();
    verifyConnectionRecovery();
    verifyQuerySizeBounds();
    verifyParallelReplies();

    return true;
}

// Exercise ordinary saves, account/map rejection, takeover, and replayed writes.
verifySaveOwnership(firstPlayer, secondPlayer)
{
    runID = newRun();
    originalInstance = scalar("SELECT createRunInstance(" + runID + ")");
    firstPlayer selectRun(runID, originalInstance);
    firstPlayer save(1, 1000);
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 1 &&
              firstPlayer.history192Warnings == 0,
          "normal save persists without ownership warning");
    firstPlayer save(2, 2000);
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 2 &&
              firstPlayer.history192Warnings == 0,
          "second normal save persists");
    resumedInstance = scalar("SELECT historyLoad(1,1," + runID + ")");
    check(resumedInstance == originalInstance + 1, "resume advances ownership generation");
    firstPlayer selectRun(runID, resumedInstance);
    firstPlayer save(3, 3000);
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 3 &&
              firstPlayer.history192Warnings == 0,
          "resumed session saves normally");
    check(!isDefined(scalar("SELECT historyLoad(1,2," + runID + ")")),
          "different account cannot claim run");
    check(!isDefined(scalar("SELECT historyLoad(2,1," + runID + ")")),
          "different map cannot claim run");

    currentInstance = scalar("SELECT historyLoad(1,1," + runID + ")");
    secondPlayer selectRun(runID, currentInstance);
    firstPlayer save(4, 4000);
    check(firstPlayer.history192Warnings == 1 &&
              scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 3,
          "stale session write blocked after real takeover");
    secondPlayer save(4, 4000);
    check(secondPlayer.history192Warnings == 0 &&
              scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 4,
          "new owner remains able to save");
    check(scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + runID) == currentInstance,
          "rejected stale write does not change current ownership");

    // A repeated identical request is not another session, but SQL ROW_COUNT is zero.
    secondPlayer save(4, 4000);
    check(secondPlayer.history192Warnings == 0 &&
              scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + runID) == currentInstance &&
              scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 4,
          "replayed save succeeds without duplicate or false ownership warning");

    secondPlayer verifyStorageFailure(runID, currentInstance);
}

// A real insert error must not be mistaken for another session taking ownership.
verifyStorageFailure(runID, instanceNumber)
{
    // Force an actual storage error, without any ownership change.
    sql("CREATE TRIGGER history192_fail"
        + " BEFORE INSERT ON playerSaves FOR EACH ROW"
        + " SIGNAL SQLSTATE '45000'"
        + " SET MESSAGE_TEXT = 'history192 injected failure'");
    self.history192Warnings = 0;
    self save(5, 5000);
    check(self.history192Warnings == 1 && isSubStr(self.history192WarningMessage, "Database error") &&
              scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + runID) == instanceNumber,
          "storage failure is reported as database error, not ownership conflict");
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 4,
          "failed storage write adds no save");
    sql("DROP TRIGGER history192_fail");
    self.history192Warnings = 0;
    self save(5, 5000);
    check(self.history192Warnings == 0 &&
              scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 5,
          "same owner can save after storage failure clears");
}

// Continue from the stale owner above, then switch to a new run before its reply arrives.
verifyLatePositionReply()
{
    // Delay only result delivery in the test copy; the SQL operation is real.
    replacementRunID = newRun();
    replacementInstance = scalar("SELECT createRunInstance(" + replacementRunID + ")");
    self.history192Warnings = 0;
    level.history192DelayedQuery = "SELECT savePosition(";
    self thread delayedSave();
    self waittill("history192_result_ready");
    self selectRun(replacementRunID, replacementInstance);
    self waittill("history192_save_done");
    level.history192DelayedQuery = undefined;
    check(self.history192Warnings == 0 &&
              scalar("SELECT instanceNumber FROM playerRuns WHERE runID=" + replacementRunID) == replacementInstance,
          "old run response is ignored after switching runs");
    self.history192Warnings = 0;
    self save(1, 1000);
    check(self.history192Warnings == 0 &&
              scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + replacementRunID) == 1,
          "new run remains savable after delayed response");

    return replacementRunID;
}

// Publish a real native recording and verify its stored chunks and category references.
verifySuccessfulPublication(runID)
{
    // Finish/publish an actual native demo through the current production path.
    checkpoint = spawnStruct();
    checkpoint.id = 1;
    self.history192Warnings = 0;
    sql("INSERT INTO checkpointStatistics("
        + "runID, cpID, timePlayed, saveCount, loadCount, explosiveJumps, "
        + "explosiveLaunches, doubleExplosives, FPSMode, ele, anyPct, hardTAS)"
        + " VALUES(" +
        runID + ",1,1000,1,0,0,0,0,'125',0,0,0)");
    finished = self openCJ\playerRuns::onRunFinished(checkpoint, "'125',0,0,0,0");
    check(finished && scalar("SELECT COUNT(*) FROM playerRuns WHERE runID=" + runID +
                             " AND finishTimeStamp IS NOT NULL") == 1,
          "normal finish stored by current owner");
    self makeDemo(runID);
    self openCJ\demoRecording::onRunFinished();
    waitForDemoPublication();
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + runID + " AND ready=1") == 1,
          "finished demo published successfully");
    check(scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + runID) == 2,
          "all native demo chunks persisted");
    check(scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + runID) == 3,
          "published demo receives category references");
    check(self.history192Warnings == 0,
          "normal demo publication does not produce profile-conflict warning");
}

// A failed candidate must leave both its finish record and the previous winner intact.
verifyFailedPublication(winnerRunID)
{
    checkpoint = spawnStruct();
    checkpoint.id = 1;
    // Failed publication must preserve the already-recorded finish.
    candidateRunID = newRun();
    candidateInstance = scalar("SELECT createRunInstance(" + candidateRunID + ")");
    self selectRun(candidateRunID, candidateInstance);
    sql("INSERT INTO checkpointStatistics("
        + "runID, cpID, timePlayed, saveCount, loadCount, explosiveJumps, "
        + "explosiveLaunches, doubleExplosives, FPSMode, ele, anyPct, hardTAS)"
        + " VALUES(" +
        candidateRunID + ",1,900,1,0,0,0,0,'125',0,0,0)");
    check(self openCJ\playerRuns::onRunFinished(checkpoint, "'125',0,0,0,0"),
          "second demo fixture finish stored");
    sql("CREATE TRIGGER history192_demo_fail"
        + " BEFORE INSERT ON demoChunks FOR EACH ROW"
        + " SIGNAL SQLSTATE '45000'"
        + " SET MESSAGE_TEXT = 'history192 injected demo failure'");
    self makeDemo(candidateRunID);
    self openCJ\demoRecording::onRunFinished();
    waitForDemoPublication();
    check(scalar("SELECT COUNT(*) FROM playerRuns WHERE runID=" + candidateRunID +
                 " AND finishTimeStamp IS NOT NULL") == 1,
          "failed demo publication retains leaderboard finish");
    check(self.history192Warnings == 0, "failed demo publication does not blame another profile");
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + candidateRunID) == 0 &&
              scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + candidateRunID) == 0,
          "failed candidate is removed instead of published");
    check(scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + candidateRunID) == 0,
          "failed candidate receives no winner references");
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + winnerRunID + " AND ready=1") == 1 &&
              scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + winnerRunID) == 2 &&
              scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + winnerRunID) == 3,
          "working demo and category references survive failed upload");
    sql("DROP TRIGGER history192_demo_fail");
    return candidateRunID;
}

// Publication normally completes quickly; ten seconds bounds a failed regression.
waitForDemoPublication()
{
    maxPolls = 200;
    pollIntervalSeconds = 0.05;
    for(attempt = 0; attempt < maxPolls; attempt++)
    {
        if(isDefined(level.demoPersisting) && level.demoPersisting == 0)
        {
            return;
        }
        wait pollIntervalSeconds;
    }
    check(false, "demo publication completes within ten seconds");
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

selectRun(runID, instanceNumber)
{
    self openCJ\playerRuns::setRunIDAndInstanceNumber(runID, instanceNumber);
    self.playerRuns_runFinished = false;
}

save(saveCount, timePlayedMs)
{
    self openCJ\statistics::setSaveCount(saveCount);
    self openCJ\statistics::setLoadCount(0);
    self openCJ\statistics::setExplosiveLaunches(0);
    self.startTime = 0;
    self.stopTime = timePlayedMs;
    self openCJ\historySave::saveToDatabase((10, 20, 30), (0, 90, 0), undefined, undefined, 0, 0, 1,
                                            "125", 0);
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

newRun()
{
    return scalar("SELECT createRunID(1,1)");
}
sql(query)
{
    return openCJ\mySQL::mysqlAsyncQuery(query);
}
scalar(query)
{
    rows = sql(query);
    if(!isDefined(rows) || rows.size == 0 || !isDefined(rows[0][0]))
    {
        return undefined;
    }
    return int(rows[0][0]);
}

makeDemo(runID)
{
    check(createDemo(runID) == runID, "native demo buffer created");
    // Cross the native 64-frame chunk boundary with a short second chunk.
    frameCount = 70;
    for(i = 0; i < frameCount; i++)
    {
        addFrameToDemo(runID, (i * 1.0, 20, 30), (0, 90, 0), 1, level.demoFlags.onGround, 0, 0, 0, 125, 1,
                       self getEntityNumber());
    }
    self.demoRecordings = [];
    recording = spawnStruct();
    recording.id = runID;
    recording.failed = false;
    recording.finishing = false;
    self.demoRecordings["" + runID] = recording;
}

check(passed, label)
{
    level.history192Checks++;
    if(!passed)
    {
        level.history192Failures++;
    }
    printf("HISTORY192 CHECK " + passed + ": " + label + "\n");
}
observation(label, reproduced)
{
    printf("HISTORY192 OBSERVATION " + label + "=" + int(reproduced) + "\n");
}
finish()
{
    printf("HISTORY192 COMPLETE failures=" + level.history192Failures +
           " checks=" + level.history192Checks + "\n");
}

verifyQueryResults()
{
    resultRows = sql("CREATE TABLE history192_probe(id INT PRIMARY KEY) ENGINE=InnoDB");
    check(isDefined(resultRows) && resultRows.size == 0, "successful async DDL returns empty success");
    rows = sql("SELECT id FROM history192_probe");
    check(isDefined(rows) && rows.size == 0, "empty SELECT remains a successful result");
    check(!isDefined(sql("SELECT id FROM history192_missing")), "SQL error returns undefined");
    rows = openCJ\mySQL::mysqlAsyncQueryNosave("INSERT INTO history192_probe VALUES(1)");
    check(isDefined(rows) && rows.size == 0, "no-result wrapper reports successful write");
    check(!isDefined(openCJ\mySQL::mysqlAsyncQueryNosave("INSERT INTO history192_probe VALUES(1)")),
          "no-result wrapper propagates duplicate-key error");
    sql("CREATE PROCEDURE history192_multi()"
        + " BEGIN"
        + " SELECT 17;"
        + " SELECT 18;"
        + " END");
    rows = sql("CALL history192_multi()");
    check(isDefined(rows) && rows.size == 1 && int(rows[0][0]) == 17,
          "CALL retains first rowset and drains following results");
    sql("CREATE PROCEDURE history192_late_error()"
        + " BEGIN"
        + " SELECT 19;"
        + " SIGNAL SQLSTATE '45000'"
        + " SET MESSAGE_TEXT = 'injected trailing failure';"
        + " END");
    check(!isDefined(sql("CALL history192_late_error()")),
          "error after first CALL rowset is not accepted as success");
    check(scalar("SELECT 20") == 20, "worker remains usable after trailing CALL failure");
    check(!isDefined(openCJ\mySQL::mysqlSyncQuery("CALL history192_late_error()")),
          "sync CALL also propagates trailing error");
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT 21");
    check(isDefined(rows) && int(rows[0][0]) == 21,
          "sync connection remains usable after trailing CALL failure");
}

verifyConnectionRecovery()
{
    connectionID = scalar("SELECT CONNECTION_ID()");
    openCJ\mySQL::mysqlSyncQuery("KILL " + connectionID);
    check(scalar("SELECT 22") == 22, "worker reconnects before the next new statement");

    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    openCJ\mySQL::mysqlSyncQuery("INSERT INTO history192_probe VALUES(3)");
    connectionRows = openCJ\mySQL::mysqlSyncQuery("SELECT CONNECTION_ID()");
    sql("KILL " + connectionRows[0][0]);
    check(!isDefined(openCJ\mySQL::mysqlSyncQuery("INSERT INTO history192_probe VALUES(4)")),
          "lost transaction connection cannot reconnect and continue writing");
    check(!isDefined(openCJ\mySQL::mysqlSyncQuery("COMMIT")),
          "broken transaction cannot report a successful commit");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM history192_probe WHERE id IN (3,4)");
    check(isDefined(rows) && int(rows[0][0]) == 0,
          "next sync operation reconnects with both transaction writes absent");
}

verifyQuerySizeBounds()
{
    maxQueryBytes = 10 * 1024;
    paddingChunkBytes = 250;
    completePaddingChunks = 40;
    queryPrefix = "SELECT 7";
    trailingPaddingBytes = maxQueryBytes - queryPrefix.size -
                           completePaddingChunks * paddingChunkBytes;
    queryBuilder = openCJ\mySQL::mysqlAsyncLongQuerySetup();
    openCJ\mySQL::mysqlAsyncLongQueryAppend(queryBuilder, queryPrefix);
    paddingChunk = "";
    for(i = 0; i < paddingChunkBytes; i++)
    {
        paddingChunk += " ";
    }
    for(i = 0; i < completePaddingChunks; i++)
    {
        openCJ\mySQL::mysqlAsyncLongQueryAppend(queryBuilder, paddingChunk);
    }
    openCJ\mySQL::mysqlAsyncLongQueryAppend(queryBuilder, getSubStr(paddingChunk, 0, trailingPaddingBytes));
    rows = openCJ\mySQL::mysqlAsyncLongQueryExecuteSave(queryBuilder);
    check(isDefined(rows) && int(rows[0][0]) == 7, "query at exact 10 KiB boundary succeeds");

    queryBuilder = openCJ\mySQL::mysqlAsyncLongQuerySetup();
    openCJ\mySQL::mysqlAsyncLongQueryAppend(queryBuilder, "INSERT INTO history192_probe VALUES(2)");
    appendAccepted = true;
    for(i = 0; i <= completePaddingChunks; i++)
    {
        appendAccepted = openCJ\mySQL::mysqlAsyncLongQueryAppend(queryBuilder, paddingChunk);
    }
    check(!appendAccepted, "oversized append is rejected");
    check(!isDefined(openCJ\mySQL::mysqlAsyncLongQueryExecuteSave(queryBuilder)),
          "overflowed query returns immediately without executing its prefix");
    check(scalar("SELECT COUNT(*) FROM history192_probe WHERE id=2") == 0,
          "rejected long query has no write side effect");
}

verifyParallelReplies()
{
    queryCount = 40;
    maxPolls = 200;
    pollIntervalSeconds = 0.05;
    level.history192Parallel = 0;
    for(i = 0; i < queryCount; i++)
    {
        thread parallelQuery(i);
    }
    for(i = 0; i < maxPolls && level.history192Parallel < queryCount; i++)
    {
        wait pollIntervalSeconds;
    }
    check(level.history192Parallel == queryCount, "all concurrent query waiters completed");
}

parallelQuery(value)
{
    rows = sql("SELECT " + value + ",SLEEP(0.01)");
    check(isDefined(rows) && int(rows[0][0]) == value, "parallel query returns its own result");
    level.history192Parallel++;
}
extraSaveChecks()
{
    runID = newRun();
    instanceNumber = scalar("SELECT createRunInstance(" + runID + ")");
    query = "SELECT savePosition(" + runID + "," + instanceNumber +
            ",1,2,3,0,90,0,1000,1,0,0,0,0,NULL,'125',0,NULL,NULL)";
    requestCount = 8;
    maxPolls = 200;
    pollIntervalSeconds = 0.05;
    level.history192DuplicateDone = 0;
    for(i = 0; i < requestCount; i++)
    {
        thread duplicateSave(query, instanceNumber);
    }
    for(i = 0; i < maxPolls && level.history192DuplicateDone < requestCount; i++)
    {
        wait pollIntervalSeconds;
    }
    check(level.history192DuplicateDone == requestCount &&
              scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 1,
          "concurrent identical saves store exactly one position");
    changedPositionQuery = "SELECT savePosition(" + runID + "," + instanceNumber +
              ",99,2,3,0,90,0,1000,1,0,0,0,0,NULL,'125',0,NULL,NULL)";
    check(scalar(changedPositionQuery) == instanceNumber &&
              scalar("SELECT COUNT(*) FROM playerSaves WHERE runID=" + runID) == 2,
          "equal run counters do not discard a different position");
    messageRows = [];
    messageRows[0] = [];
    messageRows[0][0] = undefined;
    self selectRun(runID, instanceNumber);
    message =
        self openCJ\runStorage::resultMessage(runID, instanceNumber, messageRows, "Checkpoint progress");
    check(isSubStr(message, "Database error"),
          "NULL checkpoint result with unchanged owner is a storage error");
    sql("SELECT createRunInstance(" + runID + ")");
    message =
        self openCJ\runStorage::resultMessage(runID, instanceNumber, messageRows, "Checkpoint progress");
    check(isSubStr(message, "another session"),
          "checkpoint warning requires confirmed ownership change");
    self selectRun(runID, instanceNumber + 1);
    message =
        self openCJ\runStorage::resultMessage(runID, instanceNumber, messageRows, "Checkpoint progress");
    check(message == "", "checkpoint response from previous instance is ignored");
}
duplicateSave(query, instanceNumber)
{
    rows = sql(query);
    check(isDefined(rows) && isDefined(rows[0][0]) && int(rows[0][0]) == instanceNumber,
          "concurrent duplicate confirms current ownership");
    level.history192DuplicateDone++;
}

incompleteDemoChecks(candidateRunID, winnerRunID)
{
    // Recreate only a disposable candidate; exercise the promotion gate directly.
    sql("INSERT INTO demoRuns("
        + "runID, mapID, routeID, FPSMode, modeMask, timePlayed, "
        + "explosiveJumps, frameCount, ready, createdAt)"
        + " SELECT " +
        candidateRunID +
        ",mapID,routeID,FPSMode,modeMask,900,explosiveJumps,70,0,createdAt FROM demoRuns WHERE runID=" +
        winnerRunID);
    check(scalar("SELECT COUNT(*) FROM demoRuns WHERE runID=" + candidateRunID + " AND ready=0") == 1,
          "incomplete demo candidate fixture exists");
    check(!openCJ\demoRecording::promote(candidateRunID),
          "promotion rejects a candidate with no chunks");
    sql("INSERT INTO demoChunks VALUES(" + candidateRunID + ",0,'a')");
    check(!openCJ\demoRecording::promote(candidateRunID), "promotion rejects a missing final chunk");
    sql("INSERT INTO demoChunks VALUES(" + candidateRunID + ",2,'b')");
    check(!openCJ\demoRecording::promote(candidateRunID),
          "promotion rejects a gap despite matching chunk count");
    sql("UPDATE demoChunks SET chunkNum=1,payload='' WHERE runID=" + candidateRunID + " AND chunkNum=2");
    check(!openCJ\demoRecording::promote(candidateRunID), "promotion rejects an empty chunk");
    check(scalar("SELECT COUNT(*) FROM demoWinners WHERE runID=" + winnerRunID) == 3 &&
              scalar("SELECT COUNT(*) FROM demoChunks WHERE runID=" + winnerRunID) == 2,
          "all incomplete candidates preserve the current demo");
    sql("DELETE FROM demoRuns WHERE runID=" + candidateRunID);
}

// Let real writes finish, then switch the player's run before delivering their replies.
verifyDelayedRunReplies()
{
    openCJ\playerRuns::onInit();
    level.mapid_mapID = 1;
    self.settingsLoaded = true;
    checkpoint = spawnStruct();
    checkpoint.id = 1;

    self verifyDelayedFinish(checkpoint, false);
    self verifyDelayedFinish(checkpoint, true);
    self verifyDelayedRunSave();
    self verifyDelayedCheckpointFinish(checkpoint);
    self verifyDelayedTutorialFinish(checkpoint);
    self verifyDelayedRunCreation("SELECT createRunID(", 0);
    self verifyDelayedRunCreation("SELECT createRunInstance(", 1);
    self verifyOverlappingRunCreation();
}

verifyDelayedFinish(checkpoint, resumeSameRun)
{
    originalRunID = newRun();
    originalInstance = scalar("SELECT createRunInstance(" + originalRunID + ")");
    self selectRun(originalRunID, originalInstance);
    sql("INSERT INTO checkpointStatistics(" +
        "runID, cpID, timePlayed, saveCount, loadCount, explosiveJumps, " +
        "explosiveLaunches, doubleExplosives, FPSMode, ele, anyPct, hardTAS)" + " VALUES(" +
        originalRunID + ", 1, 1000, 1, 0, 0, 0, 0, '125', 0, 0, 0)");

    replacementRunID = originalRunID;
    replacementInstance = originalInstance + 1;
    if(!resumeSameRun)
    {
        replacementRunID = newRun();
        replacementInstance = scalar("SELECT createRunInstance(" + replacementRunID + ")");
    }

    level.history192DelayedQuery = "SELECT runFinished(";
    self thread finishWithDelayedReply(checkpoint);
    self waittill("history192_result_ready");
    self selectRun(replacementRunID, replacementInstance);
    self waittill("history192_finish_done");
    level.history192DelayedQuery = undefined;

    scenario = "a different run";
    if(resumeSameRun)
    {
        scenario = "a newer instance of the same run";
    }
    check(!self.history192FinishResult && !self openCJ\playerRuns::isRunFinished(),
          "late finish reply cannot finish " + scenario);
    check(self openCJ\runStorage::isCurrent(replacementRunID, replacementInstance),
          "late finish reply preserves " + scenario);
    check(scalar("SELECT COUNT(*) FROM playerRuns WHERE runID = " + originalRunID +
                 " AND finishTimeStamp IS NOT NULL") == 1,
          "ignoring a late finish reply preserves its completed database write");
}

finishWithDelayedReply(checkpoint)
{
    self.history192FinishResult =
        self openCJ\playerRuns::onRunFinished(checkpoint, "'125',0,0,0,0");
    self notify("history192_finish_done");
}

verifyDelayedRunSave()
{
    originalRunID = newRun();
    originalInstance = scalar("SELECT createRunInstance(" + originalRunID + ")");
    replacementRunID = newRun();
    replacementInstance = scalar("SELECT createRunInstance(" + replacementRunID + ")");
    self selectRun(originalRunID, originalInstance);
    self.history192Stopped = false;

    level.history192DelayedQuery = "SELECT saveRun(";
    self thread saveRunWithDelayedReply();
    self waittill("history192_result_ready");
    self selectRun(replacementRunID, replacementInstance);
    self waittill("history192_run_save_done");
    level.history192DelayedQuery = undefined;

    check(self openCJ\runStorage::isCurrent(replacementRunID, replacementInstance),
          "late save reply cannot stop the replacement run");
    check(!self.history192Stopped,
          "late save reply does not emit a stop event for the replacement run");
}

saveRunWithDelayedReply()
{
    self openCJ\playerRuns::saveRun("delayed save");
    self notify("history192_run_save_done");
}

verifyDelayedCheckpointFinish(checkpoint)
{
    originalRunID = newRun();
    originalInstance = scalar("SELECT createRunInstance(" + originalRunID + ")");
    replacementRunID = newRun();
    replacementInstance = scalar("SELECT createRunInstance(" + replacementRunID + ")");
    self selectRun(originalRunID, originalInstance);
    self.playerRuns_runPaused = false;
    self.allowHalfBeat = false;
    self.startTime = 0;
    self.stopTime = 1000;

    level.history192FinishRequests = 0;
    level.history192DelayedQuery = "SELECT checkpointPassed(";
    self thread finishEventWithDelayedReply(checkpoint);
    self waittill("history192_result_ready");
    self selectRun(replacementRunID, replacementInstance);
    self.playerRuns_runFinishing = false;
    self waittill("history192_finish_event_done");
    level.history192DelayedQuery = undefined;

    check(level.history192FinishRequests == 0,
          "late checkpoint reply never submits a finish for the replacement run");
    check(!self openCJ\playerRuns::isRunFinished() && !self.playerRuns_runFinishing,
          "late checkpoint reply preserves the replacement run's finish state");
    check(scalar("SELECT COUNT(*) FROM checkpointStatistics WHERE runID = " + originalRunID +
                 " AND cpID = 1") == 1,
          "ignoring the checkpoint reply preserves the completed checkpoint write");
    level.history192FinishRequests = undefined;
}

finishEventWithDelayedReply(checkpoint)
{
    self openCJ\events\runFinished::main(checkpoint, 0, "verification");
    self notify("history192_finish_event_done");
}

verifyDelayedTutorialFinish(checkpoint)
{
    originalRunID = newRun();
    originalInstance = scalar("SELECT createRunInstance(" + originalRunID + ")");
    replacementRunID = newRun();
    replacementInstance = scalar("SELECT createRunInstance(" + replacementRunID + ")");
    self selectRun(originalRunID, originalInstance);
    self.tutorialRun = true;

    level.history192FinishRequests = 0;
    level.history192DelayedQuery = "UPDATE playerRuns SET tutorial = 1";
    self thread finishWithDelayedReply(checkpoint);
    self waittill("history192_result_ready");
    self selectRun(replacementRunID, replacementInstance);
    self.tutorialRun = false;
    self waittill("history192_finish_done");
    level.history192DelayedQuery = undefined;

    check(!self.history192FinishResult && level.history192FinishRequests == 0,
          "late tutorial mark never submits a finish after a run switch");
    check(!self openCJ\playerRuns::isRunFinished(),
          "late tutorial mark leaves the replacement run unfinished");
    check(scalar("SELECT tutorial FROM playerRuns WHERE runID = " + originalRunID) == 1,
          "ignoring a tutorial mark reply preserves its completed database write");
    level.history192FinishRequests = undefined;
}

verifyDelayedRunCreation(delayedQuery, expectedInstanceRequests)
{
    replacementRunID = newRun();
    replacementInstance = scalar("SELECT createRunInstance(" + replacementRunID + ")");
    self.history192CreatedEvents = 0;
    level.history192InstanceRequests = 0;
    level.history192DelayedQuery = delayedQuery;

    self thread createRunWithDelayedReply("history192_creation_done");
    self waittill("history192_result_ready");
    self selectRun(replacementRunID, replacementInstance);
    self waittill("history192_creation_done");
    level.history192DelayedQuery = undefined;

    check(self openCJ\runStorage::isCurrent(replacementRunID, replacementInstance),
          "late creation reply preserves the selected run: " + delayedQuery);
    check(self.history192CreatedEvents == 0,
          "late creation reply cannot announce or respawn a superseded run");
    check(level.history192InstanceRequests == expectedInstanceRequests,
          "superseded creation stops before submitting another instance write");
    level.history192InstanceRequests = undefined;
}

// Hold the first reply until a newer creation has completed, without relying on SQL timing.
verifyOverlappingRunCreation()
{
    self.history192CreatedEvents = 0;
    level.history192InstanceRequests = 0;
    level.history192DelayedQuery = "SELECT createRunID(";
    level.history192HoldReply = true;
    self thread createRunWithDelayedReply("history192_first_creation_done");
    self waittill("history192_result_ready");
    level.history192DelayedQuery = undefined;

    self thread createRunWithDelayedReply("history192_second_creation_done");
    self waittill("history192_second_creation_done");
    selectedRunID = self openCJ\playerRuns::getRunID();
    selectedInstance = self openCJ\playerRuns::getRunInstanceNumber();

    self notify("history192_release_result");
    self waittill("history192_first_creation_done");
    level.history192HoldReply = false;

    check(self openCJ\runStorage::isCurrent(selectedRunID, selectedInstance),
          "an older creation reply cannot replace the newer completed creation");
    check(self.history192CreatedEvents == 1,
          "overlapping creations announce and spawn only the current request");
    check(level.history192InstanceRequests == 1,
          "obsolete creation does not submit another instance write");
    level.history192InstanceRequests = undefined;
}

createRunWithDelayedReply(completionEvent)
{
    self openCJ\playerRuns::_createRunID();
    self notify(completionEvent);
}
