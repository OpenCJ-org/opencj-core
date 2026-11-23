// Exercise production cancellation and structured outcomes in the isolated VM.
run(player, otherPlayer)
{
    player.sqlRendered = 0;
    player.sqlNewest = 0;
    player thread render("old", 0.3);
    wait 0.10;
    player thread render("new", 0.01);
    wait 0.5;
    check(player.sqlRendered == 1 && player.sqlNewest == 1,
          "new menu request cancels stale callback");

    player.sqlRendered = 0;
    player thread render("closed", 0.3);
    wait 0.10;
    player openCJ\mySQL::cancelMenuReads();
    wait 0.4;
    check(player.sqlRendered == 0, "closing menu prevents late render");

    player.sqlRendered = 0;
    player thread render("old-menu", 0.3);
    wait 0.10;
    player thread render("new", 0.1, "clips");
    wait 0.08;
    player openCJ\mySQL::cancelMenuReads("opencj_leaderboard");
    wait 0.4;
    check(player.sqlRendered == 1, "late close of old menu does not cancel the new menu");

    player.sqlRendered = 0;
    player thread render("disconnect", 0.3);
    wait 0.10;
    // This is the production hook used immediately before disconnect.
    player openCJ\mySQL::cancelMenuReads();
    player notify("disconnect");
    wait 0.4;
    check(player.sqlRendered == 0, "disconnect prevents stale menu callback");

    result = openCJ\mySQL::_request("SELECT * FROM no_adapter_fixture",
                                  1, "", "", 10000, true);
    check(result.status == 1 && !isDefined(result.rows) && result.error != 0,
          "GSC receives explicit SQL failure metadata");
    result = openCJ\mySQL::_request("SELECT 1", 1, "", "", 10000, true);
    check(result.status == 0 && result.rows[0][0] == "1",
          "GSC receives successful rowset and outcome");
    longQueryBuilderChecks();
    clipSessionChecks();
    clipPublicationChecks(player);
    shopMenuChecks(player);
    shopEquipmentChecks(player);
    demoTransferChecks();
    stats = mysql_async_stats();
    check(stats[0] == 4 && stats[4] == 0, "four workers and no uncollected GSC jobs");
}

// Query completion may arrive after a newer request, close, or disconnect.
render(label, delay, menu)
{
    if(!isDefined(menu))
    {
        menu = "board";
    }
    token = self openCJ\mySQL::beginMenuRead(menu);
    if(!self openCJ\mySQL::menuReadCurrent(token))
    {
        return;
    }
    rows = self openCJ\mySQL::mysqlAsyncMenuQuery("SELECT SLEEP(" + delay + "),1", menu);
    if(!isDefined(rows))
    {
        return;
    }
    self.sqlRendered++;
    if(label == "new")
    {
        self.sqlNewest = 1;
    }
}

check(value, label)
{
    openCJ\history192Test::check(value, label);
}

// A failed append must never submit a partial query through the legacy builder API.
longQueryBuilderChecks()
{
    builder = mysql_setup_longquery();
    check(builder > 0, "long-query builder allocated");
    if(builder <= 0)
    {
        return;
    }
    check(mysql_append_longquery(builder, "SELECT "),
          "long-query builder accepts a first fragment");
    check(mysql_append_longquery(builder, "7, NULL"),
          "long-query builder accepts a second fragment");
    rows = openCJ\mySQL::mysqlAsyncLongQueryExecuteSave(builder);
    check(isDefined(rows) && rows.size == 1 && rows[0][0] == "7"
          && !isDefined(rows[0][1]), "long-query execution preserves values and SQL NULL");

    builder = mysql_setup_longquery();
    check(builder > 0 && mysql_free_longquery(builder),
          "unused long-query builder can be released");

    builder = mysql_setup_longquery();
    check(builder > 0, "limit-test builder allocated");
    if(builder <= 0)
    {
        return;
    }
    // The production query limit is 10 KiB. Small fragments stay within GSC strings.
    queryLimitBytes = 10 * 1024;
    fragment = "0123456789";
    acceptedAll = true;
    for(offset = 0; offset < queryLimitBytes - 10; offset += 10)
    {
        if(!mysql_append_longquery(builder, fragment))
        {
            acceptedAll = false;
        }
    }
    check(acceptedAll, "long-query builder accepts fragments below its limit");
    rejected = false;
    for(attempt = 0; attempt < 3; attempt++)
    {
        if(!mysql_append_longquery(builder, fragment))
        {
            rejected = true;
        }
    }
    check(rejected, "long-query builder rejects overflow");
    check(!isDefined(mysql_async_execute_longquery(builder, true)),
          "overflowed builder is consumed without submitting partial SQL");
}

// Use the disposable fixture's synthetic owner/map. No live recording is read.
demoTransferChecks()
{
    clipId = 192001;
    frameCount = 130;
    chunkFrames = 64;
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO demoClips(clipID,uploadToken,mapID,playerID,description,scopeKey,slot,"
        + "originX,originY,originZ,frameCount) VALUES("
        + clipId + ",'native-fixture',1,1,'Native test','native-fixture',1,0,0,100,"
        + frameCount + ")");

    sourceId = demoCreateTransient();
    for(frameIndex = 0; frameIndex < frameCount; frameIndex++)
    {
        addFrameToDemo(sourceId, (frameIndex, 0, 100), (0, 90, 0),
                       1, 0, 0, 0, 0, 333);
    }
    completeDemo(sourceId);
    check(demoPin(sourceId), "native upload retains its source");
    destroyDemo(sourceId);
    chunkIndex = 0;
    for(firstFrame = 0; firstFrame < frameCount; firstFrame += chunkFrames)
    {
        count = frameCount - firstFrame;
        if(count > chunkFrames)
        {
            count = chunkFrames;
        }
        receipt = openCJ\mySQL::awaitNative(
            demoUploadChunk(sourceId, clipId, 1, firstFrame, count, chunkIndex));
        check(isDefined(receipt), "native upload stores chunk " + chunkIndex);
        chunkIndex++;
    }
    demoUnpin(sourceId);
    check(!isDefined(numberOfDemoFrames(sourceId)),
          "upload releases a source whose playback owner closed");

    targetId = demoCreateTransient();
    receipt = openCJ\mySQL::awaitNative(demoLoadChunks(targetId, clipId, 1, 0));
    check(isDefined(receipt) && receipt[0][0] == chunkIndex
          && numberOfDemoFrames(targetId) == frameCount,
          "native download reconstructs all chunk frames");
    destroyDemo(targetId);

    // The old request must neither append to a reused ID nor leave its waiter stuck.
    targetId = 192002;
    createDemo(targetId);
    job = demoLoadChunks(targetId, clipId, 1, 0);
    destroyDemo(targetId);
    createDemo(targetId);
    receipt = openCJ\mySQL::awaitNative(job);
    check(!isDefined(receipt) && numberOfDemoFrames(targetId) == 0,
          "cancelled load cannot mutate a reused native ID");
    destroyDemo(targetId);

    targetId = demoCreateTransient();
    job = demoLoadChunks(targetId, clipId, 1, 0);
    mysql_async_newmap();
    wait 0.5;
    stats = mysql_async_stats();
    check(stats[4] == 0 && numberOfDemoFrames(targetId) == 0,
          "map teardown releases obsolete native reads");
    destroyDemo(targetId);

    openCJ\mySQL::mysqlSyncQuery(
        "UPDATE demoClipChunks SET payload=UNHEX('00') WHERE clipID="
        + clipId + " AND chunkNum=0");
    targetId = demoCreateTransient();
    receipt = openCJ\mySQL::awaitNative(demoLoadChunks(targetId, clipId, 1, 0));
    check(!isDefined(receipt) && numberOfDemoFrames(targetId) == 0,
          "corrupt binary payload leaves the recording empty");
    destroyDemo(targetId);

    openCJ\mySQL::mysqlSyncQuery(
        "DELETE FROM demoClipChunks WHERE clipID=" + clipId + " AND chunkNum=0");
    targetId = demoCreateTransient();
    receipt = openCJ\mySQL::awaitNative(demoLoadChunks(targetId, clipId, 1, 0));
    check(!isDefined(receipt) && numberOfDemoFrames(targetId) == 0,
          "missing first chunk rejects an out-of-order batch");
    destroyDemo(targetId);
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoClips WHERE clipID=" + clipId);
}

// The harness performs a real map change after both requests are admitted.
queueForMapChange()
{
    openCJ\mySQL::mysqlSyncQuery("CREATE TABLE adapter_map_probe(id INT) ENGINE=InnoDB");
    writeJob = mysql_async_submit(
        "INSERT INTO adapter_map_probe SELECT 1 FROM (SELECT SLEEP(1)) a",
        0, "run:map", "", 10000, 1);
    menuJob = mysql_async_submit("SELECT SLEEP(1),1", 3, "", "p:99:board", 10000, 1);
    check(writeJob > 0 && menuJob > 0, "map-change fixtures admitted before transition");
    stats = mysql_async_stats();
    setCvar("sql_adapter_accepted", stats[8]);
    setCvar("sql_adapter_checks", level.history192Checks);
    setCvar("sql_adapter_failures", level.history192Failures);
    setCvar("sql_adapter_stage", 1);
    printf("SQLPOOL_MAP_READY\n");
    level waittill("sql_adapter_unreachable");
}

// Verify the old map's accepted write completed and its disposable reads were released.
afterMap()
{
    level.history192Checks = int(getCvar("sql_adapter_checks"));
    level.history192Failures = int(getCvar("sql_adapter_failures"));
    openCJ\mySQL::onInit();
    stored = false;
    for(attempt = 0; attempt < 60; attempt++)
    {
        rows = openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM adapter_map_probe");
        if(isDefined(rows) && int(rows[0][0]) == 1)
        {
            stored = true;
            break;
        }
        wait 0.05;
    }
    check(stored, "accepted write persists through an actual engine map change");
    wait 1.1;
    stats = mysql_async_stats();
    check(stats[0] == 4 && stats[8] >= int(getCvar("sql_adapter_accepted")),
          "actual map change preserves permanent worker pool");
    check(stats[4] == 0, "old-map requests/results cleaned after actual map change");
    openCJ\history192Test::finish();
}


// Session identities must be committed before clip storage is reported as available.
clipSessionChecks()
{
    previousViewSession = getCvar("opencj_clip_view_session");
    setCvar("opencj_clip_view_session", "");
    registered = openCJ\clips::initializeSessions();
    check(registered, "clip initialization registers map and view sessions");
    if(!registered)
    {
        setCvar("opencj_clip_view_session", previousViewSession);
        return;
    }
    rows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT COUNT(*) FROM demoClipSessions WHERE sessionID IN ('"
        + level.clipSession + "','" + level.clipViewSession + "')");
    check(isDefined(rows) && int(rows[0][0]) == 2,
          "both clip sessions exist before use");
    check(getCvar("opencj_clip_view_session") == level.clipViewSession,
          "registered view session survives map changes");
    openCJ\mySQL::mysqlSyncQuery(
        "DELETE FROM demoClipSessions WHERE sessionID IN ('"
        + level.clipSession + "','" + level.clipViewSession + "')");
    setCvar("opencj_clip_view_session", previousViewSession);
}


// Exercise production slot reservation, chunk upload, publication, and browser decoding together.
clipPublicationChecks(player)
{
    nativeID = demoCreateTransient();
    for(frameIndex = 0; frameIndex < 65; frameIndex++)
    {
        addFrameToDemo(nativeID, (frameIndex, 0, 100), (0, 90, 0), 1, 8192, 0, 0, 0, 333);
    }
    completeDemo(nativeID);
    recording = spawnStruct();
    recording.id = nativeID;
    recording.first = 0;
    recording.last = 64;
    recording.busy = false;
    recording.permanent = true;
    recording.date = openCJ\clips::readDatabaseValue("SELECT NOW()");
    player.clipEdit = recording;
    player.playingDemo = false;
    level.mapid_mapID = 1;
    player openCJ\clips::submit("Publication fixture");
    check(!isDefined(player.clipUploadNative) && !isDefined(player.clipUploadToken),
          "successful clip publication releases upload ownership");
    rows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT clipID,frameCount FROM demoClips"
        + " WHERE playerID=1 AND description='Publication fixture' AND ready=1");
    published = isDefined(rows) && rows.size == 1;
    check(published, "complete clip is visible after publication");
    if(published)
    {
        clipID = int(rows[0][0]);
        check(int(rows[0][1]) == 65, "published clip retains the selected frame count");
        chunks = openCJ\mySQL::mysqlSyncQuery(
            "SELECT COUNT(*) FROM demoClipChunks WHERE clipID=" + clipID);
        check(isDefined(chunks) && int(chunks[0][0]) == 2,
              "65-frame clip uploads two bounded chunks");
        level.clipStorageReady = true;
        player.clipPage = 0;
        player.clipTab = "permanent";
        player openCJ\clips::browser();
        check(isDefined(player.clipRows) && player.clipRows.size == 1
              && player.clipRows[0].id == clipID && player.clipRows[0].frameCount == 65,
              "clip browser exposes the published recording and decoded metadata");
        openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoClips WHERE clipID=" + clipID);
    }
    player.clipEdit = undefined;
    destroyDemo(nativeID);
    check(!isDefined(numberOfDemoFrames(nativeID)),
          "published clip leaves no native upload pin behind");
}

// Hold a real completed query so menu replacement races are deterministic.
shopMenuChecks(player)
{
    check(!openCJ\menus\helper::opensAnotherMenu("opencj_shop", "open"),
          "shop open leaves cancellation to its own read scope");
    level.challengesReady = true;
    level.shopItems = [];
    item = spawnStruct();
    item.key = "pistol.fixture";
    item.category = 1;
    item.slot = "deserteagle_mp";
    item.name = "Fixture pistol";
    item.image = "weapon_desert_eagle";
    item.price = 9999;
    item.available = false;
    level.shopItems[0] = item;

    player verifyObsoleteShopRead(false);
    player verifyObsoleteShopRead(true);
    player.shopRows = [];
    player openCJ\shop::show();
    check(player.shopRows.size == 1 && player.shopRows[0].key == item.key,
          "current shop read renders the requested catalogue");
    check(player.scoreboardCache["ocj_shop_balance"] == "0 points available",
          "current shop read decodes an empty purchase balance");
    player openCJ\mySQL::cancelMenuReads();
}

// A close or another browser must prevent both rendering and the next SQL read.
verifyObsoleteShopRead(openAnotherMenu)
{
    self.shopTab = 1;
    self.shopRows = [];
    previousRow = spawnStruct();
    previousRow.key = "previous";
    self.shopRows[0] = previousRow;
    level.history192ShopOwnershipReads = 0;
    level.history192DelayedQuery = "COALESCE(SUM(pointsAwarded),0) FROM challengeCompletions";
    level.history192HoldReply = true;

    self thread openCJ\shop::show();
    self waittill("history192_result_ready");
    if(openAnotherMenu)
    {
        self openCJ\mySQL::beginMenuRead("board");
        scenario = "another browser replaces the shop";
    }
    else
    {
        self openCJ\mySQL::cancelMenuReads("opencj_shop");
        scenario = "shop read scope closes";
    }
    level.history192DelayedQuery = undefined;
    level.history192HoldReply = false;
    self notify("history192_release_result");
    wait 0.2;

    check(self.shopRows.size == 1 && self.shopRows[0].key == "previous",
          scenario + ": late result cannot replace rows");
    check(level.history192ShopOwnershipReads == 0,
          scenario + ": obsolete request starts no ownership read");
    self openCJ\mySQL::cancelMenuReads();
}

// Two reads can overlap while login, respawn, or a purchase refresh waits for SQL.
shopEquipmentChecks(player)
{
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO shopCatalog(itemKey,category,slot,price,available)"
        + " VALUES('pistol.equipment-fixture',1,'deserteagle_mp',0,0)");
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO shopPurchases(playerID,itemKey,pointsSpent)"
        + " VALUES(1,'pistol.equipment-fixture',0)");
    player.shopLoaded = false;
    player.shopEquipped = [];
    player.shopTestLoadResult = undefined;
    level.history192DelayedQuery = "SELECT 'ready','ready' UNION ALL";
    level.history192HoldReply = true;

    player thread readEquipmentForTest();
    player waittill("history192_result_ready");
    // The old result is already empty. Change storage, then finish a newer read first.
    level.history192DelayedQuery = undefined;
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO shopEquipped(playerID,slot,itemKey)"
        + " VALUES(1,'deserteagle_mp','pistol.equipment-fixture')");
    loaded = player openCJ\shop::loadEquipment();
    check(loaded && player.shopEquipped["deserteagle_mp"] == "pistol.equipment-fixture",
          "newer equipment read installs the current selection");
    player notify("history192_release_result");
    wait 0.1;
    check(isDefined(player.shopTestLoadResult) && !player.shopTestLoadResult,
          "superseded equipment read reports no usable result");
    check(isDefined(player.shopEquipped["deserteagle_mp"]) &&
          player.shopEquipped["deserteagle_mp"] == "pistol.equipment-fixture",
          "old equipment reply cannot erase a newer selection");

    player.shopLoaded = false;
    player.shopTestLoadResult = undefined;
    level.history192DelayedQuery = "SELECT 'ready','ready' UNION ALL";
    player thread readEquipmentForTest();
    player waittill("history192_result_ready");
    player.login_playerID = 2;
    player.shopEquipped = [];
    player.shopEquipped["deserteagle_mp"] = "replacement-account";
    level.history192DelayedQuery = undefined;
    player notify("history192_release_result");
    wait 0.1;
    check(isDefined(player.shopTestLoadResult) && !player.shopTestLoadResult,
          "equipment reply from the previous account is rejected");
    check(player.shopEquipped["deserteagle_mp"] == "replacement-account",
          "previous account's equipment cannot replace current account state");

    player.login_playerID = 1;
    player.shopLoaded = false;
    player.shopTestLoadResult = undefined;
    level.history192DelayedQuery = "SELECT 'ready','ready' UNION ALL";
    player thread readEquipmentForTest();
    player waittill("history192_result_ready");
    player openCJ\mySQL::cancelMenuReads();
    level.history192DelayedQuery = undefined;
    player notify("history192_release_result");
    wait 0.1;
    check(isDefined(player.shopTestLoadResult) && player.shopTestLoadResult,
          "closing menus leaves needed equipment loading active");

    player.shopLoaded = false;
    player.shopTestLoadResult = undefined;
    level.history192DelayedQuery = "SELECT 'ready','ready' UNION ALL";
    player thread readEquipmentForTest();
    player waittill("history192_result_ready");
    player openCJ\shop::cancelEquipmentRead();
    level.history192DelayedQuery = undefined;
    player notify("history192_release_result");
    wait 0.1;
    check(isDefined(player.shopTestLoadResult) && !player.shopTestLoadResult && !player.shopLoaded,
          "disconnect cancellation rejects an equipment reply already in delivery");

    player.shopLoaded = false;
    player.shopEquipped = [];
    level.history192HoldReply = false;
    player verifyQueuedEquipmentCancellation();
    openCJ\mySQL::mysqlSyncQuery(
        "DELETE FROM shopEquipped WHERE itemKey='pistol.equipment-fixture'");
    openCJ\mySQL::mysqlSyncQuery(
        "DELETE FROM shopPurchases WHERE itemKey='pistol.equipment-fixture'");
    openCJ\mySQL::mysqlSyncQuery(
        "DELETE FROM shopCatalog WHERE itemKey='pistol.equipment-fixture'");
}

readEquipmentForTest()
{
    self.shopTestLoadResult = self openCJ\shop::loadEquipment();
}

// Occupy the four pool workers so the equipment request is still queued at cancellation.
verifyQueuedEquipmentCancellation()
{
    workerCount = 4;
    level.shopEquipmentBlockersDone = 0;
    for(i = 0; i < workerCount; i++)
    {
        job = mysql_async_submit("SELECT SLEEP(0.5)", level.sqlConstants.policyRead,
                                 "", "", level.sqlConstants.defaultQueueWaitMs, true);
        check(isDefined(job) && job > 0, "equipment cancellation blocker admitted");
        thread awaitEquipmentBlocker(job);
    }
    wait 0.05;
    self.shopLoaded = false;
    self.shopTestLoadResult = undefined;
    self thread readEquipmentForTest();
    wait 0.05;
    self openCJ\shop::cancelEquipmentRead();
    wait 0.1;
    check(isDefined(self.shopTestLoadResult) && !self.shopTestLoadResult,
          "queued equipment cancellation wakes its caller before workers become available");

    for(attempt = 0; attempt < 30 && level.shopEquipmentBlockersDone < workerCount; attempt++)
    {
        wait 0.05;
    }
    check(level.shopEquipmentBlockersDone == workerCount,
          "equipment cancellation releases all unrelated blocker completions");
}

awaitEquipmentBlocker(job)
{
    openCJ\mySQL::awaitNative(job);
    level.shopEquipmentBlockersDone++;
}
