// Exercise script save publication using real native history. The private fixture
// copy observes persistence and demo calls so these checks never write player data.
main()
{
    if (getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.savePositionChecks = 0;
    level.savePositionFailures = 0;
    level.savePositionClassicFPS = 2;
    level.weapons_rpgs = [];
    openCJ\statistics::onInit();
    openCJ\savePosition::onInit();
    wait 1;

    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "synthetic player created");
    if (isDefined(player))
    {
        player.sessionTeam = "allies";
        player.sessionState = "playing";
        player.pers["team"] = "allies";
        player spawn((0, 0, 700), (0, 0, 0));
        player freezeControls(true);
        player verifyRejectedSave();
        player verifySuccessfulSave();
        player verifyUnscoredSave(false);
        player verifyUnscoredSave(true);
    }
    printf("SAVE POSITION COMPLETE failures=" + level.savePositionFailures
        + " checks=" + level.savePositionChecks + "\n");
}

check(passed, description)
{
    level.savePositionChecks++;
    if (!isDefined(passed) || !passed)
    {
        level.savePositionFailures++;
        printf("SAVE POSITION FAIL: " + description + "\n");
    }
}

seedPosition()
{
    self openCJ\statistics::onPlayerConnect();
    self openCJ\statistics::setSaveCount(7);
    self.playerRuns_runID = 1;
    self.runInstanceNumber = 1;
    self.playerRuns_runFinished = false;
    self.cpc = undefined;
    self.cheating = false;
    self.speedModeNow = false;
    self.speedModeEver = false;
    self.allowHalfBeat = false;
    self.FPSMode = "125";
    self.checkpoints_checkpoint = spawnStruct();
    self.checkpoints_checkpoint.id = 1;
    self.testPersistenceRequests = 0;
    self.testDemoMarkers = 0;
    self.testDemoSaveNumber = undefined;
    self savePosition_initClient();
    inserted = self savePosition_save((100, 200, 700), (0, 90, 0), undefined,
        0, 0, 1, level.savePositionClassicFPS, 0, 7);
    check(isDefined(inserted) && inserted == 0, "seed position accepted");
}

verifyRejectedSave()
{
    self seedPosition();
    // The native reader rejects a noninteger statistic without altering history.
    self.statistics[level.statisticsStrings_explosiveJumps] = "invalid";

    saveNumber = self openCJ\savePosition::setSavedPosition();
    wait 0.05;

    check(!isDefined(saveNumber), "rejected save returns no save number");
    check(self openCJ\statistics::getSaveCount() == 7,
        "rejected save preserves the previous counter");
    check(self.testPersistenceRequests == 0, "rejected save starts no persistence request");
    check(self.testDemoMarkers == 0, "rejected save adds no demo marker");
    self checkNativeHistory(1, 7, "rejected save");
}

verifySuccessfulSave()
{
    self seedPosition();

    saveNumber = self openCJ\savePosition::setSavedPosition();
    wait 0.05;

    check(isDefined(saveNumber) && saveNumber == 8, "accepted save returns the next number");
    check(self openCJ\statistics::getSaveCount() == 8, "accepted save advances the counter once");
    check(self.testPersistenceRequests == 1, "accepted save requests persistence once");
    check(self.testDemoMarkers == 1 && self.testDemoSaveNumber == 8,
        "accepted save records the same number in the demo");
    self checkNativeHistory(2, 8, "accepted save");
}

verifyUnscoredSave(editing)
{
    self seedPosition();
    if (editing)
    {
        self.cpc = spawnStruct();
        scenario = "editor save";
    }
    else
    {
        self.playerRuns_runFinished = true;
        scenario = "finished-run save";
    }

    saveNumber = self openCJ\savePosition::setSavedPosition();
    wait 0.05;

    check(isDefined(saveNumber) && saveNumber == -1, scenario + " keeps the unscored marker");
    check(self openCJ\statistics::getSaveCount() == 7, scenario + " does not advance the counter");
    self checkNativeHistory(2, -1, scenario);
}

checkNativeHistory(expectedCount, expectedNewestNumber, scenario)
{
    history = self savePosition_historyInfo();
    retainedCount = history[0];
    newestSaveNumber = history[4];
    check(retainedCount == expectedCount, scenario + " retains the expected number of positions");
    check(newestSaveNumber == expectedNewestNumber, scenario + " keeps the expected newest position");
}

recordPersistence(origin, angles, entityTargetName, siblingIndex, explosiveJumps,
    doubleExplosives, checkpointID, fpsMode, flags)
{
    self.testPersistenceRequests++;
}

recordDemoSave(saveNumber)
{
    self.testDemoMarkers++;
    self.testDemoSaveNumber = saveNumber;
}
