// #209 script checks only: no checkpoint traversal or landing simulation.
main()
{
    level.failures = 0;
    level.checks = 0;
    wait 1;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "test client connected");
    if (!isDefined(player)) { finish(); return; }
    spawnpoint = getEntArray("mp_dm_spawn", "classname")[0];
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn(spawnpoint.origin, spawnpoint.angles);
    player.maxHealth = 100;
    player.health = 100;

    names = strTok("tele1 tele2 tele3 tele4", " ");
    destinations = [];
    destinations[0] = (38208,3072,61200);
    destinations[1] = (-84741,75431,11343);
    destinations[2] = (407,2581,60889);
    destinations[3] = (407,2581,148229);
    angles = [];
    angles[0] = (0,270,0);
    angles[1] = (0,270,0);
    angles[2] = (0,270,0);
    angles[3] = (0,290,0);
    placed = true;
    cleared = true;
    views = true;
    for (i = 0; i < names.size; i++)
    {
        trigger = getEnt(names[i], "targetname");
        player setOriginAndAngles(trigger.origin, (0,0,0));
        player setVelocity((800,200,100));
        ok = trigger maps\mp\mp_descent_v2::teleportPlayer(player, destinations[i], angles[i]);
        if (!ok || distanceSquared(player.origin, destinations[i]) >= 1) placed = false;
        if (length(player getVelocity()) >= 1) cleared = false;
        expectedYaw = angles[i][1];
        if (expectedYaw > 180) expectedYaw -= 360;
        view = player getPlayerAngles();
        delta = abs(view[1] - expectedYaw);
        if (min(delta, abs(delta - 360)) > 0.1) views = false;
    }
    check(placed, "all four original destinations retained including high loop");
    check(cleared, "all teleports clear carried velocity");
    check(views, "all original destination view directions retained");
    trigger = getEnt("tele1", "targetname");
    fake = spawn("script_origin", (0,0,0));
    check(!(trigger maps\mp\mp_descent_v2::teleportPlayer(undefined, destinations[0], angles[0])), "undefined actor safely ignored");
    check(!(trigger maps\mp\mp_descent_v2::teleportPlayer(fake, destinations[0], angles[0])), "non-player actor safely ignored");
    check(!(trigger maps\mp\mp_descent_v2::teleportPlayer(player, undefined, angles[0])), "missing position safely ignored");
    check(!(trigger maps\mp\mp_descent_v2::teleportPlayer(player, destinations[0], undefined)), "missing angles safely ignored");
    away = spawnpoint.origin;
    player setOriginAndAngles(away, spawnpoint.angles);
    check(!(trigger maps\mp\mp_descent_v2::teleportPlayer(player, destinations[0], angles[0])), "stale trigger rejected after load away");
    player setOriginAndAngles(trigger.origin, (0,0,0));
    trigger notify("trigger", player);
    player setOriginAndAngles(away, spawnpoint.angles);
    wait 0.25;
    check(distanceSquared(player.origin, away) < 100, "no delayed teleport after load");

    listeners = strTok("easybegin easyend hardbegin hardend msg1 msg2 msg3 msg4 msg5 msg6", " ");
    for (i = 0; i < listeners.size; i++)
        getEnt(listeners[i], "targetname") notify("trigger", fake);
    wait 0.1;
    fake delete();
    // Physical route entrances no longer create a competing stopwatch.
    getEnt("easybegin", "targetname") notify("trigger", player);
    getEnt("hardbegin", "targetname") notify("trigger", player);
    wait 0.1;
    check(!isDefined(player.startTimeEasy) && !isDefined(player.startTimeHard),
          "route entrances no longer start legacy map timers");
    player.playerRuns_runID = 209;
    player.runInstanceNumber = 3;
    player.playerRuns_runFinished = false;
    getEnt("easyend", "targetname") notify("trigger", player);
    getEnt("hardend", "targetname") notify("trigger", player);
    wait 0.1;
    check(isDefined(player.easyEnd) && player.easyEnd, "plain Easy finish works without legacy start time");
    check(isDefined(player.hardEnd) && player.hardEnd, "plain Hard finish works without legacy start time");
    check(player.playerRuns_runID == 209 && player.runInstanceNumber == 3 &&
          !player.playerRuns_runFinished, "map messages do not finish or modify OpenCJ runs");
    check(getEntArray("trigger_multiple", "classname").size == 14, "all original triggers preserved");
    check(getEntArray("mp_dm_spawn", "classname").size == 4, "all original spawn points preserved");
    openCJ\mapCleanup::onInit();
    wait 0.1;
    pickups = 0;
    entities = getEntArray();
    for (i = 0; i < entities.size; i++)
        if (isDefined(entities[i].classname) && getSubStr(entities[i].classname,0,7) == "weapon_")
            pickups++;
    check(pickups == 0, "shared cleanup removes weapon pickups");
    kick(player getEntityNumber());
    wait 0.1;
    finish();
}

check(passed, label)
{
    level.checks++;
    if (!passed) level.failures++;
    printf("ALPHA SELFTEST " + label + ": " + passed + "\n");
}

finish()
{
    printf("ALPHA SELFTEST COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}
