#include openCJ\util;

onInit()
{
    _initConstants();
    // Do not enable recording against an unmigrated database.
    level.demoStorageReady =
        isDefined(openCJ\mySQL::mysqlSyncQuery("SELECT runID FROM demoRuns LIMIT 0"));
    level.demoPublicationReady = false;
    if(level.demoStorageReady)
    {
        schema = openCJ\mySQL::mysqlSyncQuery(
            "SELECT EXISTS(" + "SELECT 1 FROM information_schema.tables" +
            " WHERE table_schema=DATABASE() AND table_name='demoPublications')," +
            "EXISTS(SELECT 1 FROM information_schema.routines" +
            " WHERE routine_schema=DATABASE() AND routine_name='publishDemo'" +
            " AND routine_type='PROCEDURE')");
        level.demoPublicationReady = isDefined(schema) && schema.size == 1 &&
                                     int(schema[0][0]) == 1 && int(schema[0][1]) == 1;
    }
    // Reclaim abandoned uploads after crashes, with a generous grace period
    // so another server's active publication cannot be mistaken for an orphan.
    if(level.demoPublicationReady)
    {
        level thread openCJ\mySQL::mysqlAsyncQueryNosave(
            "DELETE FROM demoRuns WHERE ready=0 AND createdAt < NOW() - INTERVAL 7 DAY");
    }
}

// Values are stored in demo frame flags and SQL mode masks. Keep them in sync
// with DemoFrameFlag in opencj_demo.cpp and existing recordings.
_initConstants()
{
    level.demoFlags = spawnStruct();
    level.demoFlags.left = 1;
    level.demoFlags.right = 2;
    level.demoFlags.forward = 4;
    level.demoFlags.back = 8;
    level.demoFlags.sprintButton = 16;
    level.demoFlags.jump = 32;
    level.demoFlags.sprinting = 64;
    level.demoFlags.mantling = 128;
    level.demoFlags.ladder = 256;
    level.demoFlags.standing = 512;
    level.demoFlags.crouched = 1024;
    level.demoFlags.prone = 2048;
    level.demoFlags.rpg = 4096;
    level.demoFlags.onGround = 8192;
    level.demoFlags.bounce = 16384;

    level.demoModes = spawnStruct();
    level.demoModes.anyPercent = 1;
    level.demoModes.elevators = 2;
    level.demoModes.halfbeat = 4;
    level.demoModes.hardTAS = 8;
}

onConnect()
{
    self.demoRecordings = [];
}

onRunStarted()
{
    if(!isDefined(level.demoPublicationReady) || !level.demoPublicationReady ||
       getCodVersion() != 4)
    {
        return;
    }
    // Tutorial runs are never published, so they are not recorded at all
    if(self openCJ\tutorial::isTutorialRun())
    {
        return;
    }
    runID = self openCJ\playerRuns::getRunID();
    if(!isDefined(runID) || isDefined(self.demoRecordings["" + runID]))
    {
        return;
    }
    recording = spawnStruct();
    recording.id = runID;
    recording.saves = [];
    recording.failed = false;
    recording.finishing = false;
    recording.lastTick = -1;
    self.demoRecordings["" + runID] = recording;
    if(createDemo(runID) != runID)
    {
        recording.failed = true;
    }
    else
    {
        self capture();
    }
}

current()
{
    if(!self openCJ\playerRuns::hasRunID() || !isDefined(self.demoRecordings))
    {
        return undefined;
    }
    return self.demoRecordings["" + self openCJ\playerRuns::getRunID()];
}

// Sample a live run once per server tick; forced samples still respect pause and edit state.
capture(force)
{
    recording = self current();
    if(!isDefined(recording) || recording.failed || recording.finishing ||
       (isDefined(self.playerRuns_runFinishing) && self.playerRuns_runFinishing) ||
       self openCJ\demos::isPlayingDemo() || self openCJ\checkpointCreation::isEditing())
    {
        return;
    }
    // AFK pauses capture without discarding this session's run recording.
    if(isDefined(self.isAFK) && self.isAFK)
    {
        return;
    }
    if(self.sessionState != "playing" || self openCJ\playerRuns::isRunPaused() ||
       self openCJ\cheating::isCheating())
    {
        return;
    }
    if(!isDefined(force) || !force)
    {
        if(self openCJ\playerRuns::isRunFinished() || !self openCJ\playTime::isActivelyPlaying() ||
           recording.lastTick == getTime())
        {
            return;
        }
    }
    checkpoint = self openCJ\checkpoints::getCurrentCheckpoint();
    checkpointID = 0;
    if(isDefined(checkpoint))
    {
        if(isDefined(checkpoint.bigBrother))
        {
            checkpoint = checkpoint.bigBrother;
        }
        if(isDefined(checkpoint.id))
        {
            checkpointID = checkpoint.id;
        }
    }
    framesPerSecond = self openCJ\fps::getCurrentFPS();
    firedRPG = isDefined(self.eventQueue["rpg"]);
    if(!isDefined(
           addFrameToDemo(recording.id, self.origin, self getPlayerAngles(), 1, self frameFlags(),
                          0, int(isDefined(recording.loaded) && recording.loaded), int(firedRPG),
                          int(framesPerSecond), checkpointID, self getEntityNumber())))
    {
        recording.failed = true;
        destroyDemo(recording.id);
        self sendLocalChatMessage(
            "Demo recording stopped: memory limit reached. Your run is unaffected.", true);
        return;
    }
    recording.lastTick = getTime();
    recording.loaded = false;
}

onSaved(saveNumber)
{
    recording = self current();
    if(!isDefined(recording) || recording.failed || recording.finishing)
    {
        return;
    }
    self capture();
    if(recording.failed)
    {
        return;
    }
    recording.saves["" + saveNumber] = numberOfDemoFrames(recording.id);
}

// Retain failed attempts for playback, but invalidate saves beyond the restored frame.
onLoaded(saveNumber)
{
    recording = self current();
    if(!isDefined(recording) || recording.failed || recording.finishing)
    {
        return;
    }
    frameCount = recording.saves["" + saveNumber];
    if(!isDefined(frameCount) || !isDefined(demoMarkFailedSince(recording.id, frameCount)))
    {
        recording.failed = true;
        destroyDemo(recording.id);
        return;
    }
    keys = getArrayKeys(recording.saves);
    for(i = 0; i < keys.size; i++)
    {
        if(recording.saves[keys[i]] > frameCount)
        {
            recording.saves[keys[i]] = undefined;
        }
    }
    recording.lastTick = -1;
    recording.loaded = true;
}

onDisconnect()
{
    if(!isDefined(self.demoRecordings))
    {
        return;
    }
    keys = getArrayKeys(self.demoRecordings);
    for(i = 0; i < keys.size; i++)
    {
        recording = self.demoRecordings[keys[i]];
        if(!recording.failed && !recording.finishing)
        {
            destroyDemo(recording.id);
        }
    }
    self.demoRecordings = [];
}

onRunFinished()
{
    recording = self current();
    if(!isDefined(recording) || recording.failed || recording.finishing)
    {
        return;
    }
    // A recording can only exist here if the run's mode changed after it began
    if(self openCJ\tutorial::isTutorialRun())
    {
        self discard(recording.id);
        return;
    }
    recording.finishing = true;
    recording.saves = []; // No further rewind/save lookup is possible for a finished run.
    completeDemo(recording.id);
    level thread persist(recording.id);
}

frameFlags()
{
    flags = 0;
    if(self leftButtonPressed())
    {
        flags |= level.demoFlags.left;
    }
    if(self rightButtonPressed())
    {
        flags |= level.demoFlags.right;
    }
    if(self forwardButtonPressed())
    {
        flags |= level.demoFlags.forward;
    }
    if(self backButtonPressed())
    {
        flags |= level.demoFlags.back;
    }
    if(self sprintButtonPressed())
    {
        flags |= level.demoFlags.sprintButton;
    }
    if(self jumpButtonPressed())
    {
        flags |= level.demoFlags.jump;
    }
    if(self isSprinting())
    {
        flags |= level.demoFlags.sprinting;
    }
    if(self isMantling())
    {
        flags |= level.demoFlags.mantling;
    }
    if(self isOnLadder())
    {
        flags |= level.demoFlags.ladder;
    }
    stance = self getStance();
    if(stance == "stand")
    {
        flags |= level.demoFlags.standing;
    }
    else if(stance == "duck" || stance == "crouch")
    {
        flags |= level.demoFlags.crouched;
    }
    else
    {
        flags |= level.demoFlags.prone;
    }
    if(openCJ\weapons::isRPG(self getCurrentWeapon()))
    {
        flags |= level.demoFlags.rpg;
    }
    if(self isOnGround())
    {
        flags |= level.demoFlags.onGround;
    }
    if(isDefined(self.eventQueue["bounced"]))
    {
        flags |= level.demoFlags.bounce;
    }
    return flags;
}

// Runs completed in this connection alone reach here; resumed historical runs
// have no in-memory recording. SQL holds only complete candidate payloads.
persist(runID)
{
    frameCount = numberOfDemoFrames(runID);
    if(!isDefined(frameCount) || frameCount < 2)
    {
        destroyDemo(runID);
        return;
    }
    if(!isDefined(level.demoPersisting))
    {
        level.demoPersisting = 0;
    }
    level.demoPersisting++;
    uploaded = uploadCandidate(runID, frameCount);
    published = uploaded;
    if(uploaded)
    {
        published = promote(runID);
    }
    if(!isDefined(published))
    {
        printf("OpenCJ: demo publication outcome uncertain for run " + runID +
               "; candidate retained for reconciliation.\n");
    }
    else if(!published)
    {
        printf("OpenCJ: demo publication failed for run " + runID +
               "; leaderboard result retained.\n");
        // Only our unpublished candidate can be removed here.
        openCJ\mySQL::mysqlAsyncBackground(
            "DELETE FROM demoRuns WHERE runID=" + runID + " AND ready=0", "demo:" + runID);
    }
    level.demoPersisting--;
    destroyDemo(runID);
}

// Persist metadata first, then bounded chunks. Only promote() makes a complete candidate visible.
uploadCandidate(runID, frameCount)
{
    query = "INSERT INTO demoRuns(" +
            "runID,mapID,routeID,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount)" +
            " SELECT r.runID,r.mapID,c.finishRouteID,r.FPSMode," +
            "r.anyPct+2*r.ele+4*r.hb+8*r.hardTAS," + "s.timePlayed,s.explosiveJumps," + frameCount +
            " FROM playerRuns r" + " JOIN checkpoints c ON c.cpID=r.finishcpID" +
            " JOIN checkpointStatistics s ON s.runID=r.runID AND s.cpID=r.finishcpID" +
            " WHERE r.runID=" + runID + " AND r.finishTimeStamp IS NOT NULL";
    uploaded = isDefined(openCJ\mySQL::mysqlAsyncBackground(query, "demo:" + runID));
    framesPerChunk = 64; // Matches the stored chunk index and native transfer limits.
    runStorage = 0;      // demoUploadChunk: 0 is a run; 1 is a clip.
    for(firstFrame = 0; uploaded && firstFrame < frameCount; firstFrame += framesPerChunk)
    {
        chunkFrames = frameCount - firstFrame;
        if(chunkFrames > framesPerChunk)
        {
            chunkFrames = framesPerChunk;
        }
        chunkIndex = int(firstFrame / framesPerChunk);
        transferID = demoUploadChunk(runID, runID, runStorage, firstFrame, chunkFrames, chunkIndex);
        uploaded = isDefined(openCJ\mySQL::awaitNative(transferID));
    }
    return uploaded;
}

// A stored procedure owns the entire transaction on one worker connection.
// One publication lane avoids tying up several workers on the same map lock;
// the database lock also serializes publishers on separate game servers.
promote(runID)
{
    uncertain = false;
    maxAttempts = 3;
    lockWaitTimeoutError = 1205;
    deadlockError = 1213;
    retryDelaySeconds = 0.05;
    for(attempt = 0; attempt < maxAttempts; attempt++)
    {
        result = openCJ\mySQL::_request("CALL publishDemo(" + runID + ")",
                                        level.sqlConstants.policyBackground, "demo-publication", "",
                                        level.sqlConstants.backgroundQueueWaitMs, true);
        if(result.status == level.sqlConstants.outcomeOK)
        {
            if(isDefined(result.rows) && result.rows.size == 1 && result.rows[0].size == 2)
            {
                return int(result.rows[0][0]) == 1;
            }
            return undefined; // A malformed receipt cannot justify deletion.
        }
        if(result.status == level.sqlConstants.outcomeUnknown)
        {
            uncertain = true;
            // A lost reply may follow a successful commit, including a loser
            // whose payload was removed. Its durable receipt survives cleanup.
            receipt = openCJ\mySQL::_request(
                "SELECT runID FROM demoPublications WHERE runID=" + runID,
                level.sqlConstants.policyRead, "", "", level.sqlConstants.defaultQueueWaitMs, true);
            if(receipt.status != level.sqlConstants.outcomeOK || !isDefined(receipt.rows))
            {
                return undefined;
            }
            if(receipt.rows.size == 1)
            {
                return true;
            }
            // Replaying is safe: the procedure rechecks the receipt under the
            // map lock, including if the first call has not finished yet.
        }
        else if(result.status != level.sqlConstants.outcomeError ||
                (result.error != lockWaitTimeoutError && result.error != deadlockError))
        {
            if(uncertain)
            {
                return undefined;
            }
            return false;
        }
        if(attempt + 1 < maxAttempts)
        {
            wait retryDelaySeconds *(attempt + 1);
        }
    }
    if(uncertain)
    {
        return undefined;
    }
    return false;
}

isBetter(kind, elapsedTime, rpgJumpCount, previousElapsedTime, previousRPGJumpCount)
{
    if(kind == "lowrpg")
    {
        return rpgJumpCount < previousRPGJumpCount ||
               (rpgJumpCount == previousRPGJumpCount && elapsedTime < previousElapsedTime);
    }
    if(kind == "walkthrough")
    {
        return elapsedTime < previousElapsedTime;
    }
    return elapsedTime < previousElapsedTime ||
           (elapsedTime == previousElapsedTime && rpgJumpCount < previousRPGJumpCount);
}

// An explicitly abandoned run cannot be resumed through the runs menu.
discard(runID)
{
    if(!isDefined(runID) || !isDefined(self.demoRecordings))
    {
        return;
    }
    recording = self.demoRecordings["" + runID];
    if(!isDefined(recording))
    {
        return;
    }
    if(!recording.failed && !recording.finishing)
    {
        destroyDemo(runID);
    }
    self.demoRecordings["" + runID] = undefined;
}
