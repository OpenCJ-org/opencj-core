main()
{
    wait 1;
    level.failures = 0;
    verifyDistanceFormatting();

    player = createMeasurementPlayer();
    if(isDefined(player))
    {
        player verifyPointSelection();
        player verifyCancellation();
        player verifyLifecycleCleanup();
    }

    printf("MEASURE SELFTEST COMPLETE failures=" + level.failures + "\n");
}

verifyDistanceFormatting()
{
    check(openCJ\measurements::measureDecimal(0) == "0.0", "zero");
    check(openCJ\measurements::measureDecimal(1.24) == "1.2", "round down");
    check(openCJ\measurements::measureDecimal(1.25) == "1.3", "round half up");
    check(openCJ\measurements::measureDecimal(9.96) == "10.0", "carry");
    check(openCJ\measurements::measureResult((-10, 20, -30), (2, -5, 10)) ==
              "Distance (units): X: 12.0  Y: 25.0  Z: 40.0",
          "absolute axes");
}

// Use a real spawn so the weapon trace hits the selected map's geometry.
createMeasurementPlayer()
{
    player = addTestClient();
    check(isDefined(player), "real client");
    if(!isDefined(player))
    {
        return undefined;
    }

    wait 0.2;
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";

    spawnpoints = getEntArray("mp_dm_spawn", "classname");
    check(spawnpoints.size > 0, "map provides a test spawn above a surface");
    if(spawnpoints.size == 0)
    {
        return undefined;
    }

    spawnHeightUnits = 32;
    player spawn(spawnpoints[0].origin + (0, 0, spawnHeightUnits), (90, 0, 0));
    player freezeControls(true);
    return player;
}

verifyPointSelection()
{
    self openCJ\measurements::onCommandMeasure([]);
    check(isDefined(self.measureHud) && !isDefined(self.measureFirst), "first prompt");
    check(self.measureHud.archived && self.measureHud.alpha == 1,
          "prompt uses visible archival HUD pool");

    missedTrace = [];
    missedTrace["fraction"] = 1;
    missedTrace["position"] = (100, 100, 100);
    self openCJ\measurements::acceptMeasureTrace(missedTrace);
    check(!isDefined(self.measureFirst), "miss does not select first point");

    self openCJ\measurements::onWeaponFired();
    check(isDefined(self.measureFirst), "weapon shot selects surface");

    firstPoint = self.measureFirst;
    self openCJ\measurements::acceptMeasureTrace(missedTrace);
    check(self.measureFirst == firstPoint, "miss retains first point");

    surfaceTrace = [];
    surfaceTrace["fraction"] = 0.5;
    surfaceTrace["position"] = (100, 100, 100);
    self openCJ\measurements::acceptMeasureTrace(surfaceTrace);
    check(!isDefined(self.measureHud) && !isDefined(self.measureFirst),
          "second shot finishes and cleans up");
}

verifyCancellation()
{
    self openCJ\measurements::onCommandMeasure([]);
    self openCJ\measurements::onCommandMeasure([]);
    check(!isDefined(self.measureHud), "toggle cancels");
}

// Synthetic notifications exercise the listeners without disconnecting the test client.
verifyLifecycleCleanup()
{
    lifecycleEvents = [];
    lifecycleEvents[0] = "death";
    lifecycleEvents[1] = "spawned";
    lifecycleEvents[2] = "spawned_spectator";
    lifecycleEvents[3] = "disconnect";

    for(i = 0; i < lifecycleEvents.size; i++)
    {
        self openCJ\measurements::onCommandMeasure([]);
        self notify(lifecycleEvents[i]);
        wait 0.05;
        check(!isDefined(self.measureHud), "lifecycle cleanup " + lifecycleEvents[i]);
    }
}

check(condition, message)
{
    if(!condition)
    {
        level.failures++;
    }
    printf("MEASURE SELFTEST " + message + ": " + condition + "\n");
}
