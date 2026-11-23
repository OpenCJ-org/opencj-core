#include openCJ\util;
// Isolated synthetic clients and in-memory demos. No database initialization.
main()
{
    initializeFixture();
    wait 1;
    viewer = addTestClient();
    sourcePlayer = addTestClient();
    wait .2;
    if(!isDefined(viewer) || !isDefined(sourcePlayer))
    {
        check(false, "two isolated clients are available");
        reportCompletion();
        return;
    }
    setup(viewer);
    setup(sourcePlayer);
    viewer.playerRuns_runPaused = false;
    viewer.playerRuns_runFinishing = false;
    viewer.playerRuns_runFinished = false;
    sourcePlayer.playerRuns_runPaused = false;
    sourcePlayer.playerRuns_runFinishing = false;
    sourcePlayer.playerRuns_runFinished = false;
    viewer.startTime = getTime();
    sourcePlayer.startTime = getTime();
    verifyHistoryCopyAndCodec(viewer);
    verifyTechniqueHistory(viewer);
    verifyRPGConversion(viewer);
    verifyCheckpointProgress(viewer);
    verifyHistoryCommand(viewer, sourcePlayer);
    verifyCopyBudget();
    reportCompletion();
}

// Initialize only the components used by these database-free scenarios.
initializeFixture()
{
    openCJ\demoRecording::_initConstants();
    level.lifecycleChecks = 0;
    level.lifecycleFailures = 0;
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\settings::addSettingBool("sharehistory", true, "History sharing");
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
    level.demoStorageReady = true;
}

// Copies retain frames and metadata independently of source edits and destruction.
verifyHistoryCopyAndCodec(viewer)
{
    demoID = demoCreateTransient();
    // WA -> WD -> WA; non-key samples model the failed part of a run.
    for(i = 0; i < 15; i++)
    {
        flags = 5;
        if(i >= 5 && i < 10)
        {
            flags = 6;
        }
        if(i == 0 || i == 14)
        {
            flags |= 8192;
        }
        addFrameToDemo(demoID, (i, 0, 100), (0, 90, 0), int(i != 3), flags, 0, 0, int(i == 13), 333,
                       0, viewer getEntityNumber(), int(i == 11));
    }
    viewer selectPlaybackDemo(demoID);
    viewer skipPlaybackFrames(6);
    viewer demoSetTechnique(2);
    check((viewer readPlaybackFrame_flags() & 15) == 2, "fullbeat converted to halfbeat keys");
    viewAngles = viewer readPlaybackFrame_angles();
    check(viewAngles[1] > 90 && viewAngles[1] <= 135,
          "camera eases into converted strafe near RPG aiming");
    check(viewer readPlaybackFrame_fps() == 333, "conversion preserves FPS");
    viewer demoSetTechnique(0);
    check((viewer readPlaybackFrame_flags() & 15) == 6, "original keys restored");
    viewer demoSetTechnique(2);
    viewer skipPlaybackFrames(7);
    check(!(viewer demoTechniqueFallback()), "compatible RPG aim keeps consistent conversion");
    viewAngles = viewer readPlaybackFrame_angles();
    check(abs(viewAngles[1] - 90) < .01, "RPG aim direction remains exact");
    copyID = demoCopyHistory(demoID);
    check(isDefined(copyID) && copyID != demoID && numberOfDemoFrames(copyID) == 15,
          "history copied natively");
    addFrameToDemo(demoID, (999, 0, 0), (0, 0, 0), 1, 0, 0, 0, 0, 125);
    demoMarkFailedSince(demoID, 0);
    check(numberOfDemoFrames(copyID) == 15 && numberOfDemoFrames(demoID) == 16,
          "copy independent of source growth");
    viewer selectPlaybackDemo(copyID);
    viewer demoSetTechnique(0);
    check(numberOfDemoKeyFrames(copyID) == 14,
          "copied successful frames preserved after source rewind");
    rangeInfo = demoRangeInfo(copyID, 0, 14);
    check(rangeInfo[0] == 1 && rangeInfo[1] == 1 && rangeInfo[2] == 1,
          "full range captures shot/FPS/elevation");
    rangeInfo = demoRangeInfo(copyID, 0, 9);
    check(rangeInfo[0] == 0 && rangeInfo[2] == 0, "trim excludes later shot and elevation");
    encoded = demoEncodeChunk(copyID, 0, 15);
    decodedID = demoCreateTransient();
    check(demoDecodeChunk(decodedID, encoded) == 15, "OCJ5 round trip");
    rangeInfo = demoRangeInfo(decodedID, 0, 14);
    check(rangeInfo[0] == 1 && rangeInfo[2] == 1, "OCJ5 retains event metadata");
    check(numberOfDemoKeyFrames(decodedID) == 14, "OCJ5 retains failed frames");
    legacyID = demoCreateTransient();
    check(demoDecodeChunk(legacyID, "789cf377f63261644006279ca00c055f8804003888028a") == 1,
          "legacy OCJ4 loads");
    rangeInfo = demoRangeInfo(legacyID, 0, 0);
    check(rangeInfo[2] == -1, "legacy elevation remains unknown");
    check(rangeInfo[1] == -1, "ground-only footage does not invent an airborne FPS category");
    destroyDemo(demoID);
    destroyDemo(decodedID);
    destroyDemo(legacyID);
    check(numberOfDemoFrames(copyID) == 15, "source destruction leaves fixed copy playable");
    destroyDemo(copyID);
}

// Reuse one recording across technique changes and seeks to exercise cache invalidation.
verifyTechniqueHistory(viewer)
{
    styleDemoID = demoCreateTransient();
    for(i = 0; i < 40; i++)
    {
        flags = 5;
        if((i >= 10 && i < 20) || i >= 30)
        {
            flags = 6;
        }
        if(i == 0 || i == 39)
        {
            flags |= 8192;
        }
        framesPerSecond = 333;
        if(i >= 15 && i < 25)
        {
            framesPerSecond = 250;
        }
        addFrameToDemo(styleDemoID, (i * 5, 0, 100), (0, 90, 0), 1, flags, 0, 0, 0,
                       framesPerSecond);
    }
    viewer selectPlaybackDemo(styleDemoID);
    viewer.demoID = styleDemoID;
    viewer.demoStyle = 0;
    viewer.demoBegin = 0;
    viewer.demoEnd = 39;
    viewer.demoFPSWaiting = false;
    viewer.demoFPSFloor = undefined;
    viewer.fpsHistoryMode = "compact";
    viewer.demoTechnique = 0;
    viewer demoSetTechnique(0);
    viewer skipPlaybackFrames(38);
    viewer openCJ\demos::syncDemoFPSHistory(38);
    originalCompactText = viewer.fpsHistoryText;
    viewer.demoTechnique = 2;
    viewer demoSetTechnique(2);
    viewer openCJ\demos::syncDemoFPSHistory(38);
    check(viewer.fpsHistoryText == originalCompactText,
          "Compact is unchanged by viewing technique");
    viewer.fpsHistoryMode = "detailed";
    viewer openCJ\demos::syncDemoFPSHistory(38);
    convertedDetailedText = viewer demoFPSRead(38);
    viewer.demoTechnique = 0;
    viewer demoSetTechnique(0);
    viewer openCJ\demos::syncDemoFPSHistory(38);
    check((viewer demoFPSRead(38)) != convertedDetailedText,
          "Detailed follows converted key interpretation");
    printf("DEMO VIEWING FPS original=" + (viewer demoFPSRead(38)) +
           " halfbeat=" + convertedDetailedText + " compact=" + originalCompactText + "\n");
    viewer.demoTechnique = 2;
    viewer demoSetTechnique(2);
    viewer skipPlaybackFrames(12 - (viewer skipPlaybackFrames(0)));
    viewer openCJ\demos::syncDemoFPSHistory(12);
    viewer skipPlaybackFrames(38 - (viewer skipPlaybackFrames(0)));
    viewer openCJ\demos::syncDemoFPSHistory(38);
    check((viewer demoFPSRead(38)) == convertedDetailedText,
          "converted Detailed survives reverse/seek rebuild");
    viewer.playingDemo = true;
    viewer.demoFPSCacheKey = undefined;
    viewer skipPlaybackFrames(14 - (viewer skipPlaybackFrames(0)));
    viewer openCJ\demos::syncDemoFPSHistory(14);
    check(isSubStr(viewer demoFPSRead(14), "^2D ^7"),
          "Detailed shows converted halfbeat before return or landing");
    viewer.demoTechnique = 3;
    check(viewer demoSetTechnique(3), "native Invert mode accepted");
    viewer.demoFPSCacheKey = undefined;
    viewer skipPlaybackFrames(24 - (viewer skipPlaybackFrames(0)));
    viewer openCJ\demos::syncDemoFPSHistory(24);
    invertedDetailedText = viewer demoFPSRead(24);
    check((viewer readPlaybackFrame_flags() & 15) == 1, "Invert converts the return strafe to A");
    check(isSubStr(invertedDetailedText, "^2D ^7") && isSubStr(invertedDetailedText, "^6A ^7"),
          "Detailed shows both Invert sides while airborne");
    check(isSubStr(invertedDetailedText, "^6WA ^7"), "Invert history keeps diagonal takeoff");
    viewer.fpsHistoryMode = "compact";
    viewer openCJ\demos::syncDemoFPSHistory(38);
    check(viewer.fpsHistoryText == originalCompactText,
          "Invert keeps Compact FPS independent of keys");
    viewer.fpsHistoryMode = "detailed";
    viewer skipPlaybackFrames(14 - (viewer skipPlaybackFrames(0)));
    viewer openCJ\demos::syncDemoFPSHistory(14);
    check((viewer readPlaybackFrame_flags() & 15) == 2, "reverse Invert selects D");
    viewer skipPlaybackFrames(24 - (viewer skipPlaybackFrames(0)));
    viewer openCJ\demos::syncDemoFPSHistory(24);
    check((viewer demoFPSRead(24)) == invertedDetailedText,
          "Invert Detailed survives reverse and forward seek");
    viewer.demoTechnique = 0;
    viewer demoSetTechnique(0);
    for(toggleCount = 1; toggleCount <= 4; toggleCount++)
    {
        viewer openCJ\demos::toggleTechnique();
        check(viewer.demoTechnique == toggleCount % 4, "viewer cycles all four techniques");
    }
    check(viewer.demoTechniqueLabel == "Original", "fourth toggle returns to Original label");
    check(!(viewer demoSetTechnique(4)), "invalid fifth technique rejected");
    viewer.playingDemo = false;
    destroyDemo(styleDemoID);
    viewer.demoID = undefined;
    viewer.demoTechnique = 0;
    viewer.fpsHistoryMode = "compact";
}

// Converted movement keys must preserve the original RPG aim and recorded chronology.
verifyRPGConversion(viewer)
{
    rpgDemoID = demoCreateTransient();
    for(i = 0; i < 35; i++)
    {
        flags = 5;
        if(i >= 7 && i < 21)
        {
            flags = 6;
        }
        if(i == 0 || i == 34)
        {
            flags |= 8192;
        }
        addFrameToDemo(rpgDemoID, (i * 5, 0, 100), (0, 90, 0), 1, flags, 0, 0, int(i == 14), 333);
    }
    viewer selectPlaybackDemo(rpgDemoID);
    viewer.demoID = rpgDemoID;
    viewer.demoStyle = 0;
    viewer.demoBegin = 0;
    viewer.demoEnd = 34;
    viewer.demoTechnique = 2;
    viewer demoSetTechnique(2);
    viewer.fpsHistoryMode = "detailed";
    viewer.playingDemo = true;
    viewer.demoFPSCacheKey = undefined;
    for(i = 0; i <= 25; i++)
    {
        viewer skipPlaybackFrames(i - (viewer skipPlaybackFrames(0)));
        viewer openCJ\demos::syncDemoFPSHistory(i);
        if(i == 3)
        {
            check((viewer readPlaybackFrame_flags() & 15) == 5,
                  "RPG-aware halfbeat preserves diagonal takeoff");
        }
        if(i >= 7 && i < 21)
        {
            check((viewer readPlaybackFrame_flags() & 15) == 2,
                  "RPG strafe remains converted through the shot");
        }
        if(i == 14)
        {
            viewAngles = viewer readPlaybackFrame_angles();
            check(abs(viewAngles[1] - 90) < .01, "RPG-aware conversion retains exact shot aim");
        }
    }
    check(isSubStr(viewer demoFPSRead(25), "^2D ^7"),
          "Detailed includes the converted RPG strafe during the jump");
    check(isSubStr(viewer demoFPSRead(25), "^6WA ^7"),
          "Detailed keeps initial takeoff instead of relabeling it");
    viewer skipPlaybackFrames(14 - 25);
    viewer openCJ\demos::syncDemoFPSHistory(14);
    check(isSubStr(viewer demoFPSRead(14), "^2D ^7"),
          "reverse restores converted RPG strafe label");
    viewer.playingDemo = false;
    destroyDemo(rpgDemoID);
    viewer.demoID = undefined;
}

// Checkpoint labels follow recorded progress, including reverse playback.
verifyCheckpointProgress(viewer)
{
    checkpoint = spawnStruct();
    checkpoint.id = 123;
    checkpoint.checkpointsFromStart = 3;
    ending = spawnStruct();
    ending.checkpointsFromStart = 52;
    level.checkpoints_checkpoints = [];
    level.checkpoints_checkpoints[0] = checkpoint;
    level.routeEnders = [];
    level.routeEnders["test"] = [];
    level.routeEnders["test"][0] = ending;
    progressDemoID = demoCreateTransient();
    addFrameToDemo(progressDemoID, (0, 0, 0), (0, 0, 0), 1, 8192, 0, 0, 0, 125, 0);
    addFrameToDemo(progressDemoID, (0, 0, 0), (0, 0, 0), 1, 8192, 0, 0, 0, 125, 123);
    viewer selectPlaybackDemo(progressDemoID);
    viewer.demoRouteName = "test";
    viewer.demoCheckpointed = true;
    check((viewer openCJ\demos::demoCheckpointText()) == "Checkpoint 0 / 52",
          "demo starts at route checkpoint zero");
    viewer skipPlaybackFrames(1);
    check((viewer openCJ\demos::demoCheckpointText()) == "Checkpoint 3 / 52",
          "progress uses recorded checkpoint and selected route");
    viewer skipPlaybackFrames(-1);
    check((viewer openCJ\demos::demoCheckpointText()) == "Checkpoint 0 / 52",
          "checkpoint progress follows reverse seek");
    viewer.demoCheckpointed = false;
    check((viewer openCJ\demos::demoCheckpointText()) == "",
          "Any percent hides checkpoint progress");
    viewer.demoRouteName = undefined;
    destroyDemo(progressDemoID);
}

// Exercise the real history command, opt-out behavior, and copy cleanup.
verifyHistoryCommand(viewer, sourcePlayer)
{
    // Actual command path: source capture continues; stop releases only the copy.
    sourceDemoID = demoCreateTransient();
    for(i = 0; i < 20; i++)
    {
        addFrameToDemo(sourceDemoID, (i, 0, 100), (0, 0, 0), 1, 8192, 0, 0, 0, 125);
    }
    sourcePlayer.runInstanceNumber = 1;
    sourcePlayer.playerRuns_runID = sourceDemoID;
    sourcePlayer.playerRuns_runFinished = false;
    sourcePlayer.demoRecordings = [];
    recording = spawnStruct();
    recording.id = sourceDemoID;
    recording.failed = false;
    recording.finishing = false;
    sourcePlayer.demoRecordings["" + sourceDemoID] = recording;
    args = [];
    args[0] = sourcePlayer.name;
    viewer thread openCJ\demos::viewHistory(args);
    wait .1;
    check(viewer openCJ\demos::isPlayingDemo(), "view command starts fixed history");
    watchedCopyID = viewer.demoID;
    check(viewer.demoHistorySource == sourcePlayer && viewer.demoAuthor == sourcePlayer.name,
          "correct source attribution");
    check(watchedCopyID != sourceDemoID && numberOfDemoFrames(watchedCopyID) == 20,
          "view command owns separate native copy");
    viewer.settingValues["demoloop"] = true;
    viewer skipPlaybackFrames(viewer.demoEnd - (viewer skipPlaybackFrames(0)));
    viewer openCJ\demos::_endOfDemo();
    check(viewer.playbackPaused && !viewer.demoLoopPending,
          "fixed history pauses at the end despite demoloop");
    lastFrame = viewer skipPlaybackFrames(0);
    viewer.demoFirstFrame = false;
    viewer openCJ\demos::whilePlayingDemo();
    check((viewer skipPlaybackFrames(0)) == lastFrame && viewer openCJ\demos::isPlayingDemo(),
          "history remains on final frame for review");
    viewer.demoHistorySource = undefined;
    viewer.playbackPaused = false;
    viewer openCJ\demos::_endOfDemo();
    check(viewer.playbackPaused && !viewer.demoLoopPending,
          "source disconnection cannot enable history looping");
    viewer.demoHistorySource = sourcePlayer;
    sourcePlayer openCJ\demos::_shareHistory(false);
    check(viewer.demoExitRequested, "opt-out ends an existing other-player view");
    viewer openCJ\demos::stopDemo(false);
    check(!isDefined(level.demoCache["" + watchedCopyID]) && numberOfDemoFrames(sourceDemoID) == 20,
          "exit frees copy without source damage");
    sourcePlayer.settingValues["sharehistory"] = false;
    viewer thread openCJ\demos::viewHistory(args);
    wait .1;
    check(!viewer openCJ\demos::isPlayingDemo(), "opt-out denies a new view");
    sourcePlayer.settingValues["sharehistory"] = true;
    viewer thread openCJ\demos::viewHistory(args);
    wait .1;
    viewer.demoTechnique = 2;
    viewer demoSetTechnique(2);
    viewer openCJ\demos::stopDemo(false);
    check(viewer.demoTechnique == 2, "technique choice survives viewer close");
    destroyDemo(sourceDemoID);
}

// Exhaust the copy budget without changing or destroying the source recording.
verifyCopyBudget()
{
    // Bound native memory with all 32 potential viewers; reject excess without
    // touching the source. Measure copying separately from fixture creation.
    sourceDemoID = demoCreateTransient();
    for(i = 0; i < 36000; i++)
    {
        addFrameToDemo(sourceDemoID, (0, 0, 100), (0, 0, 0), 1, 8192, 0, 0, 0, 125);
        if(i % 500 == 0)
        {
            wait .05;
        }
    }
    copies = [];
    for(i = 0; i < 32; i++)
    {
        copyID = demoCopyHistory(sourceDemoID);
        if(isDefined(copyID))
        {
            copies[copies.size] = copyID;
        }
    }
    check(copies.size > 0 && numberOfDemoFrames(sourceDemoID) == 36000,
          "32 viewers respect native memory bound and preserve recording");
    printf("DEMO VIEWING COPY copies=" + copies.size + " requested=32 frames=36000\n");
    rejected = false;
    for(i = copies.size; i < 64; i++)
    {
        copyID = demoCopyHistory(sourceDemoID);
        if(!isDefined(copyID))
        {
            rejected = true;
            break;
        }
        copies[copies.size] = copyID;
    }
    check(rejected && numberOfDemoFrames(sourceDemoID) == 36000,
          "extra copies stop at the native budget without corrupting the source");
    for(i = 0; i < copies.size; i++)
    {
        destroyDemo(copies[i]);
    }
    destroyDemo(sourceDemoID);
}

// Report failures even if fixture setup could not create its clients.
reportCompletion()
{
    printf("DEMO VIEWING COMPLETE failures=" + level.lifecycleFailures +
           " checks=" + level.lifecycleChecks + "\n");
}

setup(viewer)
{
    viewer.sessionState = "playing";
    viewer.sessionTeam = "allies";
    viewer.pers["team"] = "allies";
    viewer spawn((0, 0, 300), (0, 0, 0));
    viewer freezeControls(true);
    viewer.isFirstSpawn = false;
    viewer openCJ\settings::onPlayerConnect();
    viewer openCJ\huds\base::onPlayerConnect();
    viewer openCJ\huds\hudFPSHistory::onPlayerConnect();
    viewer.fpsHistoryMode = "compact";
    viewer openCJ\huds\hudSpeedometer::onPlayerConnect();
    viewer openCJ\huds\hudOnScreenKeyboard::onPlayerConnect();
    viewer openCJ\huds\hudProgressBar::onPlayerConnect();
    viewer openCJ\huds\hudRunInfo::onPlayerConnect();
    viewer openCJ\huds\hudTimeLimit::onPlayerConnect();
    viewer openCJ\showRecords::onPlayerConnect();
    viewer openCJ\checkpointPointers::onPlayerConnect();
    viewer openCJ\statistics::onPlayerConnect();
    viewer openCJ\playerCollision::onPlayerConnect();
    viewer.statisticsHudString = "";
    viewer.showRecords_nameString = "";
    viewer.currSpeed = 0;
    viewer.maxSpeed = 0;
    viewer.demoLinker = spawn("script_origin", (0, 0, 0));
    viewer.playingDemo = false;
    viewer.cheating = false;
    viewer.allowHalfBeat = false;
    viewer giveWeapon("rpg_mp");
    viewer setSpawnWeapon("rpg_mp");
}
check(ok, label)
{
    level.lifecycleChecks++;
    if(!isDefined(ok) || !ok)
    {
        level.lifecycleFailures++;
        printf("DEMO VIEWING FAIL " + label + "\n");
    }
}
