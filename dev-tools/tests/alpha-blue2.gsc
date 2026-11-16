// Focused #209 Blue2 script checks; no checkpoint traversal or simulations.
main()
{
    level.failures = 0;
    level.checks = 0;
    wait 1;
    player = addTestClient();
    other = addTestClient();
    wait 0.2;
    check(isDefined(player) && isDefined(other), "test clients connected");
    if (!isDefined(player) || !isDefined(other)) { finish(); return; }
    setupPlayer(player);
    setupPlayer(other);

    names = strTok("easy inter hard", " ");
    destinations = [];
    destinations[0] = (476,5737,-1589);
    destinations[1] = (25734,11808,-2029);
    destinations[2] = (6387,-5,-2021);
    view = (17,123,0);
    allPlaced = true;
    allCleared = true;
    allViews = true;
    for (i = 0; i < names.size; i++)
    {
        trigger = getEnt(names[i], "targetname");
        player setOriginAndAngles(trigger.origin, view);
        expectedView = player getPlayerAngles();
        player setVelocity((800,200,100));
        ok = trigger maps\mp\mp_blue2::teleportPlayer(player, destinations[i]);
        if (!ok || distanceSquared(player.origin, destinations[i]) >= 1) allPlaced = false;
        if (length(player getVelocity()) >= 1) allCleared = false;
        if (distanceSquared(player getPlayerAngles(), expectedView) >= 1) allViews = false;
    }
    check(allPlaced, "all three original route destinations preserved");
    check(allCleared, "route teleports clear carried velocity");
    check(allViews, "route teleports retain player view");
    trigger = getEnt("easy", "targetname");
    fake = spawn("script_origin", (0,0,0));
    check(!(trigger maps\mp\mp_blue2::teleportPlayer(undefined, destinations[0])), "undefined actor safely ignored");
    check(!(trigger maps\mp\mp_blue2::teleportPlayer(fake, destinations[0])), "non-player actor safely ignored");
    check(!(trigger maps\mp\mp_blue2::teleportPlayer(player, undefined)), "undefined destination safely ignored");
    spawnpoint = getEntArray("mp_dm_spawn", "classname")[0];
    away = spawnpoint.origin;
    player setOriginAndAngles(away, view);
    check(!(trigger maps\mp\mp_blue2::teleportPlayer(player, destinations[0])), "stale trigger rejected after load away");
    player setOriginAndAngles(trigger.origin, view);
    trigger notify("trigger", player);
    player setOriginAndAngles(away, view);
    wait 0.25;
    check(distanceSquared(player.origin, away) < 100, "route entry cannot undo a subsequent position load");
    check(!isDefined(player.easy) && !isDefined(player.inter) && !isDefined(player.hard), "teleport blackout HUDs no longer created");

    // Invalid actors must not terminate map listeners.
    listeners = strTok("guid1 credits easystart interstart hardstart easyend interend hardend", " ");
    for (i = 0; i < listeners.size; i++)
        getEnt(listeners[i], "targetname") notify("trigger", fake);
    wait 0.1;
    getEnt("hardend", "targetname") notify("trigger", player);
    wait 0.1;
    check(isDefined(player.endhard) && player.endhard, "finish message listener survives invalid actor");
    fake delete();

    player thread maps\mp\mp_blue2::showCredits();
    other thread maps\mp\mp_blue2::showCredits();
    wait 0.1;
    hud = player.blue2Credits;
    check(isDefined(hud), "credits allocate a client HUD");
    player thread maps\mp\mp_blue2::showCredits();
    wait 0.1;
    check(player.blue2Credits == hud, "repeated credits request reuses active sequence");
    kick(other getEntityNumber());
    wait 6;
    check(isDefined(player.blue2Credits) && player.blue2Credits == hud, "second credits message reuses same HUD");
    wait 6;
    check(isDefined(player.blue2Credits) && player.blue2Credits == hud, "third credits message reuses same HUD");
    wait 6;
    check(!isDefined(player.blue2Credits) && !isDefined(hud), "completed credits destroy HUD and release slot");
    player thread maps\mp\mp_blue2::showCredits();
    wait 0.1;
    check(isDefined(player.blue2Credits), "credits can be opened again after cleanup");
    kick(player getEntityNumber());
    wait 0.1;
    check(getEntArray("trigger_multiple", "classname").size == 27, "all original map triggers preserved");
    check(getEntArray("mp_dm_spawn", "classname").size == 5, "all original spawn points preserved");
    finish();
}

setupPlayer(player)
{
    spawnpoint = getEntArray("mp_dm_spawn", "classname")[0];
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn(spawnpoint.origin, spawnpoint.angles);
    player.maxHealth = 100;
    player.health = 100;
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
