#include openCJ\util;

// Store checkpoint and finish data before announcing the completed run.
main(checkpoint, timeOffsetMs, routeName)
{
    self endon("disconnect");
    self endon("spawned");
    if(self openCJ\playerRuns::isRunPaused())
    {
        self iprintln("^5Finished while paused");
        self openCJ\checkpointPointers::onRunFinished(checkpoint);
        return;
    }
    if(!self openCJ\playerRuns::hasRunID() || self openCJ\cheating::isCheating())
    {
        return;
    }
    checkpointID = openCJ\checkpoints::getCheckpointID(checkpoint);
    if(!isDefined(checkpointID))
    {
        return;
    }

    self openCJ\demoRecording::capture(true);
    self.playerRuns_runFinishing = true;
    runID = self openCJ\playerRuns::getRunID();
    instanceNumber = self openCJ\playerRuns::getRunInstanceNumber();
    filters = self openCJ\playerRuns::finishSettings();
    categoryLabel = openCJ\recordNotices::category(
        self openCJ\fps::getCurrentFPSMode(), self openCJ\elevate::hasUsedEle(),
        self openCJ\anyPct::hasAnyPct(), self openCJ\halfBeat::isHalfBeatAllowed(),
        self openCJ\tas::hasHardTAS());
    explosiveJumpCount = self openCJ\statistics::getExplosiveJumps();
    self openCJ\playTime::setTimePlayed(self openCJ\playTime::getTimePlayed() + timeOffsetMs);
    timePlayedMs = self openCJ\playTime::getTimePlayed();
    self openCJ\playTime::onRunFinished(checkpoint);
    // Finish statistics must exist before the run becomes leaderboard-visible.
    if(!self openCJ\checkpoints::storeCheckpointPassed(runID, checkpointID, timePlayedMs))
    {
        return;
    }
    // The checkpoint write may outlive a restore or reset. Do not finish that new run.
    if(!self openCJ\runStorage::isCurrent(runID, instanceNumber))
    {
        return;
    }
    if(!self openCJ\playerRuns::onRunFinished(checkpoint, filters))
    {
        return;
    }
    self.playerRuns_runFinishing = false;
    self openCJ\notifications::beginResults(runID);
    self thread openCJ\finishSounds::onRunFinished(runID);
    self thread openCJ\challenges::awardRun(runID);
    self openCJ\demoRecording::onRunFinished();
    if(!isDefined(routeName))
    {
        routeName = "<unknown route>";
    }
    formattedTime = formatTimeString(timePlayedMs, false);
    iprintln(self.name + "^7 finished " + routeName + " [" + categoryLabel + "] in ^2" +
             formattedTime + "^7 (" + explosiveJumpCount + " RPGs)");
    self thread openCJ\recordNotices::onRunFinished(runID);
    self thread openCJ\discord::onRunFinished(runID, formattedTime, routeName);
    self openCJ\checkpointPointers::onRunFinished(checkpoint);
    self openCJ\showRecords::onRunFinished(checkpoint);
    self openCJ\huds\hudProgressBar::onRunFinished(checkpoint);
    self openCJ\statistics::onRunFinished();
    self openCJ\elevate::onRunFinished();
}
