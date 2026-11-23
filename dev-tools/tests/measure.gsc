
main()
{
    wait 1;
    level.failures = 0;
    check(openCJ\measurements::measureDecimal(0) == "0.0", "zero");
    check(openCJ\measurements::measureDecimal(1.24) == "1.2", "round down");
    check(openCJ\measurements::measureDecimal(1.25) == "1.3", "round half up");
    check(openCJ\measurements::measureDecimal(9.96) == "10.0", "carry");
    check(openCJ\measurements::measureResult((-10, 20, -30), (2, -5, 10)) ==
              "Distance (units): X: 12.0  Y: 25.0  Z: 40.0",
          "absolute axes");
    player = addTestClient();
    check(isDefined(player), "real client");
    if(isDefined(player))
    {
        wait 0.2;
        player.sessionTeam = "allies";
        player.sessionState = "playing";
        player.pers["team"] = "allies";
        spawnpoints = getEntArray("mp_dm_spawn", "classname");
        check(spawnpoints.size > 0, "map provides a test spawn above a surface");
        if(spawnpoints.size == 0)
        {
            printf("MEASURE SELFTEST COMPLETE failures=" + level.failures + "\n");
            return;
        }
        player spawn(spawnpoints[0].origin + (0, 0, 32), (90, 0, 0));
        player freezeControls(true);
        player openCJ\measurements::onCommandMeasure([]);
        check(isDefined(player.measureHud) && !isDefined(player.measureFirst), "first prompt");
        check(player.measureHud.archived && player.measureHud.alpha == 1,
              "prompt uses visible archival HUD pool");
        trace = [];
        trace["fraction"] = 1;
        trace["position"] = (100, 100, 100);
        player openCJ\measurements::acceptMeasureTrace(trace);
        check(!isDefined(player.measureFirst), "miss does not select first point");
        player openCJ\measurements::onWeaponFired();
        check(isDefined(player.measureFirst), "weapon shot selects surface");
        first = player.measureFirst;
        player openCJ\measurements::acceptMeasureTrace(trace);
        check(player.measureFirst == first, "miss retains first point");
        trace["fraction"] = 0.5;
        player openCJ\measurements::acceptMeasureTrace(trace);
        check(!isDefined(player.measureHud) && !isDefined(player.measureFirst),
              "second shot finishes and cleans up");
        player openCJ\measurements::onCommandMeasure([]);
        player openCJ\measurements::onCommandMeasure([]);
        check(!isDefined(player.measureHud), "toggle cancels");
        events = [];
        events[0] = "death";
        events[1] = "spawned";
        events[2] = "spawned_spectator";
        for(i = 0; i < events.size; i++)
        {
            player openCJ\measurements::onCommandMeasure([]);
            player notify(events[i]);
            wait 0.05;
            check(!isDefined(player.measureHud), "lifecycle cleanup " + events[i]);
        }
    }
    printf("MEASURE SELFTEST COMPLETE failures=" + level.failures + "\n");
}
check(ok, message)
{
    if(!ok)
    {
        level.failures++;
    }
    printf("MEASURE SELFTEST " + message + ": " + ok + "\n");
}
