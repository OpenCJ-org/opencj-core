// Focused #209 script regressions. No checkpoint traversal or landing simulation.
main()
{
    level.failures = 0;
    level.checks = 0;
    wait 1;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "test client connected");
    if (!isDefined(player)) { finish(); return; }
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((832, 256, 272), (0, 0, 0));
    player.maxHealth = 100;
    player.health = 100;

    triggers = getEntArray("teleport", "targetname");
    check(triggers.size == 11, "all eleven original teleport triggers preserved");
    destinations = true;
    cleared = true;
    for (i = 0; i < triggers.size; i++)
    {
        target = getEnt(triggers[i].target, "targetname");
        player setOriginAndAngles(triggers[i].origin, (0,0,0));
        player setVelocity((800,200,100));
        ok = triggers[i] maps\mp\mp_bouncer_training::teleportPlayer(player);
        if (!ok || distanceSquared(player.origin, target.origin) >= 1) destinations = false;
        if (length(player getVelocity()) >= 1) cleared = false;
    }
    check(destinations, "all original teleport destinations preserved");
    check(cleared, "every teleport clears carried velocity");
    fake = spawn("script_origin", (0,0,0));
    fake.target = "missing_destination_209";
    check(!(fake maps\mp\mp_bouncer_training::teleportPlayer(player)), "missing destination safely ignored");
    check(!(triggers[0] maps\mp\mp_bouncer_training::teleportPlayer(undefined)), "undefined trigger actor safely ignored");
    check(!(triggers[0] maps\mp\mp_bouncer_training::teleportPlayer(fake)), "non-player trigger actor safely ignored");
    away = (832,256,272);
    player setOriginAndAngles(away, (0,0,0));
    check(!(triggers[0] maps\mp\mp_bouncer_training::teleportPlayer(player)), "stale trigger rejected after load away");
    player setOriginAndAngles(triggers[0].origin, (0,0,0));
    triggers[0] notify("trigger", player);
    player setOriginAndAngles(away, (0,0,0));
    wait 0.25;
    check(distanceSquared(player.origin, away) < 100, "no delayed teleport after position load");
    fake delete();

    jump = getEnt("jump", "targetname");
    endpoint = getEnt("air4", "targetname").origin;
    baseline = getEntArray("script_model", "classname").size;
    player setOriginAndAngles(jump.origin, (0,0,0));
    player setVelocity((800,200,100));
    jump notify("trigger", player);
    wait 0.1;
    check(getEntArray("script_model", "classname").size == baseline + 1, "finish ride creates one temporary mover");
    wait 3;
    printf("ALPHA SELFTEST ride endpoint expected=" + endpoint + " actual=" + player.origin + " velocity=" + player getVelocity() + "\n");
    check(distanceSquared(player.origin, endpoint) < 2500, "finish ride retains original destination and duration");
    check(length(player getVelocity()) < 100, "ride does not carry entry speed");
    check(getEntArray("script_model", "classname").size == baseline, "completed ride deletes temporary mover");
    wait 1;

    // A position load unlinks from the old ride. Its eventual cleanup must not
    // move the player or unlink a different mover used by a later activity.
    player setOriginAndAngles(jump.origin, (0,0,0));
    jump notify("trigger", player);
    wait 0.2;
    player setOriginAndAngles(away, (0,0,0));
    later = spawn("script_model", away);
    player linkTo(later);
    wait 3;
    check(distanceSquared(player.origin, away) < 100, "load during ride cannot be undone by old mover");
    check(getEntArray("script_model", "classname").size == baseline + 1, "old ride cleaned without deleting later mover");
    later moveTo(away + (128,0,0), 0.2);
    wait 0.3;
    check(distanceSquared(player.origin, later.origin) < 100, "old ride does not unlink later activity");
    later delete();
    wait 1;

    player setOriginAndAngles(jump.origin, (0,0,0));
    jump notify("trigger", player);
    wait 0.2;
    kick(player getEntityNumber());
    wait 3;
    check(getEntArray("script_model", "classname").size == baseline, "disconnect during ride cleans mover without player access");
    check(getEntArray("trigger_use_touch", "classname").size == 7, "all original hints retained");
    check(getEntArray("trigger_hurt", "classname").size == 9, "all original map hazards retained");
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
