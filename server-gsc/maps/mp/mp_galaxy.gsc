// mp_galaxy OpenCJ alpha cleanup (#209).
// Map: ZeeZ. Script help: Ridgepig, Fr33g !t, Amnesia.
// Original acknowledgements: 1804, Noobaim, Silver Surfer, eBc|Nicki,
// eBc|Ultimate, Skorpiik, Drizzjeh, BADenergy and everyone who helped.
// Credits remain here; creator broadcasts, weapon grants and GUID punishments
// are disabled. Lounge access/shortcuts are disabled; preserve geometry and Testway.

main()
{
    maps\mp\_load::main();
    setDvar("jump_slowdownenable", "0");
    setDvar("bg_fallDamageMaxHeight", 9999);
    setDvar("bg_fallDamageMinHeight", 9998);
    setDvar("player_recoilScaleOn", "0");
    rotator = getEnt("rotate", "targetname");
    rotator2 = getEnt("rotate2", "targetname");
    rotator3 = getEnt("rotate3", "targetname");
    if(isDefined(rotator))
    {
        rotator thread rotateModel(22);
    }
    if(isDefined(rotator2))
    {
        rotator2 thread rotateModel(10);
    }
    if(isDefined(rotator3))
    {
        rotator3 thread rotateModel(10);
    }
    thread onConnect();
    thread loungeMessage();
    thread genauMessage();
    thread puzzleMessage();
    thread surpriseMessage();
    thread surpriseMessage2();
    thread sickMessage();
    thread ggMessage();
    thread ambientMusic();
    thread musicToggle();
    thread teleports();
    thread weaponDisplays();
    thread finishMessage("easy_end", "Easy");
    thread finishMessage("inter_end", "Inter");
    thread finishMessage("interplus_end", "Inter+");
    thread finishMessage("hard_end", "Hard");
}

teleports()
{
    triggers = getEntArray("teleport", "targetname");
    if (isDefined(triggers))
    {
        for (i = 0; i < triggers.size; i = i + 1)
        {
            if (!(triggers[i] isLoungeTeleport()))
            {
                triggers[i] thread teleporter();
            }
        }
    }
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
    if (!isDefined(self.target) || isLoungeTeleport())
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
    player setOriginAndAngles(destination.origin, angles);
    return true;
}


isLoungeTeleport()
{
    if (!isDefined(self.target))
    {
        return false;
    }
    // Disable the private entrance and twelve practice shortcuts. Keep normal
    // route/finish portals and the exit from the old lounge usable.
    disabledTargets = strTok(
        "auto38 auto40 auto41 auto42 auto43 auto44 auto45 auto46 auto47 auto48 auto49 auto50 auto51",
        " ");
    for (i = 0; i < disabledTargets.size; i++)
    {
        if (self.target == disabledTargets[i])
        {
            return true;
        }
    }
    return false;
}

rotateModel(rotationSeconds)
{
    self.rotationSeconds = rotationSeconds;
    for(;;)
    {
        self rotateYaw(360, self.rotationSeconds);
        wait((self.rotationSeconds) - 0.1);
    }
}

weaponDisplays()
{
    deagle = spawn("script_model", (-4868, -1660, 1226));
    ak74u = spawn("script_model", (-4868, -1980, 1226));
    sniper = spawn("script_model", (-4868, -2300, 1226));
    usp = spawn("script_model", (912, 688, 1176));
    deagle setModel("weapon_desert_eagle_gold");
    ak74u setModel("weapon_ak74u");
    sniper setModel("weapon_remington700");
    usp setModel("weapon_usp");
    deagle thread rotateModel(6);
    ak74u thread rotateModel(6);
    sniper thread rotateModel(6);
    usp thread rotateModel(6);
}

finishMessage(targetname, routeName)
{
    trigger = getEnt(targetname, "targetname");
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
        if (!isDefined(player.galaxyFinishes))
        {
            player.galaxyFinishes = [];
        }
        if (isDefined(player.galaxyFinishes[routeName]))
        {
            continue;
        }
        player.galaxyFinishes[routeName] = true;
        player iPrintLnBold("Congratulations, you finished " + routeName + "!");
    }
}

onConnect()
{
    for(;;)
    {
        level waittill("connected", player);
        if(isDefined(player) && isPlayer(player))
        {
            player thread onSpawn();
        }
    }
}

onSpawn()
{
    self endon("disconnect");
    for (;;)
    {
        self waittill("spawned_player");
        if (!isDefined(self.galaxyTestwayStarted))
        {
            self.galaxyTestwayStarted = true;
            self thread testwayTimer();
        }
    }
}

// Run the map's optional Testway challenge separately from OpenCJ route records.
testwayTimer()
{
    self endon("disconnect");
    startTrigger = getEnt("test_start", "targetname");
    middleTrigger = getEnt("test_check", "targetname");
    finishTrigger = getEnt("test_end", "targetname");
    resetTrigger = getEnt("reset_test", "targetname");
    if (!isDefined(startTrigger) || !isDefined(middleTrigger) || !isDefined(finishTrigger) || !isDefined(resetTrigger))
    {
        return;
    }
    // This optional four-minute challenge is separate from the normal OpenCJ routes.
    timerActive = false;
    middleReached = false;
    challengeCompleted = false;
    touchingReset = false;
    elapsedSeconds = 0;
    for (;;)
    {
        if (self isTouching(resetTrigger))
        {
            timerActive = false;
            middleReached = false;
            challengeCompleted = false;
            elapsedSeconds = 0;
            if (!touchingReset)
            {
                self iPrintLn("Testway timer reset.");
            }
            touchingReset = true;
        }
        else
        {
            touchingReset = false;
            if (self isTouching(startTrigger))
            {
                timerActive = true;
                middleReached = false;
                elapsedSeconds = 0;
            }
            if (timerActive && self isTouching(middleTrigger))
            {
                middleReached = true;
            }
            if (timerActive && middleReached && !challengeCompleted && self isTouching(finishTrigger))
            {
                challengeCompleted = true;
                testwayFinish(elapsedSeconds);
            }
        }
        // Retain the original one-second timer and spectator pause.
        if (timerActive && self.sessionState != "spectator")
        {
            elapsedSeconds++;
            wait 1;
        }
        else
        {
            wait 0.05;
        }
    }
}

testwayFinish(elapsedSeconds)
{
    challengeLimitSeconds = 4 * 60;
    passed = elapsedSeconds <= challengeLimitSeconds;
    if (passed)
    {
        self PlaySoundToPlayer("testwin_sound", self);
        self iPrintLnBold("You've successfully passed the Testway!");
    }
    else
    {
        self PlaySoundToPlayer("testfail_sound", self);
        self iPrintLnBold("You've failed the Testway!");
    }
    self iPrintLn("Testway time: " + elapsedSeconds + " seconds.");
    return passed;
}

ambientMusic()
{
    AmbientPlay("bgmusic");
}

musicToggle()
{
    trigger = getEnt("musictrigger", "targetname");
    if (!isDefined(trigger))
    {
        return;
    }
    level.galaxyMusicEnabled = true;
    for (;;)
    {
        trigger waittill("trigger", player);
        if (!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        level.galaxyMusicEnabled = !level.galaxyMusicEnabled;
        if (level.galaxyMusicEnabled)
        {
            AmbientPlay("bgmusic");
            player iPrintLn("Music enabled.");
        }
        else
        {
            AmbientStop(1);
            player iPrintLn("Music disabled.");
        }
        wait 2;
    }
}

loungeMessage()
{
    trigger = getEnt("text10", "targetname");
    if(!isDefined(trigger))
    {
        return;
    }
    for(;;)
    {
        trigger waittill("trigger", player);
        if(!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if(!isDefined(player.galaxyLoungeMessageShown))
        {
            player.galaxyLoungeMessageShown = 1;
            player iprintlnbold("^6You just entered 1804's private lounge...");
        }
    }
}

genauMessage()
{
    trigger = getEnt("text13", "targetname");
    if(!isDefined(trigger))
    {
        return;
    }
    for(;;)
    {
        trigger waittill("trigger", player);
        if(!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if(!isDefined(player.galaxyGenauMessageShown))
        {
            player.galaxyGenauMessageShown = 1;
            player iprintlnbold("^5genau m8");
        }
    }
}

puzzleMessage()
{
    trigger = getEnt("text14", "targetname");
    if(!isDefined(trigger))
    {
        return;
    }
    for(;;)
    {
        trigger waittill("trigger", player);
        if(!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if(!isDefined(player.galaxyPuzzleMessageShown))
        {
            player.galaxyPuzzleMessageShown = 1;
            player iprintlnbold("How do you get it tho?");
        }
    }
}

surpriseMessage()
{
    trigger = getEnt("text16", "targetname");
    if(!isDefined(trigger))
    {
        return;
    }
    for(;;)
    {
        trigger waittill("trigger", player);
        if(!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if(!isDefined(player.galaxySurpriseMessageShown))
        {
            player.galaxySurpriseMessageShown = 1;
            player iprintlnbold("Ohh shit");
        }
    }
}

surpriseMessage2()
{
    trigger = getEnt("text17", "targetname");
    if(!isDefined(trigger))
    {
        return;
    }
    for(;;)
    {
        trigger waittill("trigger", player);
        if(!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if(!isDefined(player.galaxySurpriseMessage2Shown))
        {
            player.galaxySurpriseMessage2Shown = 1;
            player iprintlnbold("Ohhhhhhhh shiiiiiiiiit");
        }
    }
}

sickMessage()
{
    trigger = getEnt("text18", "targetname");
    if(!isDefined(trigger))
    {
        return;
    }
    for(;;)
    {
        trigger waittill("trigger", player);
        if(!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if(!isDefined(player.galaxySickMessageShown))
        {
            player.galaxySickMessageShown = 1;
            player iprintlnbold("sick cunt");
        }
    }
}

ggMessage()
{
    trigger = getEnt("text19", "targetname");
    if(!isDefined(trigger))
    {
        return;
    }
    for(;;)
    {
        trigger waittill("trigger", player);
        if(!isDefined(player) || !isPlayer(player))
        {
            continue;
        }
        if(!isDefined(player.galaxyGgMessageShown))
        {
            player.galaxyGgMessageShown = 1;
            player iprintlnbold("gg");
        }
    }
}
