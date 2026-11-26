#include openCJ\util;

// Event handlers

onInit()
{
    // Useful for a variety of purposes such as run label cleaning
    level.basicAllowedCharacters =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_,.<>?/!@#*()[]{}|";
}

onPlayerConnect()
{
    self.playerRuns_runPaused = false;
}

onPlayerLogin()
{
    self thread _createRunID();
}

// Persist this run's finish; a delayed reply must not finish a replacement run.
onRunFinished(cp, filterStr)
{
    if(self isRunFinished() || !self hasRunID() || self openCJ\cheating::isCheating())
    {
        return false;
    }

    checkpointID = openCJ\checkpoints::getCheckpointID(cp);
    if(!isDefined(checkpointID))
    {
        return false;
    }

    runID = self getRunID();
    instanceNumber = self getRunInstanceNumber();
    if(!isDefined(filterStr))
    {
        filterStr = self finishSettings();
    }

    // A tutorial finish must be marked first so it can never enter rankings.
    if(self openCJ\tutorial::isTutorialRun())
    {
        marked = self openCJ\tutorial::markRunAsTutorial(runID);
        if(!self openCJ\runStorage::isCurrent(runID, instanceNumber))
        {
            return false;
        }
        if(!marked)
        {
            self iPrintLnBold("Could not save this tutorial finish. Try finishing again.");
            return false;
        }
    }

    query = "SELECT runFinished(" + runID + ", " + checkpointID + ", " + filterStr + ", " +
            instanceNumber + ")";
    rows = self openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
    // Let the write settle even if the player changes runs while it is in flight.
    if(!self openCJ\runStorage::isCurrent(runID, instanceNumber))
    {
        return false;
    }
    if(!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
    {
        self iPrintLnBold(
            "Could not confirm that this finish was saved. Check your records before resetting.");
        return false;
    }

    self.playerRuns_runFinished = true;
    self openCJ\halfBeat::disableCorrection();
    return true;
}

finishSettings()
{
    FPSMode = self openCJ\fps::getCurrentFPSMode();
    usedElevator = self openCJ\elevate::hasUsedEle();
    usedAnyPercent = self openCJ\anyPct::hasAnyPct();
    halfbeatAllowed = self openCJ\halfBeat::isHalfBeatAllowed();
    usedHardTAS = self openCJ\tas::hasHardTAS();

    // Keep the argument order expected by the database's runFinished function.
    return "'" + FPSMode + "', " + usedElevator + ", " + usedAnyPercent + ", " +
           halfbeatAllowed + ", " + usedHardTAS;
}

onSpawnPlayer()
{
    if(self hasRunID())
    {
        if(self hasRunStarted() && !self isRunPaused())
        {
            self openCJ\playTime::startTimer();
        }
    }
}

onSpawnSpectator()
{
    self openCJ\playTime::pauseTimer();
}

// Other functions

hasRunID()
{
    return isDefined(self.playerRuns_runID) && isDefined(self.runInstanceNumber);
}

// Automatic mode detection only applies while actually playing a scored run.
modeDetectionActive()
{
    if(!self hasRunID() || self.sessionState != "playing")
    {
        return false;
    }
    if(self isRunPaused() || self isRunFinished())
    {
        return false;
    }
    if(self openCJ\checkpointCreation::isEditing() || self openCJ\demos::isPlayingDemo())
    {
        return false;
    }
    return !self openCJ\cheating::isCheating();
}

getRunID()
{
    return self.playerRuns_runID;
}

getRunInstanceNumber()
{
    return self.runInstanceNumber;
}

pauseRun()
{
    if(self hasRunID())
    {
        self.playerRuns_runPaused = true;
        self openCJ\events\onRunPaused::main();
        self iPrintLnBold("Run paused. Load back to resume.");
    }
}

resumeRun()
{
    if(self hasRunID())
    {
        self.playerRuns_runPaused = false;
        self.playerRuns_runStarted = true;
        self openCJ\playTime::startTimer();
        self openCJ\events\onRunResumed::main();
        self iPrintLnBold("Run resumed");
    }
}

stopRun(shouldReset)
{
    // Reset archives the current run and starts another; a plain stop keeps it saved.

    if(self openCJ\demos::isPlayingDemo())
    {
        self sendLocalChatMessage("Cannot stop run during demo playback", true);
        return;
    }

    if(shouldReset)
    {
        // Archive the current run
        runID = self getRunID();
        self thread archiveRun(runID);

        // Create a new run
        self _createRunID();
    }
    else if(self hasRunID())
    {
        // Player is no longer in a run
        _clearRunVars();

        // Inform other scripts that the current run stopped
        self openCJ\events\onRunStopped::main();
    }
    else
    {
        self sendLocalChatMessage("Not in a run, can't stop", true);
    }
}

// Save the current label, then stop only the same run that the database confirmed.
saveRun(runLabel)
{
    if(!self hasRunID())
    {
        self sendLocalChatMessage("You're not currently in a run", true);
        return;
    }
    if(!self _canAccessRuns())
    {
        return;
    }

    maxRunLabelSize = 32;
    if(runLabel.size > maxRunLabelSize)
    {
        self sendLocalChatMessage("Run label can be up to 32 characters", true);
        return;
    }

    // Escaping can double the label length; the database allows 64 characters.
    cleanedRunLabel = cleanCharacters(runLabel, level.basicAllowedCharacters, maxRunLabelSize);
    escapedRunLabel = openCJ\mySQL::escapeString(cleanedRunLabel);
    runID = self getRunID();
    instanceNumber = self getRunInstanceNumber();
    query = "SELECT saveRun(" + runID + ", " + instanceNumber + ", " +
            dbStr(escapedRunLabel) + ")";

    rows = self openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
    // Saving the old run must settle, but its reply cannot stop a newer run.
    if(!isDefined(self) || !self openCJ\runStorage::isCurrent(runID, instanceNumber))
    {
        return;
    }
    if(!hasResult(rows) || int(rows[0][0]) != runID)
    {
        self sendLocalChatMessage("Run could not be saved", true);
        return;
    }

    if(escapedRunLabel != runLabel)
    {
        self sendLocalChatMessage("Run saved successfully, but some characters were replaced");
    }
    else
    {
        self sendLocalChatMessage("Run saved successfully");
    }

    // A saved run stays available; stopping here must not archive it or start another.
    self stopRun(false);
}

_canAccessRuns()
{
    if(!openCJ\mapID::hasMapID())
    {
        self sendLocalChatMessage("Sorry, the current map is not in the database", true);
        return false;
    }
    if(!self isPlayerReady(false))
    {
        self sendLocalChatMessage("You're not logged in or settings haven't loaded yet", true);
        return false;
    }
    if(self openCJ\demos::isPlayingDemo())
    {
        self sendLocalChatMessage("Can't access runs while watching a demo", true);
        return false;
    }
    return true;
}

archiveRun(runID)
{
    if(isDefined(self))
    {
        self openCJ\demoRecording::discard(runID);
    }
    if(isDefined(runID))
    {
        playerIDSqlStr = " ";
        if(isDefined(self))
        {
            playerIDSqlStr += "AND playerID = " + self openCJ\login::getPlayerID() + " ";
        }
        query =
            "UPDATE playerRuns SET archived = True" + " WHERE runID = " + runID + playerIDSqlStr;

        stored = openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
        if(!isDefined(stored))
        {
            if(isDefined(self))
            {
                self sendLocalChatMessage("Could not confirm that the run was archived.", true);
            }
            return;
        }
        if(isDefined(self))
        {
            self iprintln("^5Archived ^7run (" + runID + ")");
        }
    }
}

// Load an owned run and archive the previous run only after the restore succeeds.
// Call as a thread because loading history waits for database replies.
restoreRun(runID)
{
    self openCJ\mapBoost::cancel();
    if(isDefined(self.cpc))
    {
        self sendLocalChatMessage(
            "Exit checkpoint editing with !cp stop before restoring a run.", true);
        return;
    }
    self endon("cpc_started");
    if(self.sessionState != "playing" && self.sessionState != "spectator")
    {
        return;
    }
    if(!self _canAccessRuns())
    {
        return;
    }

    oldRunID = undefined;
    if(self hasRunID())
    {
        oldRunID = self getRunID();
    }
    self _invalidatePendingCreation();
    if(!self openCJ\historySave::historyLoad(runID))
    {
        // Valid empty runs are handled by the loader. Failure or cancellation must
        // not move the player, change the old flags, or announce a successful restore.
        return;
    }

    self.playerRuns_runFinishing = false;
    self.playerRuns_runStarted = true;
    self.playerRuns_runPaused = false;
    self.playerRuns_runFinished = false;
    loadError = self openCJ\savePosition::canLoadError(0);
    if(isDefined(oldRunID) && oldRunID != runID)
    {
        self thread archiveRun(oldRunID);
    }

    if(loadError == 0)
    {
        self thread openCJ\events\loadPosition::main(0);
    }
    else
    {
        self openCJ\savePosition::printCanLoadError(loadError);
        self openCJ\cheating::setCheating(true);
    }

    self openCJ\events\onRunRestored::main();
    // TAS users depend on this exact message.
    self iprintln("^2Restored run (" + runID + ")");
    self sendLocalChatMessage("Restored run. Be careful: using !rp again will delete this run!");
}

_clearRunVars()
{
    self _invalidatePendingCreation();
    self openCJ\notifications::cancelAll();
    self openCJ\historySave::cancelPendingPage();
    self.playerRuns_runFinishing = false;
    self.playerRuns_runStarted = false;
    self.playerRuns_runPaused = false;
    self.playerRuns_runFinished = false;
    self.playerRuns_runID = undefined;
    self.runInstanceNumber = undefined;
}

startRun()
{
    if(self openCJ\checkpointCreation::isEditing())
    {
        return;
    }
    if(self isPlayerReady(false) && self hasRunID() && (self.sessionState == "playing") &&
       !self hasRunStarted())
    {
        if(!self openCJ\fpsRegistration::canStart())
        {
            self openCJ\fpsRegistration::explainBlocked();
            self openCJ\events\spawnSpectator::main();
            return;
        }
        self.playerRuns_runStarted = true;
        self.playerRuns_runPaused = false;
        self openCJ\events\onRunStarted::main();
        self iprintln("Run started");
    }
}

hasJumpSlowdown()
{
    return getCodVersion() == 2; // placeholder
}

printRunIDandInstanceNumber()
{
    self iprintln("runid: " + self.playerRuns_runID);
    self iprintln("runinstance: " + self.runInstanceNumber);
}

isRunFinished()
{
    return (self hasRunID() && isDefined(self.playerRuns_runFinished) &&
            self.playerRuns_runFinished);
}

setRunIDAndInstanceNumber(runID, instanceNumber)
{
    self _invalidatePendingCreation();
    self openCJ\notifications::cancelAll();
    self.playerRuns_runID = runID;
    self.runInstanceNumber = instanceNumber;
}

// Cancel old lookups and invalidate creation replies when another run is selected or requested.
_invalidatePendingCreation()
{
    self openCJ\commands::cancelRestoreLookup();
    if(!isDefined(self.playerRuns_creationVersion))
    {
        self.playerRuns_creationVersion = 0;
    }
    self.playerRuns_creationVersion++;
}

// Publish the run and its instance together, only for the latest creation request.
_createRunID()
{
    if(isDefined(self.cpc))
    {
        return;
    }
    self endon("cpc_started");
    self endon("disconnect");
    if(!self openCJ\login::IsLoggedIn())
    {
        return;
    }

    self _clearRunVars();
    creationVersion = self.playerRuns_creationVersion;
    playerID = self openCJ\login::getPlayerID();
    query = "SELECT createRunID(" + playerID + ", " + openCJ\mapID::getMapID() + ")";
    rows = self openCJ\mySQL::mysqlAsyncWrite(query, "player:" + playerID);
    // The first write may already have committed. An obsolete request must not
    // start its next write or overwrite a run selected while that write was pending.
    if(self.playerRuns_creationVersion != creationVersion)
    {
        return;
    }
    if(!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
    {
        self iprintlnbold("Could not create runID. Please reconnect");
        return;
    }

    runID = int(rows[0][0]);
    rows = self openCJ\mySQL::mysqlAsyncWrite("SELECT createRunInstance(" + runID + ")",
                                              "run:" + runID);
    if(self.playerRuns_creationVersion != creationVersion)
    {
        return;
    }
    if(!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
    {
        self iprintlnbold("Could not set run instance number. Please reconnect");
        return;
    }

    instanceNumber = int(rows[0][0]);
    self setRunIDAndInstanceNumber(runID, instanceNumber);
    self iprintln("^5Created ^7new run (" + runID + ")");
    self openCJ\events\onRunCreated::main();
}

hasRunStarted()
{
    return (isDefined(self.playerRuns_runStarted) && self.playerRuns_runStarted);
}

isRunPaused()
{
    return self.playerRuns_runPaused;
}
