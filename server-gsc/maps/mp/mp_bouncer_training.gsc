// mp_bouncer_training alpha cleanup (#209). Map by pMod.MiKeY-B0Y.
// Preserve all teleport destinations, the finish ride, hints and map geometry.
main()
{
    maps\mp\_load::main();
    maps\mp\_compass::setupMiniMap("compass_map_mp_bouncer_training");

    game["allies"] = "sas";
    game["axis"] = "opfor";
    game["attackers"] = "axis";
    game["defenders"] = "allies";
    game["allies_soldiertype"] = "woodland";
    game["axis_soldiertype"] = "woodland";

    setDvar("r_specularcolorscale", "1");
    setDvar("r_glowbloomintensity0", ".25");
    setDvar("r_glowbloomintensity1", ".25");
    setDvar("r_glowskybleedintensity0", ".3");
    setDvar("compassmaxrange", "2000");
    // Ambient audio is controlled by OpenCJ's shared map cleanup.

    triggers = getEntArray("teleport", "targetname");
    for (i = 0; i < triggers.size; i++)
    {
        triggers[i] thread transporter();
    }
    thread jumper();
}

transporter()
{
    for (;;)
    {
        self waittill("trigger", player);
        teleportPlayer(player);
        wait 0.2;
    }
}

teleportPlayer(player)
{
    if (!isDefined(player) || !isPlayer(player))
    {
        return false;
    }
    if (!isDefined(self.target))
    {
        return false;
    }
    destination = getEnt(self.target, "targetname");
    if (!isDefined(destination) || !(player isTouching(self)))
    {
        return false;
    }
    // No pre-teleport delay: a subsequent load cannot be undone by this trigger.
    // OpenCJ placement also clears velocity/jump/sprint state and old links.
    player setOriginAndAngles(destination.origin, destination.angles);
    return true;
}

// Resolve the fixed finish-ride path before accepting players.
jumper()
{
    trigger = getEnt("jump", "targetname");
    if (!isDefined(trigger))
    {
        return;
    }
    // The shipped finish ride follows the four air1 through air4 entities.
    waypointCount = 4;
    rideWaypoints = [];
    for (i = 1; i <= waypointCount; i++)
    {
        waypointEntity = getEnt("air" + i, "targetname");
        if (!isDefined(waypointEntity))
        {
            return;
        }
        rideWaypoints[rideWaypoints.size] = waypointEntity.origin;
    }

    glow = getEnt("glow", "targetname");
    if (isDefined(glow))
    {
        level._effect["beacon_glow"] = loadFx("misc/ui_pickup_available");
        maps\mp\_fx::loopFx("beacon_glow", glow.origin, 3, glow.origin + (0, 0, 90));
    }

    for (;;)
    {
        trigger waittill("trigger", player);
        trigger ride(player, rideWaypoints);
        wait 1;
    }
}

// Follow the original ride path; the mover owns its cleanup after a player leaves.
ride(player, rideWaypoints)
{
    if (!isDefined(player) || !isPlayer(player) || !(player isTouching(self)))
    {
        return;
    }
    expectedWaypointCount = 4;
    if (!isDefined(rideWaypoints) || rideWaypoints.size != expectedWaypointCount)
    {
        return;
    }

    // Clear carried speed, then keep the original path and travel timings.
    player setOriginAndAngles(player.origin, player.angles);
    mover = spawn("script_model", player.origin);
    mover.angles = player.angles;
    player linkTo(mover);
    legDurationSeconds = 1;
    cornerTransitionSeconds = 0.5;
    finalTransformSettleSeconds = 0.05;
    mover moveTo(rideWaypoints[0], legDurationSeconds);
    wait legDurationSeconds;
    mover moveTo(rideWaypoints[1], legDurationSeconds);
    wait cornerTransitionSeconds;
    mover moveTo(rideWaypoints[2], legDurationSeconds);
    wait cornerTransitionSeconds;
    mover moveTo(rideWaypoints[3], legDurationSeconds);
    mover waittill("movedone");
    // Give the linked player one server frame to receive the final transform.
    wait finalTransformSettleSeconds;

    // Deleting the mover detaches only its remaining children. Native position
    // loads already unlink the player. Never touch the old player after a wait:
    // they may have loaded, respawned, disconnected or linked to another mover.
    mover delete();
}
