#include openCJ\util;

onInit()
{
    level.progressBarShader = "progress_bar_fill";
    level.progressBarHeight = 10;
    level.progressBarMinWidth = 1; // Lower than this and it will default to its normal size
    level.progressBarOffsetX = 0;
    level.progressBarOffsetY = 482; // Needs a +2 otherwise there is a gap under it, for whatever reason
    if (getCodVersion() == 2)
    {
        level.progressBarOffsetY += 5;
    }
    level.progressBarMaxValue = (640 - level.progressBarOffsetX);
    level.progressBarScaleDuration = 0.25;
    // Quantized alpha steps keep the intended strength after network encoding.
    level.progressBarTrackAlpha = 112 / 255.0;
    level.progressBarFillAlpha = 216 / 255.0;
    level.progressBarTrackColor = (0.5, 0.5, 0.5);
    level.progressBarFillColor = (0.2, 0.8, 0.3);
    precacheShader(level.progressBarShader);
}

onCheckpointsChanged(checkpointPassed)
{
    self _updateProgressBar(false, checkpointPassed);
}

onSpawnPlayer()
{
    self _updateProgressBar(false);
}

onSpawnSpectator()
{
    self _hideProgressBar();
}

onPlayerKilled(inflictor, attacker, damage, meansOfDeath, weapon, vDir, hitLoc, psOffsetTime, deathAnimDuration)
{
    self _hideProgressBar();
    //todo: hide for spectating clients too
}

onRunFinished(cp)
{
    self _updateProgressBar(true);
}

onPlayerConnect()
{
    self _createProgressBar();
}

onRunPaused()
{
    self _updateProgressBar(false);
}

onRunStopped()
{
    self _updateProgressBar(false);
}

onRunResumed()
{
    self _updateProgressBar(false);
}

onRunRestored()
{
    self _updateProgressBar(false);
}

_createProgressBar()
{
    // A fixed full-width track and the existing independently sized fill.
    self.progressBarTrack = self _createLayer(-1);
    self.progressBarTrack setShader(level.progressBarShader, level.progressBarMaxValue, level.progressBarHeight);
    self.progressBar = self _createLayer(0);
    self.progressBar setShader(level.progressBarShader, level.progressBarMinWidth, level.progressBarHeight);
    self.prevProgress = 0;
}

_createLayer(sort)
{
    hud = newClientHudElem(self);
    hud.horzAlign = "fullscreen";
    hud.vertAlign = "fullscreen";
    hud.alignX = "left";
    hud.alignY = "bottom";
    hud.x = level.progressBarOffsetX;
    hud.y = level.progressBarOffsetY;
    hud.alpha = 0;
    hud.color = (1, 1, 1);
    hud.archived = true;
    hud.hideWhenInMenu = true;
    hud.sort = sort;
    hud.shader = level.progressBarShader;
    return hud;
}

_updateProgressBar(onFinish, checkpointPassed)
{
    if(self openCJ\demos::isPlayingDemo())return;
    // Replace both sides of a pending pulse when the run state changes.
    self notify("progressBarUpdated");
    self.progressBar fadeOverTime(0.05);
    self.progressBarTrack fadeOverTime(0.05);
    self.progressBarTrack.alpha = 0;
    if (self openCJ\checkpointCreation::isEditing())
    {
        self.progressBar setShader(level.progressBarShader, level.progressBarMaxValue, level.progressBarHeight);
        self.progressBar.color = (0, 0.8, 1);
        self.progressBar.alpha = 0.4;
        self.prevProgress = level.progressBarMaxValue;
        return;
    }
    if(!self openCJ\playerRuns::hasRunID() || self openCJ\playerRuns::isRunPaused() || self openCJ\cheating::isCheating())
    {
        progress = level.progressBarMaxValue;
        self.progressBar setShader(level.progressBarShader, progress, level.progressBarHeight);
        self.progressBar.color = (0.8, 0.3, 0.3);
        self.progressBar.alpha = 0.6;
    }
    else if(self openCJ\playerRuns::isRunFinished())
    {
        progress = level.progressBarMaxValue;
        self _showProgressBar(progress);
        if(onFinish)
        {
            self _scaleProgress(progress);
            self thread _flashCheckpoint(true);
        }
        else
            self.progressBar setShader(level.progressBarShader, progress, level.progressBarHeight);
    }
    else if(self openCJ\anyPct::hasAnyPct())
    {
        // Any% has no meaningful checkpoint fraction.
        progress = 0;
        self _hideProgressBar();
    }
    else
    {
        progress = 0;
        checkpoint = self openCJ\checkpoints::getCurrentCheckpoint();
        if(isDefined(checkpoint))
        {
            passed = openCJ\checkpoints::getPassedCheckpointCount(checkpoint);
            remaining = openCJ\checkpoints::getRemainingCheckpointCount(checkpoint);
            total = passed + remaining;
            if(total > 0)progress = int((passed / total) * level.progressBarMaxValue);
        }
        // Before the first checkpoint, the gray track represents zero progress.
        if(progress < 0)progress = 0;
        if(progress > level.progressBarMaxValue)progress = level.progressBarMaxValue;
        self _showProgressBar(progress);
        if(progress > 0)
        {
            self _scaleProgress(progress);
            if(isDefined(checkpointPassed) && checkpointPassed && progress > self.prevProgress)
                self thread _flashCheckpoint(false);
        }
    }
    self.prevProgress = progress;
}

_scaleProgress(progress)
{
    start = int(max(level.progressBarMinWidth, self.prevProgress));
    self.progressBar setShader(level.progressBarShader, start, level.progressBarHeight);
    self.progressBar scaleOverTime(level.progressBarScaleDuration, progress, level.progressBarHeight);
}

_flashCheckpoint(finished)
{
    self endon("disconnect");
    self endon("progressBarUpdated");
    // A fast green signal must be noticeable while looking at the jump, not the bar.
    // The normal gray/green progress split returns as soon as the flash fades.
    self.progressBar fadeOverTime(0.001);
    self.progressBar.color = (0.4, 1, 0.5);
    self.progressBar.alpha = 232 / 255.0;
    self.progressBarTrack fadeOverTime(0.001);
    self.progressBarTrack.color = (0.1, 1, 0.2);
    self.progressBarTrack.alpha = 232 / 255.0;
    if(isDefined(finished) && finished)
    {
        self.progressBar.color = (0.55, 1, 0.65);
        self.progressBar.alpha = 248 / 255.0;
    }
    wait 0.10; // Near-instant onset, 100 ms peak, then a 100 ms fade-out.
    self.progressBar fadeOverTime(0.10);
    self.progressBar.color = level.progressBarFillColor;
    self.progressBar.alpha = level.progressBarFillAlpha;
    self.progressBarTrack fadeOverTime(0.10);
    self.progressBarTrack.color = level.progressBarTrackColor;
    self.progressBarTrack.alpha = level.progressBarTrackAlpha;
}

_hideProgressBar()
{
    self notify("progressBarUpdated");
    self.progressBar fadeOverTime(0.05);
    self.progressBar.alpha = 0;
    self.progressBarTrack fadeOverTime(0.05);
    self.progressBarTrack.alpha = 0;
}

_showProgressBar(progress)
{
    self.progressBarTrack.color = level.progressBarTrackColor;
    self.progressBarTrack.alpha = level.progressBarTrackAlpha;
    self.progressBar.color = level.progressBarFillColor;
    self.progressBar.alpha = 0;
    if(progress > 0)self.progressBar.alpha = level.progressBarFillAlpha;
}
