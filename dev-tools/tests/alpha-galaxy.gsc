// #209 Galaxy script regression checks; no checkpoint/landing simulations.
main()
{
    level.failures = 0;
    level.checks = 0;
    level.galaxyCaptured = [];
    wait 1;
    player = addTestClient();
    second = addTestClient();
    wait 0.2;
    check(isDefined(player) && isDefined(second), "two isolated test clients connected");
    if (!isDefined(player) || !isDefined(second)) { finish(); return; }
    spawnpoint = getEntArray("mp_dm_spawn", "classname")[0];
    player setupPlayer(spawnpoint);
    second setupPlayer(spawnpoint);
    triggers = getEntArray("teleport", "targetname");
    private = getEnt("guid_teleport", "targetname");
    check(triggers.size == 49 && isDefined(private), "all 50 original teleport triggers present");
    triggers[triggers.size] = private;
    placed = true;
    disabledCount = 0;
    disabledSafe = true;
    cleared = true;
    views = true;
    for (i = 0; i < triggers.size; i++)
    {
        trigger = triggers[i];
        destination = getEnt(trigger.target, "targetname");
        player setOriginAndAngles(trigger.origin, (0,0,0));
        if (trigger maps\mp\mp_galaxy::isLoungeTeleport())
        {
            disabledCount++;
            ok = trigger maps\mp\mp_galaxy::teleportPlayer(player);
            if (ok || distanceSquared(player.origin,trigger.origin) >= 1) disabledSafe = false;
            continue;
        }
        player setVelocity((800,200,100));
        ok = trigger maps\mp\mp_galaxy::teleportPlayer(player);
        if (!ok || distanceSquared(player.origin, destination.origin) >= 1)
        {
            placed = false;
            printf("ALPHA SELFTEST teleport failed: " + trigger.target + "\n");
        }
        if (length(player getVelocity()) >= 1) cleared = false;
        angles = (0,0,0);
        if (isDefined(destination.angles)) angles = destination.angles;
        expected = angles[1];
        if (expected > 180) expected -= 360;
        actual = player getPlayerAngles();
        delta = abs(actual[1] - expected);
        if (min(delta,abs(delta - 360)) > 0.1) views = false;
    }
    check(placed, "all 37 enabled destinations retained");
    check(disabledCount == 13 && disabledSafe, "lounge entrance and 12 shortcuts cannot teleport");
    check(cleared, "all teleports clear carried velocity");
    check(views, "original destination angles retained");
    trigger = triggers[0];
    fake = spawn("script_origin", spawnpoint.origin);
    check(!(trigger maps\mp\mp_galaxy::teleportPlayer(undefined)), "undefined actor ignored");
    check(!(trigger maps\mp\mp_galaxy::teleportPlayer(fake)), "non-player actor ignored");
    player setOriginAndAngles(trigger.origin, (0,0,0));
    originalTarget = trigger.target;
    trigger.target = undefined;
    check(!(trigger maps\mp\mp_galaxy::teleportPlayer(player)), "missing target ignored");
    trigger.target = "alpha_galaxy_missing";
    check(!(trigger maps\mp\mp_galaxy::teleportPlayer(player)), "missing destination ignored");
    trigger.target = originalTarget;
    player setOriginAndAngles(spawnpoint.origin, spawnpoint.angles);
    check(!(trigger maps\mp\mp_galaxy::teleportPlayer(player)), "stale trigger after load rejected");

    destination = getEnt(trigger.target, "targetname");
    player setOriginAndAngles(trigger.origin, (0,0,0));
    second setOriginAndAngles(trigger.origin, (0,0,0));
    trigger notify("trigger", player);
    trigger notify("trigger", second);
    wait 0.05;
    check(distanceSquared(player.origin,destination.origin)<100 &&
          distanceSquared(second.origin,destination.origin)<100, "listener teleports two players immediately");
    player setOriginAndAngles(spawnpoint.origin, spawnpoint.angles);
    wait 0.4;
    check(distanceSquared(player.origin,spawnpoint.origin)<400, "no queued teleport after load away");

    level.galaxyCaptured = [];
    credits = strTok("text1 text2 text3 text4 text5 text6 text7 text8 text9 text11 text12 text15", " ");
    for (i = 0; i < credits.size; i++)
        getEnt(credits[i],"targetname") notify("trigger",player);
    wait 0.05;
    check(level.galaxyCaptured.size == 0, "creator and credit triggers are silent");

    names = strTok("easy_end inter_end interplus_end hard_end", " ");
    player.playerRuns_runID = 209;
    player.runInstanceNumber = 7;
    player.playerRuns_runFinished = false;
    for (i = 0; i < names.size; i++)
        getEnt(names[i],"targetname") notify("trigger",fake);
    wait 0.05;
    for (i = 0; i < names.size; i++)
        getEnt(names[i],"targetname") notify("trigger",player);
    wait 0.05;
    check(level.galaxyCaptured.size == 4, "four plain finish messages without legacy timers");
    for (i = 0; i < names.size; i++)
        getEnt(names[i],"targetname") notify("trigger",player);
    wait 0.05;
    check(level.galaxyCaptured.size == 4, "finish messages limited to once per route");
    check(player.playerRuns_runID == 209 && player.runInstanceNumber == 7 &&
          !player.playerRuns_runFinished, "map messages leave OpenCJ runs untouched");

    level.galaxyCaptured = [];
    getEnt("veri","targetname") notify("trigger",player);
    wait 0.05;
    check(!isDefined(player.JQ5rZ3ql) && level.galaxyCaptured.size == 0, "legacy verifier no longer punishes or broadcasts");
    for (i = 1; i <= 4; i++) getEnt("give"+i,"targetname") notify("trigger",player);
    wait 0.1;
    check(!(player hasWeapon("deserteaglegold_mp")) && !(player hasWeapon("ak74u_mp")) &&
          !(player hasWeapon("remington700_mp")) && !(player hasWeapon("usp_mp")), "map weapon grants disabled");

    // Disabled portal triggers remain as map geometry, with no active listener.
    disabledListenerSafe = true;
    for (i = 0; i < triggers.size; i++)
    {
        portal = triggers[i];
        if (!(portal maps\mp\mp_galaxy::isLoungeTeleport())) continue;
        player setOriginAndAngles(portal.origin,(0,0,0));
        portal notify("trigger",player);
        wait 0.05;
        if (distanceSquared(player.origin,portal.origin)>=100) disabledListenerSafe = false;
    }
    check(disabledListenerSafe, "all disabled lounge portal listeners are inactive");
    check(!isDefined(level.galaxyLoungeGuids), "hard-coded lounge access list removed");
    player setOriginAndAngles(spawnpoint.origin,spawnpoint.angles);

    check(player maps\mp\mp_galaxy::testwayFinish(240), "Testway four-minute boundary passes");
    check(!(player maps\mp\mp_galaxy::testwayFinish(241)), "Testway over-four-minute result fails");
    // Start the real optional trigger timer; no published checkpoint traversal.
    player thread maps\mp\mp_galaxy::testwayTimer();
    level.galaxyCaptured = [];
    player setOriginAndAngles(getEnt("test_start","targetname").origin,(0,0,0));
    wait 0.1;
    player setOriginAndAngles(getEnt("test_check","targetname").origin,(0,0,0));
    wait 1.1;
    player setOriginAndAngles(getEnt("test_end","targetname").origin,(0,0,0));
    wait 1.1;
    check(hasMessage("successfully passed"), "optional Testway start/check/finish flow retained");
    level.galaxyCaptured = [];
    player setOriginAndAngles(getEnt("reset_test","targetname").origin,(0,0,0));
    wait 1.1;
    check(hasMessage("timer reset"), "optional Testway reset retained");
    check(getEntArray("script_brushmodel","classname").size == 3, "all rotating brush models preserved");
    check(getEntArray("script_model","classname").size == 4, "all original weapon display models preserved");
    check(getEntArray("trigger_multiple","classname").size == 91, "all original triggers preserved");
    check(getEntArray("mp_dm_spawn","classname").size == 10, "all original spawn points preserved");
    fake delete();
    kick(player getEntityNumber());
    kick(second getEntityNumber());
    wait 0.1;
    finish();
}

setupPlayer(spawnpoint)
{
    self.sessionTeam = "allies";
    self.sessionState = "playing";
    self.pers["team"] = "allies";
    self spawn(spawnpoint.origin,spawnpoint.angles);
    self.maxHealth = 100;
    self.health = 100;
}

captureMessage(message)
{
    if (!isDefined(level.galaxyCaptured)) level.galaxyCaptured = [];
    level.galaxyCaptured[level.galaxyCaptured.size] = message;
}

hasMessage(fragment)
{
    for (i = 0; i < level.galaxyCaptured.size; i++)
        if (isSubStr(level.galaxyCaptured[i],fragment)) return true;
    return false;
}

check(passed,label)
{
    level.checks++;
    if (!passed) level.failures++;
    printf("ALPHA SELFTEST " + label + ": " + passed + "\n");
}

finish()
{
    printf("ALPHA SELFTEST COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}
