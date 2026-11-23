#include openCJ\util;
main()
{
    level.n72Checks = 0;
    level.n72Failures = 0;
    level.n72PlayerCount = 32;
    level.n72Public = [];
    level.n72Private = [];
    level.n72Sounds = [];
    databaseName = getCvar("notify72_database");
    if(getSubStr(databaseName, 0, 17) != "opencj_verify_72_")
    {
        return;
    }
    openCJ\mySQL::onInit();
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\notifications::onInit();
    check(isDefined(level.commands["notifications"]), "command available to automatic help");
    createPlayers();
    verifyBurstCleanup();
    verifyActionModes();
    player = level.clients[0];
    verifyEdgeFades(player);
    verifyPreferencePersistence(player);
    verifyResultFades(player);
    verifyResultPriority(player);
    verifyRecordMessages(player);
    verifyChallengeAwards(player);
    verifyCheckpointReplies(player);
    verifyRunFeedbackCleanup(player);
    verifyCheckpointQueueLifecycle(player, "menu");
    verifyCheckpointQueueLifecycle(player, "load");
    verifyCheckpointQueueLifecycle(player, "run");
    verifyCheckpointQueueLifecycle(player, "stop");
    verifyCheckpointQueueLifecycle(player, "disconnect");
    verifyFinishQueueLifecycle(player);
    verifyFinishSoundDelivery(player);
    verifyFinishSoundQueue(player, "load");
    verifyFinishSoundQueue(player, "run");
    verifyFinishSoundQueue(player, "disconnect");
    verifyLateFinishSound(player, "demo");
    verifyLateFinishSound(player, "cleared");
    printf("N72 COMPLETE failures=" + level.n72Failures + " checks=" + level.n72Checks + "\n");
}

// Create isolated logged-in clients with default feedback.
createPlayers()
{
    level.clients = [];
    wait 1;
    for(i = 0; i < level.n72PlayerCount; i++)
    {
        player = addTestClient();
        wait .05;
        level.clients[i] = player;
        player.sessionTeam = "allies";
        player.sessionState = "playing";
        player.pers["team"] = "allies";
        player spawn((0, 0, 700), (0, 0, 0));
        player freezeControls(true);
        player.login_playerID = i + 1;
        player.playingDemo = false;
        player openCJ\settings::onPlayerConnect();
        player.settingsLoaded = true;
        player openCJ\notifications::action("save", "Saved");
        check(player openCJ\notifications::wantsText("save") && !isDefined(player.notificationFlash),
              "default text without HUD " + i);
    }
}

// Check that bursts reuse one pair and release it for every player.
verifyBurstCleanup()
{
    memoryAudit("text", level);
    for(i = 0; i < level.n72PlayerCount; i++)
    {
        player = level.clients[i];
        player.settingValues["notify_save"] = 3;
        player openCJ\notifications::action("save", "Saved");
        originalOverlay = player.notificationFlash;
        originalRightOverlay = player.notificationFlashRight;
        for(j = 0; j < 20; j++)
        {
            player openCJ\notifications::action("save", "Saved");
        }
        check(isDefined(originalOverlay) && player.notificationFlash == originalOverlay &&
                  player.notificationFlashRight == originalRightOverlay,
              "one edge pair during burst " + i);
    }
    memoryAudit("flashing", level);
    wait .35;
    for(i = 0; i < level.n72PlayerCount; i++)
    {
        check(!isDefined(level.clients[i].notificationFlash) &&
                  !isDefined(level.clients[i].notificationFlashRight),
              "expired pair freed " + i);
    }
    memoryAudit("expired", level);
}

// Check silent, flash, demo and disconnect behavior.
verifyActionModes()
{
    player = level.clients[0];
    player.settingValues["notify_save"] = 0;
    player openCJ\notifications::action("save", "Saved");
    check(!isDefined(player.notificationFlash) && !player openCJ\notifications::wantsText("save"),
          "off is silent");
    player.settingValues["notify_save"] = 2;
    player.playingDemo = true;
    player openCJ\notifications::action("save", "Saved");
    check(!isDefined(player.notificationFlash), "demo playback cannot flash");
    player.playingDemo = false;
    player openCJ\notifications::action("save", "Saved");
    check(isDefined(player.notificationFlash), "flash mode creates overlay");
    player openCJ\notifications::onDisconnect();
    check(!isDefined(player.notificationFlash), "disconnect cleanup");
    check(!isDefined(openCJ\notifications::modeValue("invalid")), "invalid mode rejected");
}

// Measure the encoded edge fade across real engine updates.
verifyEdgeFades(player)
{
    for(strength = 1; strength <= 3; strength++)
    {
        player.settingValues["notify_strength"] = strength;
        player openCJ\notifications::action("save");
        peakAlphaByte = 0;
        visibleFrames = 0;
        validGeometry = true;
        for(i = 0; i < 8; i++)
        {
            opacity = notificationHudProbe(player getEntityNumber(), 0);
            if(opacity < 0)
            {
                validGeometry = false;
            }
            if(opacity > peakAlphaByte)
            {
                peakAlphaByte = opacity;
            }
            if(opacity > 0)
            {
                visibleFrames++;
            }
            wait .05;
        }
        check(validGeometry, "only two edge bands with clear center " + strength);
        check(peakAlphaByte == 40 + 16 * strength, "encoded opacity reaches intended peak " + strength);
        check(visibleFrames >= 5, "flash persists across client updates " + strength);
        check(!isDefined(player.notificationFlash), "fade probe overlay released " + strength);
    }
}

// Save command choices and reload them from the disposable database.
verifyPreferencePersistence(player)
{
    args = [];
    args[0] = "all";
    args[1] = "both";
    player openCJ\notifications::command(args);
    args[0] = "load";
    args[1] = "flash";
    player openCJ\notifications::command(args);
    args[0] = "strength";
    args[1] = "medium";
    player openCJ\notifications::command(args);
    rows = undefined;
    for(i = 0; i < 40; i++)
    {
        wait .05;
        rows = openCJ\mySQL::mysqlAsyncRead(
            "SELECT s.settingName,p.value FROM playerSettings p JOIN settings s ON s.settingID=p.settingID WHERE p.playerID=1 ORDER BY s.settingName");
        if(isDefined(rows) && rows.size == 5)
        {
            break;
        }
    }
    check(isDefined(rows) && rows.size == 5, "five notification preferences persisted");
    player.settingValues = [];
    player openCJ\settings::loadSettingsFromDatabase();
    check(player openCJ\notifications::mode("checkpoint") == 3 &&
              player openCJ\notifications::mode("save") == 3 &&
              player openCJ\notifications::mode("load") == 2 &&
              player openCJ\notifications::mode("results") == 3,
          "action and result choices restored");
    check(player.settingValues["notify_strength"] == 2, "strength restored");
    check(!player openCJ\notifications::wantsText("load"), "flash mode suppresses routine text");
}

// Check action colors and the stronger result overlay.
verifyResultFades(player)
{
    check(openCJ\notifications::color("checkpoint") == (.05, 1, .10), "checkpoint green");
    check(openCJ\notifications::color("save") == (.05, .25, 1), "save blue");
    check(openCJ\notifications::color("load") == (1, .05, .05), "load red");
    player.playerRuns_runID = 1002;
    player.runInstanceNumber = 1;
    player.playerRuns_runFinished = true;
    player.settingValues["notify_results"] = 1;
    player openCJ\notifications::beginResults(1002);
    check(!isDefined(player.notificationFlash), "results default to text");
    player.settingValues["notify_results"] = 3;
    for(strength = 1; strength <= 3; strength++)
    {
        player.settingValues["notify_strength"] = strength;
        player openCJ\notifications::beginResults(1002);
        peakAlphaByte = 0;
        visibleFrames = 0;
        validGeometry = true;
        for(i = 0; i < 15; i++)
        {
            opacity = notificationHudProbe(player getEntityNumber(), 1);
            if(opacity < 0)
            {
                validGeometry = false;
            }
            if(opacity > peakAlphaByte)
            {
                peakAlphaByte = opacity;
            }
            if(opacity > 0)
            {
                visibleFrames++;
            }
            wait .05;
        }
        check(validGeometry, "result uses one full-screen overlay " + strength);
        check(peakAlphaByte == 56 + 16 * strength, "result has stronger encoded peak " + strength);
        check(visibleFrames >= 10, "result remains more noticeable " + strength);
        check(!isDefined(player.notificationFlash), "result overlay expires " + strength);
    }
}

// Keep finish, challenge and record emphasis within the same run window.
verifyResultPriority(player)
{
    player openCJ\notifications::beginResults(1002);
    originalOverlay = player.notificationFlash;
    player openCJ\notifications::result("challenge", 1002);
    check(player.notificationResultPriority == 2 && player.notificationFlash == originalOverlay,
          "challenge upgrades same finish flash");
    player openCJ\notifications::result("record", 1002);
    player openCJ\notifications::result("finish", 1002);
    check(player.notificationResultPriority == 3 && player.notificationFlash == originalOverlay,
          "record takes priority without stacking");
    check(!isDefined(level.clients[1].notificationFlash),
          "completion never flashes for other players");
    player openCJ\notifications::cancelFlash();
    player openCJ\notifications::beginResults(1002);
    player.runInstanceNumber = 2;
    player openCJ\notifications::result("record", 1002);
    check(player.notificationResultPriority == 1, "old-instance record cannot upgrade flash");
    player.playerRuns_runID = undefined;
    player.runInstanceNumber = undefined;
    player openCJ\notifications::result("record", 1002);
    check(player.notificationResultPriority == 1,
          "cleared run identity cannot upgrade a result overlay");
    player.playerRuns_runID = 1002;
    player.runInstanceNumber = 1;
    player.notificationResultUntil = getTime() - 1;
    player openCJ\notifications::result("record", 1002);
    check(player.notificationResultPriority == 1, "late record outside result window ignored");
    player openCJ\notifications::cancelFlash();
    player openCJ\notifications::beginResults(1002);
    player openCJ\notifications::action("load");
    player openCJ\notifications::result("record", 1002);
    check(!isDefined(player.notificationResultRun) && !player.notificationFlashResult &&
              isDefined(player.notificationFlashRight),
          "load cancels result window and returns to edge feedback");
    player openCJ\notifications::cancelFlash();
    player openCJ\notifications::beginResults(1002);
    player openCJ\notifications::cancelAll();
    check(!isDefined(player.notificationFlash) && !isDefined(player.notificationResultRun),
          "demo entry cancels active finish emphasis");
    player.playingDemo = true;
    player openCJ\notifications::beginResults(1002);
    check(!isDefined(player.notificationFlash), "demo playback cannot start result flash");
    player.playingDemo = false;
    player openCJ\notifications::cancelResults();
}

// Check record comparison text, ownership and duplicate callbacks.
verifyRecordMessages(player)
{
    recordRow = [];
    for(i = 0; i < 15; i++)
    {
        recordRow[i] = 0;
    }
    recordRow[1] = 0;
    recordRow[8] = 8000;
    recordRow[9] = 8;
    recordRow[10] = 10000;
    recordRow[11] = 10;
    check(openCJ\recordNotices::improvement(recordRow) == "time: 0:02.000 faster",
          "time improvement text");
    recordRow[8] = 10000;
    check(openCJ\recordNotices::improvement(recordRow) == "time: tied, 2 fewer RPGs",
          "time tiebreak text");
    recordRow[1] = 1;
    check(openCJ\recordNotices::improvement(recordRow) == "RPGs: 2 fewer", "RPG improvement text");
    recordRow[9] = 10;
    recordRow[8] = 8000;
    check(openCJ\recordNotices::improvement(recordRow) == "RPGs: tied, 0:02.000 faster",
          "RPG tiebreak text");
    recordRow[8] = 10000;
    check(openCJ\recordNotices::improvement(recordRow) == "", "exact ties do not announce");
    recordRow[10] = undefined;
    check(openCJ\recordNotices::improvement(recordRow) == "", "first finish is not a beaten record");
    malformedRows = [];
    for(i = 0; i < 4; i++)
    {
        malformedRows[i] = recordRow;
    }
    malformedRows[3] = [];
    check(!isDefined(openCJ\recordNotices::decodeRecords(malformedRows)),
          "malformed later record row rejects the complete result");
    check(openCJ\recordNotices::improvement([]) == "",
          "short record row cannot produce an improvement");

    player openCJ\notifications::beginResults(1002);
    player openCJ\recordNotices::onRunFinished(1002);
    check(player.notificationResultPriority == 3, "actual matching record selects record emphasis");
    check(level.n72Public.size == 1 && level.n72Private.size == 1,
          "server record global and PB private");
    check(level.n72Private[0].player == 1, "PB only goes to finishing player");
    player openCJ\recordNotices::onRunFinished(1002);
    check(level.n72Public.size == 1 && level.n72Private.size == 1,
          "duplicate callback does not repeat announcement");
    player.notificationFinishedRun = undefined;
    player openCJ\recordNotices::onRunFinished(2002);
    check(level.n72Public.size == 1 && level.n72Private.size == 1,
          "ten-minutes-faster any percent run cannot beat checkpoint record");
}

// Award each challenge once and show only the new completion.
verifyChallengeAwards(player)
{
    player openCJ\notifications::cancelFlash();
    player openCJ\notifications::cancelResults();
    level.challengesReady = true;
    level.challengeTierPoints[1] = 100;
    level.challengeTierPoints[2] = 0;
    player.challengePoints = 0;
    player.challengeRank = 1;
    privateMessageCount = level.n72Private.size;
    player openCJ\notifications::beginResults(1002);
    player openCJ\challenges::awardRun(1002);
    check(player.challengePoints == 10 && level.n72Private.size == privateMessageCount + 1,
          "actual challenge award prints private completion");
    check(player.notificationResultPriority == 2, "actual challenge award selects gold emphasis");
    player openCJ\notifications::cancelFlash();
    player openCJ\notifications::beginResults(1002);
    player openCJ\challenges::awardRun(1002);
    check(level.n72Private.size == privateMessageCount + 1 && player.notificationResultPriority == 1,
          "already awarded challenge does not repeat celebration");
    player openCJ\notifications::cancelFlash();
    player openCJ\notifications::cancelResults();
}

// Compare exact checkpoint categories and reject obsolete replies.
verifyCheckpointReplies(player)
{
    rows = player openCJ\mySQL::mysqlAsyncRead(
        openCJ\recordNotices::checkpointQuery(1002, 1, "mix", 0, 0, 0, 0, "rpgs"));
    check(isDefined(rows) && rows.size == 1 && int(rows[0][0]) == 9000 && int(rows[0][1]) == 8,
          "checkpoint split excludes faster any percent result");
    rows = player openCJ\mySQL::mysqlAsyncRead(
        openCJ\recordNotices::checkpointQuery(2002, 1, "mix", 0, 1, 0, 0, "time"));
    check(isDefined(rows) && !rows.size, "any percent checkpoint has no comparable prior split");
    player.playerRuns_runID = 1002;
    player.runInstanceNumber = 1;
    level.checkpointLayoutEpoch = 1;
    player.FPSMode = "mix";
    player.allowHalfBeat = false;
    level.statisticsStrings_explosiveJumps = "fixtureRPGs";
    player.statistics["fixtureRPGs"] = 7;
    player.settingValues["lbsort"] = "time";
    player.settingValues["notify_checkpoint"] = 1;
    privateMessageCount = level.n72Private.size;
    player openCJ\recordNotices::checkpoint(1002, 1, 8000);
    check(level.n72Private.size == privateMessageCount + 1 &&
              level.n72Private[privateMessageCount].text == "Checkpoint passed | ^20:01.000 ahead",
          "checkpoint split uses comparable completed run");
    level.n72DelayCheckpoint = true;
    level.n72CheckpointWaiting = false;
    privateMessageCount = level.n72Private.size;
    player thread openCJ\recordNotices::checkpoint(1002, 1, 8000);
    waitForCheckpoint();
    player.playerRuns_runID = 9999;
    wait .30;
    check(level.n72Private.size == privateMessageCount, "late checkpoint response rejected after run change");
    player.playerRuns_runID = 1002;
    level.n72CheckpointWaiting = false;
    player thread openCJ\recordNotices::checkpoint(1002, 1, 8000);
    waitForCheckpoint();
    // Bypass cancellation to exercise the late-result guard itself.
    player.playerRuns_runID = undefined;
    player.runInstanceNumber = undefined;
    wait .30;
    check(level.n72Private.size == privateMessageCount,
          "late checkpoint reply tolerates a cleared run identity");

    player.playerRuns_runID = 1002;
    player.runInstanceNumber = 1;
    level.n72CheckpointWaiting = false;
    player thread openCJ\recordNotices::checkpoint(1002, 1, 8000);
    waitForCheckpoint();
    player openCJ\notifications::action("load");
    wait .30;
    check(level.n72Private.size == privateMessageCount, "load cancels pending checkpoint message");
    level.n72DelayCheckpoint = false;
}

capturePublic(message)
{
    level.n72Public[level.n72Public.size] = message;
}
capturePrivate(message)
{
    entry = spawnStruct();
    entry.player = self openCJ\login::getPlayerID();
    entry.text = message;
    level.n72Private[level.n72Private.size] = entry;
}
check(ok, label)
{
    level.n72Checks++;
    if(!isDefined(ok) || !ok)
    {
        level.n72Failures++;
        printf("N72 FAIL " + label + "\n");
    }
}

waitForCheckpoint()
{
    maxPolls = 100;
    pollIntervalSeconds = .05;
    for(i = 0; i < maxPolls && !level.n72CheckpointWaiting; i++)
    {
        wait pollIntervalSeconds;
    }
    check(level.n72CheckpointWaiting, "checkpoint response reached test delay");
}

// Hold delivery after the real query completes, so stale-result checks remain real.
observeSQLResult(query)
{
    if(isDefined(level.n72DelaySound) && level.n72DelaySound &&
       isSubStr(query, "timeAhead AS"))
    {
        level.n72SoundWaiting = true;
        wait .20;
        return;
    }
    if(!isDefined(level.n72DelayCheckpoint) || !level.n72DelayCheckpoint)
    {
        return;
    }
    if(getSubStr(query, 0, 6) != "SELECT" || !isSubStr(query, "checkpointStatistics cs"))
    {
        return;
    }
    level.n72CheckpointWaiting = true;
    wait .20;
}

// Keep every worker occupied so removal from the queue cannot be mistaken for execution.
verifyCheckpointQueueLifecycle(player, cancellation)
{
    player.playerRuns_runID = 1002;
    player.runInstanceNumber = 1;
    privateMessageCount = level.n72Private.size;
    workerCount = occupySQLWorkers();

    player thread openCJ\recordNotices::checkpoint(1002, 1, 8000);
    wait .05;
    stats = mysql_async_stats();
    check(stats[1] == 1, cancellation + " checkpoint waits in native queue");
    if(cancellation == "menu")
    {
        player openCJ\mySQL::cancelMenuReads();
    }
    else if(cancellation == "load")
    {
        player openCJ\notifications::action("load");
    }
    else if(cancellation == "run")
    {
        player openCJ\playerRuns::setRunIDAndInstanceNumber(9999, 1);
    }
    else if(cancellation == "stop")
    {
        player openCJ\playerRuns::_clearRunVars();
    }
    else
    {
        player openCJ\notifications::onDisconnect();
    }
    wait .10;
    stats = mysql_async_stats();
    expectedQueued = 0;
    if(cancellation == "menu")
    {
        expectedQueued = 1;
    }
    check(stats[1] == expectedQueued && stats[2] == workerCount,
          cancellation + " keeps only relevant checkpoint work before a worker is free");

    waitForSQLWorkers(workerCount);
    expectedMessageCount = privateMessageCount;
    if(cancellation == "menu")
    {
        expectedMessageCount++;
    }
    check(level.n72Private.size == expectedMessageCount,
          cancellation + " prints only a relevant checkpoint reply");
}

awaitBlocker(jobID)
{
    openCJ\mySQL::awaitNative(jobID);
    level.n72BlockersDone++;
}

occupySQLWorkers()
{
    workerCount = level.sqlConstants.workerCount;
    level.n72BlockersDone = 0;
    for(i = 0; i < workerCount; i++)
    {
        jobID = mysql_async_submit("SELECT SLEEP(1)", level.sqlConstants.policyProgress,
                                  "", "", level.sqlConstants.defaultQueueWaitMs, true);
        check(isDefined(jobID) && jobID > 0, "queue blocker admitted");
        thread awaitBlocker(jobID);
    }
    stats = mysql_async_stats();
    for(attempt = 0; attempt < 10; attempt++)
    {
        stats = mysql_async_stats();
        if(stats[2] == workerCount)
        {
            break;
        }
        wait .05;
    }
    check(stats[2] == workerCount, "queue blockers occupy all workers");

    return workerCount;
}

waitForSQLWorkers(workerCount)
{
    stats = mysql_async_stats();
    for(attempt = 0; attempt < 40 && level.n72BlockersDone < workerCount; attempt++)
    {
        wait .05;
    }
    wait .10;
    stats = mysql_async_stats();
    check(level.n72BlockersDone == workerCount && stats[4] == 0,
          "queue scenario releases all results");
}

verifyRunFeedbackCleanup(player)
{
    player.playerRuns_runID = 1002;
    player.runInstanceNumber = 1;
    player.playerRuns_runFinished = true;
    player openCJ\notifications::beginResults(1002);
    player openCJ\playerRuns::setRunIDAndInstanceNumber(9999, 1);
    check(!isDefined(player.notificationFlash) && !isDefined(player.notificationResultRun),
          "replacing a run removes its active result feedback");

    player.playerRuns_runID = 1002;
    player.playerRuns_runFinished = true;
    player openCJ\notifications::beginResults(1002);
    player openCJ\playerRuns::_clearRunVars();
    check(!isDefined(player.notificationFlash) && !isDefined(player.notificationResultRun),
          "stopping a run removes its active result feedback");
}

// A new run keeps a saved finish announcement; disconnect removes its queued read.
verifyFinishQueueLifecycle(player)
{
    workerCount = occupySQLWorkers();
    publicMessageCount = level.n72Public.size;
    privateMessageCount = level.n72Private.size;
    player.notificationFinishedRun = undefined;
    player thread openCJ\recordNotices::onRunFinished(1002);
    wait .05;
    stats = mysql_async_stats();
    check(stats[1] == 1, "finished record waits in native queue");

    player openCJ\playerRuns::setRunIDAndInstanceNumber(9999, 1);
    stats = mysql_async_stats();
    check(stats[1] == 1, "new run keeps the saved finish announcement");
    player openCJ\notifications::onDisconnect();
    wait .10;
    stats = mysql_async_stats();
    check(stats[1] == 0 && stats[2] == workerCount,
          "disconnect removes the finish query before a worker is free");
    waitForSQLWorkers(workerCount);
    check(level.n72Public.size == publicMessageCount && level.n72Private.size == privateMessageCount,
          "disconnected finish read cannot publish a late announcement");
}

captureFinishSound(soundAlias)
{
    level.n72Sounds[level.n72Sounds.size] = soundAlias;
    self playLocalSound(soundAlias);
}

prepareFinishedRun(player)
{
    player.playerRuns_runID = 1002;
    player.runInstanceNumber = 1;
    player.playerRuns_runFinished = true;
    player.finishSoundRun = undefined;
    player.playingDemo = false;
}

verifyFinishSoundDelivery(player)
{
    prepareFinishedRun(player);
    soundCount = level.n72Sounds.size;
    player openCJ\finishSounds::onRunFinished(1002);
    check(level.n72Sounds.size == soundCount + 1 &&
          level.n72Sounds[soundCount] == "opencj_route_record",
          "saved podium finish selects the record sound");
    player openCJ\finishSounds::onRunFinished(1002);
    check(level.n72Sounds.size == soundCount + 1,
          "duplicate finish callback cannot repeat the sound");
    check(openCJ\finishSounds::soundForResult(undefined) == "opencj_route_complete",
          "unavailable ranking keeps ordinary completion feedback");
}

verifyFinishSoundQueue(player, cancellation)
{
    prepareFinishedRun(player);
    soundCount = level.n72Sounds.size;
    workerCount = occupySQLWorkers();
    player thread openCJ\finishSounds::onRunFinished(1002);
    wait .05;
    stats = mysql_async_stats();
    check(stats[1] == 1, cancellation + " finish sound waits in queue");
    if(cancellation == "load")
    {
        player openCJ\notifications::action("load");
    }
    else if(cancellation == "run")
    {
        player openCJ\playerRuns::setRunIDAndInstanceNumber(9999, 1);
    }
    else
    {
        player openCJ\notifications::onDisconnect();
    }
    wait .10;
    stats = mysql_async_stats();
    check(stats[1] == 0 && stats[2] == workerCount,
          cancellation + " removes obsolete sound query before a worker is free");
    waitForSQLWorkers(workerCount);
    check(level.n72Sounds.size == soundCount, cancellation + " cannot play an obsolete finish sound");
}

verifyLateFinishSound(player, changedState)
{
    prepareFinishedRun(player);
    soundCount = level.n72Sounds.size;
    level.n72DelaySound = true;
    level.n72SoundWaiting = false;
    player thread openCJ\finishSounds::onRunFinished(1002);
    for(attempt = 0; attempt < 100 && !level.n72SoundWaiting; attempt++)
    {
        wait .05;
    }
    check(level.n72SoundWaiting, "finish sound reached delayed result delivery");
    // Bypass cancellation so the current-run/demo guard must reject the late reply itself.
    if(changedState == "demo")
    {
        player.playingDemo = true;
    }
    else
    {
        player.playerRuns_runID = undefined;
        player.runInstanceNumber = undefined;
    }
    wait .30;
    check(level.n72Sounds.size == soundCount, changedState + " state rejects a late finish sound");
    level.n72DelaySound = false;
    player.playingDemo = false;
}
