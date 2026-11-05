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

	setdvar( "r_specularcolorscale", "1" );

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
	entArray = getEntArray(targetname, "targetname");

	for(Idx = 0;Idx < entArray.size;Idx++)
	{
		if(isDefined(entArray[Idx]))
			thread [[function]](entArray[Idx]);
	}
}

fps(trigger, user)
{
	if(!isDefined(user))
	{
		for(;;)
		{
			trigger waittill("trigger", user);
			if (!isDefined(user) || !isPlayer(user)) continue;

			if(isDefined(user.fps))
				continue;

			thread fps(trigger, user);
		}
	}

	user endon("disconnect");

	user.fps = true;

	for(;user isTouching(trigger);)
	{
		user setClientDvar("com_maxFPS", 125);
		wait 0.05;
	}

	user.fps = undefined;
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
    if (!isDefined(trigger)) return;
    for (;;)
    {
        trigger waittill("trigger", player);
        trigger teleportPlayer(player, destination);
        wait 0.2;
    }
}

teleportPlayer(player, destination)
{
    if (!isDefined(player) || !isPlayer(player) || !isDefined(destination)) return false;
    if (!(player isTouching(self))) return false;
    // No blackout delay or deferred player action. Keep the player's view and
    // original destination; OpenCJ placement clears carried velocity/state.
    player setOriginAndAngles(destination, player getPlayerAngles());
    return true;
}

guid()

{
	guid1 = "f2df1d5da54956fbc366153dd0abeafb";
	guid2 = "69b801c1025c7bf543468ab53b31043d";

	guidtrig = getent("guid1","targetname");
	if (!isDefined(guidtrig)) return;

	while(1)
	{
		guidtrig waittill("trigger", player );
		if (!isDefined(player) || !isPlayer(player)) continue;

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
				player iprintlnbold ("For ^1Chucky ^7and ^1Tommy ^7Only ^3xD");
				wait 2;
			}
		}
	}
}

credits()
{
    trigger = getEnt("credits", "targetname");
    if (!isDefined(trigger)) return;
    for (;;)
    {
        trigger waittill("trigger", player);
        if (!isDefined(player) || !isPlayer(player)) continue;
        if (player useButtonPressed())
            player thread showCredits();
    }
}

showCredits()
{
    self endon("disconnect");
    if (isDefined(self.blue2Credits)) return;
    hud = newClientHudElem(self);
    self.blue2Credits = hud;
    hud.alignX = "center";
    hud.alignY = "middle";
    hud.horzAlign = "center";
    hud.vertAlign = "middle";
    hud.alpha = 1;
    hud.x = 0;
    hud.y = 0;
    hud.font = "objective";
    hud.fontScale = 2;
    hud.glowAlpha = 1;
    hud.glowColor = (1,0,0);
    hud setText("Mp_Blue2, created by Chucky, have fun!");
    hud setPulseFX(40, 5400, 200);
    wait 6;
    hud.fontScale = 1.4;
    hud.glowColor = (1,1,0);
    hud setText("Xfire: chucky3379");
    hud setPulseFX(40, 5400, 200);
    wait 6;
    hud setText("^2Big thanks to ^3Tommy ^2for scripting help");
    hud setPulseFX(40, 5400, 200);
    wait 6;
    hud destroy();
    self.blue2Credits = undefined;
    // On disconnect, the engine frees all client-owned HUDs and endon stops
    // this thread before it can use the disconnected player or freed HUD.
}

start_easy_msg()
{
	start_easy_msg = getent("easystart","targetname");

	if ( isdefined(start_easy_msg) )
	{
		while(true)
		{
			start_easy_msg waittill ("trigger", user);
			if (!isDefined(user) || !isPlayer(user)) continue;

			user.starteasy = true;
			user iprintlnbold ("^5You've picked ^2Easy. ^5Good luck & have fun! ^3Map by ^2Chucky.");
			wait 3;
		}
	}
}

start_inter_msg()
{
	msg_inter = getent("interstart","targetname");

	if(isdefined(msg_inter))
	{
		while(true)
		{
			msg_inter waittill ("trigger", user);
			if (!isDefined(user) || !isPlayer(user)) continue;

			user iprintlnbold ("^5You've picked ^2Intermediate. ^5Good luck & have fun! ^3Map by ^2Chucky.");
			wait 3;
		}
	}
}

start_hard_msg()
{
	start_hard_msg = getent("hardstart","targetname");

	if ( isdefined(start_hard_msg) )
	{
		while(true)
		{
			start_hard_msg waittill ("trigger", user);
			if (!isDefined(user) || !isPlayer(user)) continue;

			user iprintlnbold ("^5You've picked ^2Hard. ^5Good luck & have fun! ^3Map by ^2Chucky.");
			wait 3;
		}
	}
}

end_easy_msg()
{
	end_easy_msg = getent("easyend","targetname");

	if(isdefined(end_easy_msg))
	{
		while(true)
		{
			end_easy_msg waittill ("trigger", user);
			if (!isDefined(user) || !isPlayer(user)) continue;

			if(!isDefined(user.endeasy) || !user.endeasy)
			{
				user.endeasy = true;
				iprintlnbold ("^5Congratulations ^3" + user.name + " ^5you've completed ^2Easy!\n^3Map by ^2Chucky.");
			}
		}
	}
}

end_inter_msg()
{
	end_inter_msg = getent("interend","targetname");
	if ( isdefined(end_inter_msg) )
	{
		while(true)
		{
			end_inter_msg waittill ("trigger", user);
			if (!isDefined(user) || !isPlayer(user)) continue;

			if(!isDefined(user.endinter) || !user.endinter)
			{
				user.endinter = true;
				iprintlnbold ("^5Congratulations ^3" + user.name + " ^5you've completed ^2Intermediate!\n^3Map by ^2Chucky.");
			}
		}
	}
}

end_hard_msg()
{
	end_hard_msg = getent("hardend","targetname");
	if ( isdefined(end_hard_msg) )
	{
		while(true)
		{
			end_hard_msg waittill ("trigger", user);
			if (!isDefined(user) || !isPlayer(user)) continue;

			if(!isDefined(user.endhard) || !user.endhard)
			{
				user.endhard = true;
				iprintlnbold ("^5Congratulations ^3" + user.name + " ^5you've completed ^2Hard!\n^3Map by ^2Chucky.");
			}
		}
	}
}
