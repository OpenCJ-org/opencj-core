// Real publication procedures with test-only failures at the SQL reply boundary.
// Both callers supply an isolated schema with fixture player 1 and map 1.
run()
{
    level.publicationChecks = 0;
    level.publicationFailures = 0;
    verifySchemaReadiness();
    openCJ\mySQL::mysqlSyncQuery("INSERT INTO checkpoints(cpID,mapID) VALUES(90000,1)");
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO routes(routeID,mapID,cpID,routeName)"
        + " VALUES(90000,1,90000,'publication recovery')");
    modes = [];
    modes[0] = "deadlock";
    modes[1] = "timeout";
    modes[2] = "before";
    modes[3] = "after";
    modes[4] = "lookupFailure";
    modes[5] = "known";
    modes[6] = "malformed";
    modes[7] = "deadlockAlways";
    modes[8] = "unknownAlways";
    for(i = 0; i < modes.size; i++)
    {
        verifyReplyFailure(modes[i], 90001 + i, 100000 - i);
    }
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoWinners WHERE routeID=90000");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoRuns WHERE runID BETWEEN 90001 AND 90009");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM playerRuns WHERE runID BETWEEN 90001 AND 90009");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM routes WHERE routeID=90000");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM checkpoints WHERE cpID=90000");
    printf("CAP PUBLICATION RECOVERY COMPLETE failures=" + level.publicationFailures
           + " checks=" + level.publicationChecks + "\n");
    return level.publicationFailures == 0;
}

verifySchemaReadiness()
{
    openCJ\demoRecording::onInit();
    check(level.demoStorageReady && level.demoPublicationReady,
          "publication schema enables recording");
    openCJ\mySQL::mysqlSyncQuery("RENAME TABLE demoPublications TO capacityPublications");
    openCJ\demoRecording::onInit();
    check(level.demoStorageReady && !level.demoPublicationReady,
          "missing migration disables new recording but preserves playback");
    openCJ\mySQL::mysqlSyncQuery("RENAME TABLE capacityPublications TO demoPublications");
    openCJ\demoRecording::onInit();
    check(level.demoPublicationReady, "restored publication schema enables recording");
}

// A successful call can lose its reply after the loser payload was already removed.
// Failure checks therefore inspect the durable receipt as well as the script result.
verifyReplyFailure(fault, runID, elapsedTime)
{
    if(fault == "after")
    {
        elapsedTime = 200000; // This run loses to the already published faster candidate.
    }
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO playerRuns(runID,playerID,mapID,FPSMode)"
        + " VALUES(" + runID + ",1,1,'mix')");
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO demoRuns("
        + "runID,mapID,routeID,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount)"
        + " VALUES(" + runID + ",1,90000,'mix',0," + elapsedTime + ",0,2)");
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO demoChunks(runID,chunkNum,payload) VALUES(" + runID + ",0,UNHEX('01'))");
    level.publicationFault = fault;
    level.publicationCalls = 0;
    published = openCJ\demoRecording::promote(runID);
    if(fault == "deadlock" || fault == "timeout" || fault == "before" || fault == "after")
    {
        check(isDefined(published) && published, "publication recovers from " + fault);
        expectedCalls = 2;
        if(fault == "after")
        {
            expectedCalls = 1;
        }
        check(level.publicationCalls == expectedCalls, "bounded publication calls " + fault);
        rows = openCJ\mySQL::mysqlSyncQuery(
            "SELECT COUNT(*) FROM demoPublications WHERE runID=" + runID);
        check(isDefined(rows) && int(rows[0][0]) == 1, "one durable receipt " + fault);
        if(fault == "after")
        {
            rows = openCJ\mySQL::mysqlSyncQuery(
                "SELECT COUNT(*) FROM demoRuns WHERE runID=" + runID);
            check(isDefined(rows) && int(rows[0][0]) == 0,
                  "lost acknowledgement recovered after losing payload cleanup");
        }
    }
    else
    {
        if(fault == "known" || fault == "deadlockAlways")
        {
            check(isDefined(published) && !published, "known publication failure " + fault);
        }
        else
        {
            check(!isDefined(published), "publication uncertainty remains explicit " + fault);
        }
        expectedCalls = 1;
        if(fault == "deadlockAlways" || fault == "unknownAlways")
        {
            expectedCalls = 3;
        }
        check(level.publicationCalls == expectedCalls, "publication failure retry bound " + fault);
        rows = openCJ\mySQL::mysqlSyncQuery("SELECT ready FROM demoRuns WHERE runID=" + runID);
        check(isDefined(rows) && rows.size == 1 && int(rows[0][0]) == 0,
              "uncertain candidate retained " + fault);
    }
    level.publicationFault = undefined;
}

check(passed, description)
{
    level.publicationChecks++;
    if(!isDefined(passed) || !passed)
    {
        level.publicationFailures++;
        printf("CAP PUBLICATION FAIL " + description + "\n");
    }
}

// The runner renames the production request function only in its private script copy.
// Ordinary queries still use the real worker pool and stored procedures.
request(query, policy, key, scope, queueWaitMs, retainRows)
{
    publicationPrefix = "CALL publishDemo(";
    isPublication = query.size >= publicationPrefix.size
                    && getSubStr(query, 0, publicationPrefix.size) == publicationPrefix;
    if(isDefined(level.publicationFault) && isPublication)
    {
        level.publicationCalls++;
        fault = level.publicationFault;
        if(level.publicationCalls == 1 || fault == "deadlockAlways" || fault == "unknownAlways")
        {
            if(fault == "after")
            {
                openCJ\mySQL::_capacityRealRequest(query, policy, key, scope, queueWaitMs, retainRows);
            }
            result = spawnStruct();
            result.rows = undefined;
            result.status = level.sqlConstants.outcomeUnknown;
            result.error = 2013; // Lost reply: the transaction may already have committed.
            if(fault == "deadlock" || fault == "deadlockAlways")
            {
                result.status = level.sqlConstants.outcomeError;
                result.error = 1213;
            }
            if(fault == "timeout")
            {
                result.status = level.sqlConstants.outcomeError;
                result.error = 1205;
            }
            if(fault == "known")
            {
                result.status = level.sqlConstants.outcomeError;
                result.error = 1064; // Syntax failure cannot be retried as a lock conflict.
            }
            if(fault == "malformed")
            {
                result.status = level.sqlConstants.outcomeOK;
                result.error = 0;
                result.rows = [];
            }
            return result;
        }
    }
    receiptPrefix = "SELECT runID FROM demoPublications WHERE runID=";
    isReceiptLookup = query.size >= receiptPrefix.size
                      && getSubStr(query, 0, receiptPrefix.size) == receiptPrefix;
    if(isDefined(level.publicationFault) && level.publicationFault == "lookupFailure"
       && isReceiptLookup)
    {
        result = spawnStruct();
        result.rows = undefined;
        result.status = 2; // Connection unavailable before the receipt query executes.
        result.error = 2006;
        return result;
    }
    return openCJ\mySQL::_capacityRealRequest(query, policy, key, scope, queueWaitMs, retainRows);
}
