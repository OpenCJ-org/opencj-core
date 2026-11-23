// mp_dark alpha cleanup (#209). Preserve the two normal routes and teleports;
// OpenCJ owns player equipment. Original map by kie; tested by paragon.
main()
{
    maps\mp\_load::main();
    game["allies"] = "marines";
    game["axis"] = "opfor";
    game["attackers"] = "axis";
    game["defenders"] = "allies";
    game["allies_soldiertype"] = "desert";
    game["axis_soldiertype"] = "desert";
    setDvar("r_specularcolorscale", "1");
    setDvar("r_glowbloomintensity0", ".25");
    setDvar("r_glowbloomintensity1", ".25");
    setDvar("r_glowskybleedintensity0", ".3");
    setDvar("compassmaxrange", "1800");

    removeWeaponReward();
    triggers = getEntArray("enter", "targetname");
    for (i = 0; i < triggers.size; i++)
    {
        triggers[i] thread transporter();
    }
}

removeWeaponReward()
{
    reward = getEnt("give_gravity_trig", "targetname");
    if (isDefined(reward))
    {
        reward delete();
    }
    // The separate gravity-gun prompt has no targetname in the shipped map.
    // Remove only that prompt; keep the map's route finish/credit hint.
    gravityPromptOrigin = (-4162, 12660, 87);
    promptMatchRadiusUnits = 1;
    hints = getEntArray("trigger_use_touch", "classname");
    for (i = 0; i < hints.size; i++)
    {
        if (distanceSquared(hints[i].origin, gravityPromptOrigin) <
            promptMatchRadiusUnits * promptMatchRadiusUnits)
        {
            hints[i] delete();
        }
    }
}

transporter()
{
    for (;;)
    {
        self waittill("trigger", player);
        // Resolve the trigger immediately: a delayed teleport could outlive a load.
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
    // The normal OpenCJ save/load placement clears velocity, jump and sprint state.
    player setOriginAndAngles(destination.origin, destination.angles);
    return true;
}
