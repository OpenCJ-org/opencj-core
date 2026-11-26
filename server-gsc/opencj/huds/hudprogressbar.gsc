#include openCJ\util;

onInit()
{
    level.progressBarShader = "progress_bar_fill";
    level.progressBarHeight = 10;
    level.progressBarMinWidth = 1; // Lower than this and it will default to its normal size
    level.progressBarOffsetX = 0;
    virtualScreenWidth = 640;
    virtualScreenHeight = 480;
    // Extend past the bottom edge so the track does not leave a visible gap.
    bottomEdgeOverlap = 2;
    level.progressBarOffsetY = virtualScreenHeight + bottomEdgeOverlap;
    if(getCodVersion() == 2)
    {
        cod2BottomOffset = 5;
        level.progressBarOffsetY += cod2BottomOffset;
    }
    level.progressBarMaxWidth = virtualScreenWidth - level.progressBarOffsetX;
    level.progressBarScaleSeconds = 0.25;
    level.progressBarTransitionSeconds = 0.05;
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

onPlayerKilled(inflictor, attacker, damage, meansOfDeath, weapon, vDir, hitLoc, psOffsetTime,
               deathAnimDuration)
{
    // Both layers are archived HUD elements, so spectators following this player
    // see this player's bar and lose it here too. Their own bar stays hidden.
    self _hideProgressBar();
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
    self.progressBarTrack setShader(level.progressBarShader, level.progressBarMaxWidth,
                                    level.progressBarHeight);
    self.progressBar = self _createLayer(0);
    self.progressBar setShader(level.progressBarShader, level.progressBarMinWidth,
                               level.progressBarHeight);
    self.previousProgressWidth = 0;
}

_createLayer(sortOrder)
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
    hud.sort = sortOrder;
    hud.shader = level.progressBarShader;
    return hud;
}

// Choose one run state before drawing; every update cancels the previous pulse.
_updateProgressBar(onFinish, checkpointPassed)
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self notify("progressBarUpdated");
    self.progressBar fadeOverTime(level.progressBarTransitionSeconds);
    self.progressBarTrack fadeOverTime(level.progressBarTransitionSeconds);
    self.progressBarTrack.alpha = 0;
    if(self openCJ\checkpointCreation::isEditing())
    {
        self _showStatusBar((0, 0.8, 1), 0.4);
        return;
    }
    runUnavailable = !self openCJ\playerRuns::hasRunID() ||
                     self openCJ\playerRuns::isRunPaused() ||
                     self openCJ\cheating::isCheating();
    if(runUnavailable)
    {
        self _showStatusBar((0.8, 0.3, 0.3), 0.6);
        return;
    }
    if(self openCJ\playerRuns::isRunFinished())
    {
        self _showFinishedProgress(onFinish);
        return;
    }
    if(self openCJ\anyPct::hasAnyPct())
    {
        // Any% has no meaningful checkpoint fraction.
        self _hideProgressBar();
        self.previousProgressWidth = 0;
        return;
    }
    self _showCheckpointProgress(checkpointPassed);
}

// Editor and unavailable-run states use a full-width status color without a track.
_showStatusBar(color, alpha)
{
    self.progressBar setShader(level.progressBarShader, level.progressBarMaxWidth,
                               level.progressBarHeight);
    self.progressBar.color = color;
    self.progressBar.alpha = alpha;
    self.previousProgressWidth = level.progressBarMaxWidth;
}

_showFinishedProgress(onFinish)
{
    progressWidth = level.progressBarMaxWidth;
    self _showProgressBar(progressWidth);
    if(onFinish)
    {
        self _scaleProgress(progressWidth);
        self thread _flashCheckpoint(true);
    }
    else
    {
        self.progressBar setShader(level.progressBarShader, progressWidth, level.progressBarHeight);
    }
    self.previousProgressWidth = progressWidth;
}

// Restores show steady progress; only a newly passed checkpoint starts a pulse.
_showCheckpointProgress(checkpointPassed)
{
    progressWidth = self _checkpointProgressWidth();
    self _showProgressBar(progressWidth);
    if(progressWidth > 0)
    {
        self _scaleProgress(progressWidth);
        advanced = progressWidth > self.previousProgressWidth;
        if(isDefined(checkpointPassed) && checkpointPassed && advanced)
        {
            self thread _flashCheckpoint(false);
        }
    }
    self.previousProgressWidth = progressWidth;
}

// Before the first checkpoint, the gray track represents zero progress.
_checkpointProgressWidth()
{
    progressWidth = 0;
    checkpoint = self openCJ\checkpoints::getCurrentCheckpoint();
    if(isDefined(checkpoint))
    {
        passedCount = openCJ\checkpoints::getPassedCheckpointCount(checkpoint);
        remainingCount = openCJ\checkpoints::getRemainingCheckpointCount(checkpoint);
        totalCount = passedCount + remainingCount;
        if(totalCount > 0)
        {
            progressWidth = int((passedCount / totalCount) * level.progressBarMaxWidth);
        }
    }
    if(progressWidth < 0)
    {
        progressWidth = 0;
    }
    if(progressWidth > level.progressBarMaxWidth)
    {
        progressWidth = level.progressBarMaxWidth;
    }
    return progressWidth;
}

_scaleProgress(progressWidth)
{
    startWidth = int(max(level.progressBarMinWidth, self.previousProgressWidth));
    self.progressBar setShader(level.progressBarShader, startWidth, level.progressBarHeight);
    self.progressBar scaleOverTime(level.progressBarScaleSeconds, progressWidth,
                                   level.progressBarHeight);
}

_flashCheckpoint(finished)
{
    self endon("disconnect");
    self endon("progressBarUpdated");
    // A fast green signal must be noticeable while looking at the jump, not the bar.
    // The normal gray/green progress split returns as soon as the flash fades.
    riseSeconds = 0.001;
    peakSeconds = 0.10;
    fadeSeconds = 0.10;
    checkpointAlpha = 232 / 255.0;
    finishAlpha = 248 / 255.0;
    self.progressBar fadeOverTime(riseSeconds);
    self.progressBar.color = (0.4, 1, 0.5);
    self.progressBar.alpha = checkpointAlpha;
    self.progressBarTrack fadeOverTime(riseSeconds);
    self.progressBarTrack.color = (0.1, 1, 0.2);
    self.progressBarTrack.alpha = checkpointAlpha;
    if(isDefined(finished) && finished)
    {
        self.progressBar.color = (0.55, 1, 0.65);
        self.progressBar.alpha = finishAlpha;
    }
    wait peakSeconds;
    self.progressBar fadeOverTime(fadeSeconds);
    self.progressBar.color = level.progressBarFillColor;
    self.progressBar.alpha = level.progressBarFillAlpha;
    self.progressBarTrack fadeOverTime(fadeSeconds);
    self.progressBarTrack.color = level.progressBarTrackColor;
    self.progressBarTrack.alpha = level.progressBarTrackAlpha;
}

_hideProgressBar()
{
    self notify("progressBarUpdated");
    self.progressBar fadeOverTime(level.progressBarTransitionSeconds);
    self.progressBar.alpha = 0;
    self.progressBarTrack fadeOverTime(level.progressBarTransitionSeconds);
    self.progressBarTrack.alpha = 0;
}

_showProgressBar(progressWidth)
{
    self.progressBarTrack.color = level.progressBarTrackColor;
    self.progressBarTrack.alpha = level.progressBarTrackAlpha;
    self.progressBar.color = level.progressBarFillColor;
    self.progressBar.alpha = 0;
    if(progressWidth > 0)
    {
        self.progressBar.alpha = level.progressBarFillAlpha;
    }
}
