#include openCJ\util;

onInit()
{
    if(getCodVersion() == 4)
    {
        precacheMenu("opencj_demo");
    }
    openCJ\commands_base::registerCommand(
        "view", "Watch a fixed copy of a player\'s current run history. Usage: !view <player>",
        ::_viewHistory, 1, undefined);
    openCJ\settings::addSettingBool(
        "sharehistory", true,
        "Allow others to view your current run history. Usage: !sharehistory on|off",
        ::_shareHistory);
    clearAllDemos();
    level.demoCache = [];
    openCJ\demoRecording::onInit();
    cmd = openCJ\commands_base::registerCommand(
        "demo",
        "!demo [wt|sr|rpg|stop|pause|resume|speed <0.25|0.5|1|2|4>|forward|reverse|next|previous]",
        ::_onCommandPlayback, 0, 2);
    openCJ\commands_base::addAlias(cmd, "playback");
    openCJ\commands_base::registerCommand(
        "srdemo",
        "Watch the fastest compatible demo at your checkpoint or nearby area. Usage: !srdemo",
        ::_onCommandSpeedrun, 0, 0);
    setting = openCJ\settings::addSettingBool("demoloop", true, "Loop demo playback");
    openCJ\commands_base::addAlias(setting, "loop");
}

_onCommandPlayback(args)
{
    if((args.size && args[0] == "stop") || (!args.size && self isPlayingDemo()))
    {
        self cancelRequest();
        self thread doNextFrame(::stopDemo);
        return;
    }
    if(self isPlayingDemo() && args.size)
    {
        action = toLower(args[0]);
        if(action == "pause" || action == "resume" || action == "speed" || action == "forward" ||
           action == "reverse" || action == "next" || action == "previous")
        {
            if(action == "pause")
            {
                self.playbackPaused = true;
            }
            if(action == "resume")
            {
                self.playbackPaused = false;
            }
            if(action == "speed" && args.size > 1)
            {
                self setDemoSpeed(args[1]);
            }
            if(action == "forward" || action == "reverse")
            {
                self setDemoDirection(action);
            }
            if(action == "next")
            {
                self.demoCheckpointRequest = 1;
            }
            if(action == "previous")
            {
                self.demoCheckpointRequest = -1;
            }
            return;
        }
    }
    kind = "walkthrough";
    if(args.size)
    {
        kind = toLower(args[0]);
    }
    if(kind == "wt")
    {
        kind = "walkthrough";
    }
    if(kind == "sr")
    {
        kind = "speedrun";
    }
    if(kind == "rpg" || kind == "low")
    {
        kind = "lowrpg";
    }
    if(kind != "walkthrough" && kind != "speedrun" && kind != "lowrpg")
    {
        self sendLocalChatMessage("Use !demo wt, !demo sr, !demo rpg, or !demo stop.", true);
        return;
    }
    self thread request(kind);
}

_onCommandSpeedrun(args)
{
    self thread request("speedrun");
}

request(kind)
{
    self cancelRequest();
    self endon("demo_request");
    self endon("disconnect");
    if(!self canWatch())
    {
        return;
    }
    location = self selectionLocation();
    if(!location.checkpoints.size && kind != "speedrun")
    {
        self sendLocalChatMessage("Stand in a checkpoint to watch its demo.", true);
        return;
    }
    fpsMode = self openCJ\fps::getCurrentFPSMode();
    modeMask = level.demoModes.anyPercent * int(self openCJ\anyPct::hasAnyPct()) +
               level.demoModes.elevators * int(self openCJ\elevate::hasUsedEle()) +
               level.demoModes.halfbeat * int(self openCJ\halfBeat::isHalfBeatAllowed()) +
               level.demoModes.hardTAS * int(self openCJ\tas::hasHardTAS());
    rows = self openCJ\mySQL::mysqlAsyncRead(
        candidateQuery(location, kind, fpsMode, modeMask, openCJ\mapID::getMapID()));
    if(!isDefined(rows))
    {
        self sendLocalChatMessage("Could not look up demos. Please try again.", true);
        return;
    }
    if(rows.size)
    {
        self sendLocalChatMessage("Finding a demo for this location...");
    }
    selected = self selectCandidate(rows, location, kind);
    if(!isDefined(selected))
    {
        self sendLocalChatMessage("No matching demo is available here for these modes.", true);
        return;
    }
    self playRun(selected.id, false, kind, selected.range);
    self releaseSelection();
}

candidateQuery(location, kind, fpsMode, allowedModes, mapID)
{
    if(kind == "walkthrough")
    {
        allowedModes = 0;
        if(fpsMode == "hax")
        {
            fpsMode = "mix";
        }
        fpsFilter = "(" + dbStr(fpsMode) + ")";
    }
    else
    {
        fpsFilter = openCJ\menus\board_base::getFPSModeStr(fpsMode);
    }
    routeIDs = getArrayKeys(location.routes);
    routeFilter = "";
    if(routeIDs.size)
    {
        routeIDList = "";
        for(i = 0; i < routeIDs.size; i++)
        {
            if(i)
            {
                routeIDList += ",";
            }
            routeIDList += int(routeIDs[i]);
        }
        routeFilter = " AND w.routeID IN (" + routeIDList + ")";
    }
    winnerOrder = "d.timePlayed,d.explosiveJumps";
    if(kind == "lowrpg")
    {
        winnerOrder = "d.explosiveJumps,d.timePlayed";
    }
    return "SELECT d.runID,d.modeMask,d.frameCount" +
           " FROM demoWinners w JOIN demoRuns d ON d.runID=w.runID" +
           " WHERE d.ready=1 AND w.mapID=" + mapID + routeFilter + " AND w.kind=" + dbStr(kind) +
           " AND (w.modeMask & " + allowedModes + ")=w.modeMask" + " AND w.FPSMode IN " +
           fpsFilter + " ORDER BY " + winnerOrder +
           ",BIT_COUNT(d.modeMask),FIELD(d.FPSMode,'125','mix','hax'),d.runID";
}

// Capture physical context once. A finished run or a stale route after noclip
// must neither hide a valid shared-start demo nor select an unrelated lesson.
selectionLocation()
{
    location = spawnStruct();
    location.origin = self.origin;
    location.checkpoints = [];
    location.routes = [];
    groundEntity = self getGroundEntity();
    for(i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        checkpoint = level.checkpoints_checkpoints[i];
        if(!self openCJ\checkpoints::touchesArea(checkpoint, true, groundEntity))
        {
            continue;
        }
        if(isDefined(checkpoint.bigBrother))
        {
            checkpoint = checkpoint.bigBrother;
        }
        location.checkpoints["" + checkpoint.id] = checkpoint.id;
        endCheckpoints = openCJ\checkpoints::getEndCheckpoints(checkpoint);
        if(!isDefined(endCheckpoints))
        {
            continue;
        }
        for(j = 0; j < endCheckpoints.size; j++)
        {
            if(isDefined(endCheckpoints[j].finishRouteID))
            {
                location.routes["" + endCheckpoints[j].finishRouteID] = true;
            }
        }
    }
    return location;
}

segmentAtLocation(runID, matchByPosition, skipFailedFrames, location)
{
    checkpointKeys = getArrayKeys(location.checkpoints);
    bestRange = undefined;
    for(i = 0; i < checkpointKeys.size; i++)
    {
        range = demoFindSegment(runID, location.checkpoints[checkpointKeys[i]], location.origin,
                                matchByPosition, skipFailedFrames, 1);
        if(isDefined(range) && betterLesson(range, bestRange))
        {
            bestRange = range;
        }
    }
    if(checkpointKeys.size)
    {
        return bestRange;
    }
    // Only speedrun requests reach this spatial fallback. Strict matching
    // rejects the legacy Any% fallback to an unrelated complete recording.
    return demoFindSegment(runID, 0, location.origin, 1, skipFailedFrames, 1);
}

betterLesson(candidateRange, previousRange)
{
    if(!isDefined(previousRange))
    {
        return true;
    }
    // demoFindSegment returns start, end, RPG shots, then successful frame count.
    candidateRPGShots = candidateRange[2];
    previousRPGShots = previousRange[2];
    if(candidateRPGShots != previousRPGShots)
    {
        return candidateRPGShots < previousRPGShots;
    }
    candidateFrames = candidateRange[3];
    previousFrames = previousRange[3];
    return candidateFrames < previousFrames;
}

// The winner query is already ordered by full-run time/RPG policy. Walkthrough
// choices instead compare the actual matching jump, not the length of its route.
selectCandidate(rows, location, kind)
{
    selectedCandidate = undefined;
    for(i = 0; i < rows.size; i++)
    {
        runID = int(rows[i][0]);
        modeMask = int(rows[i][1]);
        frameCount = int(rows[i][2]);
        if(!self acquireCache(runID, frameCount))
        {
            continue;
        }
        range = segmentAtLocation(runID, modeMask & level.demoModes.anyPercent,
                                  int(kind != "speedrun"), location);
        previousRange = undefined;
        if(isDefined(selectedCandidate))
        {
            previousRange = selectedCandidate.range;
        }
        if(isDefined(range) && (kind != "walkthrough" || betterLesson(range, previousRange)))
        {
            self releaseSelection();
            self.demoSelectionId = runID;
            self.demoSelectionCache = self.demoPendingCache;
            self.demoPendingId = undefined;
            self.demoPendingCache = undefined;
            selectedCandidate = spawnStruct();
            selectedCandidate.id = runID;
            selectedCandidate.range = range;
            if(kind != "walkthrough")
            {
                break;
            }
        }
        else
        {
            self releasePending();
        }
    }
    return selectedCandidate;
}

// Each pending viewer holds this exact entry, so a reused run ID cannot inherit old work.
acquireCache(runID, expectedFrames)
{
    key = "" + runID;
    startLoading = !isDefined(level.demoCache[key]);
    if(startLoading)
    {
        cache = spawnStruct();
        cache.loading = true;
        cache.ready = false;
        cache.cancelled = false;
        cache.nativeCreated = false;
        cache.refs = 0;
        level.demoCache[key] = cache;
    }
    cache = level.demoCache[key];
    cache.refs++;
    self.demoPendingId = runID;
    self.demoPendingCache = cache;
    if(startLoading)
    {
        level thread _loadCache(runID, expectedFrames, cache);
    }
    while(cache.loading)
    {
        if(!self ownsPendingCache(runID, cache))
        {
            return false;
        }
        wait 0.05;
    }
    if(!self ownsPendingCache(runID, cache))
    {
        return false;
    }
    if(!cache.ready)
    {
        self releasePending(cache);
        return false;
    }
    return true;
}

ownsPendingCache(runID, cache)
{
    return isDefined(self.demoPendingId) && self.demoPendingId == runID &&
           isDefined(self.demoPendingCache) && self.demoPendingCache == cache;
}

releaseSelection()
{
    if(isDefined(self.demoSelectionId))
    {
        releaseCache(self.demoSelectionId, self.demoSelectionCache);
        self.demoSelectionId = undefined;
        self.demoSelectionCache = undefined;
    }
}

canWatch()
{
    if(!level.demoStorageReady)
    {
        self sendLocalChatMessage("Demo storage has not been initialized.", true);
        return false;
    }
    if(isDefined(self.playerRuns_runFinishing) && self.playerRuns_runFinishing)
    {
        return false;
    }
    if(self.sessionState != "playing" || self openCJ\checkpointCreation::isEditing() ||
       self isPlayingDemo())
    {
        self sendLocalChatMessage("Spawn and leave CPC/current playback before watching a demo.",
                                  true);
        return false;
    }
    return true;
}

// Called by leaderboard row selection. Explicit rows always play the full run.
playRun(runID, playFullRun, kind, selectedRange)
{
    self endon("disconnect");
    self endon("demo_request");
    if(!self canWatch())
    {
        return;
    }
    self sendLocalChatMessage("Loading demo...");
    if(!isDefined(playFullRun))
    {
        playFullRun = true;
    }
    metadata = self readRunMetadata(runID);
    if(!isDefined(metadata))
    {
        self sendLocalChatMessage("This run has no retained demo.", true);
        return;
    }
    // Leaderboard rows can also be the walkthrough winner. Explicit requests
    // retain their requested style, even when the same recording wins both.
    if(!isDefined(kind))
    {
        kind = leaderboardKind(metadata.isWalkthrough);
    }
    if(!self acquireCache(runID, metadata.frameCount))
    {
        self sendLocalChatMessage("The recording could not be loaded.", true);
        return;
    }
    if(!self canWatch())
    {
        self releasePending();
        return;
    }
    range = [];
    range[0] = 0;
    range[1] = numberOfDemoFrames(runID) - 1;
    if(!playFullRun)
    {
        range = selectedRange;
        if(!isDefined(range))
        {
            range = self segmentAtPosition(runID, metadata.modeMask & level.demoModes.anyPercent,
                                           int(kind != "speedrun"));
        }
        if(!isDefined(range))
        {
            self sendLocalChatMessage("No matching demo segment is available at this checkpoint.",
                                      true);
            self releasePending();
            return;
        }
    }
    // Start outside a client-command / movement callback.
    pendingCache = self.demoPendingCache;
    waittillframeend;
    if(!self ownsPendingCache(runID, pendingCache))
    {
        return;
    }
    if(!self canWatch())
    {
        self releasePending();
        return;
    }
    self.demoPendingId = undefined;
    self.demoPendingCache = undefined;
    self.demoAuthor = metadata.authorName;
    if(!isDefined(self.demoAuthor) || self.demoAuthor == "")
    {
        self.demoAuthor = "Unknown player";
    }
    self.demoKind = kind;
    self.demoRouteName = metadata.routeName;
    self.demoDetails = metadata.routeName + " | " +
                       runModeLabel(metadata.fpsMode, metadata.modeMask) +
                       " | Run: " + metadata.rpgJumps + " RPG jumps";
    self.demoStyle = 0;
    if(kind == "lowrpg")
    {
        self.demoStyle = 1;
    }
    else if(kind == "walkthrough")
    {
        self.demoStyle = 2;
    }
    self.demoBegin = range[0];
    self.demoEnd = range[1];
    self.demoCheckpointed = (metadata.modeMask & level.demoModes.anyPercent) == 0;
    self startDemo(runID);
}

// Decode the database projection once, before playback decisions use its fields.
readRunMetadata(runID)
{
    rows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT frameCount,modeMask," + "EXISTS(SELECT 1 FROM demoWinners w" +
        " WHERE w.runID=demoRuns.runID AND w.kind='walkthrough')," +
        "(SELECT p.playerName FROM playerRuns r" +
        " JOIN playerDisplayNames p ON p.playerID=r.playerID" + " WHERE r.runID=demoRuns.runID)," +
        "(SELECT routeName FROM routes WHERE routeID=demoRuns.routeID)," +
        "FPSMode,explosiveJumps" + " FROM demoRuns WHERE ready=1 AND mapID=" +
        openCJ\mapID::getMapID() + " AND runID=" + runID);
    if(!isDefined(rows) || !rows.size)
    {
        return undefined;
    }
    row = rows[0];
    metadata = spawnStruct();
    metadata.frameCount = int(row[0]);
    metadata.modeMask = int(row[1]);
    metadata.isWalkthrough = int(row[2]) != 0;
    metadata.authorName = row[3];
    metadata.routeName = row[4];
    metadata.fpsMode = row[5];
    metadata.rpgJumps = row[6];
    return metadata;
}

// Looking up a lesson must not depend on, or change, the viewer's run progress.
// Noclip and returning after a finish leave that progress at an unrelated CP.
segmentAtPosition(runID, matchByPosition, skipFailedFrames)
{
    current = self openCJ\checkpoints::getCurrentCheckpoint();
    groundEntity = self getGroundEntity();
    for(i = -1; i < level.checkpoints_checkpoints.size; i++)
    {
        checkpoint = current;
        if(i >= 0)
        {
            checkpoint = level.checkpoints_checkpoints[i];
        }
        if(!isDefined(checkpoint) ||
           !self openCJ\checkpoints::touchesArea(checkpoint, true, groundEntity))
        {
            continue;
        }
        if(isDefined(checkpoint.bigBrother))
        {
            checkpoint = checkpoint.bigBrother;
        }
        range =
            demoFindSegment(runID, checkpoint.id, self.origin, matchByPosition, skipFailedFrames);
        if(isDefined(range))
        {
            return range;
        }
    }
    checkpointID = 0;
    if(isDefined(current))
    {
        if(isDefined(current.bigBrother))
        {
            current = current.bigBrother;
        }
        if(isDefined(current.id))
        {
            checkpointID = current.id;
        }
    }
    return demoFindSegment(runID, checkpointID, self.origin, matchByPosition, skipFailedFrames);
}

leaderboardKind(isWalkthrough)
{
    if(isWalkthrough)
    {
        return "walkthrough";
    }
    return "speedrun";
}

// Load shared chunks until complete or until the last viewer releases this entry.
_loadCache(runID, expectedFrames, cache)
{
    if(cache.cancelled)
    {
        return;
    }
    createdID = createDemo(runID);
    loaded = createdID == runID;
    cache.nativeCreated = loaded;
    if(loaded)
    {
        // Each bounded query already yields. Do not add another frame wait after decoding.
        nextChunk = 0;
        runStorage = 0; // Native chunk source: 0 is a run, 1 is a clip.
        while(loaded && numberOfDemoFrames(runID) < expectedFrames)
        {
            rows = openCJ\mySQL::awaitNative(demoLoadChunks(runID, runID, runStorage, nextChunk));
            // Cancellation destroys the old native owner. The same run ID may now belong
            // to a newer request, so this loader must not read, finish, or destroy it.
            if(cache.cancelled)
            {
                return;
            }
            loaded = isDefined(rows) && rows.size > 0 && rows[0][0] > nextChunk;
            if(loaded)
            {
                nextChunk = rows[0][0];
            }
        }
        if(loaded)
        {
            loaded = numberOfDemoFrames(runID) == expectedFrames;
        }
        if(loaded)
        {
            completeDemo(runID);
        }
        else
        {
            destroyDemo(runID);
            cache.nativeCreated = false;
        }
    }
    cache.ready = loaded;
    cache.loading = false;
    if(!loaded)
    {
        printf("OpenCJ: failed to load demo " + runID + ".\n");
    }
    if(cache.refs == 0)
    {
        releaseCache(runID, cache);
    }
}

// The final viewer also stops queued native reads; active SQL retains its connection
// until the worker finishes, then discards the cancelled result.
releaseCache(runID, expectedCache)
{
    key = "" + runID;
    cache = level.demoCache[key];
    if(!isDefined(cache))
    {
        return;
    }
    if(isDefined(expectedCache) && cache != expectedCache)
    {
        return;
    }
    if(cache.refs > 0)
    {
        cache.refs--;
    }
    if(cache.refs > 0)
    {
        return;
    }

    ownsNative = cache.ready || (isDefined(cache.nativeCreated) && cache.nativeCreated);
    cache.cancelled = true;
    cache.loading = false;
    cache.ready = false;
    if(ownsNative)
    {
        destroyDemo(runID);
    }
    cache.nativeCreated = false;
    level.demoCache[key] = undefined;
}

// Save the live run before any playback state can replace it.
captureDemoReturnState()
{
    state = spawnStruct();
    state.origin = self.origin;
    state.angles = self getPlayerAngles();
    state.velocity = self getVelocity();
    state.stance = self getStance();
    state.weapon = self getCurrentWeapon();
    state.health = self.health;
    state.paused = self.playerRuns_runPaused;
    state.time = self openCJ\playTime::getTimePlayed();
    state.timerRunning = !isDefined(self.stopTime);
    self openCJ\huds\hudFPSHistory::_flushPendingInput();
    state.fpshistory = self.fpshistory;
    state.fpsHistoryText = self.fpsHistoryText;
    state.fpsHistoryShortFPS = self.fpshistory["shortfps"];
    state.fpsHistoryEvents = self.fpsHistoryEvents;
    state.fpsHistoryTruncated = self.fpsHistoryTruncated;
    state.fpsHistoryStyle = self.fpsHistoryStyle;
    state.speed = self.currSpeed;
    state.maxSpeed = self.maxSpeed;
    state.started = getTime();
    return state;
}

// Take ownership of a ready cache entry and pause the live run until stopDemo().
startDemo(demoID)
{
    self openCJ\mapBoost::cancel();
    self openCJ\shop::stopInspect();
    if(getCodVersion() == 4 && !(self demoBeginPresentation()))
    {
        releaseCache(demoID);
        self sendLocalChatMessage("Could not prepare demo playback", true);
        return;
    }
    self openCJ\events\spawnPlayer::cancelPendingSpawn();
    state = self captureDemoReturnState();
    self.demoReturn = state;
    self.checkpointContact = undefined;
    self openCJ\historySave::cancelPendingPage();
    self openCJ\notifications::cancelAll();
    self.playingDemo = true;
    self openCJ\halfBeat::disableCorrection();
    self.demoExitRequested = false;
    self hide();
    // The local body is needed by the third-person camera. Native visibility
    // keeps this playback body hidden from unrelated players.
    if(getCodVersion() == 4)
    {
        self showToPlayer(self);
    }
    self.playerRuns_runPaused = true;
    self openCJ\playTime::pauseTimer();
    self.eventQueue = [];
    self.demoID = demoID;
    self.playbackPaused = false;
    self.slowmoCount = 0;
    self.demoPreviousStance = state.stance;
    self.demoPreviousState = "none";
    self.demoPreviousFPS = undefined;
    self.demoPreviousOnGround = true;
    self.demoFirstFrame = true;
    self.demoLastPresentedFrame = undefined;
    self.demoLoopPending = false;
    self.demoFPSCacheKey = undefined;
    self demoFPSReset();
    self.demoFPSFloor = undefined;
    self.demoFPSWaiting = false;
    self.demoRate = 1;
    self.demoStepRemainder = 0;
    self.demoStepRate = 1;
    self.demoMenuRate = undefined;
    self.demoControlButtons = 0;
    self.demoCheckpointRequest = 0;
    self.demoMenuOpened = false;
    self demoDisplayStart();
    self.maxSpeed = 0;
    self selectPlaybackDemo(demoID);
    if(!isDefined(self.demoTechnique))
    {
        self.demoTechnique = 0;
    }
    self demoSetTechnique(self.demoTechnique);
    if(!isDefined(self.demoStyle))
    {
        self.demoStyle = 0;
    }
    edited = self demoPlaybackStyle(self.demoStyle, self.demoBegin, self.demoEnd);
    if(isDefined(edited))
    {
        self.demoBegin = edited[0];
        self.demoEnd = edited[1];
    }
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(self.demoBegin - current);
    self.demoLinker.origin = self.origin;
    self linkTo(self.demoLinker, "", (0, 0, 0), (0, 0, 0));
    self disableWeapons();
    self openCJ\buttonPress::resetButtons();
    if(getCodVersion() == 4)
    {
        self setClientCvar("opencj_demo_checkpointed",
                           int(isDefined(self.demoCheckpointed) && self.demoCheckpointed));
        menu = "opencj_demo";
        if(isDefined(self.clipEdit))
        {
            menu = "opencj_clipedit";
        }
        else if(isDefined(self.clipPreview))
        {
            menu = "opencj_clips";
        }
        self closeInGameMenu();
        self closeMenu();
        self setClientCvar("g_scriptMainMenu", menu);
        self.demoStatusText = undefined;
        self.demoMenuPaused = undefined;
        self.demoClipCursor = undefined;
        self demoUpdateOverlay();
        self openMenu(menu);
    }
    self sendLocalChatMessage("Demo: use the playback bar. Escape or Exit returns to your run.");
}

isPlayingDemo()
{
    if(isDefined(self.playingDemo))
    {
        return self.playingDemo;
    }

    return false;
}

onPlayerConnect()
{
    self.demoTechnique = 0;
    self thread demoMenuResponses();
    self openCJ\clips::onConnect();
    self.playingDemo = false;
    self openCJ\demoRecording::onConnect();
    self.playbackPaused = false;
    self.demoLinker = spawn("script_origin", (0, 0, 0));
}

onPlayPauseDemo()
{
    self.playbackPaused = !self.playbackPaused;
    if(self.playbackPaused)
    {
        self iprintln("Playback paused");
    }
    else
    {
        self iprintln("Playback resumed");
    }
}

_getDemoFrame(frameOffset, shouldSkipFails)
{
    if(shouldSkipFails)
    {
        newFrame = self skipPlaybackKeyFrames(frameOffset);
    }
    else
    {
        newFrame = self skipPlaybackFrames(frameOffset);
    }

    if(newFrame < self.demoBegin)
    {
        newFrame = self skipPlaybackFrames(self.demoBegin - newFrame);
    }
    if(newFrame > self.demoEnd)
    {
        newFrame = self skipPlaybackFrames(self.demoEnd - newFrame);
    }

    frame = spawnStruct();
    frame.origin = self readPlaybackFrame_origin();
    frame.angles = self readPlaybackFrame_angles();
    frame.techniquePhase = self demoTechniquePhase();
    frame.saveNow = self readPlaybackFrame_saveNow();
    frame.loadNow = self readPlaybackFrame_loadNow();
    frame.rpgNow = self readPlaybackFrame_rpgNow();
    flags = self readPlaybackFrame_flags();

    frame.left = (flags & level.demoFlags.left) != 0;
    frame.right = (flags & level.demoFlags.right) != 0;
    frame.forward = (flags & level.demoFlags.forward) != 0;
    frame.back = (flags & level.demoFlags.back) != 0;
    frame.sprint = (flags & level.demoFlags.sprintButton) != 0;
    frame.jump = (flags & level.demoFlags.jump) != 0;

    frame.state = "none";
    if((flags & level.demoFlags.mantling) != 0)
    {
        frame.state = "mantling";
    }
    else if((flags & level.demoFlags.ladder) != 0)
    {
        frame.state = "ladder";
    }
    else if((flags & level.demoFlags.sprinting) != 0)
    {
        frame.state = "sprinting";
    }

    frame.stance = "stand";
    if((flags & level.demoFlags.crouched) != 0)
    {
        frame.stance = "crouch";
    }
    else if((flags & level.demoFlags.prone) != 0)
    {
        frame.stance = "prone";
    }

    if((flags & level.demoFlags.rpg) != 0)
    {
        frame.weapon = "rpg";
    }
    else
    {
        frame.weapon = "default";
    }
    frame.onGround = (flags & level.demoFlags.onGround) != 0;
    frame.bounce = (flags & level.demoFlags.bounce) != 0;

    frame.FPS = self readPlaybackFrame_FPS();
    frame.number = newFrame;

    return frame;
}

// Advance or seek, present the selected sample, then handle the range endpoint.
whilePlayingDemo()
{
    if(isDefined(self.demoExitRequested) && self.demoExitRequested)
    {
        self stopDemo();
        return;
    }
    self demoControls();
    // Keep the final frame selected for the entire snapshot. Loop only on
    // the next tick, so pausing/marking an endpoint agrees with the picture.
    if(isDefined(self.demoLoopPending) && self.demoLoopPending && !self.playbackPaused)
    {
        if(self.demoRate > 0 && isDefined(self.demoLoopAt) && getTime() < self.demoLoopAt)
        {
            self demoApplyPresentation();
            return;
        }
        self.demoLoopPending = false;
        if(self.demoRate > 0)
        {
            if(!isDefined(self.clipPlayback) && !isDefined(self.clipEdit) &&
               !self openCJ\settings::getSetting("demoloop"))
            {
                self stopDemo();
                return;
            }
            currentFrame = self skipPlaybackFrames(0);
            self skipPlaybackFrames(self.demoBegin - currentFrame);
            self.demoFirstFrame = true;
            self.demoLastPresentedFrame = undefined;
            self.maxSpeed = 0;
        }
    }
    soughtCheckpoint = false;
    if(self.demoCheckpointRequest != 0)
    {
        if(isDefined(self.demoCheckpointed) && self.demoCheckpointed)
        {
            target = self demoSeekCheckpoint(self.demoCheckpointRequest);
            if(isDefined(target))
            {
                self.demoBegin = 0;
                self.demoEnd = numberOfDemoFrames(self.demoID) - 1;
                currentFrame = self skipPlaybackFrames(0);
                self skipPlaybackFrames(target - currentFrame);
                self.demoFirstFrame = true;
                self.demoLastPresentedFrame = undefined;
                soughtCheckpoint = true;
            }
        }
        self.demoCheckpointRequest = 0;
    }
    self demoUpdateOverlay();
    if(self.playbackPaused && !soughtCheckpoint && !self.demoFirstFrame)
    {
        self demoApplyPresentation();
        return;
    }
    frame = self advanceDemoFrame();
    self syncDemoFPSHistory(frame.number);

    self presentDemoFrame(frame);

    self demoUpdateOverlay();
    if(!self.playbackPaused && ((self.demoRate > 0 && frame.number >= self.demoEnd) ||
                                (self.demoRate < 0 && frame.number <= self.demoBegin)))
    {
        self _endOfDemo();
    }
}

// Apply the selected sample without replaying landing/RPG events during interpolation.
presentDemoFrame(frame)
{
    isInterpolatedFrame = frame.interpolated;
    self.demoLinker.origin = frame.origin;
    self setPlayerAngles(frame.angles);
    if(frame.stance != self.demoPreviousStance)
    {
        self setStance(frame.stance);
    }
    detailed = self demoApplyPresentation();
    if(!detailed)
    {
        self openCJ\weapons::switchToDemoWeapon(frame.weapon == "rpg");
        self openCJ\huds\hudSpeedometer::_hideSpeedometer();
    }
    else
    {
        if(isDefined(self.clipEdit))
        {
            self openCJ\huds\hudSpeedometer::_hideSpeedometer();
        }
        else
        {
            self openCJ\huds\hudSpeedometer::whileAlive();
        }
        sequential = !isDefined(self.demoLastPresentedFrame) ||
                     frame.number == self.demoLastPresentedFrame + 1;
        if(isDefined(self.demoLastPresentedFrame) && sequential && !isInterpolatedFrame &&
           !frame.loadNow)
        {
            self demoPlayLanding();
        }
        if(frame.rpgNow && sequential && !isInterpolatedFrame)
        {
            sound = self readPlaybackFrame_rpgSound();
            if(isDefined(sound))
            {
                self playLocalSound(sound);
            }
        }
    }
    self openCJ\clips::onPresented();
    if(!isInterpolatedFrame)
    {
        self.demoLastPresentedFrame = frame.number;
    }
    if(!isDefined(self.clipEdit))
    {
        self openCJ\huds\hudOnScreenKeyboard::showKeyboardDemo(
            frame.forward, frame.back, frame.left, frame.right, frame.jump, frame.sprint);
    }
    if(frame.stance != self.demoPreviousStance)
    {
        self.demoPreviousStance = frame.stance;
    }
    if(frame.state != self.demoPreviousState)
    {
        self.demoPreviousState = frame.state;
    }
}

_endOfDemo()
{
    if(self.demoRate < 0 || (isDefined(self.demoKind) && self.demoKind == "history"))
    {
        self.demoLoopPending = false;
        self.playbackPaused = true;
        self.demoStepRemainder = 0;
        self demoUpdateOverlay();
        return;
    }
    // Let the client render the terminal snapshot before looping or exiting.
    // This is presentation time only; no frames are added to the recording.
    self.demoLoopPending = true;
    terminalFrameHoldMs = 200;
    self.demoLoopAt = getTime() + terminalFrameHoldMs;
}

// Restore the saved live run before optionally loading the clip viewer's own save.
stopDemo(loadClipSave)
{
    if(!self isPlayingDemo())
    {
        return;
    }
    if(getCodVersion() == 4)
    {
        self closeInGameMenu();
        self closeMenu();
        self setClientCvar("g_scriptMainMenu", level.menu["ingame"]);
    }
    self.demoMenuOpened = false;
    self demoDisplayStop();
    state = self.demoReturn;
    returnToSave =
        (!isDefined(loadClipSave) || loadClipSave) &&
        (isDefined(self.clipEdit) || isDefined(self.clipPlayback) || isDefined(self.clipPreview));
    demoID = self.demoID;
    self unlink();
    // Disable playback prediction/freeze before the normal teleport runs Pmove.
    self demoEndPresentation();
    self openCJ\mapBoost::cancel();
    self setoriginandangles(state.origin, state.angles);
    self setVelocity(state.velocity);
    self setStance(state.stance);
    self enableWeapons();
    if(state.weapon != "none" && state.weapon != "")
    {
        self switchToWeapon(state.weapon);
    }
    self.demoStyle = undefined;
    self.currSpeed = state.speed;
    self.maxSpeed = state.maxSpeed;
    self openCJ\huds\hudSpeedometer::whileAlive();
    self.health = state.health;
    self.playerRuns_runPaused = state.paused;
    self openCJ\playTime::setTimePlayed(state.time);
    self.demoExitRequested = false;
    self.playingDemo = false;
    self openCJ\clips::onPlaybackStopped();
    self show();
    openCJ\playerCollision::onFrame();
    if(state.timerRunning)
    {
        self openCJ\playTime::startTimer();
    }
    self.activelyPlayingOrigin = state.origin;
    self.activelyPlayingTimer = getTime() + 5000;
    self.previousOrigin = state.origin;
    self.previousOnground = self isOnGround();
    viewingTimeMs = getTime() - state.started;
    pausedStatistics = [];
    pausedStatistics[0] = level.statisticsStrings_lastExplosiveFiredTime;
    pausedStatistics[1] = level.statisticsStrings_lastJumpTime;
    for(i = 0; i < pausedStatistics.size; i++)
    {
        if(isDefined(self.statistics[pausedStatistics[i]]))
        {
            self.statistics[pausedStatistics[i]] += viewingTimeMs;
        }
    }
    self.eventQueue = [];
    self openCJ\buttonPress::resetButtons();
    self openCJ\checkpointPointers::showCheckpointPointers();
    self openCJ\showRecords::onSpawnPlayer();
    self openCJ\huds\hudStatistics::onSpawnPlayer();
    self openCJ\huds\hudProgressBar::onSpawnPlayer();
    self openCJ\huds\hudRunInfo::onSpawnPlayer();
    self openCJ\huds\hudFPSHistory::restoreLiveHistory(state);
    self openCJ\halfBeat::syncPolicy();
    self.demoID = undefined;
    self.demoReturn = undefined;
    self.demoFPSCacheKey = undefined;
    self demoFPSReset();
    self.demoFPSFloor = undefined;
    self.demoFPSWaiting = false;
    releaseCache(demoID);
    if(returnToSave && isDefined(self openCJ\savePosition::getSavedPosition(0)))
    {
        self openCJ\savePosition::resetBackwardsCount();
        self openCJ\events\loadPosition::main(0);
        self sendLocalChatMessage("Clip stopped. Loaded your saved position.");
    }
    else
    {
        self sendLocalChatMessage("Demo stopped. Returned to your previous position and run.");
    }
}

onDisconnect()
{
    self demoEndPresentation();
    self.demoStyle = undefined;
    self releasePending();
    self releaseSelection();
    if(self isPlayingDemo())
    {
        releaseCache(self.demoID);
    }
    self demoFPSReset();
    if(isDefined(self.demoLinker))
    {
        self.demoLinker delete();
    }
}

releasePending(expectedCache)
{
    if(!isDefined(self.demoPendingId))
    {
        return;
    }
    if(isDefined(expectedCache) &&
       (!isDefined(self.demoPendingCache) || self.demoPendingCache != expectedCache))
    {
        return;
    }
    releaseCache(self.demoPendingId, self.demoPendingCache);
    self.demoPendingId = undefined;
    self.demoPendingCache = undefined;
}

cancelRequest()
{
    self notify("demo_request");
    self releasePending();
    self releaseSelection();
}

demoControls()
{
    slowerButton = 1;
    fasterButton = 2;
    previousCheckpointButton = 4;
    nextCheckpointButton = 8;
    buttons = slowerButton * int(self leftButtonPressed()) +
              fasterButton * int(self rightButtonPressed()) +
              previousCheckpointButton * int(self leanLeftButtonPressed()) +
              nextCheckpointButton * int(self leanRightButtonPressed());
    pressedButtons = buttons & ~self.demoControlButtons;
    self.demoControlButtons = buttons;
    rates = [];
    rates[0] = .25;
    rates[1] = .5;
    rates[2] = 1;
    rates[3] = 2;
    rates[4] = 4;
    normalSpeedIndex = 2;
    rateIndex = normalSpeedIndex;
    rate = abs(self.demoRate);
    for(i = 0; i < rates.size; i++)
    {
        if(rates[i] == rate)
        {
            rateIndex = i;
        }
    }
    if((pressedButtons & slowerButton) && rateIndex > 0)
    {
        rateIndex--;
    }
    if((pressedButtons & fasterButton) && rateIndex + 1 < rates.size)
    {
        rateIndex++;
    }
    if(pressedButtons & (slowerButton | fasterButton))
    {
        self setDemoSpeed("" + rates[rateIndex]);
    }
    if(pressedButtons & previousCheckpointButton)
    {
        self.demoCheckpointRequest = -1;
    }
    if(pressedButtons & nextCheckpointButton)
    {
        self.demoCheckpointRequest = 1;
    }
}

// Signed rate is kept internally; the menu controls direction and speed
// independently. Changing either leaves an explicitly paused demo paused.
setDemoSpeed(value)
{
    if(value != "0.25" && value != "0.5" && value != "1" && value != "2" && value != "4")
    {
        return false;
    }
    rate = float(value);
    if(self.demoRate < 0)
    {
        rate = 0 - rate;
    }
    self.demoRate = rate;
    self.demoStepRemainder = 0;
    self.demoStepRate = rate;
    return true;
}

setDemoDirection(direction)
{
    reverse = self.demoRate < 0;
    if(direction == "toggle")
    {
        reverse = !reverse;
    }
    else if(direction == "reverse")
    {
        reverse = true;
    }
    else if(direction == "forward")
    {
        reverse = false;
    }
    else
    {
        return false;
    }
    rate = abs(self.demoRate);
    if(reverse)
    {
        rate = 0 - rate;
    }
    self.demoRate = rate;
    self.demoStepRemainder = 0;
    self.demoStepRate = rate;
    self.demoLoopPending = false;
    return true;
}

advanceDemoFrame()
{
    if(self.demoFirstFrame)
    {
        self.demoFirstFrame = false;
        self.demoStepRemainder = 0;
        frame = self _getDemoFrame(0, false);
        frame.interpolated = false;
        return frame;
    }
    frameStep = self demoFrameStep();
    frame = self _getDemoFrame(frameStep, self.demoStyle != 0);
    frame.interpolated = frameStep == 0;
    if(self.demoStepRemainder > 0)
    {
        direction = 1;
        if(self.demoRate < 0)
        {
            direction = -1;
        }
        nextFrame = self _getDemoFrame(direction, self.demoStyle != 0);
        // Peeking must leave native presentation, events and time on the anchor.
        self skipPlaybackFrames(frame.number - nextFrame.number);
        if(canBlendDemoFrames(frame, nextFrame))
        {
            interpolationFactor = self.demoStepRemainder;
            frame.origin = frame.origin + (nextFrame.origin - frame.origin) * interpolationFactor;
            frame.angles =
                (blendDemoAngle(frame.angles[0], nextFrame.angles[0], interpolationFactor),
                 blendDemoAngle(frame.angles[1], nextFrame.angles[1], interpolationFactor),
                 blendDemoAngle(frame.angles[2], nextFrame.angles[2], interpolationFactor));
        }
    }
    return frame;
}

canBlendDemoFrames(firstFrame, secondFrame)
{
    if(abs(firstFrame.number - secondFrame.number) != 1)
    {
        return false;
    }
    laterFrame = secondFrame;
    if(firstFrame.number > secondFrame.number)
    {
        laterFrame = firstFrame;
    }
    if(laterFrame.loadNow)
    {
        return false;
    }
    // Legacy recordings have no explicit map-portal marker. Large single-sample
    // jumps stay discrete rather than drawing a path through the map.
    maxBlendDistance = 256; // Map units between neighboring samples.
    return distance(firstFrame.origin, secondFrame.origin) <= maxBlendDistance;
}

blendDemoAngle(startDegrees, endDegrees, interpolationFactor)
{
    angleDelta = endDegrees - startDegrees;
    if(angleDelta > 180)
    {
        angleDelta -= 360;
    }
    else if(angleDelta < (-180))
    {
        angleDelta += 360;
    }
    return startDegrees + angleDelta * interpolationFactor;
}

// FPS history follows recorded chronology, independently of displayed rate.
// Cache rendered strings (not mutable event structs) for bounded reverse/seek
// reuse. The live event builder remains at demoFPSStateFrame.
syncDemoFPSHistory(targetFrame)
{
    historyMode = self.fpsHistoryMode;
    if(!isDefined(historyMode))
    {
        historyMode = "detailed";
    }
    if(historyMode == "off")
    {
        return;
    }
    if(isDefined(self.demoFPSWaiting) && self.demoFPSWaiting)
    {
        onGround = (self readPlaybackFrame_flags() & level.demoFlags.onGround) != 0;
        leftGround = isDefined(self.demoFPSWaitGround) && self.demoFPSWaitGround && !onGround;
        self.demoFPSWaitGround = onGround;
        if(!leftGround)
        {
            return;
        }
        self.demoFPSWaiting = false;
        self.demoFPSFloor = targetFrame;
    }
    techniqueMode = 0;
    if(isDefined(self.demoTechnique))
    {
        techniqueMode = self.demoTechnique;
    }
    cacheKey = self.demoID + ":" + self.demoStyle + ":" + self.demoBegin + ":" + self.demoEnd +
               ":" + historyMode + ":" + techniqueMode;
    if(!isDefined(self.demoFPSCacheKey) || self.demoFPSCacheKey != cacheKey)
    {
        self.demoFPSCacheKey = cacheKey;
        self demoFPSReset();
        self.demoFPSStateFrame = undefined;
    }
    cachedText = self demoFPSRead(targetFrame);
    if(isDefined(cachedText))
    {
        self showDemoFPSCache(targetFrame);
        return;
    }
    self.fpsHistoryBatch = true;
    maxIncrementalFrames = 4;
    cachedHistoryFrames = 512; // Matches the native FPS text cache capacity.
    if(isDefined(self.demoFPSStateFrame) && targetFrame > self.demoFPSStateFrame &&
       targetFrame - self.demoFPSStateFrame <= maxIncrementalFrames)
    {
        // Cached reverse display never changes the event builder. Restore its
        // current text from those events before processing new source samples.
        self openCJ\huds\hudFPSHistory::_refresh();
        self skipPlaybackFrames(self.demoFPSStateFrame - (self skipPlaybackFrames(0)));
        previousFrame = self.demoFPSStateFrame;
    }
    else
    {
        self demoFPSReset();
        // Walk to the oldest relevant native sample, then process forward one
        // sample at a time. Never retain an array of 512 full GSC frame structs.
        frame = self _getDemoFrame(1 - cachedHistoryFrames, self.demoStyle != 0);
        firstRelevantFrame = self.demoBegin;
        if(isDefined(self.demoFPSFloor) && self.demoFPSFloor > firstRelevantFrame)
        {
            firstRelevantFrame = self.demoFPSFloor;
        }
        if(targetFrame < firstRelevantFrame)
        {
            self skipPlaybackFrames(targetFrame - (self skipPlaybackFrames(0)));
            self.fpsHistoryBatch = false;
            self openCJ\huds\hudFPSHistory::_hide();
            return;
        }
        if(frame.number < firstRelevantFrame)
        {
            self skipPlaybackFrames(firstRelevantFrame - frame.number);
            frame = self _getDemoFrame(0, false);
        }
        self openCJ\huds\hudFPSHistory::applyRecordedFrame(frame, false, false);
        if(frame.number > firstRelevantFrame && !frame.onGround)
        {
            self.fpsHistoryTruncated = true;
            self openCJ\huds\hudFPSHistory::_refresh();
        }
        self cacheDemoFPS(frame.number);
        previousFrame = frame.number;
    }
    while(previousFrame < targetFrame)
    {
        frame = self _getDemoFrame(1, self.demoStyle != 0);
        if(frame.number <= previousFrame)
        {
            break;
        }
        self openCJ\huds\hudFPSHistory::applyRecordedFrame(frame, frame.number == previousFrame + 1,
                                                           false);
        self cacheDemoFPS(frame.number);
        previousFrame = frame.number;
    }
    self.demoFPSStateFrame = targetFrame;
    self.demoFPSFloor = undefined;
    self skipPlaybackFrames(targetFrame - (self skipPlaybackFrames(0)));
    self.fpsHistoryBatch = false;
    self showDemoFPSCache(targetFrame);
}

cacheDemoFPS(frameIndex)
{
    historyText = self.fpsHistoryText;
    if(!isDefined(self.fpsHistoryMode) || self.fpsHistoryMode == "detailed")
    {
        historyText = self.fpsHistoryDetailedText;
    }
    self demoFPSStore(frameIndex, historyText);
}

showDemoFPSCache(frameIndex)
{
    historyText = self demoFPSRead(frameIndex);
    if(!isDefined(historyText))
    {
        return;
    }
    if(!isDefined(self.fpsHistoryMode) || self.fpsHistoryMode == "detailed")
    {
        self.fpsHistoryDetailedText = historyText;
    }
    else
    {
        self.fpsHistoryText = historyText;
    }
    self openCJ\huds\hudFPSHistory::_publish();
}

demoFrameStep()
{
    if(!isDefined(self.demoStepRate) || self.demoStepRate != self.demoRate ||
       !isDefined(self.demoStepRemainder))
    {
        self.demoStepRate = self.demoRate;
        self.demoStepRemainder = 0;
    }
    self.demoStepRemainder += abs(self.demoRate);
    frameStep = int(self.demoStepRemainder);
    self.demoStepRemainder -= frameStep;
    if(self.demoRate < 0)
    {
        frameStep = 0 - frameStep;
    }
    return frameStep;
}

demoTime(frameCount)
{
    recordedFramesPerSecond = 20;
    secondsPerMinute = 60;
    seconds = int(frameCount / recordedFramesPerSecond);
    minutes = int(seconds / secondsPerMinute);
    seconds = seconds % secondsPerMinute;
    prefix = "";
    if(seconds < 10)
    {
        prefix = "0";
    }
    return minutes + ":" + prefix + seconds;
}

demoUpdateOverlay()
{
    self updateTechniqueLabel();
    checkpointText = self demoCheckpointText();
    if(!isDefined(self.demoCheckpointText) || self.demoCheckpointText != checkpointText)
    {
        self.demoCheckpointText = checkpointText;
        self setClientCvar("opencj_demo_checkpoint", checkpointText);
    }
    frameIndex = self skipPlaybackFrames(0);
    status = "PLAY";
    if(self.demoRate < 0)
    {
        status = "REVERSE";
    }
    if(self.playbackPaused)
    {
        status = "PAUSED";
    }
    playbackSpeed = self.demoRate;
    if(playbackSpeed < 0)
    {
        playbackSpeed = 0 - playbackSpeed;
    }
    if(!isDefined(self.demoMenuRate) || self.demoMenuRate != self.demoRate)
    {
        self.demoMenuRate = self.demoRate;
        self setClientCvar("opencj_demo_reverse", int(self.demoRate < 0));
        self setClientCvar("opencj_demo_speed", playbackSpeed);
    }
    elapsedFrames = frameIndex - self.demoBegin;
    durationFrames = self.demoEnd - self.demoBegin;
    playbackTiming = self demoPlaybackTime(self.demoBegin, self.demoEnd);
    if(isDefined(playbackTiming))
    {
        elapsedFrames = playbackTiming[0];
        durationFrames = playbackTiming[1];
    }
    statusText = demoTime(elapsedFrames) + " / " + demoTime(durationFrames);
    if(self.playbackPaused)
    {
        if(isDefined(self.demoKind) && self.demoKind == "history" && frameIndex == self.demoEnd)
        {
            statusText = "End  " + statusText;
        }
        else
        {
            statusText = "Paused  " + statusText;
        }
    }
    if(isDefined(self.clipEdit))
    {
        frameCount = numberOfDemoFrames(self.demoID);
        statusText =
            status + " " + playbackSpeed + "x   Frame " + (frameIndex + 1) + " / " + frameCount;
        if(!isDefined(self.demoClipCursor) || self.demoClipCursor != frameIndex)
        {
            self.demoClipCursor = frameIndex;
            timelineLeft = 20;
            timelineWidth = 600;
            self setClientCvar("opencj_clip_cursor_x",
                               timelineLeft + frameIndex * timelineWidth / frameCount);
        }
    }
    if(!isDefined(self.demoStatusText) || self.demoStatusText != statusText)
    {
        self.demoStatusText = statusText;
        self setClientCvar("opencj_demo_status", statusText);
    }
    if(!isDefined(self.demoMenuPaused) || self.demoMenuPaused != self.playbackPaused)
    {
        self.demoMenuPaused = self.playbackPaused;
        self setClientCvar("opencj_demo_paused", int(self.playbackPaused));
    }
}

demoMenuResponses()
{
    self endon("disconnect");
    for(;;)
    {
        self waittill("menuresponse", menu, response);
        if(menu != "opencj_demo" || !self isPlayingDemo())
        {
            continue;
        }
        if(response == "opened")
        {
            self.demoMenuOpened = true;
        }
        else if(response == "stop")
        {
            self.demoExitRequested = true;
        }
        else if(response == "pause")
        {
            self.playbackPaused = true;
        }
        else if(response == "resume")
        {
            self.playbackPaused = false;
        }
        else if(response == "previous")
        {
            self.demoCheckpointRequest = -1;
        }
        else if(response == "next")
        {
            self.demoCheckpointRequest = 1;
        }
        else if(response == "direction")
        {
            self setDemoDirection("toggle");
        }
        else if(response == "technique")
        {
            self toggleTechnique();
        }
        else
        {
            args = strTok(response, "_");
            if(args.size == 2 && args[0] == "speed")
            {
                self setDemoSpeed(args[1]);
            }
        }
    }
}

// Presentation only: do not alter spectator interpolation or recorded motion.
demoDisplayStart()
{
    // Hide live-run overlays through the same operations used by other events.
    // Do not dispatch gameplay events: viewing a recording must not change a run.
    self openCJ\showRecords::hideForSpectators();
    self openCJ\checkpointPointers::_hideCheckpointPointers();
    self openCJ\huds\hudStatistics::hideForSpectators();
    self openCJ\huds\hudProgressBar::_hideProgressBar();
    self openCJ\huds\hudSpeedometer::_hideSpeedometer();
    self openCJ\huds\hudTimeLimit::setPlaybackLayout(true);
    self demoMovementHudInMenu(isDefined(self.clipEdit) || isDefined(self.clipPreview));
    keys = getArrayKeys(self.hudSpeed);
    for(i = 0; i < keys.size; i++)
    {
        self.hudSpeed[keys[i]].archived = true;
    }
    if(getCodVersion() != 4)
    {
        return;
    }
    self setClientCvar("cg_drawSpectatorMessages", 0);
    self.demoCaption = [];
    for(i = 0; i < 3; i++)
    {
        hud = newClientHudElem(self);
        hud.archived = true;
        hud.foreground = true;
        hud.hideWhenInMenu = false;
        hud.horzAlign = "center";
        hud.vertAlign = "top";
        hud.alignX = "center";
        hud.alignY = "top";
        hud.x = 0;
        hud.y = 8 + i * 16;
        hud.font = "objective";
        hud.fontScale = 1.4;
        hud.alpha = 1;
        self.demoCaption[i] = hud;
    }
    author = "Unknown player";
    if(isDefined(self.demoAuthor))
    {
        author = self.demoAuthor;
    }
    if(isDefined(self.demoHistorySource))
    {
        self.demoCaption[0] setText("VIEWING " + author + "^7's RUN HISTORY");
        self.demoCaption[1] setText("Fixed copy");
    }
    else if(isDefined(self.clipEdit))
    {
        self.demoCaption[0] setText("EDITING CLIP");
        self.demoCaption[1] setText(self.name);
    }
    else if(isDefined(self.clipDescription))
    {
        self.demoCaption[0] setText("CLIP by " + author);
        self.demoCaption[1] setText(self.clipDescription);
    }
    else
    {
        kind = "SPEEDRUN";
        if(isDefined(self.demoKind) && self.demoKind == "walkthrough")
        {
            kind = "WALKTHROUGH";
        }
        else if(isDefined(self.demoKind) && self.demoKind == "lowrpg")
        {
            kind = "LOW RPG";
        }
        self.demoCaption[0] setText(kind + " by " + author);
        if(isDefined(self.demoDetails))
        {
            self.demoCaption[1] setText(self.demoDetails);
        }
    }
    if(isDefined(self.clipDescription))
    {
        self.demoCaption[2] setText(
            rangeLabel(demoRangeInfo(self.demoID, self.demoBegin, self.demoEnd)));
    }
}

demoDisplayStop()
{
    // Playback returns without spawning, so explicitly clear its input overlay.
    self openCJ\huds\hudOnScreenKeyboard::_hideKeyboard();
    self openCJ\huds\hudTimeLimit::setPlaybackLayout(false);
    self demoMovementHudInMenu(true);
    keys = getArrayKeys(self.hudSpeed);
    for(i = 0; i < keys.size; i++)
    {
        self.hudSpeed[keys[i]].archived = false;
    }
    if(getCodVersion() != 4)
    {
        return;
    }
    if(isDefined(self.demoCaption))
    {
        for(i = 0; i < self.demoCaption.size; i++)
        {
            self.demoCaption[i] destroy();
        }
    }
    self.demoCaption = undefined;
    self.demoAuthor = undefined;
    self.demoDetails = undefined;
    self.demoKind = undefined;
    self.demoRouteName = undefined;
    self.demoHistorySource = undefined;
    self setClientCvar("cg_drawSpectatorMessages", 1);
}

// Native HUD suppression follows all client menus, including stock menus.
// The playback toolbar is the only exception; its movement HUD is useful.
demoMovementHudInMenu(hide)
{
    keys = getArrayKeys(self.hudSpeed);
    for(i = 0; i < keys.size; i++)
    {
        self.hudSpeed[keys[i]].hideWhenInMenu = hide;
    }
    keys = getArrayKeys(self.keyboard);
    for(i = 0; i < keys.size; i++)
    {
        self.keyboard[keys[i]].hideWhenInMenu = hide;
    }
}

// Archived demo captions are inherited by followers. Suppress only the stock
// spectator label while following playback, restoring it when the target changes.
spectatorCaption()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    playback = false;
    if(self.sessionState == "spectator" && self.spectatorClient >= 0)
    {
        target = getEntByNum(self.spectatorClient);
        playback = isDefined(target) && target isPlayingDemo();
    }
    if(!isDefined(self.demoSpectatorCaption) || self.demoSpectatorCaption != playback)
    {
        self.demoSpectatorCaption = playback;
        self setClientCvar("cg_drawSpectatorMessages", int(!playback));
    }
}

// Connection-only choice shared by demos, history and clip viewers.
toggleTechnique()
{
    if(!self isPlayingDemo())
    {
        return;
    }
    if(!isDefined(self.demoTechnique))
    {
        self.demoTechnique = 0;
    }
    techniqueCount = 4; // Original, fullbeat, halfbeat, and inverted input.
    self.demoTechnique = (self.demoTechnique + 1) % techniqueCount;
    self demoSetTechnique(self.demoTechnique);
    self.demoFPSCacheKey = undefined;
    self.demoFPSStateFrame = undefined;
    // Re-present the current sample even when paused; do not advance the cursor.
    self.demoFirstFrame = true;
    self updateTechniqueLabel();
}
updateTechniqueLabel()
{
    originalTechnique = 0;
    fullbeatTechnique = 1;
    halfbeatTechnique = 2;
    invertedTechnique = 3;
    mode = originalTechnique;
    if(isDefined(self.demoTechnique))
    {
        mode = self.demoTechnique;
    }
    text = "Original";
    if(mode == fullbeatTechnique)
    {
        text = "Fullbeat";
    }
    else if(mode == halfbeatTechnique)
    {
        text = "Halfbeat";
    }
    else if(mode == invertedTechnique)
    {
        text = "Invert";
    }
    if(!isDefined(self.demoTechniqueLabel) || self.demoTechniqueLabel != text)
    {
        self.demoTechniqueLabel = text;
        self setClientCvar("opencj_demo_technique", text);
    }
    fallback = mode != originalTechnique && self demoTechniqueFallback();
    if(!isDefined(self.demoTechniqueFallback) || self.demoTechniqueFallback != fallback)
    {
        self.demoTechniqueFallback = fallback;
        self setClientCvar("opencj_demo_technique_original", int(fallback));
    }
}

// These labels describe the original run's rules, never the viewing technique.
runModeLabel(fpsMode, modeMask)
{
    modeLabel = fpsMode + " FPS | CP";
    if(modeMask & level.demoModes.anyPercent)
    {
        modeLabel = fpsMode + " FPS | Any%";
    }
    if(modeMask & level.demoModes.elevators)
    {
        modeLabel += " / Ele";
    }
    if(modeMask & level.demoModes.halfbeat)
    {
        modeLabel += " / HB";
    }
    if(modeMask & level.demoModes.hardTAS)
    {
        modeLabel += " / TAS";
    }
    return modeLabel;
}

rangeLabel(info)
{
    if(!isDefined(info))
    {
        return "Recording details unavailable";
    }
    rpgShots = info[0];
    fpsMode = info[1];
    usedElevators = info[2];
    fpsLabel = "?";
    if(fpsMode == 0)
    {
        fpsLabel = "125";
    }
    else if(fpsMode == 1)
    {
        fpsLabel = "Mix";
    }
    else if(fpsMode == 2)
    {
        fpsLabel = "Hax";
    }
    elevatorLabel = "Ele unknown";
    if(usedElevators == 0)
    {
        elevatorLabel = "No ele";
    }
    else if(usedElevators == 1)
    {
        elevatorLabel = "Ele";
    }
    return rpgShots + " RPG shots | " + fpsLabel + " FPS | " + elevatorLabel;
}

_viewHistory(args)
{
    self thread viewHistory(args);
}

_shareHistory(enabled)
{
    if(enabled)
    {
        return true;
    }
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        if(players[i] != self && isDefined(players[i].demoHistorySource) &&
           players[i].demoHistorySource == self)
        {
            players[i].demoExitRequested = true;
        }
    }
    return true;
}

viewHistory(args)
{
    self cancelRequest();
    self endon("demo_request");
    self endon("disconnect");
    if(!self canWatch())
    {
        return;
    }
    playerName = args[0];
    for(i = 1; i < args.size; i++)
    {
        playerName += " " + args[i];
    }
    sourcePlayer = findHistoryPlayer(playerName);
    if(!isDefined(sourcePlayer))
    {
        self sendLocalChatMessage("No unique player matches that name. Use more of their name.",
                                  true);
        return;
    }
    if(sourcePlayer != self && !(sourcePlayer openCJ\settings::getSetting("sharehistory")))
    {
        self sendLocalChatMessage("This player has disabled run-history sharing.", true);
        return;
    }
    recording = sourcePlayer openCJ\demoRecording::current();
    if(!isDefined(recording) || recording.failed || recording.finishing ||
       sourcePlayer openCJ\playerRuns::isRunFinished())
    {
        self sendLocalChatMessage("This player has no current run recording to view.", true);
        return;
    }
    // No yield between copying and registering ownership. Native memory remains
    // separate from the source recording, including later rewinds/disconnects.
    copyID = demoCopyHistory(recording.id);
    if(!isDefined(copyID))
    {
        self sendLocalChatMessage(
            "Run history is too short or recording capacity is currently full.", true);
        return;
    }
    cache = spawnStruct();
    cache.ready = true;
    cache.loading = false;
    cache.refs = 1;
    level.demoCache["" + copyID] = cache;
    self.demoPendingId = copyID;
    self.demoPendingCache = cache;
    authorName = sourcePlayer.name;
    waittillframeend;
    if(!self ownsPendingCache(copyID, cache))
    {
        return;
    }
    if(!self canWatch() || !isDefined(sourcePlayer) ||
       (sourcePlayer != self && !(sourcePlayer openCJ\settings::getSetting("sharehistory"))))
    {
        self releasePending();
        return;
    }
    self.demoPendingId = undefined;
    self.demoPendingCache = undefined;
    self.demoHistorySource = sourcePlayer;
    self.demoAuthor = authorName;
    self.demoKind = "history";
    self.demoStyle = 0;
    self.demoBegin = 0;
    self.demoEnd = numberOfDemoFrames(copyID) - 1;
    self.demoCheckpointed = false;
    self startDemo(copyID);
    if(!self isPlayingDemo())
    {
        self.demoHistorySource = undefined;
        self.demoAuthor = undefined;
        self.demoKind = undefined;
    }
}

findHistoryPlayer(playerName)
{
    playerName = toLower(stripColors(playerName));
    players = getEntArray("player", "classname");
    match = undefined;
    partialMatches = 0;
    exact = undefined;
    exactMatches = 0;
    for(i = 0; i < players.size; i++)
    {
        candidateName = toLower(stripColors(players[i].name));
        if(candidateName == playerName)
        {
            exact = players[i];
            exactMatches++;
        }
        for(j = 0; j <= candidateName.size - playerName.size; j++)
        {
            if(getSubStr(candidateName, j, j + playerName.size) == playerName)
            {
                match = players[i];
                partialMatches++;
                break;
            }
        }
    }
    if(exactMatches == 1)
    {
        return exact;
    }
    if(!exactMatches && partialMatches == 1)
    {
        return match;
    }
    return undefined;
}

// Use the demo's recorded CP and selected route, including shared checkpoints.
// Nothing here reads or changes the viewer's own run.
demoCheckpointText()
{
    if(!isDefined(self.demoCheckpointed) || !self.demoCheckpointed ||
       !isDefined(self.demoRouteName) || !isDefined(level.routeEnders))
    {
        return "";
    }
    routeEnders = level.routeEnders[self.demoRouteName];
    if(!isDefined(routeEnders))
    {
        return "";
    }
    checkpointID = self readPlaybackFrame_checkpoint();
    if(!isDefined(checkpointID))
    {
        return "";
    }
    totalCheckpoints = undefined;
    for(i = 0; i < routeEnders.size; i++)
    {
        checkpointsFromStart = routeEnders[i].checkpointsFromStart;
        if(isDefined(checkpointsFromStart) &&
           (!isDefined(totalCheckpoints) || checkpointsFromStart > totalCheckpoints))
        {
            totalCheckpoints = checkpointsFromStart;
        }
    }
    if(!isDefined(totalCheckpoints) || totalCheckpoints <= 0)
    {
        return "";
    }
    passedCheckpoints = 0;
    if(checkpointID > 0)
    {
        checkpoint = openCJ\checkpoints::getCheckpointByID(checkpointID);
        if(!isDefined(checkpoint))
        {
            return "";
        }
        passedCheckpoints = checkpoint.checkpointsFromStart;
        if(!isDefined(passedCheckpoints) || passedCheckpoints > totalCheckpoints)
        {
            return "";
        }
    }
    return "Checkpoint " + passedCheckpoints + " / " + totalCheckpoints;
}
