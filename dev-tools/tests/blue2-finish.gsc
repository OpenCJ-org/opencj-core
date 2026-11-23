main()
{
    level.blue2Checks = 0;
    level.blue2Failures = 0;
    wait 0.2;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "isolated finish client connected");
    if(!isDefined(player))
    {
        finish();
        return;
    }

    checkFinishFlags(player);
    checkInertWeaponPickups();
    finish();
}

// Exercise the map's installed trigger handlers with invalid, first and repeated actors.
checkFinishFlags(player)
{
    nonPlayer = spawn("script_origin", (0, 0, 0));
    triggerNames = strTok("easyend interend hardend", " ");
    for(i = 0; i < triggerNames.size; i++)
    {
        trigger = getEnt(triggerNames[i], "targetname");
        check(isDefined(trigger), "finish trigger exists: " + triggerNames[i]);
        if(!isDefined(trigger))
        {
            continue;
        }
        trigger notify("trigger", nonPlayer);
        wait .05;
        check(!isDefined(readFinishFlag(nonPlayer, triggerNames[i])),
              "non-player cannot receive finish flag: " + triggerNames[i]);
        trigger notify("trigger", player);
        wait .05;
        check(isDefined(readFinishFlag(player, triggerNames[i])) && readFinishFlag(player, triggerNames[i]),
              "first player trigger sets finish flag: " + triggerNames[i]);
        trigger notify("trigger", player);
        wait .05;
        check(isDefined(readFinishFlag(player, triggerNames[i])) && readFinishFlag(player, triggerNames[i]),
              "repeated trigger retains finish flag: " + triggerNames[i]);
    }
    nonPlayer delete();
}

// Residual weapon-grant handlers would fault on this non-player actor.
checkInertWeaponPickups()
{
    nonPlayer = spawn("script_origin", (0, 0, 0));
    pickupNames = strTok(
        "ak_1 ak_2 ak_3 ak_4 deagle_2 deagle_3 r700_1 r700_2 m40a3_1 m40a3_2 usp_1 usp_2 usp_3", " ");
    for(i = 0; i < pickupNames.size; i++)
    {
        trigger = getEnt(pickupNames[i], "targetname");
        check(isDefined(trigger), "pickup trigger exists: " + pickupNames[i]);
        if(!isDefined(trigger))
        {
            continue;
        }
        trigger notify("trigger", nonPlayer);
        wait .05;
        trigger notify("trigger", nonPlayer);
        wait .05;
    }
    nonPlayer delete();
}

check(passed, message)
{
    level.blue2Checks++;
    if(!passed)
    {
        level.blue2Failures++;
    }
    printf("BLUE2 TEST " + passed + ": " + message + "\n");
}

finish()
{
    printf("BLUE2 TEST COMPLETE failures=" + level.blue2Failures +
           " checks=" + level.blue2Checks + "\n");
}

// GSC entity fields cannot be indexed dynamically.
readFinishFlag(actor, triggerName)
{
    if(triggerName == "easyend")
    {
        return actor.endeasy;
    }
    if(triggerName == "interend")
    {
        return actor.endinter;
    }
    return actor.endhard;
}
