#include openCJ\util;

main(cp, tOffset, route)
{
    self endon("disconnect");
    self endon("spawned");
    if(self openCJ\playerRuns::isRunPaused())
    {
        self iprintln("^5Finished while paused");
        self openCJ\checkpointPointers::onRunFinished(cp);
        return;
    }
    if(!self openCJ\playerRuns::hasRunID() || self openCJ\cheating::isCheating())
    {
        return;
    }
    cpID = openCJ\checkpoints::getCheckpointID(cp);
    if(!isDefined(cpID))
    {
        return;
    }

    self openCJ\demoRecording::capture(true);
    self.playerRuns_runFinishing = true;
    runID = self openCJ\playerRuns::getRunID();
    instanceNumber = self openCJ\playerRuns::getRunInstanceNumber();
    filters = self openCJ\playerRuns::finishSettings();
    category = openCJ\recordNotices::category(
        self openCJ\fps::getCurrentFPSMode(), self openCJ\elevate::hasUsedEle(),
        self openCJ\anyPct::hasAnyPct(), self openCJ\halfBeat::isHalfBeatAllowed(),
        self openCJ\tas::hasHardTAS());
    finishedRPGs = self openCJ\statistics::getExplosiveJumps();
    self openCJ\playTime::setTimePlayed(self openCJ\playTime::getTimePlayed() + tOffset);
    timePlayed = self openCJ\playTime::getTimePlayed();
    self openCJ\playTime::onRunFinished(cp);
    // Finish statistics must exist before the run becomes leaderboard-visible.
    if(!self openCJ\checkpoints::storeCheckpointPassed(runID, cpID, timePlayed))
    {
        return;
    }
    // The checkpoint write may outlive a restore or reset. Do not finish that new run.
    if(!self openCJ\runStorage::isCurrent(runID, instanceNumber))
    {
        return;
    }
    if(!self openCJ\playerRuns::onRunFinished(cp, filters))
    {
        return;
    }
    self.playerRuns_runFinishing = false;
    self openCJ\notifications::beginResults(runID);
    self thread openCJ\finishSounds::onRunFinished(runID);
    self thread openCJ\challenges::awardRun(runID);
    self openCJ\demoRecording::onRunFinished();
    if(!isDefined(route))
    {
        route = "<unknown route>";
    }
    timeStr = formatTimeString(timePlayed, false);
    iprintln(self.name + "^7 finished " + route + " [" + category + "] in ^2" + timeStr + "^7 (" +
             finishedRPGs + " RPGs)");
    self thread openCJ\recordNotices::onRunFinished(runID);
    self thread openCJ\discord::onRunFinished(runID, timeStr, route);
    self openCJ\checkpointPointers::onRunFinished(cp);
    self openCJ\showRecords::onRunFinished(cp);
    self openCJ\huds\hudProgressBar::onRunFinished(cp);
    self openCJ\statistics::onRunFinished();
    self openCJ\elevate::onRunFinished();
}
