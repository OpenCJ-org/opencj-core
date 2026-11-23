main()
{
    level.descentChecks = 0;
    level.descentFailures = 0;
    wait 0.2;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "isolated finish client connected");
    if(!isDefined(player))
    {
        finish();
        return;
    }
    checkFinishEligibility(player, "easyend");
    checkFinishEligibility(player, "hardend");
    finish();
}

// OpenCJ owns timing; the map's finish announcements require a playing client.
checkFinishEligibility(player, triggerName)
{
    trigger = getEnt(triggerName, "targetname");
    check(isDefined(trigger), "finish trigger exists: " + triggerName);
    if(!isDefined(trigger))
    {
        return;
    }
    nonPlayer = spawn("script_origin", (0, 0, 0));
    nonPlayer.sessionState = "playing";
    trigger notify("trigger", nonPlayer);
    wait .05;
    check(!isDefined(readFinishFlag(nonPlayer, triggerName)), "non-player cannot finish: " + triggerName);
    nonPlayer delete();

    player.sessionState = "spectator";
    trigger notify("trigger", player);
    wait .05;
    check(!isDefined(readFinishFlag(player, triggerName)), "spectator cannot finish: " + triggerName);

    player.sessionState = "playing";
    trigger notify("trigger", player);
    wait .05;
    check(isDefined(readFinishFlag(player, triggerName)) && readFinishFlag(player, triggerName),
          "first playing trigger sets finish flag: " + triggerName);
    trigger notify("trigger", player);
    wait .05;
    check(isDefined(readFinishFlag(player, triggerName)) && readFinishFlag(player, triggerName),
          "repeated trigger retains finish flag: " + triggerName);
}

check(passed, message)
{
    level.descentChecks++;
    if(!passed)
    {
        level.descentFailures++;
    }
    printf("DESCENT TEST " + passed + ": " + message + "\n");
}

finish()
{
    printf("DESCENT TEST COMPLETE failures=" + level.descentFailures +
           " checks=" + level.descentChecks + "\n");
}

// GSC entity fields cannot be indexed dynamically.
readFinishFlag(actor, triggerName)
{
    if(triggerName == "easyend")
    {
        return actor.easyEnd;
    }
    return actor.hardEnd;
}
