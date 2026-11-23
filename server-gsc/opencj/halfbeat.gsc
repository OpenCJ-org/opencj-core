#include openCJ\util;

onInit()
{
    underlyingCmd = openCJ\settings::addSettingBool("allowhalfbeat", false, "Allow the use of halfbeat in your runs", ::_onSettingHalfBeat);
    openCJ\commands_base::addAlias(underlyingCmd, "halfbeat");
}

_onSettingHalfBeat(newVal)
{
    if (!newVal && self.allowHalfBeat && self openCJ\playerRuns::hasRunStarted())
    {
        self sendLocalChatMessage("Your run allows halfbeat, so load back or !reset your run", true);
    }
    else
    {
        self.allowHalfBeat = newVal;
        self resetTracking();
    }
}

onPlayerConnected()
{
    self.allowHalfBeat = false;
    self.hbMessagePrinted = false;
    self disableCorrection();
    self.hbLastCorrection = 0;
    thread _detectHalfBeat();
}

onLoadPosition()
{
    self resetTracking();
}

onRunStarted()
{
    self.allowHalfBeat = self openCJ\settings::getSetting("allowhalfbeat");
    self resetTracking();
}

onRunRestored()
{
    // The load position that occurs will properly set whether or not halfbeat is allowed
    self resetTracking();
}

isHalfBeatAllowed()
{
    return self.allowHalfBeat;
}

setAllowHalfBeat(val)
{
    // If saved position allowed halfbeat, it'll be enforced
    self.allowHalfBeat = val;
    self resetTracking();
}

// Detection and correction now run at the engine's air-acceleration step.
// This lightweight loop synchronizes run policy and reports the first correction.
syncPolicy()
{
    enabled = self isPlayerReady(true) && self openCJ\playerRuns::modeDetectionActive() &&
              !self isHalfBeatAllowed();
    if(!isDefined(self.hbCorrectionEnabled) || self.hbCorrectionEnabled != enabled)
    {
        self setHalfbeatCorrection(int(enabled));
        self.hbCorrectionEnabled = enabled;
    }
}

disableCorrection()
{
    self setHalfbeatCorrection(0);
    self.hbCorrectionEnabled = false;
    self resetStrafeTracking();
}

resetTracking()
{
    self.hbMessagePrinted = false;
    self resetStrafeTracking();
    stats = self getHalfbeatStats();
    self.hbLastCorrection = stats[0];
    self syncPolicy();
}

_detectHalfBeat()
{
    self endon("disconnect");
    while(true)
    {
        self syncPolicy();
        stats = self getHalfbeatStats();
        if(isDefined(self.hbLastCorrection) && stats[0] > self.hbLastCorrection &&
           !self.hbMessagePrinted)
        {
            self iprintln("Limited halfbeat acceleration (^5!allowhalfbeat^7)");
            self.hbMessagePrinted = true;
        }
        self.hbLastCorrection = stats[0];
        wait .05;
    }
}
