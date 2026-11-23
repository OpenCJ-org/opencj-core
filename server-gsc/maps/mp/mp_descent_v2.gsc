// OpenCJ #209: contact-checked teleports clear carried velocity; safe trigger actors.
// OpenCJ owns timing; retain plain finish messages, duplicate guards and credits.
/*                          __                          __          ___
   ____ ___  ____      ____/ /__  _____________  ____  / /_   _   _|__ \
  / __ `__ \/ __ \    / __  / _ \/ ___/ ___/ _ \/ __ \/ __/  | | / /_/ /
 / / / / / / /_/ /   / /_/ /  __(__  ) /__/  __/ / / / /_    | |/ / __/
/_/ /_/ /_/ .___/____\__,_/\___/____/\___/\___/_/ /_/\__/____|___/____/
         /_/   /_____/                                 /_____/
   _____           _       __          __         	 ______
  / ___/__________(_)___  / /______   / /_  __  __	/_  __/___  ____ ___  ____ ___  __  __
  \__ \/ ___/ ___/ / __ \/ __/ ___/  / __ \/ / / /	 / / / __ \/ __ `__ \/ __ `__ \/ / / /
 ___/ / /__/ /  / / /_/ / /_(__  )  / /_/ / /_/ / 	/ / / /_/ / / / / / / / / / / / /_/ /
/____/\___/_/  /_/ .___/\__/____/  /_.___/\__, /   / / / /_/ / / / / / / / / / / / /_/ /
                /_/                      /____/   /_/  \____/_/ /_/ /_/_/ /_/ /_/\__, /
																				/____/
									XFire: noheadman
				feel free to use any of this code, but please give credits
*/

main()
{
	maps\mp\_load::main();

	game["allies"] = "marines";
	game["axis"] = "opfor";
	game["attackers"] = "axis";
	game["defenders"] = "allies";
	game["allies_soldiertype"] = "desert";
	game["axis_soldiertype"] = "desert";

	setdvar("r_specularcolorscale", "9");

	setdvar("r_glowbloomintensity0", ".25");
	setdvar("r_glowbloomintensity1", ".25");
	setdvar("r_glowskybleedintensity0", ".3");
	setdvar("compassmaxrange", "1800");

	thread easyEnd();
	thread hardEnd();
	thread msg1();
	thread msg2();
	thread msg3();
	thread msg4();
	thread msg5();
	thread msg6();
	thread teleport_top();
	thread teleport_out();
	thread teleport_in();
	thread teleport_loop();
}

easyEnd()
{
    level endon("game_ended");
    trigger = getEnt("easyend", "targetname");
    if (!isDefined(trigger))
    {
        return;
    }
    for (;;)
    {
        trigger waittill("trigger", player);
        if (!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if (player.sessionState != "playing" || (isDefined(player.easyEnd) && player.easyEnd))
        {
            continue;
        }
        player iPrintLnBold("Congratulations, you finished ^5mp_descent_v2 ^2Easy!");
        player.easyEnd = true;
    }
}

hardEnd()
{
    level endon("game_ended");
    trigger = getEnt("hardend", "targetname");
    if (!isDefined(trigger))
    {
        return;
    }
    for (;;)
    {
        trigger waittill("trigger", player);
        if (!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if (player.sessionState != "playing" || (isDefined(player.hardEnd) && player.hardEnd))
        {
            continue;
        }
        iPrintLnBold("^5" + player.name + " ^7finished ^5mp_descent_v2 ^1Hard!");
        player.hardEnd = true;
    }
}

msg1()
{
	level endon("game_ended");

	trigger = getent("msg1", "targetname");
	if (!isDefined(trigger))
	{
		return;
	}

	while (1)
	{
		trigger waittill("trigger", player);
		if (!isDefined(player) || !isPlayer(player))
		{
			continue;
		}

		if (player.sessionstate != "playing")
		{
			wait 0.05;
		}
		else
		{
			iPrintLnBold(
			    "Thanks to ^3Paragon, Soap, Sycotic, ShadowLinkX, Furi, and Wez ^7for testing!"); //INSERT TEXT HERE
			wait 10;
		}
	}
}

msg2()
{
	level endon("game_ended");

	trigger = getent("msg2", "targetname");
	if (!isDefined(trigger))
	{
		return;
	}

	while (1)
	{
		trigger waittill("trigger", player);
		if (!isDefined(player) || !isPlayer(player))
		{
			continue;
		}

		if (player.sessionstate != "playing")
		{
			wait 0.05;
		}
		else
		{
			iPrintLnBold("^4Map by: ^1=.VaRtaZiaN.="); //INSERT TEXT HERE
			iPrintLnBold("^3XFire: ^1vartazian147");   //INSERT TEXT HERE
			wait 10;
		}
	}
}

msg3()
{
	level endon("game_ended");

	trigger = getent("msg3", "targetname");
	if (!isDefined(trigger))
	{
		return;
	}

	while (1)
	{
		trigger waittill("trigger", player);
		if (!isDefined(player) || !isPlayer(player))
		{
			continue;
		}

		if (player.sessionstate != "playing")
		{
			wait 0.05;
		}
		else
		{
			iPrintLnBold("Thanks to ^2Tommy ^7for most of  the scripting!"); //INSERT TEXT HERE
			wait 10;
		}
	}
}

msg4()
{
	level endon("game_ended");

	trigger = getent("msg4", "targetname");
	if (!isDefined(trigger))
	{
		return;
	}

	while (1)
	{
		trigger waittill("trigger", player);
		if (!isDefined(player) || !isPlayer(player))
		{
			continue;
		}

		if (player.sessionstate != "playing")
		{
			wait 0.05;
		}
		else
		{
			iPrintLnBold("" + player.name + " ^7is a ^5BOSS"); //INSERT TEXT HERE
			wait 10;
		}
	}
}

msg5()
{
	level endon("game_ended");

	trigger = getent("msg5", "targetname");
	if (!isDefined(trigger))
	{
		return;
	}

	while (1)
	{
		trigger waittill("trigger", player);
		if (!isDefined(player) || !isPlayer(player))
		{
			continue;
		}

		if (player.sessionstate != "playing")
		{
			wait 0.05;
		}
		else
		{
			iPrintLnBold("CoDRadiant ^8SUCKS ^7._."); //INSERT TEXT HERE
			wait 10;
		}
	}
}

msg6()
{
	level endon("game_ended");

	trigger = getent("msg6", "targetname");
	if (!isDefined(trigger))
	{
		return;
	}

	while (1)
	{
		trigger waittill("trigger", player);
		if (!isDefined(player) || !isPlayer(player))
		{
			continue;
		}

		if (player.sessionstate != "playing")
		{
			wait 0.05;
		}
		else
		{
			iPrintLnBold("Map took ^410.12 GB ^7to compile."); //INSERT TEXT HERE
			wait 10;
		}
	}
}
teleport_top()
{
    teleporter("tele1", (38208, 3072, 61200), (0, 270, 0));
}

teleport_out()
{
    teleporter("tele2", (-84741, 75431, 11343), (0, 270, 0));
}

teleport_in()
{
    teleporter("tele3", (407, 2581, 60889), (0, 270, 0));
}

teleport_loop()
{
    teleporter("tele4", (407, 2581, 148229), (0, 290, 0));
}

teleporter(targetname, destination, angles)
{
    level endon("game_ended");
    trigger = getEnt(targetname, "targetname");
    if (!isDefined(trigger))
    {
        return;
    }
    for (;;)
    {
        trigger waittill("trigger", player);
        trigger teleportPlayer(player, destination, angles);
        wait 0.2;
    }
}

teleportPlayer(player, destination, angles)
{
    if (!isDefined(player) || !isPlayer(player))
    {
        return false;
    }
    if (!isDefined(destination) || !isDefined(angles))
    {
        return false;
    }
    if (!(player isTouching(self)))
    {
        return false;
    }
    // Original destination/angle, applied immediately. Native placement also
    // clears velocity and movement state, without a deferred action after load.
    player setOriginAndAngles(destination, angles);
    return true;
}
