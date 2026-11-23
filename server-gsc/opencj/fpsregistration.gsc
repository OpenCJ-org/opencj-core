// Registration confirms reporting only; FPS legality remains in fps.gsc.
hasReportedFPS(value)
{
    return isDefined(value) && value != "";
}

canStart()
{
    if(getCodVersion() != 4)
    {
        return true;
    }
    if(isDefined(self.fpsRegistrationPending) && self.fpsRegistrationPending)
    {
        return false;
    }
    reportedFPS = self getUserInfo("com_maxfps");
    if(isDefined(self.fpsRegistrationRequested) && self.fpsRegistrationRequested)
    {
        return hasRestoredFPS(reportedFPS);
    }
    return hasReportedFPS(reportedFPS);
}

// During our menu handshake, 999 is the temporary value, not completion.
// Other reported values still undergo the unchanged FPS legality checks.
hasRestoredFPS(value)
{
    temporaryFPSValue = "999";
    return hasReportedFPS(value) && value != temporaryFPSValue;
}

begin()
{
    self.fpsRegistrationRequested = !hasReportedFPS(self getUserInfo("com_maxfps"));
    self.fpsRegistrationPending = self.fpsRegistrationRequested;
    self.fpsRegistrationMessageAt = undefined;
}

finish()
{
    self.fpsRegistrationPending = false;
    if(!self canStart())
    {
        // A pending message must never suppress the terminal failure message.
        self.fpsRegistrationMessageAt = undefined;
        self explainBlocked();
        return;
    }

    if(isDefined(self.fpsRegistrationMessageAt))
    {
        self iprintln("^2FPS verified. Ready to play.");
    }

    // Complete an initial spawn that was held while registration was pending.
    if(isDefined(self.fpsRegistrationSpawnPending) && self.fpsRegistrationSpawnPending)
    {
        self.fpsRegistrationSpawnPending = false;
        self openCJ\events\spawnPlayer::main(self.fpsRegistrationSpawnAtSave);
    }
}

explainBlocked()
{
    messageCooldownMs = 5000;
    if(isDefined(self.fpsRegistrationMessageAt) && getTime() < self.fpsRegistrationMessageAt + messageCooldownMs)
    {
        return;
    }
    self.fpsRegistrationMessageAt = getTime();
    if(isDefined(self.fpsRegistrationPending) && self.fpsRegistrationPending)
    {
        self iprintln("^3Checking FPS settings - you will join automatically.");
    }
    else
    {
        self iprintlnbold(
            "^1Cannot start run: FPS registration failed. Reconnect; contact an admin if it persists.");
    }
}
