// Temporary ramp boosts. Cancellation must precede any relocation/state reset.
// Only registered boost owners are affected; other maps' movement is untouched.
start(boostScale)
{
    self endon("disconnect");
    self endon("opencj_map_boost_cancelled");
    if(isDefined(self.mapBoostOwned))
    {
        return;
    }
    if(!isAlive(self) || self.sessionstate != "playing" || !(self isOnGround()))
    {
        return;
    }
    // Editing checkpoints does not change ramp physics. Editor travel cancels
    // at its teleport boundary, just like normal position loads.
    if(self openCJ\noclip::hasNoclip() || self openCJ\demos::isPlayingDemo())
    {
        return;
    }

    self.mapBoostOwned = true;
    updateIntervalSeconds = 0.05;
    cooldownSeconds = 2;
    // Preserve the original ramp's sampling and takeoff behavior exactly.
    // Do not test trigger membership here: some launch platforms extend outside it.
    while(isAlive(self) && self.sessionstate == "playing" && self isOnGround())
    {
        self SetMoveSpeedScale(boostScale);
        wait updateIntervalSeconds;
    }
    self SetMoveSpeedScale(1);
    wait cooldownSeconds;
    self.mapBoostOwned = undefined;
}

cancel()
{
    if(!isDefined(self.mapBoostOwned))
    {
        return;
    }
    // Stop the owner AND its cooldown before clearing state, so a stale thread
    // can never restore its boost or clear a later attempt's ownership.
    self notify("opencj_map_boost_cancelled");
    self SetMoveSpeedScale(1);
    self.mapBoostOwned = undefined;
}
