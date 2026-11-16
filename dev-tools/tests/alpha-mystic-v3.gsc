// #209 Mystic script checks only; no checkpoint traversal/landing simulation.
main()
{
    level.failures = 0;
    level.checks = 0;
    wait 1;
    player = addTestClient();
    second = addTestClient();
    wait 0.2;
    check(isDefined(player) && isDefined(second), "two isolated test clients connected");
    if (!isDefined(player) || !isDefined(second)) { finish(); return; }
    spawnpoint = getEntArray("mp_dm_spawn", "classname")[0];
    player setupPlayer(spawnpoint);
    second setupPlayer(spawnpoint);
    triggers = getEntArray("enter", "targetname");
    check(triggers.size == 18, "all 18 original teleports preserved");
    placed = true;
    cleared = true;
    views = true;
    for (i = 0; i < triggers.size; i++)
    {
        trigger = triggers[i];
        destination = getEnt(trigger.target, "targetname");
        player setOriginAndAngles(trigger.origin, (0,0,0));
        player setVelocity((800,200,100));
        ok = trigger maps\mp\mp_mystic_v3::teleportPlayer(player);
        if (!ok || distanceSquared(player.origin,destination.origin)>=1) placed = false;
        if (length(player getVelocity())>=1) cleared = false;
        expected = destination.angles[1];
        if (expected>180) expected-=360;
        actual = player getPlayerAngles();
        delta = abs(actual[1]-expected);
        if (min(delta,abs(delta-360))>0.1) views = false;
    }
    check(placed, "all original route and gap-practice destinations retained");
    check(cleared, "all teleports clear carried velocity");
    check(views, "all destination view directions retained");
    trigger = triggers[0];
    fake = spawn("script_origin",spawnpoint.origin);
    check(!(trigger maps\mp\mp_mystic_v3::teleportPlayer(undefined)), "undefined actor ignored");
    check(!(trigger maps\mp\mp_mystic_v3::teleportPlayer(fake)), "non-player actor ignored");
    player setOriginAndAngles(trigger.origin,(0,0,0));
    target = trigger.target;
    trigger.target = undefined;
    check(!(trigger maps\mp\mp_mystic_v3::teleportPlayer(player)), "missing target ignored");
    trigger.target = "alpha_mystic_missing";
    check(!(trigger maps\mp\mp_mystic_v3::teleportPlayer(player)), "missing destination ignored");
    trigger.target = target;
    player setOriginAndAngles(spawnpoint.origin,spawnpoint.angles);
    check(!(trigger maps\mp\mp_mystic_v3::teleportPlayer(player)), "stale trigger after load rejected");

    // Actual listener placement must finish before the former 0.1-second delay.
    destination = getEnt(trigger.target,"targetname");
    player setOriginAndAngles(trigger.origin,(0,0,0));
    second setOriginAndAngles(trigger.origin,(0,0,0));
    trigger notify("trigger",player);
    trigger notify("trigger",second);
    wait 0.05;
    check(distanceSquared(player.origin,destination.origin)<100 &&
          distanceSquared(second.origin,destination.origin)<100, "two players teleport immediately");
    player setOriginAndAngles(spawnpoint.origin,spawnpoint.angles);
    wait 0.25;
    check(distanceSquared(player.origin,spawnpoint.origin)<400, "no delayed teleport after loading away");

    for (i = 0; i < triggers.size; i++) triggers[i] notify("trigger",fake);
    wait 0.05;
    check(getEntArray("trigger_multiple","classname").size == 18, "all original trigger geometry preserved");
    check(getEntArray("script_origin","classname").size == 6, "all five destination entities preserved plus fixture marker");
    check(getEntArray("mp_dm_spawn","classname").size == 1, "original spawn point preserved");
    check(isDefined(getEnt("gapone","targetname")) && isDefined(getEnt("gaptwo","targetname")), "optional gap-practice area preserved");
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
