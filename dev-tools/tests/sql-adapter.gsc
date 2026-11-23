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
