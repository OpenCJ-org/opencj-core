#include openCJ\util;

onInit()
{
    if(getCodVersion() != 4)
    {
        level.clipStorageReady = false;
        return;
    }
    precacheMenu("opencj_clipedit");
    precacheMenu("opencj_clips");
    level.clipStorageReady =
        isDefined(openCJ\mySQL::mysqlSyncQuery("SELECT clipID FROM demoClips LIMIT 0"));
    if(level.clipStorageReady)
    {
        level.clipStorageReady = initializeSessions();
        if(level.clipStorageReady)
        {
            level thread sessionHeartbeat();
        }
    }
    recordCommand = openCJ\commands_base::registerCommand("record", "!record", ::_record, 0, 0);
    openCJ\commands_base::addAlias(recordCommand, "startrecord");
    openCJ\commands_base::registerCommand("stoprecord", "!stoprecord", ::_stop, 0, 0);
    openCJ\commands_base::registerCommand("clipdemo", "!clipdemo [id]", ::_watch, 0, 1);
    openCJ\commands_base::registerCommand("renameclip", "!renameclip <id> <name>", ::_rename, 2,
                                          undefined);
    openCJ\commands_base::registerCommand("deleteclip", "!deleteclip <id>", ::_delete, 1, 1);
}

// A failed schema/session operation must leave clips unavailable rather than partially enabled.
initializeSessions()
{
    level.clipSession = readDatabaseValue("SELECT UUID()");
    if(!isDefined(level.clipSession))
    {
        return false;
    }
    registered = openCJ\mySQL::mysqlSyncQuery("INSERT INTO demoClipSessions(sessionID) VALUES(" +
                                              dbStr(level.clipSession) + ")");
    if(!isDefined(registered))
    {
        return false;
    }
    viewSession = getCvar("opencj_clip_view_session");
    if(viewSession == "")
    {
        viewSession = readDatabaseValue("SELECT UUID()");
        if(!isDefined(viewSession))
        {
            return false;
        }
    }
    registered = openCJ\mySQL::mysqlSyncQuery("INSERT INTO demoClipSessions(sessionID) VALUES(" +
                                              dbStr(viewSession) +
                                              ") ON DUPLICATE KEY UPDATE heartbeat=NOW()");
    if(!isDefined(registered))
    {
        return false;
    }
    level.clipViewSession = viewSession;
    setCvar("opencj_clip_view_session", viewSession);
    return true;
}

// Timestamp and UUID queries need one nonempty value before native ownership can move.
readDatabaseValue(query)
{
    rows = openCJ\mySQL::mysqlSyncQuery(query);
    if(!isDefined(rows) || rows.size != 1 || rows[0].size != 1)
    {
        return undefined;
    }
    value = rows[0][0];
    if(!isDefined(value) || value == "")
    {
        return undefined;
    }
    return value;
}

sessionHeartbeat()
{
    for(;;)
    {
        openCJ\mySQL::mysqlAsyncQuery(
            "UPDATE demoClipSessions SET heartbeat=NOW() WHERE sessionID IN (" +
            dbStr(level.clipSession) + "," + dbStr(level.clipViewSession) + ")");
        // Old sessions are invisible immediately. Reclaim crashed-server payloads
        // after a grace period without touching another server's active session.
        openCJ\mySQL::mysqlAsyncQuery(
            "DELETE FROM demoClipSessions WHERE heartbeat < NOW() - INTERVAL 10 MINUTE");
        openCJ\mySQL::mysqlAsyncQuery(
            "DELETE FROM demoClips WHERE ready=0 AND createdAt < NOW() - INTERVAL 1 DAY");
        wait 60;
    }
}

onConnect()
{
    self setClientCvar("opencj_clips_preview", 0);
    self thread responses();
}

available()
{
    if(!level.clipStorageReady || getCodVersion() != 4)
    {
        self sendLocalChatMessage("Clip storage is unavailable.", true);
        return false;
    }
    if(!isDefined(self openCJ\login::getPlayerID()))
    {
        self sendLocalChatMessage("Log in before using clips.", true);
        return false;
    }
    return true;
}

_record(args)
{
    self thread record();
}
_stop(args)
{
    self thread edit();
}
_watch(args)
{
    self thread nearby(args);
}
_delete(args)
{
    self thread remove(int(args[0]));
}
_rename(args)
{
    description = args[1];
    for(i = 2; i < args.size; i++)
    {
        description += " " + args[i];
    }
    self thread rename(int(args[0]), getSubStr(description, 0, 32));
}

// Start an editable rolling recording only after its storage metadata is available.
record()
{
    self endon("disconnect");
    if(!self available())
    {
        return;
    }
    if(isDefined(self.clipRecording) || isDefined(self.clipEdit))
    {
        self sendLocalChatMessage("Finish or cancel your current clip first.", true);
        return;
    }
    if(!self openCJ\demos::canWatch())
    {
        return;
    }
    if(self openCJ\tutorial::isTutorialRun())
    {
        self sendLocalChatMessage("Clips are not available in tutorial mode.", true);
        return;
    }
    recordedAt = readDatabaseValue("SELECT NOW()");
    if(!isDefined(recordedAt))
    {
        self sendLocalChatMessage("Could not start the clip recording. Please try again.", true);
        return;
    }
    nativeDemoID = demoCreateTransient();
    if(!isDefined(nativeDemoID))
    {
        self sendLocalChatMessage("No recording capacity available.", true);
        return;
    }
    recording = spawnStruct();
    recording.id = nativeDemoID;
    recording.loaded = false;
    recording.saved = false;
    recording.lastTick = -1;
    recording.date = recordedAt;
    self.clipRecording = recording;
    self capture();
    self sendLocalChatMessage(
        "Clip recording started. Keeping the last 60 seconds; use !stoprecord to edit.");
}

// Retain the newest minute of eligible play, including save/load and elevator events.
capture()
{
    if(!isDefined(self.clipRecording) || self openCJ\demos::isPlayingDemo() ||
       self openCJ\checkpointCreation::isEditing() || self.sessionState != "playing")
    {
        return;
    }
    if(isDefined(self.isAFK) && self.isAFK)
    {
        return;
    }
    recording = self.clipRecording;
    // Tutorial play must not end up in a clip, e.g. after loading a tutorial run
    if(self openCJ\tutorial::isTutorialRun())
    {
        destroyDemo(recording.id);
        self.clipRecording = undefined;
        self sendLocalChatMessage(
            "Clip recording stopped: clips are not available in tutorial mode.", true);
        return;
    }
    if(recording.lastTick == getTime())
    {
        return;
    }
    framesPerSecond = self openCJ\fps::getCurrentFPS();
    if(!isDefined(addFrameToDemo(recording.id, self.origin, self getPlayerAngles(), 1,
                                 self openCJ\demoRecording::frameFlags(), int(recording.saved),
                                 int(recording.loaded), int(isDefined(self.eventQueue["rpg"])),
                                 int(framesPerSecond), 0, self getEntityNumber(),
                                 int(isDefined(recording.elevated) && recording.elevated))))
    {
        destroyDemo(recording.id);
        self.clipRecording = undefined;
        self sendLocalChatMessage("Clip recording ran out of memory.", true);
        return;
    }
    clipWindowFrames = 1200; // Sixty seconds at the server's 20 Hz sample rate.
    demoKeepLast(recording.id, clipWindowFrames);
    recording.loaded = false;
    recording.saved = false;
    recording.elevated = false;
    recording.lastTick = getTime();
}

onSaved()
{
    if(isDefined(self.clipRecording))
    {
        self.clipRecording.saved = true;
    }
}

onLoaded()
{
    if(isDefined(self.clipRecording))
    {
        self.clipRecording.loaded = true;
    }
}

// Transfer the live recording into a paused preview and build its timeline cells.
edit()
{
    maxTimelineCells = 40; // Matches the fixed cells in opencj_clipedit.menu.
    timelineLeft = 20;
    timelineWidth = 600;

    self endon("disconnect");
    if(!isDefined(self.clipRecording))
    {
        self sendLocalChatMessage("Use !record first.", true);
        return;
    }
    if(!self openCJ\demos::canWatch())
    {
        return;
    }
    self capture();
    if(!isDefined(self.clipRecording))
    {
        return;
    }
    recording = self.clipRecording;
    frameCount = numberOfDemoFrames(recording.id);
    if(frameCount < 2)
    {
        self sendLocalChatMessage("Record at least two frames first.", true);
        return;
    }
    self.clipRecording = undefined;
    info = demoClipInfo(recording.id, 0);
    recording.first = info[2];
    recording.last = frameCount - 1;
    recording.permanent = false;
    recording.busy = false;
    completeDemo(recording.id);
    cache = spawnStruct();
    cache.ready = true;
    cache.loading = false;
    cache.refs = 1;
    level.demoCache["" + recording.id] = cache;
    self.clipEdit = recording;
    cellCount = frameCount;
    if(cellCount > maxTimelineCells)
    {
        cellCount = maxTimelineCells;
    }
    self setClientCvar("opencj_clip_cells", cellCount);
    layout = [];
    for(i = 0; i < cellCount; i++)
    {
        firstFrame = int((frameCount * i + cellCount - 1) / cellCount);
        nextFrame = int((frameCount * (i + 1) + cellCount - 1) / cellCount);
        layout["opencj_clip_cellx" + i] = timelineLeft + firstFrame * timelineWidth / frameCount;
        layout["opencj_clip_cellw" + i] = (nextFrame - firstFrame) * timelineWidth / frameCount;
    }
    recording.layoutCommands = self numericCvars(layout);
    self openCJ\huds\hudOnScreenKeyboard::_hideKeyboard();
    self openCJ\huds\hudSpeedometer::_hideSpeedometer();
    self.demoStyle = 0;
    self.demoBegin = 0;
    self.demoEnd = frameCount - 1;
    self.demoCheckpointed = false;
    waittillframeend;
    self openCJ\demos::startDemo(recording.id);
    if(!self openCJ\demos::isPlayingDemo())
    {
        self.clipEdit = undefined;
        return;
    }
    self.playbackPaused = true;
    self.demoBegin = recording.first;
    self.demoEnd = recording.last;
    self seek(recording.first);
    self setClientCvar("opencj_clip_hint",
                       "Name clip, choose range, then Submit. Green: save | Red: load.");
    self updateEditor();
}

seek(frameIndex)
{
    self.demoLoopPending = false;
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(frameIndex - current);
    self.demoFirstFrame = true;
    self.demoLastPresentedFrame = undefined;
}

updateEditor()
{
    maxTimelineCells = 40; // Matches the fixed cells in opencj_clipedit.menu.
    timelineLeft = 20;
    timelineWidth = 600;

    if(!isDefined(self.clipEdit))
    {
        return;
    }
    recording = self.clipEdit;
    cellCount = numberOfDemoFrames(recording.id);
    if(cellCount > maxTimelineCells)
    {
        cellCount = maxTimelineCells;
    }
    self setClientCvar("opencj_clip_cells", cellCount);
    self setClientCvar("opencj_clip_trim", "Start " + seconds(recording.first) + "s   End " +
                                               seconds(recording.last) + "s   Length " +
                                               seconds(recording.last - recording.first + 1) + "s");
    self setClientCvar("opencj_clip_start",
                       int(recording.first * cellCount / numberOfDemoFrames(recording.id)));
    self setClientCvar("opencj_clip_end",
                       int(recording.last * cellCount / numberOfDemoFrames(recording.id)));
    frameCount = numberOfDemoFrames(recording.id);
    self setClientCvar("opencj_clip_start_x",
                       timelineLeft + recording.first * timelineWidth / frameCount);
    self setClientCvar("opencj_clip_end_x",
                       timelineLeft - 1 + (recording.last + 1) * timelineWidth / frameCount);
    clipInfo = demoClipInfo(recording.id, recording.first, recording.last);
    events = [];
    for(i = 0; i < maxTimelineCells; i++)
    {
        if(!isDefined(recording.eventCells) || recording.eventCells[i] != clipInfo[3][i])
        {
            events["opencj_clip_event" + i] = clipInfo[3][i];
        }
    }
    recording.eventCommands = self numericCvars(events);
    recording.eventCells = clipInfo[3];
    self openCJ\demos::demoUpdateOverlay();
    storageLabel = "Until map changes";
    if(recording.permanent)
    {
        storageLabel = "Permanently";
    }
    self setClientCvar("opencj_clip_storage", storageLabel);
}

seconds(frameCount)
{
    return frameCount * 0.05;
}

scopeFilter()
{
    return "(c.sessionID IS NULL OR c.sessionID=" + dbStr(level.clipSession) + ")";
}

// Hold the editor's source frames through upload, then publish or leave it ready to retry.
submit(description)
{
    if(!isDefined(self.clipEdit) || self.clipEdit.busy)
    {
        return;
    }
    if(isDefined(self.clipUploadToken) || isDefined(self.clipUploadNative))
    {
        self setClientCvar("opencj_clip_hint",
                           "Your previous clip is still uploading. Try again when it finishes.");
        return;
    }
    recording = self.clipEdit;
    if(!validDescription(description))
    {
        self setClientCvar("opencj_clip_hint", "Use 1-32 letters, numbers and spaces only.");
        return;
    }
    recording.busy = true;
    // Hold the native recording while SQL yields, even if the editor closes.
    if(!demoPin(recording.id))
    {
        recording.busy = false;
        return;
    }
    self.clipUploadNative = recording.id;
    clipInfo = demoClipInfo(recording.id, recording.first);
    rangeInfo = demoRangeInfo(recording.id, recording.first, recording.last);
    if(!isDefined(clipInfo) || !isDefined(rangeInfo))
    {
        self releaseUpload();
        recording.busy = false;
        self setClientCvar("opencj_clip_hint", "The selected recording range is unavailable.");
        return;
    }
    metadata = spawnStruct();
    metadata.origin = clipInfo[0];
    metadata.rpgShots = rangeInfo[0];
    fpsMode = rangeInfo[1];
    usedElevators = rangeInfo[2];
    uploadToken = readDatabaseValue("SELECT UUID()");
    if(!isDefined(uploadToken))
    {
        self releaseUpload();
        recording.busy = false;
        self setClientCvar("opencj_clip_hint", "Could not start the upload. Please try again.");
        return;
    }
    self.clipUploadToken = uploadToken;
    metadata.fpsModeSQL = "NULL";
    if(fpsMode == 0)
    {
        metadata.fpsModeSQL = "'125'";
    }
    else if(fpsMode == 1)
    {
        metadata.fpsModeSQL = "'mix'";
    }
    else if(fpsMode == 2)
    {
        metadata.fpsModeSQL = "'hax'";
    }
    metadata.elevatorSQL = "NULL";
    if(usedElevators >= 0)
    {
        metadata.elevatorSQL = "" + usedElevators;
    }
    clipID = self reserveClipSlot(recording, metadata, description, uploadToken);
    if(!isDefined(clipID))
    {
        self releaseUpload();
        self.clipUploadToken = undefined;
        recording.busy = false;
        self setClientCvar("opencj_clip_hint",
                           "No slot available (limit 5 per storage type). Use !deleteclip <id>.");
        return;
    }
    uploaded = self uploadClipFrames(recording, clipID);
    self releaseUpload();
    if(uploaded)
    {
        uploaded = isDefined(self openCJ\mySQL::mysqlAsyncBackground(
            "UPDATE demoClips SET ready=1 WHERE clipID=" + clipID, "clip-upload:" + uploadToken));
    }
    if(!uploaded)
    {
        self openCJ\mySQL::mysqlAsyncBackground("DELETE FROM demoClips WHERE clipID=" + clipID +
                                                    " AND ready=0",
                                                "clip-upload:" + uploadToken);
        self.clipUploadToken = undefined;
        recording.busy = false;
        self setClientCvar("opencj_clip_hint",
                           "Upload failed. Your clip is still open; try again.");
        return;
    }
    self.clipUploadToken = undefined;
    // Publication can outlive the editor. Leave a subsequently opened demo alone.
    if(self openCJ\demos::isPlayingDemo() && self.demoID == recording.id)
    {
        self openCJ\demos::stopDemo();
    }
    self sendLocalChatMessage("Clip #" + clipID + " submitted: " + description +
                              ". Remove it with !deleteclip " + clipID + ".");
}

// Claim one of the player's bounded slots. A UUID resolves INSERT IGNORE retries.
reserveClipSlot(recording, metadata, description, uploadToken)
{
    playerID = self openCJ\login::getPlayerID();
    mapID = openCJ\mapID::getMapID();
    scopeKey = level.clipSession;
    sessionSQL = dbStr(scopeKey);
    if(recording.permanent)
    {
        scopeKey = "permanent";
        sessionSQL = "NULL";
    }
    slotsPerStorageType = 5;
    for(slot = 1; slot <= slotsPerStorageType; slot++)
    {
        query = "INSERT IGNORE INTO demoClips(" +
                "uploadToken,mapID,playerID,description,scopeKey,sessionID,slot," +
                "originX,originY,originZ,frameCount,recordedAt,RPGShots,FPSMode,eleUsed)" +
                " VALUES(" + dbStr(uploadToken) + "," + mapID + "," + playerID + "," +
                dbStr(openCJ\mySQL::escapeString(description)) + "," + dbStr(scopeKey) + "," +
                sessionSQL + "," + slot + "," + metadata.origin[0] + "," + metadata.origin[1] +
                "," + metadata.origin[2] + "," + (recording.last - recording.first + 1) + "," +
                dbStr(recording.date) + "," + metadata.rpgShots + "," + metadata.fpsModeSQL + "," +
                metadata.elevatorSQL + ")";
        result = self openCJ\mySQL::mysqlAsyncBackground(query, "clip-upload:" + uploadToken);
        if(!isDefined(result))
        {
            break;
        }
        rows = self openCJ\mySQL::mysqlAsyncRead("SELECT clipID FROM demoClips WHERE uploadToken=" +
                                                 dbStr(uploadToken));
        if(isDefined(rows) && rows.size)
        {
            return int(rows[0][0]);
        }
    }
    return undefined;
}

// Each completed query releases its result before the next bounded frame chunk.
uploadClipFrames(recording, clipID)
{
    framesPerChunk = 64;
    clipStorage = 1; // Native transfer API: runs use 0, clips use 1.
    chunkIndex = 0;
    for(firstFrame = recording.first; firstFrame <= recording.last; firstFrame += framesPerChunk)
    {
        chunkFrames = recording.last - firstFrame + 1;
        if(chunkFrames > framesPerChunk)
        {
            chunkFrames = framesPerChunk;
        }
        result = self openCJ\mySQL::awaitNative(demoUploadChunk(
            recording.id, clipID, clipStorage, firstFrame, chunkFrames, chunkIndex));
        if(!isDefined(result))
        {
            return false;
        }
        chunkIndex++;
    }
    return true;
}

remove(clipID)
{
    self endon("disconnect");
    if(!self available() || clipID < 1)
    {
        return;
    }
    playerID = self openCJ\login::getPlayerID();
    rows =
        self openCJ\mySQL::mysqlAsyncRead("SELECT clipID FROM demoClips c WHERE clipID=" + clipID +
                                          " AND playerID=" + playerID + " AND " + scopeFilter());
    if(!isDefined(rows) || !rows.size)
    {
        self sendLocalChatMessage("No clip with that ID belongs to you.", true);
        return;
    }
    result = self openCJ\mySQL::mysqlAsyncQuery("DELETE FROM demoClips WHERE clipID=" + clipID +
                                                " AND playerID=" + playerID);
    if(isDefined(result))
    {
        self sendLocalChatMessage("Deleted clip #" + clipID + ".");
    }
}

nearby(args)
{
    self endon("disconnect");
    if(!self available() || !self openCJ\demos::canWatch())
    {
        return;
    }
    viewerOrigin = self.origin;
    maxHorizontalDistanceSquared = 128 * 128; // Map units around the viewer.
    maxVerticalDistance = 70;
    displayedClipLimit = 10;
    query = "SELECT c.clipID,c.description FROM demoClips c WHERE c.ready=1 AND c.mapID=" +
            openCJ\mapID::getMapID() + " AND " + scopeFilter() + " AND POW(c.originX-(" +
            viewerOrigin[0] + "),2)+POW(c.originY-(" + viewerOrigin[1] +
            "),2)<=" + maxHorizontalDistanceSquared + " AND ABS(c.originZ-(" + viewerOrigin[2] +
            "))<=" + maxVerticalDistance;
    if(args.size)
    {
        query += " AND c.clipID=" + int(args[0]);
    }
    rows = self openCJ\mySQL::mysqlAsyncQuery(query + " ORDER BY c.clipID LIMIT " +
                                              (displayedClipLimit + 1));
    if(!isDefined(rows) || !rows.size)
    {
        self sendLocalChatMessage("No matching clip nearby.", true);
        return;
    }
    if(rows.size == 1)
    {
        self play(int(rows[0][0]), false);
        return;
    }
    self sendLocalChatMessage("Nearby clips: choose with !clipdemo <id>.");
    for(i = 0; i < rows.size && i < displayedClipLimit; i++)
    {
        self sendLocalChatMessage("#" + rows[i][0] + " - " + rows[i][1]);
    }
    if(rows.size > displayedClipLimit)
    {
        self sendLocalChatMessage("More clips are available in the Clips menu.");
    }
}

// Read the selected page and update its menu; stale menu replies are cancelled by SQL.
browser()
{
    sqlToken = self openCJ\mySQL::beginMenuRead("clips");
    if(!self openCJ\mySQL::menuReadCurrent(sqlToken))
    {
        return;
    }
    if(!self available())
    {
        return;
    }
    if(!isDefined(self.clipPage))
    {
        self.clipPage = 0;
    }
    if(!isDefined(self.clipTab))
    {
        self.clipTab = "permanent";
    }
    scopeKey = level.clipSession;
    if(self.clipTab == "permanent")
    {
        scopeKey = "permanent";
    }
    clipsPerPage = 4;
    rows = self openCJ\mySQL::mysqlAsyncMenuQuery(
        "SELECT c.clipID,c.description,p.playerName,c.frameCount," +
            "DATE_FORMAT(c.recordedAt,'%Y-%m-%d %H:%i:%s'),COUNT(*) OVER()," +
            "COALESCE(c.RPGShots,-1),COALESCE(c.FPSMode,'?'),COALESCE(c.eleUsed,-1),c.viewCount" +
            " FROM demoClips c JOIN playerDisplayNames p ON c.playerID=p.playerID" +
            " WHERE c.ready=1 AND c.mapID=" + openCJ\mapID::getMapID() +
            " AND c.scopeKey=" + dbStr(scopeKey) + " ORDER BY c.clipID DESC LIMIT " + clipsPerPage +
            " OFFSET " + (self.clipPage * clipsPerPage),
        "clips");
    if(!isDefined(rows))
    {
        return;
    }
    self.clipRows = decodeBrowserRows(rows);
    totalClips = 0;
    if(isDefined(rows) && rows.size)
    {
        totalClips = self.clipRows[0].totalClips;
    }
    if(!totalClips && self.clipPage > 0)
    {
        self.clipPage = 0;
        self thread browser();
        return;
    }
    self.clipPages = int((totalClips + clipsPerPage - 1) / clipsPerPage);
    if(self.clipPages < 1)
    {
        self.clipPages = 1;
    }
    self setClientCvar("opencj_clips_page", "Page " + (self.clipPage + 1) + " / " + self.clipPages);
    tabLabel = "Show: This map session";
    if(self.clipTab == "permanent")
    {
        tabLabel = "Show: Permanent clips";
    }
    self setClientCvar("opencj_clips_tab", tabLabel);
    self setClientCvar("opencj_clips_previous", int(self.clipPage > 0));
    self setClientCvar("opencj_clips_next", int(self.clipPage + 1 < self.clipPages));
    self setClientCvar(
        "opencj_clips_hint",
        "Select once to preview the location; select again to play. Delete your clips: !deleteclip <id>");
    if(!totalClips)
    {
        self setClientCvar(
            "opencj_clips_hint",
            "No clips in this category yet. Use !record, then !stoprecord to create one.");
    }
    for(slot = 0; slot < clipsPerPage; slot++)
    {
        clip = undefined;
        if(slot < self.clipRows.size)
        {
            clip = self.clipRows[slot];
        }
        self renderBrowserRow(slot, clip);
    }
}

// These fields match the SELECT in browser(); menu actions keep the same decoded row.
decodeBrowserRows(rows)
{
    clips = [];
    for(i = 0; i < rows.size; i++)
    {
        row = rows[i];
        clip = spawnStruct();
        clip.id = int(row[0]);
        clip.description = row[1];
        clip.authorName = row[2];
        clip.frameCount = int(row[3]);
        clip.recordedAt = row[4];
        clip.totalClips = int(row[5]);
        clip.rpgShots = int(row[6]);
        clip.fpsMode = row[7];
        clip.usedElevators = int(row[8]);
        clip.viewCount = row[9];
        clips[i] = clip;
    }
    return clips;
}

// Clear unused slots too, so changing pages cannot leave an older clip visible.
renderBrowserRow(slot, clip)
{
    exists = isDefined(clip);
    self setClientCvar("opencj_clips_exists" + slot, int(exists));
    fields = [];
    fields[0] = ""; // ID
    fields[1] = ""; // Description
    fields[2] = ""; // Author
    fields[3] = ""; // Duration
    fields[4] = ""; // Recording date
    details = "";
    if(exists)
    {
        fields[0] = "#" + clip.id;
        fields[1] = clip.description;
        authorName = clip.authorName;
        maxAuthorCharacters = 16; // Available width in the Clips menu.
        if(authorName.size > maxAuthorCharacters)
        {
            authorName = getSubStr(authorName, 0, maxAuthorCharacters);
        }
        fields[2] = authorName;
        fields[3] = "" + seconds(clip.frameCount) + "s";
        fields[4] = clip.recordedAt;
        shots = "" + clip.rpgShots;
        if(clip.rpgShots < 0)
        {
            shots = "?";
        }
        elevatorLabel = "Ele unknown";
        if(clip.usedElevators == 0)
        {
            elevatorLabel = "No ele";
        }
        else if(clip.usedElevators == 1)
        {
            elevatorLabel = "Ele";
        }
        details = shots + " RPG shots | " + clip.fpsMode + " FPS | " + elevatorLabel + " | " +
                  clip.viewCount + " views";
    }
    self setClientCvar("opencj_clips_details" + slot, details);
    for(column = 0; column < fields.size; column++)
    {
        self setClientCvar("opencj_clips_cell" + slot + "_" + column, fields[column]);
    }
}

// Load a clip into a private native recording before transferring it to playback.
play(clipID, preview)
{
    self endon("disconnect");
    if(isDefined(self.clipRecording) || isDefined(self.clipEdit))
    {
        self sendLocalChatMessage("Finish your clip recording/editor first.", true);
        return;
    }
    if(self openCJ\demos::isPlayingDemo())
    {
        if(!isDefined(self.clipPreview))
        {
            return;
        }
        if(self.clipPreview == clipID)
        {
            self.clipPreview = undefined;
            self.playbackPaused = false;
            self.demoFirstFrame = true;
            self setClientCvar("opencj_clips_preview", 0);
            self.clipViewPending = clipID;
            self openCJ\demos::demoMovementHudInMenu(false);
            self closeInGameMenu();
            self closeMenu();
            self setClientCvar("g_scriptMainMenu", "opencj_demo");
            self openMenu("opencj_demo");
            return;
        }
        self openCJ\demos::stopDemo(false);
    }
    if(!self openCJ\demos::canWatch())
    {
        return;
    }
    if(isDefined(self.demoPendingId))
    {
        return;
    }
    rows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT c.frameCount,c.description,p.playerName" +
        " FROM demoClips c JOIN playerDisplayNames p ON p.playerID=c.playerID" +
        " WHERE c.ready=1 AND c.clipID=" + clipID + " AND c.mapID=" + openCJ\mapID::getMapID() +
        " AND " + scopeFilter());
    if(!isDefined(rows) || !rows.size)
    {
        self sendLocalChatMessage("This clip is no longer available.", true);
        return;
    }
    if(isDefined(self.demoPendingId) || !self openCJ\demos::canWatch())
    {
        return;
    }
    nativeDemoID = demoCreateTransient();
    if(!isDefined(nativeDemoID))
    {
        return;
    }
    expectedFrames = int(rows[0][0]);
    description = rows[0][1];
    authorName = rows[0][2];
    clipStorage = 1; // Native chunk source: 0 is a run, 1 is a clip.
    loaded = true;
    nextChunk = 0;
    cache = spawnStruct();
    cache.ready = true;
    cache.loading = false;
    cache.refs = 1;
    level.demoCache["" + nativeDemoID] = cache;
    self.demoPendingId = nativeDemoID;
    self.demoPendingCache = cache;
    while(loaded && numberOfDemoFrames(nativeDemoID) < expectedFrames)
    {
        loadedChunks = self openCJ\mySQL::awaitNative(
            demoLoadChunks(nativeDemoID, clipID, clipStorage, nextChunk));
        if(!self openCJ\demos::ownsPendingCache(nativeDemoID, cache))
        {
            return;
        }
        loaded = isDefined(loadedChunks) && loadedChunks.size > 0 && loadedChunks[0][0] > nextChunk;
        if(loaded)
        {
            nextChunk = loadedChunks[0][0];
        }
    }
    cache.loading = false;
    if(!loaded || numberOfDemoFrames(nativeDemoID) != expectedFrames)
    {
        self openCJ\demos::releasePending();
        return;
    }
    completeDemo(nativeDemoID);
    if(!self openCJ\demos::canWatch())
    {
        self openCJ\demos::releasePending();
        return;
    }
    self.demoBegin = 0;
    self.demoEnd = expectedFrames - 1;
    self.demoCheckpointed = false;
    self.demoStyle = 0;
    waittillframeend;
    if(!self openCJ\demos::ownsPendingCache(nativeDemoID, cache))
    {
        return;
    }
    self.demoPendingId = undefined;
    self.demoPendingCache = undefined;
    if(preview)
    {
        self.clipPreview = clipID;
    }
    self.clipDescription = description;
    self.demoAuthor = authorName;
    self openCJ\demos::startDemo(nativeDemoID);
    if(!self openCJ\demos::isPlayingDemo())
    {
        self.clipDescription = undefined;
        self.clipPreview = undefined;
        self.demoAuthor = undefined;
        return;
    }
    self.clipPlayback = true;
    self setClientCvar("opencj_clips_preview", int(preview));
    if(!preview)
    {
        self.clipViewPending = clipID;
    }
    if(preview)
    {
        self.clipPreview = clipID;
        self.playbackPaused = true;
    }
}

onPlaybackStopped()
{
    self.clipEdit = undefined;
    self.clipPreview = undefined;
    self.clipPlayback = undefined;
    self.clipDescription = undefined;
    self.clipViewPending = undefined;
    self setClientCvar("opencj_clips_preview", 0);
}

onDisconnect()
{
    self releaseUpload();
    if(isDefined(self.clipUploadToken))
    {
        level thread openCJ\mySQL::mysqlAsyncQuery(
            "DELETE FROM demoClips WHERE ready=0 AND uploadToken=" + dbStr(self.clipUploadToken));
    }
    self cancelRecording();
}

// Keep the wait loop small so each menu's actions can be reviewed independently.
responses()
{
    self endon("disconnect");
    for(;;)
    {
        self waittill("menuresponse", menu, response);
        if(menu == "opencj_clips")
        {
            self browserResponse(response);
        }
        else if(menu == "opencj_clipedit" && isDefined(self.clipEdit))
        {
            self editorResponse(response);
        }
    }
}

browserResponse(response)
{
    if(response == "technique")
    {
        self openCJ\demos::toggleTechnique();
        return;
    }
    if(response == "close")
    {
        self closeInGameMenu();
        self closeMenu();
        if(isDefined(self.clipPreview))
        {
            self.demoExitRequested = true;
        }
        return;
    }
    if(response == "open" || response == "toggle" || response == "session" ||
       response == "permanent" || response == "next" || response == "previous")
    {
        if(response == "toggle")
        {
            if(isDefined(self.clipTab) && self.clipTab == "permanent")
            {
                response = "session";
            }
            else
            {
                response = "permanent";
            }
        }
        if(response == "session" || response == "permanent")
        {
            self.clipTab = response;
            self.clipPage = 0;
        }
        if(response == "next" && isDefined(self.clipPages) && self.clipPage + 1 < self.clipPages)
        {
            self.clipPage++;
        }
        if(response == "previous" && isDefined(self.clipPage) && self.clipPage > 0)
        {
            self.clipPage--;
        }
        self thread browser();
    }
    else if(getSubStr(response, 0, 4) == "row:")
    {
        rowIndex = int(getSubStr(response, 4));
        if(isDefined(self.clipRows) && rowIndex >= 0 && rowIndex < self.clipRows.size)
        {
            self play(self.clipRows[rowIndex].id, true);
        }
    }
}

// Editing stays on the selected recording; submission owns its busy state across SQL waits.
editorResponse(response)
{
    if(self.clipEdit.busy)
    {
        return;
    }
    currentFrame = self skipPlaybackFrames(0);
    lastFrame = numberOfDemoFrames(self.demoID) - 1;
    if(response == "stop")
    {
        self.demoExitRequested = true;
        return;
    }
    if(response == "submit")
    {
        wait 0.1;
        if(isDefined(self.clipEdit))
        {
            self submit(self getUserinfo("opencj_clip_description"));
        }
        return;
    }
    if(response == "storage")
    {
        self.clipEdit.permanent = !self.clipEdit.permanent;
    }
    if(response == "start")
    {
        self.playbackPaused = true;
        self.clipEdit.first = currentFrame;
        if(currentFrame > self.clipEdit.last)
        {
            self.clipEdit.last = currentFrame;
        }
    }
    if(response == "end")
    {
        self.playbackPaused = true;
        self.clipEdit.last = currentFrame;
        if(currentFrame < self.clipEdit.first)
        {
            self.clipEdit.first = currentFrame;
        }
    }
    if(response == "reset")
    {
        self.clipEdit.first = 0;
        self.clipEdit.last = lastFrame;
        self.demoBegin = 0;
        self.demoEnd = lastFrame;
    }
    if(response == "preview")
    {
        self.demoBegin = self.clipEdit.first;
        self.demoEnd = self.clipEdit.last;
        self seek(self.demoBegin);
        self.playbackPaused = false;
        self.demoRate = 1;
    }
    if(response == "all")
    {
        self.demoBegin = 0;
        self.demoEnd = lastFrame;
    }
    if(response == "pause")
    {
        self.playbackPaused = true;
    }
    if(response == "resume")
    {
        self.playbackPaused = false;
    }
    parts = strTok(response, ":");
    maxTimelineCells = 40; // Same fixed cells as edit() and updateEditor().
    if(parts.size == 2 && parts[0] == "seek")
    {
        cellCount = lastFrame + 1;
        if(cellCount > maxTimelineCells)
        {
            cellCount = maxTimelineCells;
        }
        cellIndex = int(parts[1]);
        if(cellIndex >= 0 && cellIndex < cellCount)
        {
            self.demoBegin = 0;
            self.demoEnd = lastFrame;
            targetFrame = int(((lastFrame + 1) * cellIndex + cellCount - 1) / cellCount);
            if(targetFrame > lastFrame)
            {
                targetFrame = lastFrame;
            }
            self seek(targetFrame);
            self.playbackPaused = true;
        }
    }
    if(parts.size == 2 && parts[0] == "step")
    {
        frameStep = int(parts[1]);
        if(frameStep == -1 || frameStep == 1 || frameStep == -20 || frameStep == 20)
        {
            self.demoBegin = 0;
            self.demoEnd = lastFrame;
            targetFrame = currentFrame + frameStep;
            if(targetFrame < 0)
            {
                targetFrame = 0;
            }
            if(targetFrame > lastFrame)
            {
                targetFrame = lastFrame;
            }
            self seek(targetFrame);
            self.playbackPaused = true;
        }
    }
    if(parts.size == 2 && parts[0] == "speed")
    {
        playbackRate = int(parts[1]);
        if(playbackRate == 1 || playbackRate == 2 || playbackRate == 4 || playbackRate == -1 ||
           playbackRate == -2 || playbackRate == -4)
        {
            self.demoRate = playbackRate;
            self.playbackPaused = false;
        }
    }
    self updateEditor();
}

validDescription(description)
{
    maxDescriptionLength = 32;
    if(!isDefined(description) || description.size < 1 || description.size > maxDescriptionLength)
    {
        return false;
    }
    hasNonSpace = false;
    for(i = 0; i < description.size; i++)
    {
        character = getSubStr(description, i, i + 1);
        if(character != " ")
        {
            if(!isAlphaNumeric(character))
            {
                return false;
            }
            hasNonSpace = true;
        }
    }
    return hasNonSpace;
}

rename(clipID, description)
{
    self endon("disconnect");
    if(!self available() || clipID < 1)
    {
        return;
    }
    if(!validDescription(description))
    {
        self sendLocalChatMessage("Use 1-32 letters, numbers and spaces only.", true);
        return;
    }
    renameCooldownMs = 10000;
    if(isDefined(self.clipRenameAt) && getTime() - self.clipRenameAt < renameCooldownMs)
    {
        self sendLocalChatMessage("Wait 10 seconds between clip rename requests.", true);
        return;
    }
    // Reserve the cooldown before yielding, including unsuccessful requests.
    self.clipRenameAt = getTime();
    playerID = self openCJ\login::getPlayerID();
    rows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT clipID FROM demoClips c WHERE ready=1 AND clipID=" + clipID +
        " AND playerID=" + playerID + " AND " + scopeFilter());
    if(!isDefined(rows) || !rows.size)
    {
        self sendLocalChatMessage("No available clip with that ID belongs to you.", true);
        return;
    }
    result = self openCJ\mySQL::mysqlAsyncQuery(
        "UPDATE demoClips SET description=" + dbStr(openCJ\mySQL::escapeString(description)) +
        " WHERE clipID=" + clipID + " AND playerID=" + playerID);
    if(isDefined(result))
    {
        self sendLocalChatMessage("Renamed clip #" + clipID + " to " + description + ".");
    }
}

cancelRecording()
{
    if(!isDefined(self.clipRecording))
    {
        return;
    }
    destroyDemo(self.clipRecording.id);
    self.clipRecording = undefined;
}

onSpawnSpectator()
{
    if(!isDefined(self.clipRecording))
    {
        return;
    }
    self cancelRecording();
    self sendLocalChatMessage("Unfinished clip discarded when entering spectator mode.");
}

// CoD4's "v" command accepts multiple dvar/value pairs. Keep each command
// below the engine's 1024-byte limit instead of filling its reliable queue.
// Callers supply only fixed UI dvar names and numeric values.
numericCvars(values)
{
    cvarNames = getArrayKeys(values);
    maxCommandBytes = 800; // Reserve space below the engine command limit.
    command = "v";
    commandsSent = 0;
    for(i = 0; i < cvarNames.size; i++)
    {
        cvarAssignment = " " + cvarNames[i] + " \"" + values[cvarNames[i]] + "\"";
        if(command.size + cvarAssignment.size > maxCommandBytes)
        {
            self SV_GameSendServerCommand(command, true);
            commandsSent++;
            command = "v";
        }
        command += cvarAssignment;
    }
    if(command != "v")
    {
        self SV_GameSendServerCommand(command, true);
        commandsSent++;
    }
    return commandsSent;
}

releaseUpload()
{
    if(!isDefined(self.clipUploadNative))
    {
        return;
    }
    demoUnpin(self.clipUploadNative);
    self.clipUploadNative = undefined;
}

// Called only after a non-preview clip frame has actually been presented.
onPresented()
{
    if(!isDefined(self.clipViewPending) || isDefined(self.clipPreview) ||
       isDefined(self.clipEdit) || self.playbackPaused)
    {
        return;
    }
    clipID = self.clipViewPending;
    self.clipViewPending = undefined;
    viewerID = self openCJ\login::getPlayerID();
    if(!isDefined(viewerID))
    {
        return;
    }
    viewSession = level.clipViewSession;
    level thread openCJ\mySQL::mysqlAsyncQuery("CALL countClipView(" + dbStr(viewSession) + "," +
                                               clipID + "," + viewerID + ")");
}
