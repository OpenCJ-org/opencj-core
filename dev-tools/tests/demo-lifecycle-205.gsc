#include openCJ\util;
// Isolated synthetic clients and in-memory demos. No database initialization.
main()
{
    initializeFixture();
    cacheOwnershipChecks();
    wait 1;
    player = addTestClient();
    follower = addTestClient();
    wait .2;
    check(isDefined(player) && isDefined(follower), "two isolated clients");
    if(!isDefined(player) || !isDefined(follower))
    {
        reportCompletion();
        return;
    }
    setup(player);
    setup(follower);
    follower.sessionState = "spectator";
    follower.sessionTeam = "spectator";
    follower followPlayer(player getEntityNumber());
    wait .1;
    verifyPlaybackReturn(player, follower, "demo");
    verifyPlaybackReturn(player, follower, "clip editor");
    verifyPlaybackReturn(player, follower, "clip preview");
    verifySharedHUDCleanup(player, follower);
    player clipDatabaseFailureChecks();
    reportCompletion();
}

// Prepare the database-free HUD and playback fixture.
initializeFixture()
{
    openCJ\demoRecording::_initConstants();
    // Record panels cancel their reads by SQL policy; no database is opened.
    openCJ\mySQL::_initConstants();
    level.lifecycleChecks = 0;
    level.lifecycleFailures = 0;
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\huds\infiniteHuds::onInit();
    openCJ\huds\hudFPSHistory::onInit();
    openCJ\huds\infiniteHuds::initInfiniteHud("fps");
    openCJ\statistics::onInit();
    openCJ\showRecords::onInit();
    openCJ\huds\hudProgressBar::onInit();
    openCJ\huds\hudRunInfo::onInit();
    openCJ\huds\hudOnScreenKeyboard::onInit();
    openCJ\checkpointPointers::onInit();
    openCJ\notifications::onInit();
    precacheMenu("opencj_demo");
    precacheMenu("opencj_clipedit");
    precacheMenu("opencj_clips");
    precacheItem("rpg_mp");
    level.demoCache = [];
    level.menu["ingame"] = "opencj_ingame";
}

// Each viewer mode must restore the same live run, motion, timer, counters and HUD state.
verifyPlaybackReturn(player, follower, playbackMode)
{
    // Normal demo, clip editor and browser preview use the same lifecycle.
    player.clipEdit = undefined;
    player.clipPreview = undefined;
    if(playbackMode == "clip editor")
    {
        player.clipEdit = spawnStruct();
    }
    if(playbackMode == "clip preview")
    {
        player.clipPreview = true;
    }
    player.playerRuns_runPaused = playbackMode == "clip editor";
    player.startTime = getTime() - 5000;
    player.stopTime = undefined;
    if(playbackMode == "clip editor")
    {
        player.stopTime = getTime();
    }
    player.playerRuns_runID = 17205;
    player.runInstanceNumber = 3;
    player.playerRuns_runStarted = false;
    player.playerRuns_runFinished = false;
    player.playerRuns_runFinishing = false;
    checkpoint = spawnStruct();
    checkpoint.id = 205;
    checkpoint.childs = [];
    checkpoint.checkpointsFromStart = 0;
    checkpoint.checkpointsTillEnd = 0;
    checkpoint.enders = [];
    player.checkpoints_checkpoint = checkpoint;
    player openCJ\huds\hudFPSHistory::_setFPSHistory("32-323");
    player.fpshistory["shortfps"] = "3";
    player.statistics[level.statisticsStrings_saveCount] = 7;
    player.statistics[level.statisticsStrings_loadCount] = 4;
    player.statistics[level.statisticsStrings_explosiveJumps] = 2;
    player.currSpeed = 123;
    player.maxSpeed = 456;
    player.health = 75;
    player setVelocity((12, 34, 0));
    player setStance("stand");
    player.notificationFlash = player openCJ\notifications::_createOverlay(0, 64, "white");
    player.notificationResultRun = 17205;
    player.notificationResultUntil = getTime() + 5000;
    player.statisticsHudString = "old";
    follower.statisticsHudString = "old";
    player.showRecords_nameString = "old";
    follower.showRecords_nameString = "old";
    player.progressBar.alpha = 1;
    demoID = demoCreateTransient();
    for(i = 0; i < 8; i++)
    {
        addFrameToDemo(demoID, (i, 0, 100), (0, 90, 0), 1, 8192, 0, 0, 0, 333, 0,
                       player getEntityNumber());
    }
    cache = spawnStruct();
    cache.refs = 1;
    cache.loading = false;
    cache.ready = true;
    level.demoCache["" + demoID] = cache;
    player.demoBegin = 0;
    player.demoEnd = 7;
    player.demoStyle = 0;
    originalOrigin = player.origin;
    originalAngles = player getPlayerAngles();
    originalVelocity = player getVelocity();
    playedTimeMs = player openCJ\playTime::getTimePlayed();
    wasPaused = player.playerRuns_runPaused;
    player openCJ\demos::startDemo(demoID);
    check(player openCJ\demos::isPlayingDemo(), "entered playback " + playbackMode);
    if(playbackMode == "clip editor")
    {
        player.clipEdit.first = 0;
        player.clipEdit.last = 7;
        player.clipEdit.id = demoID;
        player.clipEdit.busy = false;
        player.clipEdit.permanent = false;
        player openCJ\clips::seek(3);
        player openCJ\clips::editorResponse("start");
        check(player.clipEdit.first == 3 && player.clipEdit.last == 7,
              "editor start uses the current playback frame");
        player openCJ\clips::seek(5);
        player openCJ\clips::editorResponse("end");
        check(player.clipEdit.first == 3 && player.clipEdit.last == 5,
              "editor end preserves the selected start");
        player openCJ\clips::editorResponse("reset");
        check(player.clipEdit.first == 0 && player.clipEdit.last == 7,
              "editor reset restores the full recording range");
    }
    check(player.playerRuns_runPaused && isDefined(player.stopTime),
          "run timer paused " + playbackMode);
    check(!isDefined(player.notificationFlash) && !isDefined(player.notificationResultUntil),
          "pending feedback cancelled " + playbackMode);
    check(player.statisticsHudString == "" && follower.statisticsHudString == "",
          "statistics hidden for player and spectator " + playbackMode);
    check(player.showRecords_nameString == "" && follower.showRecords_nameString == "",
          "records hidden for player and spectator " + playbackMode);
    check(player.progressBar.alpha == 0 && player.hudSpeed["curr"].alpha == 0,
          "live progress and speed hidden " + playbackMode);
    check(player.hudTimeLimit.x == -8 && player.hudTimeLimit.y == -74 &&
              player.hudTimeLimit.alignX == "right",
          "timer clear of toolbar " + playbackMode);
    check(player.hudSpeed["curr"].hideWhenInMenu == (playbackMode != "demo") &&
              player.keyboard["forward"].hideWhenInMenu == (playbackMode != "demo"),
          "menu overlay policy " + playbackMode);
    player openCJ\events\eventHandler::onSavePositionRequest();
    check(!isDefined(player.eventQueue["save"]), "watching cannot enqueue a save " + playbackMode);
    player openCJ\events\eventHandler::onLoadPositionRequest(1);
    check(player.demoExitRequested && !isDefined(player.eventQueue["load"]),
          "load requests exit without changing run " + playbackMode);
    check(player.checkpoints_checkpoint == checkpoint && player.playerRuns_runID == 17205 &&
              player.runInstanceNumber == 3,
          "checkpoint and run unchanged during playback " + playbackMode);
    // Exercise the actual exit with a changed playback pose and health.
    player unlink();
    player setOrigin((400, 500, 600));
    player.health = 99;
    wait .1;
    player openCJ\demos::stopDemo(false);
    check(!player openCJ\demos::isPlayingDemo() && !isDefined(player.demoReturn) &&
              !isDefined(player.demoID),
          "exit clears playback state " + playbackMode);
    check(distanceSquared(player.origin, originalOrigin) < .01 &&
              distanceSquared(player getVelocity(), originalVelocity) < .01,
          "position and velocity restored " + playbackMode);
    check(distanceSquared(player getPlayerAngles(), originalAngles) < .01 && player.health == 75,
          "view and health restored " + playbackMode);
    check(player.playerRuns_runPaused == wasPaused && isDefined(player.stopTime) == wasPaused,
          "original paused/running state restored " + playbackMode);
    check(abs((player openCJ\playTime::getTimePlayed()) - playedTimeMs) < 51,
          "watching does not advance run time " + playbackMode);
    check(player.checkpoints_checkpoint == checkpoint && player.playerRuns_runID == 17205 &&
              player.runInstanceNumber == 3,
          "checkpoint and run survive exit " + playbackMode);
    check(player openCJ\statistics::getSaveCount() == 7 &&
              player openCJ\statistics::getLoadCount() == 4 &&
              player openCJ\statistics::getExplosiveJumps() == 2,
          "run counters unchanged " + playbackMode);
    check(player.fpsHistoryText == "32-323" && player.maxSpeed == 456,
          "live FPS history and maximum speed restored " + playbackMode);
    check(player.hudTimeLimit.x == 0 && player.hudTimeLimit.y == -12 &&
              player.hudTimeLimit.alignX == "center",
          "normal timer layout restored " + playbackMode);
    check(!isDefined(player.demoCaption) && player.hudSpeed["curr"].hideWhenInMenu &&
              !player.hudSpeed["curr"].archived,
          "temporary HUDs removed and menu policy restored " + playbackMode);
    check(!isDefined(level.demoCache["" + demoID]) && !isDefined(player.clipEdit) &&
              !isDefined(player.clipPreview),
          "cache and clip state released " + playbackMode);
    player openCJ\demos::stopDemo(false);
    check(player.checkpoints_checkpoint == checkpoint, "repeated stop is harmless " + playbackMode);
}

// Run and disconnect events must use the same HUD cleanup as playback.
verifySharedHUDCleanup(player, follower)
{
    // Other events retain the shared cleanup for the watched player too.
    player.statisticsHudString = "old";
    follower.statisticsHudString = "old";
    player openCJ\huds\hudStatistics::onRunCreated();
    check(player.statisticsHudString == "" && follower.statisticsHudString == "",
          "new run shares statistics cleanup");
    player.statisticsHudString = "old";
    follower.statisticsHudString = "old";
    player openCJ\huds\hudStatistics::onRunStopped();
    check(player.statisticsHudString == "" && follower.statisticsHudString == "",
          "stopped run shares statistics cleanup");
    player.showRecords_nameString = "old";
    follower.showRecords_nameString = "old";
    player openCJ\showRecords::onRunStopped();
    check(player.showRecords_nameString == "" && follower.showRecords_nameString == "",
          "stopped run shares records cleanup");
    player.notificationFlash = player openCJ\notifications::_createOverlay(0, 64, "white");
    player.notificationResultUntil = getTime() + 5000;
    player openCJ\notifications::onDisconnect();
    check(!isDefined(player.notificationFlash) && !isDefined(player.notificationResultUntil),
          "disconnect shares feedback cleanup");
}

// Report the completed assertions, including client setup failures.
reportCompletion()
{
    printf("DEMO LIFECYCLE COMPLETE failures=" + level.lifecycleFailures +
           " checks=" + level.lifecycleChecks + "\n");
}

setup(player)
{
    player.sessionState = "playing";
    player.sessionTeam = "allies";
    player.pers["team"] = "allies";
    player spawn((0, 0, 300), (0, 0, 0));
    player freezeControls(true);
    player.isFirstSpawn = false;
    player openCJ\settings::onPlayerConnect();
    player openCJ\huds\base::onPlayerConnect();
    player openCJ\huds\hudFPSHistory::onPlayerConnect();
    player.fpsHistoryMode = "compact";
    player openCJ\huds\hudSpeedometer::onPlayerConnect();
    player openCJ\huds\hudOnScreenKeyboard::onPlayerConnect();
    player openCJ\huds\hudProgressBar::onPlayerConnect();
    player openCJ\huds\hudRunInfo::onPlayerConnect();
    player openCJ\huds\hudTimeLimit::onPlayerConnect();
    player openCJ\showRecords::onPlayerConnect();
    player openCJ\checkpointPointers::onPlayerConnect();
    player openCJ\statistics::onPlayerConnect();
    player openCJ\playerCollision::onPlayerConnect();
    player.demoLinker = spawn("script_origin", (0, 0, 0));
    player.playingDemo = false;
    player.cheating = false;
    player.allowHalfBeat = false;
    player giveWeapon("rpg_mp");
    player setSpawnWeapon("rpg_mp");
}
check(ok, label)
{
    level.lifecycleChecks++;
    if(!isDefined(ok) || !ok)
    {
        level.lifecycleFailures++;
        printf("DEMO LIFECYCLE FAIL " + label + "\n");
    }
}

// Releasing one viewer must preserve shared work; the final release cancels its native owner.
cacheOwnershipChecks()
{
    demoID = 205001;
    key = "" + demoID;
    oldEntry = spawnStruct();
    oldEntry.refs = 2;
    oldEntry.loading = true;
    oldEntry.ready = false;
    oldEntry.cancelled = false;
    oldEntry.nativeCreated = true;
    level.demoCache[key] = oldEntry;
    check(createDemo(demoID) == demoID, "cache cancellation fixture owns a native recording");

    openCJ\demos::releaseCache(demoID);
    check(oldEntry.refs == 1 && !oldEntry.cancelled && isDefined(numberOfDemoFrames(demoID)),
          "another viewer preserves a shared load");
    openCJ\demos::releaseCache(demoID);
    cancelled = oldEntry.cancelled;
    check(cancelled, "last viewer cancels the loading cache entry");
    check(!isDefined(level.demoCache[key]) && !isDefined(numberOfDemoFrames(demoID)),
          "last viewer releases cache and native ownership");

    check(createDemo(demoID) == demoID, "replacement native recording can reuse the ID");
    addFrameToDemo(demoID, (1, 2, 3), (0, 0, 0), 1, 0, 0, 0, 0, 333);
    replacement = spawnStruct();
    replacement.refs = 1;
    replacement.loading = false;
    replacement.ready = true;
    level.demoCache[key] = replacement;
    openCJ\demos::_loadCache(demoID, 2, oldEntry);
    check(numberOfDemoFrames(demoID) == 1 && level.demoCache[key] == replacement,
          "obsolete loader cannot replace a newer recording with the same ID");
    openCJ\demos::releaseCache(demoID, oldEntry);
    check(replacement.refs == 1 && numberOfDemoFrames(demoID) == 1,
          "late cache release cannot affect a replacement entry");

    owner = spawnStruct();
    owner.demoPendingId = demoID;
    owner.demoPendingCache = replacement;
    owner openCJ\demos::releasePending(oldEntry);
    check(isDefined(owner.demoPendingId) && owner.demoPendingCache == replacement &&
              replacement.refs == 1,
          "late cleanup cannot release a newer pending request");

    openCJ\demos::releaseCache(demoID);
    destroyDemo(demoID);
    level.demoCache[key] = undefined;
}

// The fixture has no SQL connection: synchronous timestamp/UUID reads must fail cleanly.
clipDatabaseFailureChecks()
{
    check(!openCJ\clips::initializeSessions(), "missing session identity leaves clips unavailable");
    level.clipStorageReady = true;
    level.demoStorageReady = true;
    level.mapid_mapID = 1;
    level.clipSession = "isolated";
    self.login_playerID = 1;
    self openCJ\clips::record();
    check(!isDefined(self.clipRecording), "missing timestamp leaves no clip recording");

    nativeID = demoCreateTransient();
    addFrameToDemo(nativeID, (0, 0, 100), (0, 90, 0), 1, 0, 0, 0, 0, 333);
    addFrameToDemo(nativeID, (1, 0, 100), (0, 90, 0), 1, 0, 0, 0, 0, 333);
    recording = spawnStruct();
    recording.id = nativeID;
    recording.first = 0;
    recording.last = 1;
    recording.busy = false;
    recording.permanent = true;
    recording.date = "2026-01-01 00:00:00";
    self.clipEdit = recording;
    self openCJ\clips::submit("Fixture clip");
    check(!recording.busy && !isDefined(self.clipUploadNative) && !isDefined(self.clipUploadToken),
          "missing upload token releases its pin and permits another attempt");
    check(self.clipEdit == recording && numberOfDemoFrames(nativeID) == 2,
          "failed upload preserves the editor recording");
    recording.first = -1;
    self openCJ\clips::submit("Fixture clip");
    check(!recording.busy && !isDefined(self.clipUploadNative),
          "invalid native range releases the upload pin");
    self.clipEdit = undefined;
    destroyDemo(nativeID);
    check(!isDefined(numberOfDemoFrames(nativeID)), "failed upload leaves no native pin behind");
}
