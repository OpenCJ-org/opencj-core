#include openCJ\util;
main()
{
    level.n72Checks = 0;
    level.n72Failures = 0;
    level.n72Public = [];
    level.n72Private = [];
    expected = getCvar("notify72_database");
    if(getSubStr(expected, 0, 17) != "opencj_verify_72_")
    {
        return;
    }
    openCJ\mySQL::onInit();
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\notifications::onInit();
    check(isDefined(level.commands["notifications"]), "command available to automatic help");
    level.clients = [];
    wait 1;
    for(i = 0; i < 32; i++)
    {
        p = addTestClient();
        wait .05;
        level.clients[i] = p;
        p.sessionTeam = "allies";
        p.sessionState = "playing";
        p.pers["team"] = "allies";
        p spawn((0, 0, 700), (0, 0, 0));
        p freezeControls(true);
        p.login_playerID = i + 1;
        p.playingDemo = false;
        p openCJ\settings::onPlayerConnect();
        p.settingsLoaded = true;
        p openCJ\notifications::action("save", "Saved");
        check(p openCJ\notifications::wantsText("save") && !isDefined(p.notificationFlash),
              "default text without HUD " + i);
    }
    memoryAudit("text", level);
    for(i = 0; i < 32; i++)
    {
        p = level.clients[i];
        p.settingValues["notify_save"] = 3;
        p openCJ\notifications::action("save", "Saved");
        original = p.notificationFlash;
        originalRight = p.notificationFlashRight;
        for(j = 0; j < 20; j++)
        {
            p openCJ\notifications::action("save", "Saved");
        }
        check(isDefined(original) && p.notificationFlash == original &&
                  p.notificationFlashRight == originalRight,
              "one edge pair during burst " + i);
    }
    memoryAudit("flashing", level);
    wait .35;
    for(i = 0; i < 32; i++)
    {
        check(!isDefined(level.clients[i].notificationFlash) &&
                  !isDefined(level.clients[i].notificationFlashRight),
              "expired pair freed " + i);
    }
    memoryAudit("expired", level);
    p = level.clients[0];
    p.settingValues["notify_save"] = 0;
    p openCJ\notifications::action("save", "Saved");
    check(!isDefined(p.notificationFlash) && !p openCJ\notifications::wantsText("save"),
          "off is silent");
    p.settingValues["notify_save"] = 2;
    p.playingDemo = true;
    p openCJ\notifications::action("save", "Saved");
    check(!isDefined(p.notificationFlash), "demo playback cannot flash");
    p.playingDemo = false;
    p openCJ\notifications::action("save", "Saved");
    check(isDefined(p.notificationFlash), "flash mode creates overlay");
    p openCJ\notifications::onDisconnect();
    check(!isDefined(p.notificationFlash), "disconnect cleanup");
    check(!isDefined(openCJ\notifications::modeValue("invalid")), "invalid mode rejected");

    for(strength = 1; strength <= 3; strength++)
    {
        p.settingValues["notify_strength"] = strength;
        p openCJ\notifications::action("save");
        peak = 0;
        visibleFrames = 0;
        valid = true;
        for(i = 0; i < 8; i++)
        {
            opacity = notificationHudProbe(p getEntityNumber(), 0);
            if(opacity < 0)
            {
                valid = false;
            }
            if(opacity > peak)
            {
                peak = opacity;
            }
            if(opacity > 0)
            {
                visibleFrames++;
            }
            wait .05;
        }
        check(valid, "only two edge bands with clear center " + strength);
        check(peak == 40 + 16 * strength, "encoded opacity reaches intended peak " + strength);
        check(visibleFrames >= 5, "flash persists across client updates " + strength);
        check(!isDefined(p.notificationFlash), "fade probe overlay released " + strength);
    }

    args = [];
    args[0] = "all";
    args[1] = "both";
    p openCJ\notifications::command(args);
    args[0] = "load";
    args[1] = "flash";
    p openCJ\notifications::command(args);
    args[0] = "strength";
    args[1] = "medium";
    p openCJ\notifications::command(args);
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
    p.settingValues = [];
    p openCJ\settings::loadSettingsFromDatabase();
    check(p openCJ\notifications::mode("checkpoint") == 3 &&
              p openCJ\notifications::mode("save") == 3 &&
              p openCJ\notifications::mode("load") == 2 &&
              p openCJ\notifications::mode("results") == 3,
          "action and result choices restored");
    check(p.settingValues["notify_strength"] == 2, "strength restored");
    check(!p openCJ\notifications::wantsText("load"), "flash mode suppresses routine text");

    check(openCJ\notifications::color("checkpoint") == (.05, 1, .10), "checkpoint green");
    check(openCJ\notifications::color("save") == (.05, .25, 1), "save blue");
    check(openCJ\notifications::color("load") == (1, .05, .05), "load red");
    p.playerRuns_runID = 1002;
    p.runInstanceNumber = 1;
    p.playerRuns_runFinished = true;
    p.settingValues["notify_results"] = 1;
    p openCJ\notifications::beginResults(1002);
    check(!isDefined(p.notificationFlash), "results default to text");
    p.settingValues["notify_results"] = 3;
    for(strength = 1; strength <= 3; strength++)
    {
        p.settingValues["notify_strength"] = strength;
        p openCJ\notifications::beginResults(1002);
        peak = 0;
        visibleFrames = 0;
        valid = true;
        for(i = 0; i < 15; i++)
        {
            opacity = notificationHudProbe(p getEntityNumber(), 1);
            if(opacity < 0)
            {
                valid = false;
            }
            if(opacity > peak)
            {
                peak = opacity;
            }
            if(opacity > 0)
            {
                visibleFrames++;
            }
            wait .05;
        }
        check(valid, "result uses one full-screen overlay " + strength);
        check(peak == 56 + 16 * strength, "result has stronger encoded peak " + strength);
        check(visibleFrames >= 10, "result remains more noticeable " + strength);
        check(!isDefined(p.notificationFlash), "result overlay expires " + strength);
    }
    p openCJ\notifications::beginResults(1002);
    original = p.notificationFlash;
    p openCJ\notifications::result("challenge", 1002);
    check(p.notificationResultPriority == 2 && p.notificationFlash == original,
          "challenge upgrades same finish flash");
    p openCJ\notifications::result("record", 1002);
    p openCJ\notifications::result("finish", 1002);
    check(p.notificationResultPriority == 3 && p.notificationFlash == original,
          "record takes priority without stacking");
    check(!isDefined(level.clients[1].notificationFlash),
          "completion never flashes for other players");
    p openCJ\notifications::cancelFlash();
    p openCJ\notifications::beginResults(1002);
    p.runInstanceNumber = 2;
    p openCJ\notifications::result("record", 1002);
    check(p.notificationResultPriority == 1, "old-instance record cannot upgrade flash");
    p.runInstanceNumber = 1;
    p.notificationResultUntil = getTime() - 1;
    p openCJ\notifications::result("record", 1002);
    check(p.notificationResultPriority == 1, "late record outside result window ignored");
    p openCJ\notifications::cancelFlash();
    p openCJ\notifications::beginResults(1002);
    p openCJ\notifications::action("load");
    p openCJ\notifications::result("record", 1002);
    check(!isDefined(p.notificationResultRun) && !p.notificationFlashResult &&
              isDefined(p.notificationFlashRight),
          "load cancels result window and returns to edge feedback");
    p openCJ\notifications::cancelFlash();
    p openCJ\notifications::beginResults(1002);
    p openCJ\notifications::cancelAll();
    check(!isDefined(p.notificationFlash) && !isDefined(p.notificationResultRun),
          "demo entry cancels active finish emphasis");
    p.playingDemo = true;
    p openCJ\notifications::beginResults(1002);
    check(!isDefined(p.notificationFlash), "demo playback cannot start result flash");
    p.playingDemo = false;
    p openCJ\notifications::cancelResults();

    row = [];
    for(i = 0; i < 15; i++)
    {
        row[i] = 0;
    }
    row[1] = 0;
    row[8] = 8000;
    row[9] = 8;
    row[10] = 10000;
    row[11] = 10;
    check(openCJ\recordNotices::improvement(row) == "time: 0:02.000 faster",
          "time improvement text");
    row[8] = 10000;
    check(openCJ\recordNotices::improvement(row) == "time: tied, 2 fewer RPGs",
          "time tiebreak text");
    row[1] = 1;
    check(openCJ\recordNotices::improvement(row) == "RPGs: 2 fewer", "RPG improvement text");
    row[9] = 10;
    row[8] = 8000;
    check(openCJ\recordNotices::improvement(row) == "RPGs: tied, 0:02.000 faster",
          "RPG tiebreak text");
    row[8] = 10000;
    check(openCJ\recordNotices::improvement(row) == "", "exact ties do not announce");
    row[10] = undefined;
    check(openCJ\recordNotices::improvement(row) == "", "first finish is not a beaten record");
    p openCJ\notifications::beginResults(1002);
    p openCJ\recordNotices::onRunFinished(1002);
    check(p.notificationResultPriority == 3, "actual matching record selects record emphasis");
    check(level.n72Public.size == 1 && level.n72Private.size == 1,
          "server record global and PB private");
    check(level.n72Private[0].player == 1, "PB only goes to finishing player");
    p openCJ\recordNotices::onRunFinished(1002);
    check(level.n72Public.size == 1 && level.n72Private.size == 1,
          "duplicate callback does not repeat announcement");
    p.notificationFinishedRun = undefined;
    p openCJ\recordNotices::onRunFinished(2002);
    check(level.n72Public.size == 1 && level.n72Private.size == 1,
          "ten-minutes-faster any percent run cannot beat checkpoint record");

    p openCJ\notifications::cancelFlash();
    p openCJ\notifications::cancelResults();
    level.challengesReady = true;
    level.challengeTierPoints[1] = 100;
    level.challengeTierPoints[2] = 0;
    p.challengePoints = 0;
    p.challengeRank = 1;
    before = level.n72Private.size;
    p openCJ\notifications::beginResults(1002);
    p openCJ\challenges::awardRun(1002);
    check(p.challengePoints == 10 && level.n72Private.size == before + 1,
          "actual challenge award prints private completion");
    check(p.notificationResultPriority == 2, "actual challenge award selects gold emphasis");
    p openCJ\notifications::cancelFlash();
    p openCJ\notifications::beginResults(1002);
    p openCJ\challenges::awardRun(1002);
    check(level.n72Private.size == before + 1 && p.notificationResultPriority == 1,
          "already awarded challenge does not repeat celebration");
    p openCJ\notifications::cancelFlash();
    p openCJ\notifications::cancelResults();

    rows = p openCJ\mySQL::mysqlAsyncRead(
        openCJ\recordNotices::checkpointQuery(1002, 1, "mix", 0, 0, 0, 0, "rpgs"));
    check(isDefined(rows) && rows.size == 1 && int(rows[0][0]) == 9000 && int(rows[0][1]) == 8,
          "checkpoint split excludes faster any percent result");
    rows = p openCJ\mySQL::mysqlAsyncRead(
        openCJ\recordNotices::checkpointQuery(2002, 1, "mix", 0, 1, 0, 0, "time"));
    check(isDefined(rows) && !rows.size, "any percent checkpoint has no comparable prior split");
    p.playerRuns_runID = 1002;
    p.runInstanceNumber = 1;
    level.checkpointLayoutEpoch = 1;
    p.FPSMode = "mix";
    p.allowHalfBeat = false;
    level.statisticsStrings_explosiveJumps = "fixtureRPGs";
    p.statistics["fixtureRPGs"] = 7;
    p.settingValues["lbsort"] = "time";
    p.settingValues["notify_checkpoint"] = 1;
    before = level.n72Private.size;
    p openCJ\recordNotices::checkpoint(1002, 1, 8000);
    check(level.n72Private.size == before + 1 &&
              level.n72Private[before].text == "Checkpoint passed | ^20:01.000 ahead",
          "checkpoint split uses comparable completed run");
    level.n72DelayCheckpoint = true;
    level.n72CheckpointWaiting = false;
    before = level.n72Private.size;
    p thread openCJ\recordNotices::checkpoint(1002, 1, 8000);
    waitForCheckpoint();
    p.playerRuns_runID = 9999;
    wait .30;
    check(level.n72Private.size == before, "late checkpoint response rejected after run change");
    p.playerRuns_runID = 1002;
    level.n72CheckpointWaiting = false;
    p thread openCJ\recordNotices::checkpoint(1002, 1, 8000);
    waitForCheckpoint();
    p openCJ\notifications::action("load");
    wait .30;
    check(level.n72Private.size == before, "load cancels pending checkpoint message");
    level.n72DelayCheckpoint = false;
    printf("N72 COMPLETE failures=" + level.n72Failures + " checks=" + level.n72Checks + "\n");
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
    for(i = 0; i < 100 && !level.n72CheckpointWaiting; i++)
    {
        wait .05;
    }
    check(level.n72CheckpointWaiting, "checkpoint response reached test delay");
}

// Hold delivery after the real query completes, so stale-result checks remain real.
observeSQLResult(query)
{
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
