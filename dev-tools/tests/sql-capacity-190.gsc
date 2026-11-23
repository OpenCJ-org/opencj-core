// Isolated 32-client benchmark. No production database or account callbacks.
main()
{
    if(!initializeFixture())
    {
        finish();
        return;
    }
    if(!createPlayersAndRecordings())
    {
        finish();
        return;
    }
    if(!clipTransfers())
    {
        finish();
        return;
    }
    if(!phase("record32", level.capClientCount, false, false))
    {
        finish();
        return;
    }
    if(!phase("mixed16", 16, false, false))
    {
        finish();
        return;
    }
    if(!fillRecordingBuffers())
    {
        finish();
        return;
    }
    if(!phase("finish32_watch32", 0, false, true))
    {
        finish();
        return;
    }
    if(!phase("shared32", 0, true, false))
    {
        finish();
        return;
    }
    verifyStoredResults();
    finish();
}

// Initialize only the features exercised here, after validating the disposable database.
initializeFixture()
{
    level.capPhase = 0;
    level.capStage = "setup";
    level.capFailures = 0;
    level.capChecks = 0;
    level.capPending = 0;
    level.capClientCount = 32;
    level.capTickSeconds = 0.05;
    level.capDeadlineTicks = 2400; // Two minutes; the outer runner also stops a failed engine.
    level.capFramesPerChunk = 64;
    level.capClipFrames = 1200;
    level.capExpectedWorkers = getCvarInt("capacity_workers");
    level.capQueryProfile = getCvarInt("capacity_query_profile");
    level.capExtendedReads = getCvarInt("capacity_extended_reads");
    level.capMenuIntervalTicks = 10;
    level.capSaveIntervalTicks = 20;
    level.capStats = spawnStruct();
    level.capStats.workers = 0;
    level.capStats.queued = 1;
    level.capStats.running = 2;
    level.capStats.completed = 3;
    level.capStats.outstanding = 4;
    level.capStats.queryBytes = 5;
    level.capStats.peakJobs = 6;
    level.capStats.peakBytes = 7;
    level.capStats.failures = 10;
    level.capStats.rejected = 12;
    level.capStats.expired = 13;
    level.capStats.uncertain = 14;
    expectedDatabase = getCvar("capacity_database");
    fixturePrefix = "opencj_verify_capacity_";
    if(getSubStr(expectedDatabase, 0, fixturePrefix.size) != fixturePrefix)
    {
        check(false, "disposable database prefix");
        return false;
    }
    openCJ\mySQL::onInit();
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT DATABASE()");
    correctDatabase = isDefined(rows) && rows.size == 1 && rows[0][0] == expectedDatabase;
    check(correctDatabase, "isolated schema selected");
    if(!correctDatabase)
    {
        return false;
    }
    openCJ\demoRecording::_initConstants();
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\huds\infiniteHuds::onInit();
    openCJ\huds\hudFPSHistory::onInit();
    openCJ\huds\infiniteHuds::initInfiniteHud("fps");
    level.weapons_rpgs = [];
    level.weapons_rpgs["default"] = "rpg_mp";
    level.demoCache = [];
    level.demoStorageReady = true;
    level.demoPublicationReady = true;
    level.demoPersisting = 0;
    level.capFrames = getCvarInt("capacity_frames");
    level.capTicks = getCvarInt("capacity_ticks");
    level.clients = [];
    return true;
}

// Each client has separate recording and save identities in the synthetic SQL data.
createPlayersAndRecordings()
{
    wait 1;
    for(i = 0; i < level.capClientCount; i++)
    {
        player = addTestClient();
        check(isDefined(player), "test client " + i);
        if(!isDefined(player))
        {
            return false;
        }
        level.clients[i] = player;
        wait level.capTickSeconds;
        player.sessionTeam = "allies";
        player.sessionState = "playing";
        player.pers["team"] = "allies";
        player spawn((i * 50, 0, 500), (0, 0, 0));
        player freezeControls(true);
        player.login_playerID = i + 1;
        player.FPS = 333;
        player.cheating = false;
        player.isFirstSpawn = false;
        player.eventQueue = [];
        player.playerRuns_runPaused = false;
        player.playerRuns_runFinished = false;
        player openCJ\playerRuns::setRunIDAndInstanceNumber(1001 + i, 1);
        player openCJ\huds\base::onPlayerConnect();
        player openCJ\huds\hudFPSHistory::onPlayerConnect();
        player.fpsHistoryMode = "detailed";
        player openCJ\demoRecording::onConnect();
        recording = spawnStruct();
        recording.id = 1001 + i;
        recording.failed = false;
        recording.finishing = false;
        recording.lastTick = -1;
        recording.saves = [];
        player.demoRecordings["" + recording.id] = recording;
        created = createDemo(recording.id) == recording.id;
        check(created, "native recording buffer " + i);
        if(!created)
        {
            return false;
        }
    }
    return true;
}

fillRecordingBuffers()
{
    // Fill each real native recording buffer to the configured run duration.
    level.capStage = "prepare";
    setCvar("capacity_stage", 0);
    yieldEveryFrames = 1024;
    for(i = 0; i < level.capClientCount; i++)
    {
        player = level.clients[i];
        demoID = 1001 + i;
        for(frameIndex = numberOfDemoFrames(demoID); frameIndex < level.capFrames; frameIndex++)
        {
            flags = level.demoFlags.left | level.demoFlags.forward | level.demoFlags.standing;
            if(frameIndex % 40 > 20)
            {
                flags = level.demoFlags.right | level.demoFlags.forward | level.demoFlags.standing;
            }
            if(frameIndex % 100 < 5)
            {
                flags |= level.demoFlags.onGround;
            }
            passed = addFrameToDemo(demoID, (frameIndex * .7, i * 20, 500 + sin(frameIndex) * 80),
                                    (0, frameIndex % 360, 0), 1, flags, 0, 0, 0, 333, i + 1,
                                    player getEntityNumber());
            if(!isDefined(passed))
            {
                check(false, "recording memory capacity " + i);
                return false;
            }
            if(frameIndex % yieldEveryFrames == 0)
            {
                wait level.capTickSeconds;
            }
        }
    }
    return true;
}

verifyStoredResults()
{
    level.capStage = "verify";
    rows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT COUNT(*) FROM demoRuns WHERE runID BETWEEN 1001 AND 1032 AND ready=1");
    check(isDefined(rows) && int(rows[0][0]) == 32, "all 32 native recordings published");
    rows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT COUNT(*) FROM demoChunks WHERE runID BETWEEN 1001 AND 1032");
    check(isDefined(rows) &&
              int(rows[0][0]) == 32 * int(ceil(level.capFrames / float(level.capFramesPerChunk))),
          "all upload chunks persisted");
    poolStats = mysql_async_stats();
    check(poolStats[level.capStats.workers] == level.capExpectedWorkers &&
              poolStats[level.capStats.outstanding] == 0,
          "configured workers and empty completion backlog");
    check(poolStats[level.capStats.failures] == 0 && poolStats[level.capStats.rejected] == 0 &&
              poolStats[level.capStats.expired] == 0 && poolStats[level.capStats.uncertain] == 0,
          "no SQL failures rejections expirations or uncertain writes");
}

// Run recording, playback and persistence concurrently for one timed workload.
phase(name, recorderCount, sharedRecording, publishAtStart)
{
    level.capPhase++;
    setCvar("capacity_stage", level.capPhase);
    level.capStage = name;
    level.capPending = 0;
    startedAtMs = capacityClock();
    printf("CAP BEGIN " + name + " " + startedAtMs + "\n");
    for(i = 0; i < recorderCount; i++)
    {
        level.clients[i].capBefore = numberOfDemoFrames(1001 + i);
    }
    if(publishAtStart)
    {
        for(i = 0; i < level.capClientCount; i++)
        {
            completeDemo(1001 + i);
            level thread publishRecording(1001 + i);
        }
    }
    for(i = recorderCount; i < level.capClientCount; i++)
    {
        demoID = 3001 + i;
        if(sharedRecording)
        {
            demoID = 3001;
        }
        level.capPending++;
        level.clients[i] thread watch(demoID);
    }
    // Menus and saves begin in the same tick as cold playback loads/uploads.
    for(tick = 0; tick < level.capTicks || level.capPending > 0 || level.demoPersisting > 0; tick++)
    {
        if(tick > level.capDeadlineTicks)
        {
            check(false, "phase deadline " + name);
            return false;
        }
        tickStartedAtMs = capacityClock();
        for(i = 0; i < level.capClientCount; i++)
        {
            player = level.clients[i];
            if(i < recorderCount)
            {
                player openCJ\demoRecording::capture(true);
            }
            else if(isDefined(player.capWatching) && player.capWatching)
            {
                frame = player openCJ\demos::advanceDemoFrame();
                player openCJ\demos::syncDemoFPSHistory(frame.number);
                // Native playback presentation is exercised without opening UI.
                player demoApplyPresentation();
            }
            if((tick < level.capTicks || level.demoPersisting > 0) && menuDue(i, tick))
            {
                player thread menu(i, tick);
            }
            if((tick < level.capTicks || level.demoPersisting > 0) && saveDue(i, tick))
            {
                player thread progress(i, tick);
            }
            if(level.capExtendedReads && tick < level.capTicks && tick % 400 == (i * 12) % 400)
            {
                player thread auditRead(i);
            }
        }
        if(tick % 20 == 0)
        {
            poolStats = mysql_async_stats();
            printf("CAP SAMPLE " + name + " " + poolStats[level.capStats.queued] + " " +
                   poolStats[level.capStats.running] + " " + poolStats[level.capStats.completed] +
                   " " + poolStats[level.capStats.outstanding] + " " +
                   poolStats[level.capStats.queryBytes] + " " +
                   (capacityClock() - tickStartedAtMs) + "\n");
        }
        wait level.capTickSeconds;
    }
    wait .2;
    for(i = recorderCount; i < level.capClientCount; i++)
    {
        player = level.clients[i];
        if(isDefined(player.capWatching) && player.capWatching)
        {
            player demoEndPresentation();
            player demoFPSReset();
            player.playingDemo = false;
            openCJ\demos::releaseCache(player.demoID, player.capCache);
            player.capCache = undefined;
            player.capWatching = false;
            player openCJ\huds\hudFPSHistory::_clearFPSHistory();
        }
    }
    for(i = 0; i < recorderCount; i++)
    {
        check(numberOfDemoFrames(1001 + i) - level.clients[i].capBefore == tick,
              "every recording tick captured");
    }
    poolStats = mysql_async_stats();
    printf("CAP END " + name + " " + (capacityClock() - startedAtMs) + " " + tick + " " +
           poolStats[level.capStats.peakJobs] + " " + poolStats[level.capStats.peakBytes] + "\n");
    return true;
}
watch(demoID)
{
    startedAtMs = capacityClock();
    passed = self openCJ\demos::acquireCache(demoID, level.capFrames);
    check(passed, "playback cache " + demoID);
    if(passed)
    {
        self.capCache = self.demoPendingCache;
        self.demoPendingCache = undefined;
        self.demoPendingId = undefined;
        self selectPlaybackDemo(demoID);
        self.demoID = demoID;
        self.demoBegin = 0;
        self.demoEnd = level.capFrames - 1;
        self.demoStyle = 0;
        self.playingDemo = true;
        self.demoFirstFrame = true;
        self.demoRate = 1;
        self.demoStepRemainder = 0;
        self.demoStepRate = 1;
        self.demoFPSCacheKey = undefined;
        self demoFPSReset();
        self.demoFPSFloor = undefined;
        self.playbackPaused = false;
        self.demoPreviousOnGround = true;
        self.demoPreviousFPS = undefined;
        check(self demoBeginPresentation(), "native demo presentation");
        self.capWatching = true;
    }
    printf("CAP LOAD " + level.capStage + " " + demoID + " " + (capacityClock() - startedAtMs) +
           "\n");
    level.capPending--;
}
publishRecording(demoID)
{
    startedAtMs = capacityClock();
    openCJ\demoRecording::persist(demoID);
    printf("CAP UPLOAD " + level.capStage + " " + demoID + " " + (capacityClock() - startedAtMs) +
           "\n");
}
menu(i, tick)
{
    level.capPending++;
    token = self openCJ\mySQL::beginMenuRead("board");
    if(self openCJ\mySQL::menuReadCurrent(token))
    {
        // Same joins/window functions as the production leaderboard and runs menu.
        if(int(tick / 10) % 2 == 0)
        {
            query =
                "SELECT COUNT(*) OVER(),b.playerName,a.timePlayed,a.runID FROM (SELECT pr.playerID,cs.timePlayed,cs.runID,ROW_NUMBER() OVER(PARTITION BY pr.playerID ORDER BY cs.timePlayed,cs.explosiveJumps) rn ";
            query +=
                "FROM checkpointStatistics cs JOIN playerRuns pr ON pr.runID=cs.runID WHERE cs.cpID=1 AND pr.finishcpID IS NOT NULL AND pr.finishTimeStamp IS NOT NULL AND pr.ele<=1 AND pr.anyPct<=1 AND pr.hb<=1 AND pr.hardTAS<=1 AND pr.FPSMode IN ('125','mix','hax')) a JOIN playerDisplayNames b ON a.playerID=b.playerID WHERE a.rn=1 ORDER BY a.timePlayed LIMIT 10";
        }
        else
        {
            query =
                "SELECT COUNT(*) OVER(),a.runID,rl.runLabel,a.timePlayed,a.explosiveJumps FROM (SELECT ROW_NUMBER() OVER(PARTITION BY pr.runID ORDER BY ps.saveNumber DESC) rn,pr.playerID,pr.runID,pr.timePlayed,ps.explosiveJumps ";
            query +=
                "FROM playerSaves ps JOIN playerRuns pr ON pr.runID=ps.runID WHERE pr.finishTimeStamp IS NULL AND pr.finishcpID IS NULL AND pr.archived=0 AND pr.mapID=1) a LEFT JOIN runLabels rl ON a.runID=rl.runID WHERE a.rn=1 AND a.playerID=" +
                (i + 1) + " ORDER BY a.timePlayed LIMIT 10";
        }
        rows = self openCJ\mySQL::mysqlAsyncMenuQuery(query, "board");
        if(self openCJ\mySQL::menuReadCurrent(token))
        {
            check(isDefined(rows), "current menu query");
        }
    }
    level.capPending--;
}
progress(i, tick)
{
    level.capPending++;
    runID = 2001 + i;
    self.capSave = 0;
    if(isDefined(self.capSaveCount))
    {
        self.capSave = self.capSaveCount;
    }
    self.capSave++;
    self.capSaveCount = self.capSave;
    query = "SELECT savePosition(" + runID + ",1,10,20,30,0,90,0," + (self.capSave * 1000) + "," +
            self.capSave + ",0,0,0,0,1,'mix',0,NULL,NULL)";
    rows = openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
    check(isDefined(rows) && rows.size > 0 && isDefined(rows[0][0]), "progress save");
    level.capPending--;
}
// The observer passes the production API's structured completion unchanged.
queryMetric(policy, startedAtMs, result)
{
    printf("CAP SQL " + level.capStage + " " + policy + " " + (capacityClock() - startedAtMs) +
           " " + result.status + " " + result.waitMs + " " + result.executionMs + "\n");
}

check(passed, label)
{
    level.capChecks++;
    if(!isDefined(passed) || !passed)
    {
        level.capFailures++;
        printf("CAP FAILURE " + label + "\n");
    }
}
finish()
{
    setCvar("capacity_stage", 5);
    wait .1;
    printf("CAP COMPLETE failures=" + level.capFailures + " checks=" + level.capChecks + "\n");
}

clipTransfers()
{
    legacy = demoCreateTransient();
    check(demoDecodeChunk(legacy, "789cf377f63264640081067b20e100440e0c10a050cb2008a2014807033c") ==
              1,
          "legacy OCJ1 codec remains compatible");
    destroyDemo(legacy);
    level.mapid_mapID = 1;
    level.clipSession = "capacity";
    level.capStage = "clip32";
    level.capPending = 0;
    for(i = 0; i < level.capClientCount; i++)
    {
        player = level.clients[i];
        player.playingDemo = false;
        demoID = demoCreateTransient();
        check(isDefined(demoID), "clip native buffer " + i);
        if(!isDefined(demoID))
        {
            return false;
        }
        for(frameIndex = 0; frameIndex < level.capClipFrames; frameIndex++)
        {
            flags = level.demoFlags.left | level.demoFlags.forward | level.demoFlags.standing;
            if(frameIndex % 40 >= 20)
            {
                flags = level.demoFlags.right | level.demoFlags.forward | level.demoFlags.standing;
            }
            check(isDefined(addFrameToDemo(demoID,
                                           (frameIndex * .6, i * 20, 500 + sin(frameIndex) * 80),
                                           (0, frameIndex % 360, 0), 1, flags, 0, 0, 0, 333, 0,
                                           player getEntityNumber())),
                  "clip frame");
        }
        completeDemo(demoID);
        recording = spawnStruct();
        recording.id = demoID;
        recording.first = 0;
        recording.last = level.capClipFrames - 1;
        recording.permanent = true;
        recording.busy = false;
        recording.date = "2026-11-13 00:00:00";
        player.clipEdit = recording;
        player.capClipNative = demoID;
        wait level.capTickSeconds;
    }
    for(i = 0; i < level.capClientCount; i++)
    {
        level.capPending++;
        level.clients[i] thread publishClip();
    }
    tick = 0;
    while(level.capPending > 0 && tick < level.capDeadlineTicks)
    {
        for(i = 0; i < level.capClientCount; i++)
        {
            if(menuDue(i, tick))
            {
                level.clients[i] thread menu(i, tick);
            }
            if(saveDue(i, tick))
            {
                level.clients[i] thread progress(i, tick);
            }
        }
        tick++;
        wait level.capTickSeconds;
    }
    check(level.capPending == 0, "clip upload completion deadline");
    if(level.capPending != 0)
    {
        return false;
    }
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoClips WHERE ready=1");
    check(isDefined(rows) && int(rows[0][0]) == 32, "32 simultaneous clip publications");
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoClipChunks");
    check(isDefined(rows) && int(rows[0][0]) == 32 * 19, "all clip chunks persisted");
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT clipID FROM demoClips ORDER BY clipID LIMIT 1");
    hasClip = isDefined(rows) && rows.size == 1;
    check(hasClip, "published clip is available for transfer checks");
    if(!hasClip)
    {
        return false;
    }
    clipID = int(rows[0][0]);
    nativeDemoID = demoCreateTransient();
    receipt = openCJ\mySQL::awaitNative(demoLoadChunks(nativeDemoID, clipID, 1, 0));
    check(isDefined(receipt) && receipt[0][0] == 19 && numberOfDemoFrames(nativeDemoID) == 1200,
          "clip uses native binary download");
    destroyDemo(nativeDemoID);
    // Reusing an ID must never let an old SQL completion append into a new demo.
    nativeDemoID = 770002;
    createDemo(nativeDemoID);
    transferID = demoLoadChunks(nativeDemoID, clipID, 1, 0);
    destroyDemo(nativeDemoID);
    createDemo(nativeDemoID);
    receipt = openCJ\mySQL::awaitNative(transferID);
    check(!isDefined(receipt) && numberOfDemoFrames(nativeDemoID) == 0,
          "stale load rejects reused native ID");
    destroyDemo(nativeDemoID);
    // No script waiter remains after a map change; its native result is drained.
    nativeDemoID = demoCreateTransient();
    transferID = demoLoadChunks(nativeDemoID, clipID, 1, 0);
    mysql_async_newmap();
    wait .5;
    poolStats = mysql_async_stats();
    check(poolStats[level.capStats.outstanding] == 0 && numberOfDemoFrames(nativeDemoID) == 0,
          "map change drains abandoned native read");
    destroyDemo(nativeDemoID);
    // Malformed bytes fail normally, without touching script strings or crashing.
    openCJ\mySQL::mysqlSyncQuery(
        "UPDATE demoClipChunks SET payload=UNHEX('00') WHERE clipID=" + clipID + " AND chunkNum=0");
    nativeDemoID = demoCreateTransient();
    receipt = openCJ\mySQL::awaitNative(demoLoadChunks(nativeDemoID, clipID, 1, 0));
    check(!isDefined(receipt) && numberOfDemoFrames(nativeDemoID) == 0,
          "corrupt binary payload rejected");
    destroyDemo(nativeDemoID);
    printf("CAP CLIPS COMPLETE\n");
    return true;
}
publishClip()
{
    nativeDemoID = self.capClipNative;
    // submit pins the native source before its first SQL wait. This sibling
    // simulates closing the editor and releasing its playback owner meanwhile.
    self thread closeClipDuringUpload(nativeDemoID);
    self openCJ\clips::submit("Capacity clip");
    check(self.playingDemo && self.demoID == -1,
          "completed upload does not stop subsequent playback");
    self.playingDemo = false;
    check(!isDefined(self.clipUploadNative), "clip upload released native ownership");
    check(!isDefined(self.clipUploadToken), "finished upload permits next submission");
    check(!isDefined(numberOfDemoFrames(nativeDemoID)),
          "closed clip buffer reclaimed after upload");
    self.clipEdit = undefined;
    level.capPending--;
}
closeClipDuringUpload(nativeDemoID)
{
    self endon("disconnect");
    wait level.capTickSeconds;
    destroyDemo(nativeDemoID);
    self.clipEdit = spawnStruct();
    self.clipEdit.busy = false;
    token = self.clipUploadToken;
    self openCJ\clips::submit("Overlapping clip");
    check(self.clipUploadNative == nativeDemoID && self.clipUploadToken == token &&
              !self.clipEdit.busy,
          "overlapping submission preserves pending upload ownership");
    self.clipEdit = undefined;
    self.playingDemo = true;
    self.demoID = -1;
}

// Query hosting traffic is staggered; stress traffic arrives in synchronized bursts.
menuDue(playerIndex, tick)
{
    if(level.capQueryProfile)
    {
        return tick % 200 == (playerIndex * 6) % 200;
    }
    return tick % level.capMenuIntervalTicks == 0;
}

saveDue(playerIndex, tick)
{
    if(level.capQueryProfile)
    {
        return tick % 120 == (playerIndex * 3) % 120;
    }
    return tick % level.capSaveIntervalTicks == 0;
}
