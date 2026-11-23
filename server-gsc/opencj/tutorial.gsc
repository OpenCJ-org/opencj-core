#include openCJ\util;

// Tutorial mode: a separate run mode for new players. While a tutorial run is
// played, the server sets the player's com_maxfps during jumps (native code:
// server-ext/opencj_autofps.cpp). Finished tutorial runs are stored with
// playerRuns.tutorial = 1 and never count for leaderboards, record notices,
// finish sounds or challenges.
//
// The "tutorial" setting is the player's choice for new runs. A run's mode is
// fixed when the run is created: switching saves the current run (if it has
// started) and starts a new run in the chosen mode.

onInit()
{
    level.tutorialSettingName = "tutorial";
    openCJ\settings::addSettingBool(level.tutorialSettingName, false,
        "Tutorial mode: the server sets your FPS while you jump. Tutorial runs never count for " +
        "leaderboards or challenges. Switching saves your run and starts a new one. Usage: !tutorial [on/off]",
        ::_onSettingTutorial);

    // New accounts get this switched on; answering the introduction switches it off.
    level.tutorialIntroSettingName = "tutorialintro";
    openCJ\settings::addSettingBool(level.tutorialIntroSettingName, false,
        "Show the beginner introduction (with the tutorial mode offer) when you next spawn. " +
        "Usage: !tutorialintro [on/off]", ::_onSettingTutorialIntro);
    level.tutorialIntroMenu = "opencj_tutorial_intro";
    level.tutorialOfferMenu = "opencj_tutorial_offer";
    precacheMenu(level.tutorialIntroMenu);
    precacheMenu(level.tutorialOfferMenu);

    // cl_maxpackets during auto-FPS (players' usual competitive setting).
    level.tutorialMaxPackets = 100;
}

onPlayerConnect()
{
    self.tutorialSkipLoadPending = false;
    self.tutorialIntroShownThisConnection = false;
    self.tutorialRun = false;
    self.tutorialSwitching = false;
    self.tutorialNextRunMode = undefined;
    self.tutorialAutoFPSActive = false;
    self.tutorialRestoreFPS = undefined;
    self.tutorialRestoreMaxPackets = undefined;
}

onPlayerConnected()
{
    self thread _syncAutoFPSLoop();
}

isTutorialRun()
{
    return isDefined(self.tutorialRun) && self.tutorialRun;
}

// A new run uses the mode requested by a switch, otherwise the player's setting.
onRunCreated()
{
    if (isDefined(self.tutorialNextRunMode))
    {
        self.tutorialRun = self.tutorialNextRunMode;
        self.tutorialNextRunMode = undefined;
        return;
    }

    self.tutorialRun = false;
    if (self openCJ\settings::areSettingsLoaded())
    {
        self.tutorialRun = self openCJ\settings::getSetting(level.tutorialSettingName);
    }
}

// Loading a save (including restoring a saved run) takes the mode of that run.
setTutorialRun(isTutorial)
{
    self.tutorialRun = isTutorial;
}

// Marks a run as a tutorial run in the database before it is finished, so the
// finish can never enter rankings. Returns false if that could not be confirmed;
// the caller must then not record the finish.
markRunAsTutorial(runID)
{
    query = "UPDATE playerRuns SET tutorial = 1" +
            " WHERE runID = " + runID +
            " AND playerID = " + self openCJ\login::getPlayerID();
    stored = self openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
    return isDefined(stored);
}

_onSettingTutorial(requestedTutorialMode)
{
    // While settings load at login there is no run yet; the value only applies
    // to runs created later.
    if (!self openCJ\playerRuns::hasRunID() || self.tutorialSwitching)
    {
        return;
    }
    if (requestedTutorialMode == self isTutorialRun())
    {
        return;
    }

    // An untouched run has nothing worth keeping, so it changes mode in place.
    if (!self openCJ\playerRuns::hasRunStarted())
    {
        self.tutorialRun = requestedTutorialMode;
        self _announceMode();
        return;
    }

    self thread _switchRunMode(requestedTutorialMode);
}

// Saves the current run and starts a new run in the requested mode.
_switchRunMode(useTutorial)
{
    self endon("disconnect");
    self.tutorialSwitching = true;

    // A run without saves can neither be restored nor listed in the runs menu,
    // so it is archived like !reset instead of saved.
    noSavesError = 1;
    if (self openCJ\savePosition::canLoadError(0) == noSavesError)
    {
        self.tutorialNextRunMode = useTutorial;
        self openCJ\playerRuns::stopRun(true);
        self.tutorialSwitching = false;
        self _announceMode();
        return;
    }

    // Saved without a label, like !saverun without one; the runs board shows the
    // run's mode. saveRun stops the run only when the save succeeded.
    self openCJ\playerRuns::saveRun("");
    if (self openCJ\playerRuns::hasRunID())
    {
        self sendLocalChatMessage("Your run could not be saved, so it stays as it is. " +
                                  "Your tutorial setting applies to your next run.", true);
        self.tutorialSwitching = false;
        return;
    }

    self.tutorialNextRunMode = useTutorial;
    // With no current run this only creates a new run and respawns the player.
    self openCJ\playerRuns::stopRun(true);
    self.tutorialSwitching = false;
    self _announceMode();
}

_announceMode()
{
    if (self isTutorialRun())
    {
        self iprintlnbold("Tutorial mode: your FPS is set for you while jumping");
        self sendLocalChatMessage("Tutorial runs do not count for leaderboards or challenges. Use !tutorial to leave.");
    }
    else
    {
        self iprintlnbold("Normal mode");
    }
}

// Tutorial runs must follow a route, because auto-FPS aims at the next
// checkpoint. A checkpoint that would start any% (skipped checkpoint or route
// change) loads the player back instead; without a save the run starts over.
onCheckpointSkipped()
{
    if (self.tutorialSkipLoadPending)
    {
        return;
    }
    self.tutorialSkipLoadPending = true;
    self iprintlnbold("Tutorial runs follow the route: checkpoint skipped, loading back");
    self thread _loadBackAfterSkip();
}

isSkipLoadPending()
{
    return self.tutorialSkipLoadPending;
}

_loadBackAfterSkip()
{
    self endon("disconnect");
    noSavesError = 1;
    loadError = self openCJ\savePosition::canLoadError(0);
    if (loadError == noSavesError)
    {
        self openCJ\playerRuns::stopRun(true);
    }
    else if (loadError == 0)
    {
        self openCJ\events\loadPosition::main(0);
    }
    else
    {
        self openCJ\savePosition::printCanLoadError(loadError);
    }
    self.tutorialSkipLoadPending = false;
}

// A brand-new account is asked whether it knows CodJumper on its first spawn.
onNewAccount()
{
    self openCJ\settings::setSettingByScript(level.tutorialIntroSettingName, true);
}

// Switching the introduction on (also with !tutorialintro) shows it on the next spawn.
_onSettingTutorialIntro(showIntroduction)
{
    if (showIntroduction)
    {
        self.tutorialIntroShownThisConnection = false;
    }
}

// Shows the introduction once per connection while it is still unanswered, so a
// player who closes it with Escape is asked again on the next connection only.
onSpawnPlayer()
{
    if (self.tutorialIntroShownThisConnection)
    {
        return;
    }
    if (!self openCJ\settings::areSettingsLoaded())
    {
        return;
    }
    if (!self openCJ\settings::getSetting(level.tutorialIntroSettingName))
    {
        return;
    }
    self.tutorialIntroShownThisConnection = true;
    self thread _runIntroduction();
}

// Asks "familiar with CodJumper?"; a "No" leads to the tutorial mode offer.
// Waits for the player's answers until they choose or disconnect.
_runIntroduction()
{
    self endon("disconnect");
    // Let the spawn finish first, so the popup is not closed by spawn menu handling.
    wait 1;
    self openMenu(level.tutorialIntroMenu);

    while (true)
    {
        self waittill("menuresponse", menu, response);
        if (menu == level.tutorialIntroMenu)
        {
            if (response == "familiar")
            {
                self _finishIntroduction(false);
                self sendLocalChatMessage("Welcome! You can try tutorial mode any time with !tutorial.");
                return;
            }
            if (response == "new")
            {
                self openMenu(level.tutorialOfferMenu);
                continue;
            }
            if (response == "later")
            {
                return;
            }
        }
        else if (menu == level.tutorialOfferMenu)
        {
            if (response == "yes")
            {
                self _finishIntroduction(true);
                return;
            }
            if (response == "no")
            {
                self _finishIntroduction(false);
                self sendLocalChatMessage("You can switch to tutorial mode any time with !tutorial.");
                return;
            }
            if (response == "later")
            {
                return;
            }
        }
    }
}

_finishIntroduction(useTutorial)
{
    self openCJ\settings::setSettingByScript(level.tutorialIntroSettingName, false);
    if (useTutorial)
    {
        // Goes through the normal setting change, which switches the current run.
        self openCJ\settings::setSettingByScript(level.tutorialSettingName, true);
    }
}

// Lets auto-FPS tell an RPG push from a bounce: both raise the player's speed
// during movement, but only a push follows (or precedes) a shot.
onRPGFired()
{
    if (self.tutorialAutoFPSActive)
    {
        self notifyAutoFPSRPGFired();
    }
}

// Auto-FPS runs only while a tutorial run is actually being played.
_shouldAutoSetFPS()
{
    if (!self isTutorialRun() || self.sessionState != "playing")
    {
        return false;
    }
    if (!self openCJ\playerRuns::hasRunStarted())
    {
        return false;
    }
    if (self openCJ\demos::isPlayingDemo() || self openCJ\checkpointCreation::isEditing())
    {
        return false;
    }
    return true;
}

// Checks every server frame (50 ms) whether auto-FPS should be on, and switches
// the native selection on or off. When it switches off, the player's own
// com_maxfps from before tutorial mode is given back.
_syncAutoFPSLoop()
{
    self endon("disconnect");
    while (true)
    {
        shouldAutoSetFPS = self _shouldAutoSetFPS();
        if (shouldAutoSetFPS != self.tutorialAutoFPSActive)
        {
            if (shouldAutoSetFPS)
            {
                self _startAutoFPS();
            }
            else
            {
                self _stopAutoFPS();
            }
        }
        if (self.tutorialAutoFPSActive)
        {
            self _updateTargetHeight();
        }
        wait 0.05;
    }
}

// Tells auto-FPS the nearest point of the nearest next checkpoint, so a jump that
// would reach it too low gets 333. Without a next checkpoint there is no target.
_updateTargetHeight()
{
    nextCheckpoints = self openCJ\checkpoints::getCurrentChildCheckpoints();
    nearestPoint = undefined;
    nearestDistanceSquared = undefined;
    if (isDefined(nextCheckpoints))
    {
        for (i = 0; i < nextCheckpoints.size; i++)
        {
            point = self _nearestCheckpointPoint(nextCheckpoints[i]);
            if (!isDefined(point))
            {
                continue;
            }
            distanceToPoint = distanceSquared(self.origin, point);
            if (!isDefined(nearestDistanceSquared) || distanceToPoint < nearestDistanceSquared)
            {
                nearestDistanceSquared = distanceToPoint;
                nearestPoint = point;
            }
        }
    }

    if (isDefined(nearestPoint))
    {
        // Checkpoint positions can hold whole numbers; the native side takes floats.
        self setAutoFPSTarget(nearestPoint[0] * 1.0, nearestPoint[1] * 1.0, nearestPoint[2] * 1.0);
    }
    else
    {
        self clearAutoFPSTarget();
    }
}

// The point of a checkpoint the player can land on first: for a landing area the
// nearest point of its perimeter (players land near the edge they come from, often
// hundreds of units before the middle), otherwise the checkpoint's origin.
_nearestCheckpointPoint(checkpoint)
{
    if (!isDefined(checkpoint.area) || checkpoint.area.size < 3)
    {
        return checkpoint.origin;
    }
    points = checkpoint.area;
    nearestPoint = undefined;
    nearestDistanceSquared = undefined;
    polygonSide = 0;
    isInside = true;
    for (i = 0; i < points.size; i++)
    {
        edgeStart = points[i];
        edgeEnd = points[(i + 1) % points.size];
        // Above the area (all edges on the same side): the player is over it.
        edgeCrossProduct = (edgeEnd[0] - edgeStart[0]) * (self.origin[1] - edgeStart[1])
            - (edgeEnd[1] - edgeStart[1]) * (self.origin[0] - edgeStart[0]);
        if (edgeCrossProduct != 0)
        {
            edgeSide = 1;
            if (edgeCrossProduct < 0)
            {
                edgeSide = -1;
            }
            if (polygonSide != 0 && polygonSide != edgeSide)
            {
                isInside = false;
            }
            polygonSide = edgeSide;
        }
        point = _nearestPointOnCheckpointEdge(self.origin, edgeStart, edgeEnd);
        x = self.origin[0] - point[0];
        y = self.origin[1] - point[1];
        if (!isDefined(nearestDistanceSquared) || x * x + y * y < nearestDistanceSquared)
        {
            nearestDistanceSquared = x * x + y * y;
            nearestPoint = point;
        }
    }
    if (isInside)
    {
        return (self.origin[0], self.origin[1], nearestPoint[2]);
    }
    return nearestPoint;
}

// Project a position onto a checkpoint edge, keeping its interpolated landing height.
_nearestPointOnCheckpointEdge(position, edgeStart, edgeEnd)
{
    dx = edgeEnd[0] - edgeStart[0];
    dy = edgeEnd[1] - edgeStart[1];
    lengthSquared = dx * dx + dy * dy;
    interpolationFactor = 0;
    // Avoid dividing by a nearly zero horizontal edge.
    minimumEdgeLengthSquared = 0.0001;
    if (lengthSquared > minimumEdgeLengthSquared)
    {
        interpolationFactor = ((position[0] - edgeStart[0]) * dx
            + (position[1] - edgeStart[1]) * dy) / lengthSquared;
    }
    if (interpolationFactor < 0)
    {
        interpolationFactor = 0;
    }
    if (interpolationFactor > 1)
    {
        interpolationFactor = 1;
    }
    return edgeStart + vectorScale(edgeEnd - edgeStart, interpolationFactor);
}

_startAutoFPS()
{
    // Remember the player's own FPS before the server starts changing it.
    self.tutorialRestoreFPS = intOrUndefined(self getUserInfo("com_maxfps"));
    self setAutoFPSEnabled(true);
    self.tutorialAutoFPSActive = true;

    // More packets per second let the server see strafe switches sooner, so FPS
    // changes arrive earlier. Only for clients that report their own value (the
    // client mod registers it), so it can be given back.
    maxPackets = intOrUndefined(self getUserInfo("cl_maxpackets"));
    if (isDefined(maxPackets) && maxPackets < level.tutorialMaxPackets)
    {
        self.tutorialRestoreMaxPackets = maxPackets;
        self setClientCvar("cl_maxpackets", level.tutorialMaxPackets);
    }
}

_stopAutoFPS()
{
    self setAutoFPSEnabled(false);
    self.tutorialAutoFPSActive = false;
    if (isDefined(self.tutorialRestoreFPS))
    {
        self setClientCvar("com_maxfps", self.tutorialRestoreFPS);
    }
    self.tutorialRestoreFPS = undefined;
    if (isDefined(self.tutorialRestoreMaxPackets))
    {
        self setClientCvar("cl_maxpackets", self.tutorialRestoreMaxPackets);
    }
    self.tutorialRestoreMaxPackets = undefined;
}
