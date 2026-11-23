#include openCJ\util;
main()
{
    level.history175Checks = 0;
    level.history175Failures = 0;
    level.history175Queries = 0;
    level.history175Peak = 0;
    level.history175ClientCount = 32;
    level.history175Limit = 100;
    level.history175PageSize = 50;
    level.history175FirstRunID = 1001;
    level.history175NewestSave = 160;
    level.history175MissingPeriod = 17;
    level.history175Fields = spawnStruct();
    level.history175Fields.count = 0;
    level.history175Fields.oldest = 1;
    level.history175Fields.generation = 2;
    level.history175Fields.newest = 4;
    expectedDatabase = getCvar("history175_database");
    fixtureDatabasePrefix = "opencj_verify_history_";
    if(getSubStr(expectedDatabase, 0, fixtureDatabasePrefix.size) != fixtureDatabasePrefix)
    {
        return;
    }
    openCJ\mySQL::onInit();
    openCJ\historySave::onInit();
    openCJ\savePosition::onInit();
    level.mapid_mapID = 1;
    level.checkpointLayoutEpoch = 1;
    level.clients = [];
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT DATABASE()");
    isFixtureDatabase = isDefined(rows) && rows.size == 1 && rows[0][0] == expectedDatabase;
    check(isFixtureDatabase, "disposable database");
    if(!isFixtureDatabase)
    {
        finish();
        return;
    }
    wait 1;
    for(i = 0; i < level.history175ClientCount; i++)
    {
        player = addTestClient();
        check(isDefined(player), "client " + i);
        if(!isDefined(player))
        {
            finish();
            return;
        }
        level.clients[i] = player;
        wait .05;
        player.sessionTeam = "allies";
        player.sessionState = "playing";
        player.pers["team"] = "allies";
        player spawn((i * 30, 0, 700), (0, 0, 0));
        player freezeControls(true);
        player.login_playerID = i + 1;
        player.playingDemo = false;
        player openCJ\playerRuns::setRunIDAndInstanceNumber(level.history175FirstRunID + i, 1);
        player openCJ\savePosition::resetBackwardsCount();
        player savePosition_initClient();
    }
    firstPlayer = level.clients[0];
    secondPlayer = level.clients[1];
    firstPlayer verifyNativeHistory(secondPlayer);
    memoryAudit("baseline", level);
    level.history175Pending = level.history175ClientCount;
    for(i = 0; i < level.history175ClientCount; i++)
    {
        level.clients[i] thread loadInitial(level.history175FirstRunID + i);
    }
    waitForInitialLoads();
    for(i = 0; i < level.history175ClientCount; i++)
    {
        player = level.clients[i];
        historyInfo = player savePosition_historyInfo();
        check(historyInfo[level.history175Fields.count] == level.history175PageSize,
              "initial page " + i);
        check(player savePosition_selectSave(0) == 0 && player savePosition_getSaveNum() == 160,
              "actual newest save number " + i);
        check(player savePosition_selectSave(49) == 0 &&
                  player savePosition_getSaveNum() == saveNumberAt(49),
              "gaps preserve oldest number " + i);
        origin = player savePosition_getOrigin();
        check(origin[0] == saveNumberAt(49), "saved coordinates " + i);
        player thread requestOlderPageRepeatedly();
    }
    waitForOlderPages();
    for(i = 0; i < level.history175ClientCount; i++)
    {
        player = level.clients[i];
        historyInfo = player savePosition_historyInfo();
        check(historyInfo[level.history175Fields.count] == level.history175Limit &&
                  historyInfo[level.history175Fields.oldest] == saveNumberAt(99),
              "bounded full history " + i);
        check(player savePosition_selectSave(99) == 0 &&
                  player savePosition_getSaveNum() == saveNumberAt(99),
              "oldest reachable " + i);
        check(!player openCJ\historySave::maybePrefetch(99), "no fetch past cap " + i);
        check(player openCJ\savePosition::canLoadError(100) == 2,
              "cap is visible to controls " + i);
    }
    check(level.history175Peak <= 2, "at most two retained SQL pages");
    check(level.history175Queries == 64, "one initial and one older query per client");
    memoryAudit("loaded", level);
    firstPlayer verifyRacesAndFailures();
    for(i = 0; i < level.history175ClientCount; i++)
    {
        level.clients[i] savePosition_initClient();
    }
    memoryAudit("released", level);
    check(level.historySavesActive == 0, "all read slots released");
    finish();
}
check(passed, message)
{
    level.history175Checks++;
    if(!isDefined(passed) || !passed)
    {
        level.history175Failures++;
        printf("H175 FAILURE " + message + "\n");
    }
}
finish()
{
    printf("H175 COMPLETE failures=" + level.history175Failures +
           " checks=" + level.history175Checks + " peak=" + level.history175Peak +
           " queries=" + level.history175Queries + "\n");
}
// The synthetic SQL intentionally omits every seventeenth save.
saveNumberAt(index)
{
    eligibleCount = 0;
    for(saveNumber = level.history175NewestSave; saveNumber >= 1; saveNumber--)
    {
        if(saveNumber % level.history175MissingPeriod == 0)
        {
            continue;
        }
        if(eligibleCount == index)
        {
            return saveNumber;
        }
        eligibleCount++;
    }
    return -1;
}
loadInitial(runID)
{
    self savePosition_initClient();
    passed = self openCJ\historySave::_loadSavesFromDatabase(runID, 1);
    check(passed, "initial SQL/native restore " + runID);
    level.history175Pending--;
}
waitForInitialLoads()
{
    pollLimit = 200;
    pollIntervalSeconds = 0.05;
    for(i = 0; i < pollLimit && level.history175Pending > 0; i++)
    {
        wait pollIntervalSeconds;
    }
    check(level.history175Pending == 0, "initial requests complete");
}
requestOlderPageRepeatedly()
{
    for(j = 0; j < 10; j++)
    {
        self openCJ\historySave::maybePrefetch(40);
    }
}
waitForOlderPages()
{
    pollLimit = 200;
    pollIntervalSeconds = 0.05;
    for(k = 0; k < pollLimit; k++)
    {
        pendingPages = level.historySavesActive;
        for(j = 0; j < level.clients.size; j++)
        {
            if(isDefined(level.clients[j].historySaves) && level.clients[j].historySaves.loading)
            {
                pendingPages++;
            }
        }
        if(pendingPages == 0)
        {
            return;
        }
        wait pollIntervalSeconds;
    }
    check(false, "page requests complete");
}
// Test native eviction, selection invalidation and ordering without SQL.
verifyNativeHistory(other)
{
    for(saveNumber = 1; saveNumber <= 140; saveNumber++)
    {
        self savePosition_save((saveNumber, 0, 700), (0, 0, 0), undefined, 0, 0, 1, 5, 0,
                               saveNumber);
    }
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == level.history175Limit &&
              historyInfo[level.history175Fields.oldest] == 41 &&
              historyInfo[level.history175Fields.newest] == 140,
          "live saves evict oldest at 100");
    self savePosition_selectSave(99);
    self savePosition_save((141, 0, 700), (0, 0, 0), undefined, 0, 0, 1, 5, 0, 141);
    check(!isDefined(self savePosition_getSaveNum()), "evicted selection invalidated safely");
    check(self savePosition_addOlder((0, 0, 0), (0, 0, 0), undefined, 0, 0, 1, 5, 0, 40) == 1,
          "older insertion cannot exceed cap");
    check(self savePosition_selectSave(-1) == 2, "negative history index rejected");
    other savePosition_selectWithoutFlag(1, self getEntityNumber());
    self savePosition_initClient();
    check(!isDefined(other savePosition_getOrigin()), "cross-player selection cleared on release");
    clearedHistory = self savePosition_historyInfo();
    check(clearedHistory[level.history175Fields.generation] !=
              historyInfo[level.history175Fields.generation],
          "clear advances history generation");
    self savePosition_addOlder((200, 0, 0), (0, 0, 0), undefined, 0, 0, 1, 5, 0, 200);
    self savePosition_selectSave(0);
    self savePosition_addOlder((199, 0, 0), (0, 0, 0), undefined, 0, 0, 1, 5, 0, 199);
    check(self savePosition_getSaveNum() == 200, "older append preserves selection");
    check(self savePosition_addOlder((199, 0, 0), (0, 0, 0), undefined, 0, 0, 1, 5, 0, 199) == 2,
          "duplicate older insertion rejected");
    check(self savePosition_addOlder((201, 0, 0), (0, 0, 0), undefined, 0, 0, 1, 5, 0, 201) == 2,
          "newer insertion rejected at older end");
    self savePosition_initClient();
}
reloadInitialHistory()
{
    self openCJ\historySave::cancelPendingPage();
    self savePosition_initClient();
    self.playingDemo = false;
    self.cpc = undefined;
    level.checkpointLayoutEpoch = 1;
    self openCJ\playerRuns::setRunIDAndInstanceNumber(1001, 1);
    check(self openCJ\historySave::_loadSavesFromDatabase(1001, 1), "reset initial fixture");
}
verifyRacesAndFailures()
{
    self verifyInitialLoadLocks();
    self verifyCancelledQueuedPage();
    self verifyNewSavesDuringFetch();
    self verifyDisconnectDuringFetch();
    self verifyChangedRunInstance();
    self verifyChangedLayout();
    self verifyModeCancellation();
    self verifyOlderPageRetry();
    self verifyInitialPageFailure();
    self verifyExhaustedPages();
    self verifyPendingNavigation();
}

verifyInitialLoadLocks()
{
    self reloadInitialHistory();
    // While initial SQL is pending, neither a new save nor a load may mix runs.
    self savePosition_initClient();
    level.history175DelayOwner = 1;
    level.history175Pending = 1;
    self thread loadInitial(1001);
    self waittill("history175_result_ready");
    check(self openCJ\savePosition::canSaveError() == 4, "initial restore blocks new saves");
    check(self openCJ\savePosition::canLoadError(0) == 3, "initial restore blocks position loads");
    waitForInitialLoads();
    level.history175DelayOwner = undefined;
}

verifyCancelledQueuedPage()
{
    // Hold both read slots, invalidate the queued request, then release them.
    self reloadInitialHistory();
    level.historySavesActive = 2;
    queriesBefore = level.history175Queries;
    self openCJ\historySave::maybePrefetch(40);
    self savePosition_initClient();
    wait .1;
    check(!self.historySaves.loading && level.history175Queries == queriesBefore,
          "stale queued request stops without querying");
    level.historySavesActive = 0;
}

verifyNewSavesDuringFetch()
{
    self reloadInitialHistory();
    level.history175DelayOwner = 1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    for(saveNumber = 161; saveNumber <= 180; saveNumber++)
    {
        self savePosition_save((saveNumber, 0, 700), (0, 0, 0), undefined, 0, 0, 1, 5, 0,
                               saveNumber);
    }
    waitForOlderPages();
    level.history175DelayOwner = undefined;
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == level.history175Limit &&
              historyInfo[level.history175Fields.newest] == 180 &&
              historyInfo[level.history175Fields.oldest] == saveNumberAt(79),
          "new saves during fetch preserve cap and chronology");
}

verifyDisconnectDuringFetch()
{
    self reloadInitialHistory();
    level.history175DelayOwner = 1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self notify("disconnect");
    self savePosition_initClient();
    self savePosition_save((999, 0, 700), (0, 0, 0), undefined, 0, 0, 1, 5, 0, 999);
    waitForOlderPages();
    level.history175DelayOwner = undefined;
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == 1 &&
              historyInfo[level.history175Fields.newest] == 999,
          "stale page rejected after native reset/disconnect notification");
}

verifyChangedRunInstance()
{
    self reloadInitialHistory();
    level.history175DelayOwner = 1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self.runInstanceNumber = 2;
    waitForOlderPages();
    level.history175DelayOwner = undefined;
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == level.history175PageSize,
          "stale run-instance page rejected");
}

verifyChangedLayout()
{
    self reloadInitialHistory();
    level.history175DelayOwner = 1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    level.checkpointLayoutEpoch++;
    waitForOlderPages();
    level.history175DelayOwner = undefined;
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == level.history175PageSize,
          "stale layout page rejected");
}

verifyModeCancellation()
{
    self reloadInitialHistory();
    level.history175DelayOwner = 1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self openCJ\historySave::cancelPendingPage();
    self.playingDemo = true;
    self.playingDemo = false;
    wait .3;
    level.history175DelayOwner = undefined;
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == level.history175PageSize,
          "mode cancellation rejects reply even after returning");
}

verifyOlderPageRetry()
{
    self reloadInitialHistory();
    level.history175FailOwner = 1;
    self openCJ\historySave::maybePrefetch(40);
    waitForOlderPages();
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == level.history175PageSize &&
              self.historySaves.failed,
          "failed page preserves loaded history");
    check(!self openCJ\historySave::maybePrefetch(40), "failed page has retry delay");
    level.history175FailOwner = undefined;
    wait 1.05;
    self openCJ\historySave::maybePrefetch(40);
    waitForOlderPages();
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == level.history175Limit &&
              !self.historySaves.failed,
          "failed page can retry without duplicates");
}

verifyInitialPageFailure()
{
    self savePosition_initClient();
    level.history175FailOwner = 1;
    check(!self openCJ\historySave::_loadSavesFromDatabase(1001, 1),
          "initial page failure reported");
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == 0 && !isDefined(self.historySaves),
          "initial page failure clears state");
    level.history175FailOwner = undefined;
}

verifyExhaustedPages()
{
    self savePosition_initClient();
    state = self openCJ\historySave::_beginHistory(1001, 1);
    state.initial = false;
    self openCJ\historySave::_startPage(state, 11);
    waitForOlderPages();
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == 10 &&
              historyInfo[level.history175Fields.oldest] == 1 && state.exhausted,
          "short last page stops prefetch");
    check(!self openCJ\historySave::maybePrefetch(9), "exhausted history does not query again");

    self savePosition_initClient();
    state = self openCJ\historySave::_beginHistory(1001, 1);
    state.initial = false;
    self openCJ\historySave::_startPage(state, 1);
    waitForOlderPages();
    historyInfo = self savePosition_historyInfo();
    check(historyInfo[level.history175Fields.count] == 0 && state.exhausted,
          "empty history stops prefetch");
}

verifyPendingNavigation()
{
    self reloadInitialHistory();
    level.history175DelayOwner = 1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self.savePosition_backwardsCount = 50;
    check(self openCJ\savePosition::canLoadError(50) == 3, "unloaded boundary reports loading");
    self openCJ\savePosition::printCanLoadError(3);
    check(self openCJ\savePosition::getBackwardsCount() == 49,
          "pending boundary does not skip a position");
    self setOrigin((321, 123, 700));
    waitForOlderPages();
    level.history175DelayOwner = undefined;
    check(self.origin[0] == 321 && self.origin[1] == 123, "late page never teleports player");
    self.savePosition_backwardsCount = 100;
    self openCJ\savePosition::printCanLoadError(2);
    check(self openCJ\savePosition::getBackwardsCount() == 99, "cap keeps navigation bounded");
}
