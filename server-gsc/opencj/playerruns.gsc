#include openCJ\util;

// Event handlers

onInit()
{
    // Useful for a variety of purposes such as run label cleaning
    level.basicAllowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_,.<>?/!@#*()[]{}|";
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
    if (self isRunFinished() || !self hasRunID() || self openCJ\cheating::isCheating())
    {
        return false;
    }

    checkpointID = openCJ\checkpoints::getCheckpointID(cp);
    if (!isDefined(checkpointID))
    {
        return false;
    }

    runID = self getRunID();
    instanceNumber = self getRunInstanceNumber();
    if (!isDefined(filterStr))
    {
        filterStr = self finishSettings();
    }

    // A tutorial finish must be marked first so it can never enter rankings.
    if (self openCJ\tutorial::isTutorialRun())
    {
        marked = self openCJ\tutorial::markRunAsTutorial(runID);
        if (!self openCJ\runStorage::isCurrent(runID, instanceNumber))
        {
            return false;
        }
        if (!marked)
        {
            self iPrintLnBold("Could not save this tutorial finish. Try finishing again.");
            return false;
        }
    }

    query = "SELECT runFinished(" + runID + ", " + checkpointID + ", " +
            filterStr + ", " + instanceNumber + ")";
    rows = self openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
    // Let the write settle even if the player changes runs while it is in flight.
    if (!self openCJ\runStorage::isCurrent(runID, instanceNumber))
    {
        return false;
    }
    if (!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
    {
        self iPrintLnBold("Could not confirm that this finish was saved. Check your records before resetting.");
        return false;
    }

    self.playerRuns_runFinished = true;
    self openCJ\halfBeat::disableCorrection();
    return true;
}

finishSettings()
{
    FPSMode = self openCJ\fps::getCurrentFPSMode();
    usedEle = self openCJ\elevate::hasUsedEle();
    usedAnyPct = self openCJ\anyPct::hasAnyPct();
    allowHb = self openCJ\halfBeat::isHalfBeatAllowed();
    usedHardTAS = self openCJ\tas::hasHardTAS();

    // This is a store procedure in SQL database
    return "'" + FPSMode + "'" + ", " + usedEle + ", " + usedAnyPct + ", " + allowHb + ", " + usedHardTAS;
}

onSpawnPlayer()
{
    if (self hasRunID())
    {
        if (self hasRunStarted() && !self isRunPaused())
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
    return self hasRunID() && self.sessionState == "playing" &&
        !self isRunPaused() && !self isRunFinished() &&
        !self openCJ\checkpointCreation::isEditing() && !self openCJ\demos::isPlayingDemo() &&
        !self openCJ\cheating::isCheating();
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
    if (self hasRunID())
    {
        self.playerRuns_runPaused = true;
        self openCJ\events\onRunPaused::main();
        self iPrintLnBold("Run paused. Load back to resume.");
    }
}

resumeRun()
{
    if (self hasRunID())
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
    // Resetting a run will stop the current run, create a new run and respawn the player
    // When stopping a run normally (such as saving it),

    if(self openCJ\demos::isPlayingDemo())
    {
        self sendLocalChatMessage("Cannot stop run during demo playback", true);
        return;
    }

    if (shouldReset)
    {
        // Archive the current run
        runID = self getRunID();
        self thread archiveRun(runID);

        // Create a new run
        self _createRunID();
    }
    else if (self hasRunID())
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

saveRun(runLabel)
{
    if (!self openCJ\playerRuns::hasRunID())
    {
        self sendLocalChatMessage("You're not currently in a run", true);
        return;
    }
    if (!self openCJ\mapID::hasMapID())
    {
        self sendLocalChatMessage("Sorry, the current map is not in the database", true);
        return;
    }

    if (!self isPlayerReady(false))
    {
        self sendLocalChatMessage("You're not logged in or settings haven't loaded yet", true);
        return;
    }

    if (self openCJ\demos::isPlayingDemo())
    {
        self sendLocalChatMessage("Can't access runs while watching a demo", true);
        return;
    }

    maxRunLabelSize = 32;
    if (runLabel.size > maxRunLabelSize)
    {
        self sendLocalChatMessage("Run label can be up to 32 characters", true);
        return;
    }

    // Clean the run label, escape it for database and limit it to 32 chars. escapeString might make it slightly larger, so db allows 64.
    cleanedRunLabel = openCJ\mySQL::escapeString(cleanCharacters(runLabel, level.basicAllowedCharacters, maxRunLabelSize));
    mapId = self openCJ\mapID::getMapID();
    runID = self getRunID();
    runInstanceNumber = self getRunInstanceNumber();

    query = "SELECT saveRun(" + runID + ", " + runInstanceNumber + ", " + dbStr(cleanedRunLabel) + ")";
    printf("DEBUG: executing saveRun query:\n" + query + "\n");

    rows = self openCJ\mySQL::mysqlAsyncWrite(query, "run:"+runID);
    // Saving the old run must settle, but its reply cannot stop a newer run.
    if (!isDefined(self) || !self openCJ\runStorage::isCurrent(runID, runInstanceNumber))
    {
        return;
    }
    if (isDefined(rows) && isDefined(rows[0]) && isDefined(rows[0][0]) && (int(rows[0][0]) == runID))
    {
        // Successfully saved
        if (cleanedRunLabel != runLabel)
        {
            self sendLocalChatMessage("Run saved successfully, but some characters were replaced");
        }
        else
        {
            self sendLocalChatMessage("Run saved successfully");
        }

        // Stop the run but don't archive and don't start a new run
        stopRun(false);
    }
    else
    {
        self sendLocalChatMessage("Run could not be saved", true);
    }
}

archiveRun(runID)
{
    if(isDefined(self))self openCJ\demoRecording::discard(runID);
    if (isDefined(runID))
    {
        playerIDSqlStr = " ";
        if (isDefined(self))
        {
            playerIDSqlStr += "AND playerID = " + self openCJ\login::getPlayerID() + " ";
        }
        query = "UPDATE playerRuns SET archived = True" +
                " WHERE runID = " + runID +
                playerIDSqlStr;
        printf("DEBUG: executing archiveRun query:\n" + query + "\n");

        stored=openCJ\mySQL::mysqlAsyncWrite(query, "run:"+runID);
        if(!isDefined(stored))
        {
            if(isDefined(self))self sendLocalChatMessage("Could not confirm that the run was archived.",true);
            return;
        }
        if (isDefined(self))
        {
            self iprintln("^5Archived ^7run (" + runID + ")");
        }
    }
}

restoreRun(runID) // Call this function as a thread
{
    self openCJ\mapBoost::cancel();
    if (isDefined(self.cpc))
    {
        self sendLocalChatMessage("Exit checkpoint editing with !cp stop before restoring a run.", true);
        return;
    }
    self endon("cpc_started");

    if ((self.sessionState != "playing") && (self.sessionState != "spectator"))
    {
        return;
    }

    if (!self openCJ\mapID::hasMapID())
    {
        self sendLocalChatMessage("Sorry, the current map is not in the database", true);
        return;
    }

    if (!self isPlayerReady(false))
    {
        self sendLocalChatMessage("You're not logged in or settings haven't loaded yet", true);
        return;
    }

    if (self openCJ\demos::isPlayingDemo())
    {
        self sendLocalChatMessage("Can't access runs while watching a demo", true);
        return;
    }

    // First archive the user's current run, since it's typically a newly created run that will remain unused and clutter up the runs menu
    oldRunID = undefined;
    if (self hasRunID())
    {
        oldRunID = self getRunID();
    }
    self _invalidatePendingCreation();
    if(self openCJ\historySave::historyLoad(runID)) // Sets runID and runInstanceNumber
    {
        self.playerRuns_runFinishing = false;
        self.playerRuns_runStarted = true;
        self.playerRuns_runPaused = false;
        self.playerRuns_runFinished = false;
        error = self openCJ\savePosition::canLoadError(0);
        if(isDefined(oldRunID) && oldRunID != runID)
        {
            self thread archiveRun(oldRunID);
        }

        if(error == 0)
        {

            self thread openCJ\events\loadPosition::main(0);
        }
        else
        {
            self openCJ\savePosition::printCanLoadError(error);
            self openCJ\cheating::setCheating(true);
        }
    }
    else
    {
        // The history loader handles valid empty runs itself. False means the
        // restore failed or became stale; do not change the old run or report success.
        return;
    }

    self openCJ\events\onRunRestored::main();
    self iprintln("^2Restored run (" + runID + ")"); // TAS users depend on this message, do not modify
    self sendLocalChatMessage("Restored run. Be careful: using !rp again will delete this run!");
}

_clearRunVars()
{
    self _invalidatePendingCreation();
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
    if (self openCJ\checkpointCreation::isEditing())
        return;
    if(self isPlayerReady(false) && self hasRunID() && (self.sessionState == "playing") && !self hasRunStarted())
    {
        if (!self openCJ\fpsRegistration::canStart())
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
    return getCodVersion() == 2; //placeholder
}

printRunIDandInstanceNumber()
{
    self iprintln("runid: " + self.playerRuns_runID);
    self iprintln("runinstance: " + self.runInstanceNumber);
}

isRunFinished()
{
    return (self hasRunID() && isDefined(self.playerRuns_runFinished) && self.playerRuns_runFinished);
}

setRunIDAndInstanceNumber(runID, instanceNumber)
{
    self _invalidatePendingCreation();
    self.playerRuns_runID = runID;
    self.runInstanceNumber = instanceNumber;
}

// Invalidate pending creation replies when another run is selected or requested.
_invalidatePendingCreation()
{
    if (!isDefined(self.playerRuns_creationVersion))
    {
        self.playerRuns_creationVersion = 0;
    }
    self.playerRuns_creationVersion++;
}

// Publish the run and its instance together, only for the latest creation request.
_createRunID()
{
    if (isDefined(self.cpc))
    {
        return;
    }
    self endon("cpc_started");
    self endon("disconnect");
    if (!self openCJ\login::IsLoggedIn())
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
    if (self.playerRuns_creationVersion != creationVersion)
    {
        return;
    }
    if (!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
    {
        self iprintlnbold("Could not create runID. Please reconnect");
        return;
    }

    runID = int(rows[0][0]);
    rows = self openCJ\mySQL::mysqlAsyncWrite(
        "SELECT createRunInstance(" + runID + ")", "run:" + runID);
    if (self.playerRuns_creationVersion != creationVersion)
    {
        return;
    }
    if (!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
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
