#include openCJ\util;

onInit()
{
    level.historySavesActive = 0;
    level.historySavesSequence = 0;
}

// Load an owned run only while the player session and checkpoint layout still match.
historyLoad(runID)
{
    self openCJ\mapBoost::cancel();
    if(isDefined(self.cpc))
    {
        return false;
    }
    self notify("history_load_changed");
    self endon("history_load_changed");
    self endon("cpc_started");
    self endon("disconnect");
    self cancelPendingPage();
    self endon("history_load_cancelled");
    self.historySaves = undefined;
    initialHistoryInfo = self savePosition_historyInfo();
    historyGeneration = initialHistoryInfo[2];
    checkpointLayoutEpoch = level.checkpointLayoutEpoch;
    allowed = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT runID FROM playerRuns WHERE runID=" + runID + " AND archived=0");
    currentHistoryInfo = self savePosition_historyInfo();
    if(currentHistoryInfo[2] != historyGeneration || checkpointLayoutEpoch != level.checkpointLayoutEpoch)
    {
        return false;
    }
    if(!isDefined(allowed) || !allowed.size)
    {
        self iprintlnbold("This run is archived and cannot be resumed. Start a new run.");
        return false;
    }
    rows = self openCJ\mySQL::mysqlAsyncWrite("SELECT historyLoad(" + openCJ\mapID::getMapID() +
                                                  ", " + self openCJ\login::getPlayerID() + ", " +
                                                  runID + ")",
                                              "run:" + runID);
    currentHistoryInfo = self savePosition_historyInfo();
    if(currentHistoryInfo[2] != historyGeneration || checkpointLayoutEpoch != level.checkpointLayoutEpoch)
    {
        return false;
    }
    if(!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
    {
        self iprintlnbold("^1Failed loading history for run: " + runID);
        return false;
    }
    self savePosition_initClient();
    self openCJ\savePosition::resetBackwardsCount();
    return self _loadSavesFromDatabase(runID, int(rows[0][0]));
}

// Load the first bounded history page, then restore run statistics and position.
_loadSavesFromDatabase(runID, instanceNumber)
{
    self endon("disconnect");
    state = self _beginHistory(runID, instanceNumber);
    runRows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT timePlayed, saveCount, loadCount, explosiveLaunches"
        + " FROM playerRuns"
        + " WHERE archived = 0 AND runID = " + runID
        + " AND instanceNumber = " + instanceNumber);
    if(!self _isHistoryCurrent(state) || !isDefined(runRows) || !runRows.size)
    {
        if(self _isHistoryCurrent(state))
        {
            self.historySaves = undefined;
        }
        return false;
    }
    self _startPage(state, undefined);
    while(self _isHistoryCurrent(state) && state.loading)
    {
        wait 0.05;
    }
    if(!self _isHistoryCurrent(state) || state.failed)
    {
        if(self _isHistoryCurrent(state))
        {
            self savePosition_initClient();
            self.historySaves = undefined;
        }
        return false;
    }
    self _restoreRunState(runID, instanceNumber, runRows);
    state.initial = false;
    historyInfo = self savePosition_historyInfo();
    retainedSaveCount = historyInfo[0];
    if(retainedSaveCount == 0)
    {
        spawnpoint = self openCJ\spawnpoints::getPlayerSpawnpoint();
        self freezeControls(true);
        self setVelocity((0, 0, 0));
        wait 0.05;
        if(!self _isHistoryCurrent(state))
        {
            self freezeControls(false);
            return false;
        }
        self openCJ\mapBoost::cancel();
        self setOrigin(spawnpoint.origin);
        self setPlayerAngles(spawnpoint.angles);
        self freezeControls(false);
    }
    return true;
}

// Restore the run counters and player effects after the initial page has loaded.
_restoreRunState(runID, instanceNumber, runRows)
{
    self openCJ\playerRuns::setRunIDAndInstanceNumber(runID, instanceNumber);

    // The SELECT in _loadSavesFromDatabase defines this field order.
    timePlayed = int(runRows[0][0]);
    saveCount = int(runRows[0][1]);
    loadCount = int(runRows[0][2]);
    explosiveLaunches = int(runRows[0][3]);
    self openCJ\statistics::clear();
    self openCJ\statistics::setSaveCount(saveCount);
    self openCJ\statistics::setLoadCount(loadCount);
    // TODO: Restore the value at this save rather than the total for the run.
    self openCJ\statistics::setExplosiveLaunches(explosiveLaunches);

    self openCJ\playtime::setTimePlayed(timePlayed);
    self openCJ\healthRegen::resetHealthRegen();
    self openCJ\shellShock::resetShellShock();
    self openCJ\checkpointPointers::showCheckpointPointers();
}

// Capture the owner, map and native history generation for this load operation.
_beginHistory(runID, instanceNumber)
{
    historyInfo = self savePosition_historyInfo();
    level.historySavesSequence++;
    state = spawnStruct();
    state.id = level.historySavesSequence;
    state.runID = runID;
    state.instance = instanceNumber;
    state.owner = self openCJ\login::getPlayerID();
    state.map = openCJ\mapID::getMapID();
    state.generation = historyInfo[2];
    state.layout = level.checkpointLayoutEpoch;
    state.initial = true;
    state.loading = false;
    state.failed = false;
    state.exhausted = false;
    state.requestID = 0;
    state.retryAtMs = 0;
    self.historySaves = state;
    return state;
}

// Reject history belonging to a different player, map, editor state or native generation.
_isHistoryCurrent(state)
{
    if(!isDefined(self) || !isPlayer(self) || !isDefined(self.historySaves))
    {
        return false;
    }
    if(self.historySaves.id != state.id)
    {
        return false;
    }
    if(!isDefined(state.map) || !isDefined(state.owner) || !isDefined(state.instance))
    {
        return false;
    }
    if(isDefined(self.cpc) || self openCJ\demos::isPlayingDemo() ||
       state.layout != level.checkpointLayoutEpoch)
    {
        return false;
    }
    if(state.owner != self openCJ\login::getPlayerID() || state.map != openCJ\mapID::getMapID())
    {
        return false;
    }
    historyInfo = self savePosition_historyInfo();
    if(historyInfo[2] != state.generation)
    {
        return false;
    }
    if(!state.initial && (self openCJ\playerRuns::getRunID() != state.runID ||
                          self openCJ\playerRuns::getRunInstanceNumber() != state.instance))
    {
        return false;
    }
    return true;
}

isLoadingInitial()
{
    return isDefined(self.historySaves) && self.historySaves.initial &&
           self _isHistoryCurrent(self.historySaves);
}

_finishPage(state, requestID)
{
    if(isDefined(self) && isDefined(self.historySaves) && self.historySaves.id == state.id &&
       state.requestID == requestID)
    {
        state.loading = false;
    }
}

// Cancel run selection and invalidate page replies before a load or mode change.
cancelPendingPage()
{
    self openCJ\commands::cancelRestoreLookup();
    self notify("history_load_cancelled");
    if(!isDefined(self.historySaves))
    {
        return;
    }
    state = self.historySaves;
    state.requestID++;
    state.loading = false;
    if(state.initial)
    {
        self.historySaves = undefined;
    }
}

// Returns true while the requested older data is queued/loading.
maybePrefetch(backwardsCount)
{
    if(!isDefined(self.historySaves))
    {
        return false;
    }
    state = self.historySaves;
    if(!self _isHistoryCurrent(state))
    {
        return false;
    }
    if(state.initial)
    {
        return true;
    }
    historyInfo = self savePosition_historyInfo();
    retainedSaveCount = historyInfo[0];
    oldestSaveNumber = historyInfo[1];
    historyCapacity = historyInfo[3];
    prefetchRemainingSaves = 10;
    if(retainedSaveCount >= historyCapacity || state.exhausted)
    {
        return false;
    }
    if(state.loading)
    {
        return true;
    }
    if(retainedSaveCount == 0 || backwardsCount < retainedSaveCount - prefetchRemainingSaves ||
       getTime() < state.retryAtMs)
    {
        return false;
    }
    self _startPage(state, oldestSaveNumber);
    return true;
}

// Start one page under level ownership so disconnect cannot strand a read slot.
_startPage(state, cursor)
{
    state.loading = true;
    state.failed = false;
    state.requestID++;
    // Level owns the task: disconnect cannot abandon an occupied read slot.
    level thread _fetchPage(self, state, cursor, state.requestID);
}

// Fetch a bounded page and publish it only to the request that still owns it.
_fetchPage(player, state, cursor, requestID)
{
    maxConcurrentPages = 2;
    pageSaveLimit = 50;
    slotPollSeconds = 0.05;
    while(level.historySavesActive >= maxConcurrentPages)
    {
        if(!isDefined(player) || !player _isHistoryCurrent(state) || state.requestID != requestID)
        {
            if(isDefined(player))
            {
                player _finishPage(state, requestID);
            }
            return;
        }
        wait slotPollSeconds;
    }
    if(!isDefined(player) || !player _isHistoryCurrent(state) || state.requestID != requestID)
    {
        if(isDefined(player))
        {
            player _finishPage(state, requestID);
        }
        return;
    }
    level.historySavesActive++;
    historyInfo = player savePosition_historyInfo();
    retainedSaveCount = historyInfo[0];
    historyCapacity = historyInfo[3];
    requestedSaveCount = historyCapacity - retainedSaveCount;
    if(requestedSaveCount > pageSaveLimit)
    {
        requestedSaveCount = pageSaveLimit;
    }
    if(requestedSaveCount > 0)
    {
        cursorCondition = "";
        if(isDefined(cursor))
        {
            cursorCondition = " AND s.saveNumber<" + cursor;
        }
        query = "SELECT s.saveNumber, s.x, s.y, s.z,"
            + " s.alpha, s.beta, s.gamma,"
            + " s.explosiveJumps, s.doubleExplosives, s.checkpointID,"
            + " s.FPSMode, s.flags, s.entTargetName, s.numOfEnt"
            + " FROM playerSaves s"
            + " JOIN playerRuns r ON r.runID = s.runID"
            + " WHERE r.runID = " + state.runID
            + " AND r.playerID = " + state.owner
            + " AND r.mapID = " + state.map
            + " AND r.instanceNumber = " + state.instance
            + " AND r.archived = 0" + cursorCondition
            + " ORDER BY s.saveNumber DESC"
            + " LIMIT " + requestedSaveCount;
        rows = openCJ\mySQL::mysqlAsyncRead(query);
        if(isDefined(player) && player _isHistoryCurrent(state) && state.requestID == requestID)
        {
            player _restorePage(state, rows, requestedSaveCount);
        }
    }
    // Free the page before another queued reader acquires its slot.
    rows = undefined;
    level.historySavesActive--;
    if(isDefined(player))
    {
        player _finishPage(state, requestID);
    }
}

// Copy a current page into native history without yielding or retaining its SQL rows.
_restorePage(state, rows, requestedSaveCount)
{
    retryDelayMs = 1000;
    historyFullStatus = 1;
    state.failed = !isDefined(rows);
    if(isDefined(rows))
    {
        for(i = 0; i < rows.size; i++)
        {
            restoreStatus = self _restoreOlderRow(rows[i]);
            if(!isDefined(restoreStatus))
            {
                state.failed = true;
                break;
            }
            if(restoreStatus == historyFullStatus)
            {
                break; // New live saves may have filled the cap.
            }
        }
        state.exhausted = rows.size < requestedSaveCount;
    }
    if(state.failed)
    {
        state.retryAtMs = getTime() + retryDelayMs;
    }
}

// Decode one saved-position row; return the native insertion status or undefined.
_restoreOlderRow(row)
{
    expectedFieldCount = 14;
    restoredHeightOffset = 0.01;
    if(row.size != expectedFieldCount || !isDefined(row[0]) || !isDefined(row[1]) ||
       !isDefined(row[2]) || !isDefined(row[3]))
    {
        return undefined;
    }
    origin = (strToPreciseFloat(row[1]), strToPreciseFloat(row[2]),
              strToPreciseFloat(row[3]) + restoredHeightOffset);
    angles = (int(row[4]), int(row[5]), int(row[6]));
    entity = _getEntNum(row[12], intOrUndefined(row[13]));
    explosiveJumps = int(row[7]);
    doubleExplosives = int(row[8]);
    checkpointID = intOrUndefined(row[9]);
    fpsMode = openCJ\fps::FPSModeToInt(row[10]);
    saveFlags = int(row[11]);
    saveNumber = int(row[0]);
    return self savePosition_addOlder(origin, angles, entity, explosiveJumps, doubleExplosives,
                                      checkpointID, fpsMode, saveFlags, saveNumber);
}

_getEntNum(targetName, numOfEnt)
{
    if(!isDefined(targetName) || !isDefined(numOfEnt) || numOfEnt < 0)
    {
        return undefined;
    }
    ents = getEntArray(targetName, "targetname");
    if(isDefined(ents) && isDefined(ents[numOfEnt]))
    {
        return ents[numOfEnt] getEntityNumber();
    }
    return undefined;
}

// Persist a position in run order and report a rejected or uncertain save to its player.
saveToDatabase(origin, angles, entTargetName, numOfEnt, explosiveJumps, doubleExplosives,
               checkpointID, FPSMode, flags)
{
    self openCJ\playerRuns::onProgressStored();
    self endon("disconnect");

    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    if(self openCJ\playerRuns::isRunFinished())
    {
        return;
    }
    if(!self openCJ\playerRuns::hasRunID())
    {
        return;
    }
    if(self openCJ\cheating::isCheating())
    {
        return;
    }

    runID = self openCJ\playerRuns::getRunID();
    timePlayed = self openCJ\playTime::getTimePlayed();
    saveCount = self openCJ\statistics::getSaveCount();
    loadCount = self openCJ\statistics::getLoadCount();
    explosiveLaunches = self openCJ\statistics::getExplosiveLaunches();

    runInstance = self openCJ\playerRuns::getRunInstanceNumber();
    if(!isDefined(entTargetName))
    {
        entTargetName = "NULL";
    }
    else
    {
        entTargetName = "'" + openCJ\mySQL::escapeString(entTargetName) + "'";
    }
    if(!isDefined(numOfEnt))
    {
        numOfEnt = "NULL";
    }
    if(!isDefined(checkpointID))
    {
        checkpointID = "NULL";
    }
    x = preciseFloatToStr(origin[0]);
    y = preciseFloatToStr(origin[1]);
    z = preciseFloatToStr(origin[2]);

    alpha = int(angles[0]);
    beta = int(angles[1]);
    gamma = int(angles[2]);
    FPSMode = "'" + FPSMode + "'";

    query = "SELECT savePosition("
        + runID + ", " + runInstance + ", "
        + x + ", " + y + ", " + z + ", "
        + alpha + ", " + beta + ", " + gamma + ", "
        + timePlayed + ", " + saveCount + ", " + loadCount + ", "
        + explosiveLaunches + ", " + explosiveJumps + ", " + doubleExplosives + ", "
        + checkpointID + ", " + FPSMode + ", " + flags + ", "
        + entTargetName + ", " + numOfEnt + ")";

    rows = openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
    message = self openCJ\runStorage::resultMessage(runID, runInstance, rows, "this position");
    if(message != "")
    {
        self iPrintLnBold(message);
    }
}
