// OpenCJ: preserve route and secret mechanics; fix legacy mod dependency and trigger safety.
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

    level.moonMessageCooldownActive = false;
    level.moonMessageCooldownSeconds = 2;
    thread showAdvancedFinish();
    thread showBasicFinish();
    thread showAuthorMessage();
    thread showPlayerPraise();
    thread showSecretBounceMessage();

    thread startResetTriggers();
    thread startBoostTrigger("svt_accelerate_1");
    thread startBoostTrigger("svt_accelerate_2");
    thread startBoostTrigger("svt_accelerate_3");
    thread showIntermediateFinish();
}

showAdvancedFinish()
{
    trigger = getent("end", "targetname");
    if (!isDefined(trigger))
    {
        return;
    }

    while (1)
    {
        trigger waittill("trigger", player);
        if (!isDefined(player) || !isPlayer(player) || !isAlive(player))
        {
            continue;
        }
        if (isdefined(player.moonDoneAdvanced))
        {
            wait 0.5;
        }
        else
        {
            iprintlnbold("Congratulations, " + player.name +
                         ", you have completed mp_to_the_moon ^5Advanced!!");
            player iprintlnbold("Map created by ^1=.VaRtaZiaN.=");
            player.moonDoneAdvanced = true;
        }
    }
}

showAuthorMessage()
{
    authorTrigger = getent("message2", "targetname");
    if ( isdefined(authorTrigger) )
    {
        while (true)
        {
            authorTrigger waittill("trigger", player);
            if ( isDefined(player) && isPlayer(player) && isAlive(player) && !level.moonMessageCooldownActive )
            {
                level.moonMessageCooldownActive = true;
                iprintlnbold("^4 Map by: ^1=.VaRtaZiaN.=");
                wait level.moonMessageCooldownSeconds;
                level.moonMessageCooldownActive = false;
            }
        }
    }
}

showPlayerPraise()
{
    praiseTrigger = getent("message3", "targetname");
    if ( isdefined(praiseTrigger) )
    {
        while (true)
        {
            praiseTrigger waittill("trigger", player);
            if ( isDefined(player) && isPlayer(player) && isAlive(player) && !level.moonMessageCooldownActive )
            {
                level.moonMessageCooldownActive = true;
                iprintlnbold("" + player.name + " ^7is ^3better than you");
                wait level.moonMessageCooldownSeconds;
                level.moonMessageCooldownActive = false;
            }
        }
    }
}

showSecretBounceMessage()
{
    secretBounceTrigger = getent("message4", "targetname");
    if ( isdefined(secretBounceTrigger) )
    {
        while (true)
        {
            secretBounceTrigger waittill("trigger", player);
            if ( isDefined(player) && isPlayer(player) && isAlive(player) && !level.moonMessageCooldownActive )
            {
                level.moonMessageCooldownActive = true;
                iprintlnbold("^1Another secret bounce?  ^3U Jelly Brah!!");
                wait level.moonMessageCooldownSeconds;
                level.moonMessageCooldownActive = false;
            }
        }
    }
}

showBasicFinish()
{
    trigger = getent("end1", "targetname");
    if (!isDefined(trigger))
    {
        return;
    }

    while (1)
    {
        trigger waittill("trigger", player);
        if (!isDefined(player) || !isPlayer(player) || !isAlive(player))
        {
            continue;
        }
        if (isdefined(player.moonDoneBasic))
        {
            wait 0.5;
        }
        else
        {
            player iprintlnbold(
                "Congratulations, " + player.name +
                ", you have completed Basic way of mp_to_the_moon!! Now go try Intermediate ;)");
            player iprintlnbold("Map created by ^1=.VaRtaZiaN.=");
            player.moonDoneBasic = true;
        }
    }
}

startResetTriggers()
{
    resetTriggers = getentarray("reset", "targetname");
    if(isdefined(resetTriggers))
    {
        for(i = 0; i < resetTriggers.size; i++)
        {
            resetTriggers[i] thread resetPlayerOnTouch();
        }
    }
}

// Handle this contact before yielding so a later player action cannot be undone.
resetPlayerOnTouch()
{
    // Keep the old combined cooldown, with no deferred action against the player.
    repeatDelaySeconds = 0.2;
    while (true)
    {
        self waittill("trigger", player);
        if (isDefined(player) && isPlayer(player) && isAlive(player))
        {
            player openCJ\events\eventHandler::onLoadPositionRequest(0);
        }
        wait repeatDelaySeconds;
    }
}

startBoostTrigger(triggerName)
{
    trigger = getent(triggerName, "targetname");
    if (!isDefined(trigger))
    {
        return;
    }
    for (;;)
    {
        trigger waittill("trigger", player);
        if (isDefined(player) && isPlayer(player) && isAlive(player))
        {
            player thread moonBoost();
        }
    }
}

showIntermediateFinish()
{
    trigger = getent("end2", "targetname");
    if (!isDefined(trigger))
    {
        return;
    }

    while (1)
    {
        trigger waittill("trigger", player);
        if (!isDefined(player) || !isPlayer(player) || !isAlive(player))
        {
            continue;
        }
        if (isdefined(player.moonDoneIntermediate))
        {
            wait 0.5;
        }
        else
        {
            player iprintlnbold(
                "Congratulations, " + player.name +
                ", you have completed Intermediate way of mp_to_the_moon!! Now go try Hard way ;)");
            player iprintlnbold("Map created by ^1=.VaRtaZiaN.=");
            player.moonDoneIntermediate = true;
        }
    }
}

// Preserve the original boost physics; OpenCJ owns lifecycle cancellation.
moonBoost()
{
    boostDurationSeconds = 12;
    self openCJ\mapBoost::start(boostDurationSeconds);
}
