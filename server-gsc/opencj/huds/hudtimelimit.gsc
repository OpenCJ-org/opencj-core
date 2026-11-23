onPlayerConnect()
{
    if (!isDefined(self.hudTimeLimit))
    {
        self.hudTimeLimit = newClientHudElem(self);
        self.hudTimeLimit.alpha = 0;
        self.hudTimeLimit.foreground = true;
        self.hudTimeLimit.aligny = "bottom";
        self.hudTimeLimit.vertalign = "bottom";
        self.hudTimeLimit.color = (1.0, 1.0, 1.0);
        self.hudTimeLimit.fontscale = 1.4;
        self.hudTimeLimit.archived = false;
        self setPlaybackLayout(false);

        // The HUD itself is just a timer counting down the level time
        self thread _updateTimer();
    }
}

whileAlive()
{
    // If time gets low, make timer more red and play a sound
    lowTimeThresholdSeconds = 60.0;
    if (level.remainingTimeSeconds <= 0)
    {
        self thread _updateTimer(); // Will hide the timer
    }
    else
    {
        self _setTimerColor();
    }
}

_setTimerColor()
{
    lowTimeThresholdSeconds = 60.0;
    if (level.remainingTimeSeconds < lowTimeThresholdSeconds)
    {
        factor = level.remainingTimeSeconds / lowTimeThresholdSeconds;
        self.hudTimeLimit.color = (1.0, factor, factor);
    }
    else
    {
        self.hudTimeLimit.color = (1.0, 1.0, 1.0);
    }
}

onTimeLimitReached()
{
    _updatePlayerTimers();
}

onRemainingTimeChanged()
{
    _updatePlayerTimers();
}

_updateTimer()
{
    // The HUD itself is just a timer counting down the level time, but it has to be synced with the sound effect
    self endon("disconnect");
    self notify("update_timelimithud");
    self endon("update_timelimithud");
    level waittill("second_passed", secondsLeft);
    if (!isDefined(self))
    {
        return;
    }

    if (secondsLeft > 0)
    {
        self.hudTimeLimit setTimer(secondsLeft);
        self _setTimerColor();
        self.hudTimeLimit.alpha = 1;
    }
    else
    {
        self.hudTimeLimit.alpha = 0;
    }
}

_updatePlayerTimers()
{
    players = getEntArray("player", "classname");
    for (i = 0; i < players.size; i++)
    {
        players[i] thread _updateTimer();
    }
}

// Playback moves the level timer clear of the toolbar; gameplay uses its normal position.
setPlaybackLayout(playback)
{
    align = "center";
    x = 0;
    y = -12;
    if(playback)
    {
        align = "right";
        x = -8;
        y = -74;
    }
    self.hudTimeLimit.horzalign = align;
    self.hudTimeLimit.alignx = align;
    self.hudTimeLimit.x = x;
    self.hudTimeLimit.y = y;
    self.hudTimeLimit.hideWhenInMenu = false;
}
