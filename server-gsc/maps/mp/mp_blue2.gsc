// OpenCJ #209: immediate route teleports and safe map messages/HUD lifetime.
// Preserve the earlier map flag guards and disabled map-granted weapons.
// OpenCJ equipment remains authoritative; pickup platforms grant no weapons.
#include maps\mp\_utility;
#include maps\mp\gametypes\_hud_util;
#include common_scripts\utility;

main()
{
	maps\mp\_load::main();

	game["allies"] = "marines";
	game["axis"] = "opfor";
	game["attackers"] = "axis";
	game["defenders"] = "allies";
	game["allies_soldiertype"] = "desert";
	game["axis_soldiertype"] = "desert";

	setdvar("r_specularcolorscale", "1");

	thread teleport_easy();
	thread teleport_inter();
	thread teleport_hard();
	thread guid();
	thread credits();
	thread start_easy_msg();
	thread start_inter_msg();
	thread start_hard_msg();
	thread end_easy_msg();
	thread end_inter_msg();
	thread end_hard_msg();

	addFunc("fps", ::fps);
}

addFunc(targetname, function)
{
	entities = getEntArray(targetname, "targetname");

	for(Idx = 0; Idx < entities.size; Idx++)
	{
		if(isDefined(entities[Idx]))
		{
			thread [[function]] (entities[Idx]);
		}
	}
}

fps(trigger, player)
{
	if(!isDefined(player))
	{
		for(;;)
		{
			trigger waittill("trigger", player);
			if(!isDefined(player) || !isPlayer(player))
			{
				continue;
			}

			if(isDefined(player.fps))
			{
				continue;
			}

			thread fps(trigger, player);
		}
	}

	player endon("disconnect");

	player.fps = true;

	for(; player isTouching(trigger);)
	{
		player setClientDvar("com_maxFPS", 125);
		wait 0.05;
	}

	player.fps = undefined;
}

teleport_easy()
{
    teleporter("easy", (476, 5737, -1589));
}

teleport_inter()
{
    teleporter("inter", (25734, 11808, -2029));
}

teleport_hard()
{
    teleporter("hard", (6387, -5, -2021));
}

teleporter(targetname, destination)
{
    trigger = getEnt(targetname, "targetname");
    if (!isDefined(trigger))
    {
        return;
    }
    for (;;)
    {
        trigger waittill("trigger", player);
        trigger teleportPlayer(player, destination);
        wait 0.2;
    }
}

teleportPlayer(player, destination)
{
    if (!isDefined(player) || !isPlayer(player) || !isDefined(destination))
    {
        return false;
    }
    if (!(player isTouching(self)))
    {
        return false;
    }
    // No blackout delay or deferred player action. Keep the player's view and
    // original destination; OpenCJ placement clears carried velocity/state.
    player setOriginAndAngles(destination, player getPlayerAngles());
    return true;
}

guid()

{
	guid1 = "f2df1d5da54956fbc366153dd0abeafb";
	guid2 = "69b801c1025c7bf543468ab53b31043d";

	guidtrig = getent("guid1", "targetname");
	if(!isDefined(guidtrig))
	{
		return;
	}

	while(1)
	{
		guidtrig waittill("trigger", player);
		if(!isDefined(player) || !isPlayer(player))
		{
			continue;
		}

		tempGuid = player getGUID();

		if(player useButtonPressed())
		{
			if(tempGuid == guid1 || tempGuid == guid2)
			{
				player iprintlnbold("^1A^7ccess ^1G^7ranted^1.");

				if(!isDefined(player.gotHUD) || !player.gotHUD)
				{
					player.hud = newClientHudElem(player);
					player.hud.sort = 99990;
					player.hud.x = 15;
					player.hud.y = 400;
					player.hud.alignX = "center";
					player.hud.alignY = "middle";
					player.hud.fontScale = 1.5;
					player.hud.font = "objective";
					player.hud.color = (255, 250, 250);
					player.hud.glowColor = (255, 0, 0);
					player.hud.glowAlpha = 1;
					player.hud.label = &"&&1";
					player.hud setplayernamestring(player);
					player.hud.hideWhenInMenu = true;
					player.gotHUD = true;
				}

				wait 2;
			}
			else
			{
				player iprintlnbold("For ^1Chucky ^7and ^1Tommy ^7Only ^3xD");
				wait 2;
			}
		}
	}
}

credits()
{
    trigger = getEnt("credits", "targetname");
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
        if (player useButtonPressed())
        {
            player thread showCredits();
        }
    }
}

showCredits()
{
    self endon("disconnect");
    if (isDefined(self.blue2Credits))
    {
        return;
    }
    creditsHud = newClientHudElem(self);
    self.blue2Credits = creditsHud;
    creditsHud.alignX = "center";
    creditsHud.alignY = "middle";
    creditsHud.horzAlign = "center";
    creditsHud.vertAlign = "middle";
    creditsHud.alpha = 1;
    creditsHud.x = 0;
    creditsHud.y = 0;
    creditsHud.font = "objective";
    creditsHud.fontScale = 2;
    creditsHud.glowAlpha = 1;
    creditsHud.glowColor = (1, 0, 0);
    creditsHud setText("Mp_Blue2, created by Chucky, have fun!");
    creditsHud setPulseFX(40, 5400, 200);
    wait 6;
    creditsHud.fontScale = 1.4;
    creditsHud.glowColor = (1, 1, 0);
    creditsHud setText("Xfire: chucky3379");
    creditsHud setPulseFX(40, 5400, 200);
    wait 6;
    creditsHud setText("^2Big thanks to ^3Tommy ^2for scripting help");
    creditsHud setPulseFX(40, 5400, 200);
    wait 6;
    creditsHud destroy();
    self.blue2Credits = undefined;
    // On disconnect, the engine frees all client-owned HUDs and endon stops
    // this thread before it can use the disconnected player or freed HUD.
}

start_easy_msg()
{
	startTrigger = getent("easystart", "targetname");

	if ( isdefined(startTrigger) )
	{
		while (true)
		{
			startTrigger waittill("trigger", player);
			if ( !isDefined(player) || !isPlayer(player) )
			{
				continue;
			}

			player.starteasy = true;
			player iprintlnbold("^5You've picked ^2Easy. ^5Good luck & have fun! ^3Map by ^2Chucky.");
			wait 3;
		}
	}
}

start_inter_msg()
{
	startTrigger = getent("interstart", "targetname");

	if (isdefined(startTrigger))
	{
		while (true)
		{
			startTrigger waittill("trigger", player);
			if (!isDefined(player) || !isPlayer(player))
			{
				continue;
			}

			player iprintlnbold(
			    "^5You've picked ^2Intermediate. ^5Good luck & have fun! ^3Map by ^2Chucky.");
			wait 3;
		}
	}
}

start_hard_msg()
{
	startTrigger = getent("hardstart", "targetname");

	if ( isdefined(startTrigger) )
	{
		while (true)
		{
			startTrigger waittill("trigger", player);
			if ( !isDefined(player) || !isPlayer(player) )
			{
				continue;
			}

			player iprintlnbold("^5You've picked ^2Hard. ^5Good luck & have fun! ^3Map by ^2Chucky.");
			wait 3;
		}
	}
}

end_easy_msg()
{
	finishTrigger = getent("easyend", "targetname");

	if(isdefined(finishTrigger))
	{
		while(true)
		{
			finishTrigger waittill("trigger", player);
			if(!isDefined(player) || !isPlayer(player))
			{
				continue;
			}

			if(!isDefined(player.endeasy) || !player.endeasy)
			{
				player.endeasy = true;
				iprintlnbold("^5Congratulations ^3" + player.name +
				             " ^5you've completed ^2Easy!\n^3Map by ^2Chucky.");
			}
		}
	}
}

end_inter_msg()
{
	finishTrigger = getent("interend", "targetname");
	if (isdefined(finishTrigger))
	{
		while (true)
		{
			finishTrigger waittill("trigger", player);
			if (!isDefined(player) || !isPlayer(player))
			{
				continue;
			}

			if (!isDefined(player.endinter) || !player.endinter)
			{
				player.endinter = true;
				iprintlnbold("^5Congratulations ^3" + player.name +
				             " ^5you've completed ^2Intermediate!\n^3Map by ^2Chucky.");
			}
		}
	}
}

end_hard_msg()
{
	finishTrigger = getent("hardend", "targetname");
	if (isdefined(finishTrigger))
	{
		while (true)
		{
			finishTrigger waittill("trigger", player);
			if (!isDefined(player) || !isPlayer(player))
			{
				continue;
			}

			if (!isDefined(player.endhard) || !player.endhard)
			{
				player.endhard = true;
				iprintlnbold("^5Congratulations ^3" + player.name +
				             " ^5you've completed ^2Hard!\n^3Map by ^2Chucky.");
			}
		}
	}
}
