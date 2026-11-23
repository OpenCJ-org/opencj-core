#include openCJ\util;

// Prepare the map's SQL interface before starting completion delivery.
onInit()
{
    _initConstants();
    level.database = [];
    level.database["host"] = getCvar("db_host");
    level.database["user"] = getCvar("db_user");
    level.database["pass"] = getCvar("db_pass");
    level.database["port"] = int(getCvar("db_port"));
    level.database["name"] = getCvar("db_base") + getCodVersion();

    level.mySQL = mysql_reuse_connection();
    if(!isDefined(level.mySQL))
    {
        level.mySQL = mysql_init();
        if(!isDefined(level.mySQL))
        {
            return;
        }
        connectionResult = mysql_real_connect(level.mySQL, level.database["host"],
                                              level.database["user"], level.database["pass"],
                                              level.database["name"], level.database["port"]);
        if(!isDefined(connectionResult) || !connectionResult)
        {
            printf("ERROR: MYSQL errno=" + mysql_errno(level.mySQL) +
                   " error= " + mysql_error(level.mySQL) + "\n");
            mysql_close(level.mySQL);
            level.mySQL = undefined;
            return;
        }
    }
    mysql_async_newmap();
    thread _asyncMySQL();
}

// Policy and outcome values mirror mysql_async_pool.hpp. Queue deadlines
// expire work before it starts; native execution has separate SQL/socket limits.
_initConstants()
{
    level.sqlConstants = spawnStruct();
    level.sqlConstants.policyProgress = 0;
    level.sqlConstants.policyRead = 1;
    level.sqlConstants.policyBackground = 2;
    level.sqlConstants.policyMenu = 3;
    level.sqlConstants.policyWrite = 4;
    level.sqlConstants.outcomeOK = 0;
    level.sqlConstants.outcomeError = 1;
    level.sqlConstants.outcomeUnknown = 3;
    level.sqlConstants.outcomeCancelled = 5;
    level.sqlConstants.outcomeInvalid = 7;
    level.sqlConstants.scopeExact = 0;
    level.sqlConstants.scopePrefix = 1;
    level.sqlConstants.retainCompletion = 0;
    level.sqlConstants.workerCount = 4;
    level.sqlConstants.completionPollSeconds = 0.05;
    level.sqlConstants.defaultQueueWaitMs = 10000;
    level.sqlConstants.backgroundQueueWaitMs = 30000;
    level.sqlConstants.menuQueueWaitMs = 2000;
    level.sqlConstants.busyNoticeIntervalMs = 5000;
}

// Consume every native completion, even if its waiting player disconnected.
// This level-owned loop releases results that no script caller still needs.
_asyncMySQL()
{
    mysql_async_initializer(level.database["host"], level.database["user"], level.database["pass"],
                            level.database["name"], level.database["port"],
                            level.sqlConstants.workerCount);
    while(true)
    {
        completedIDs = mysql_async_getdone_list();
        for(i = 0; i < completedIDs.size; i++)
        {
            completion = mysql_async_getstatus(completedIDs[i]);
            rows = mysql_async_getrows_and_free(completedIDs[i]);
            level notify("mysqlQueryDone" + completedIDs[i], rows, completion);
        }
        wait level.sqlConstants.completionPollSeconds;
    }
}

// Return rows from the shared synchronous connection, or undefined on failure.
mysqlSyncQuery(query)
{
    if(!isDefined(level.mySQL))
    {
        return undefined;
    }
    queryError = mysql_query(level.mySQL, query);
    if(isDefined(queryError) && !queryError)
    {
        result = mysql_store_result(level.mySQL);
        rows = _getRowsAndFree(result);
        return rows;
    }
    return undefined;
}

// Copy a native rowset into script values and release its native storage.
_getRowsAndFree(result)
{
    rows = [];
    if (!isDefined(result))
    {
        return undefined; // SQL failure, not an empty success.
    }
    if (result == 0)
    {
        return rows; // Successful statement with no rowset.
    }
    rowCount = mysql_num_rows(result);
    for (i = 0; i < rowCount; i++)
    {
        row = mysql_fetch_row(result);
        rows[rows.size] = row;
    }
    mysql_free_result(result);
    return rows;
}

mysqlAsyncLongQuerySetup()
{
    return mysql_setup_longquery();
}

mysqlAsyncLongQueryFree(handle)
{
    return mysql_free_longquery(handle);
}

mysqlAsyncLongQueryAppend(queryID, queryPart)
{
    return mysql_append_longquery(queryID, queryPart);
}

mysqlAsyncLongQueryExecuteSave(queryID)
{
    if(isPlayer(self))
    {
        self endon("disconnect");
    }
    id = mysql_async_execute_longquery(queryID, true);
    if(!isDefined(id))
    {
        return undefined;
    }
    level waittill("mysqlQueryDone" + id, rows);
    return rows;
}

// No caller receives an unmanaged MYSQL_RES pointer.
mysqlAsyncQueryNoRows(query)
{
    return mysqlAsyncQueryNosave(query);
}

mysqlAsyncLongQueryExecuteNosave(queryID)
{
    if(isPlayer(self))
    {
        self endon("disconnect");
    }
    id = mysql_async_execute_longquery(queryID, false);
    if(!isDefined(id))
    {
        return undefined;
    }
    level waittill("mysqlQueryDone" + id, rows);
    return rows;
}

// Compatibility wrapper: unclassified operations are writes, never guessed
// from the SQL verb. Explicit helpers below select policy/order/cancellation.
mysqlAsyncQuery(query)
{
    result = _request(query, level.sqlConstants.policyWrite, defaultWriteKey(), "",
                      level.sqlConstants.defaultQueueWaitMs, true);
    if (!isDefined(result))
    {
        return undefined;
    }
    return result.rows;
}

mysqlAsyncQueryNosave(query)
{
    result = _request(query, level.sqlConstants.policyWrite, defaultWriteKey(), "",
                      level.sqlConstants.defaultQueueWaitMs, false);
    if (!isDefined(result))
    {
        return undefined;
    }
    if (result.status != level.sqlConstants.outcomeOK)
    {
        _reportFailure(result.status);
    }
    if (!isDefined(result))
    {
        return undefined;
    }
    return result.rows;
}

mysqlAsyncRead(query)
{
    result = _request(query, level.sqlConstants.policyRead, "", "",
                      level.sqlConstants.defaultQueueWaitMs, true);
    if (!isDefined(result))
    {
        return undefined;
    }
    return result.rows;
}

mysqlAsyncWrite(query, key)
{
    result = _request(query, level.sqlConstants.policyProgress, key, "",
                      level.sqlConstants.defaultQueueWaitMs, true);
    if (!isDefined(result))
    {
        return undefined;
    }
    return result.rows;
}

mysqlAsyncWriteNosave(query, key)
{
    result = _request(query, level.sqlConstants.policyProgress, key, "",
                      level.sqlConstants.defaultQueueWaitMs, false);
    if (!isDefined(result))
    {
        return undefined;
    }
    if (result.status != level.sqlConstants.outcomeOK)
    {
        _reportFailure(result.status);
    }
    if (!isDefined(result))
    {
        return undefined;
    }
    return result.rows;
}

mysqlAsyncBackground(query, key)
{
    result = _request(query, level.sqlConstants.policyBackground, key, "",
                      level.sqlConstants.backgroundQueueWaitMs, true);
    if (!isDefined(result))
    {
        return undefined;
    }
    return result.rows;
}

// Discard obsolete menu results before notifying the player about a failure.
mysqlAsyncMenuQuery(query, menu)
{
    token = self.sqlMenuTokens[menu];
    scope = "p:" + self getEntityNumber() + ":" + menu;
    result = _request(query, level.sqlConstants.policyMenu, "", scope,
                      level.sqlConstants.menuQueueWaitMs, true);
    if (!isDefined(result) || !self menuReadCurrent(token))
    {
        return undefined;
    }
    if (result.status != level.sqlConstants.outcomeOK &&
        result.status != level.sqlConstants.outcomeCancelled)
    {
        if (!isDefined(self.sqlBusyNotice) ||
            getTime() - self.sqlBusyNotice > level.sqlConstants.busyNoticeIntervalMs)
        {
            self.sqlBusyNotice = getTime();
            self openCJ\util::sendLocalChatMessage(
                "Database busy or unavailable. Please try the menu again.");
        }
    }
    if (!isDefined(result))
    {
        return undefined;
    }
    return result.rows;
}

// Structured API for callers needing the precise outcome. Successful empty
// statements remain []; failures have undefined rows and an explicit status.
_request(query, policy, key, scope, queueWaitMs, retainRows)
{
    if (isPlayer(self))
    {
        self endon("disconnect");
    }
    if (!isDefined(key))
    {
        key = "";
    }
    result = spawnStruct();
    result.rows = undefined;
    result.error = 0;
    result.waitMs = 0;
    result.executionMs = 0;
    jobID = mysql_async_submit(query, policy, key, scope, queueWaitMs, int(retainRows));
    if (!isDefined(jobID))
    {
        result.status = level.sqlConstants.outcomeInvalid;
        return result;
    }
    if (jobID <= 0)
    {
        result.status = 0 - jobID;
        return result;
    }
    level waittill("mysqlQueryDone" + jobID, rows, nativeCompletion);
    result.rows = rows;
    result.status = nativeCompletion[0];
    result.error = nativeCompletion[1];
    result.waitMs = nativeCompletion[2];
    result.executionMs = nativeCompletion[3];
    return result;
}

_reportFailure(status)
{
    // No SQL or credentials. Player-facing critical callers report their own
    // result; fire-and-forget persistence still has an observable failure.
    printf("OpenCJ SQL: persistence request failed, outcome=" + status + "\n");
    if (isPlayer(self))
    {
        self openCJ\util::sendLocalChatMessage(
            "Database could not confirm that your change was saved.", true);
    }
}

// Replace older reads for this menu and return the identity of the new request.
beginMenuRead(menu)
{
    if (!isDefined(self.sqlActiveMenu) || self.sqlActiveMenu != menu)
    {
        self cancelMenuReads();
    }
    self.sqlActiveMenu = menu;
    if (!isDefined(self.sqlMenuVersions))
    {
        self.sqlMenuVersions = [];
    }
    if (!isDefined(self.sqlMenuTokens))
    {
        self.sqlMenuTokens = [];
    }
    if (!isDefined(self.sqlMenuEpoch))
    {
        self.sqlMenuEpoch = 0;
    }
    version = 0;
    if (isDefined(self.sqlMenuVersions[menu]))
    {
        version = self.sqlMenuVersions[menu];
    }
    version++;
    self.sqlMenuVersions[menu] = version;
    token = spawnStruct();
    token.menu = menu;
    token.version = version;
    token.epoch = self.sqlMenuEpoch;
    self.sqlMenuTokens[menu] = token;
    mysql_async_cancel("p:" + self getEntityNumber() + ":" + menu, level.sqlConstants.scopeExact,
                       level.sqlConstants.retainCompletion);
    // Superseded frames wake with cancellation and return normally. A helper's
    // endon does not reliably terminate all of its calling frames in this VM.
    wait level.sqlConstants.completionPollSeconds;
    return token;
}

// A menu result belongs only to the current menu version and player epoch.
menuReadCurrent(token)
{
    return isDefined(token) && isDefined(self.sqlMenuEpoch) && token.epoch == self.sqlMenuEpoch &&
           self.sqlMenuVersions[token.menu] == token.version;
}

// Invalidate matching request tokens and cancel their queued native menu reads.
cancelMenuReads(menu)
{
    scope = "";
    if (isDefined(menu))
    {
        if (menu == "opencj_leaderboard" || menu == "opencj_runsboard")
        {
            scope = "board";
        }
        else if (menu == "opencj_challenges")
        {
            scope = "challenges";
        }
        else if (menu == "opencj_clips")
        {
            scope = "clips";
        }
        else
        {
            return;
        }
    }
    if (scope != "")
    {
        if (isDefined(self.sqlMenuVersions) && isDefined(self.sqlMenuVersions[scope]))
        {
            self.sqlMenuVersions[scope]++;
        }
        mysql_async_cancel("p:" + self getEntityNumber() + ":" + scope,
                           level.sqlConstants.scopeExact, level.sqlConstants.retainCompletion);
        if (isDefined(self.sqlActiveMenu) && self.sqlActiveMenu == scope)
        {
            self.sqlActiveMenu = "";
        }
        return;
    }
    if (!isDefined(self.sqlMenuEpoch))
    {
        self.sqlMenuEpoch = 0;
    }
    self.sqlMenuEpoch++;
    self.sqlActiveMenu = "";
    mysql_async_cancel("p:" + self getEntityNumber() + ":", level.sqlConstants.scopePrefix,
                       level.sqlConstants.retainCompletion);
}

// Decode the native statistics field order before composing player-facing text.
showStats(args)
{
    stats = mysql_async_stats();
    workerCount = stats[0];
    queuedCount = stats[1];
    runningCount = stats[2];
    completedCount = stats[3];
    queryBytes = stats[5];
    failedCount = stats[10];
    rejectedCount = stats[12];
    uncertainCount = stats[14];
    oldestWaitMs = stats[15];
    maxWaitMs = stats[16];
    maxExecutionMs = stats[17];
    self openCJ\util::sendLocalChatMessage(
        "SQL: " + workerCount + " workers | queued " + queuedCount + " | running " + runningCount +
        " | waiting results " + completedCount + " | query bytes " + queryBytes);
    self openCJ\util::sendLocalChatMessage("Oldest wait " + oldestWaitMs + "ms | max wait " +
                                           maxWaitMs + "ms | max execution " + maxExecutionMs +
                                           "ms | rejected " + rejectedCount + " | failed " +
                                           failedCount + " | uncertain " + uncertainCount);
}

escapeString(string)
{
    return mysql_real_escape_string(level.mysql, string);
}


defaultWriteKey()
{
    if (!isPlayer(self))
    {
        return "";
    }
    if (isDefined(self.login_playerID))
    {
        return "player:" + self.login_playerID;
    }
    return "slot:" + self getEntityNumber();
}

// Native demo/clip transfers return the usual small receipt. No payload bytes
// are copied into script variables, including while the caller waits for SQL.
awaitNative(id)
{
    if(isPlayer(self))
    {
        self endon("disconnect");
    }
    if(!isDefined(id) || id <= 0)
    {
        return undefined;
    }
    level waittill("mysqlQueryDone" + id, rows, outcome);
    return rows;
}
