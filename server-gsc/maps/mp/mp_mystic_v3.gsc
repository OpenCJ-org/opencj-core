// mp_mystic_v3 alpha cleanup (#209): immediate, contact-checked teleports.
main()
{
	maps\mp\_load::main();
	triggers = getEntArray("enter", "targetname");
	for (i = 0; i < triggers.size; i++)
	{
		triggers[i] thread teleporter();
	}

	game["allies"] = "marines";
	game["axis"] = "opfor";
	game["attackers"] = "axis";
	game["defenders"] = "allies";
	game["allies_soldiertype"] = "desert";
	game["axis_soldiertype"] = "desert";

	setdvar("r_specularcolorscale", "1");
	setdvar("jump_slowdownEnable", "0");
	setdvar("bg_falldamagemaxheight", "9999");
	setdvar("bg_falldamageminheight", "9998");
	setdvar("r_glowbloomintensity0", ".25");
	setdvar("r_glowbloomintensity1", ".25");
	setdvar("r_glowskybleedintensity0", ".3");
	setdvar("compassmaxrange", "1800");
}

teleporter()
{
    for (;;)
    {
        self waittill("trigger", player);
        teleportPlayer(player);
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
    angles = (0, 0, 0);
    if (isDefined(destination.angles))
    {
        angles = destination.angles;
    }
    // Native placement clears carried velocity and jump/sprint state.
    player setOriginAndAngles(destination.origin, angles);
    return true;
}
