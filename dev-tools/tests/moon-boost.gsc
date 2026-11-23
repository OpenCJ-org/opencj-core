// Exercise independent boost ownership, lifecycle exits, and matching movement traces.
main()
{
    wait 1;
    level.moonFailures = 0;
    level.moonChecks = 0;
    level.moonBoostScale = 12;
    level.moonNormalScale = 1;
    level.checkpointLayoutEpoch = 1;
    openCJ\historySave::onInit();
    player = addTestClient();
    otherPlayer = addTestClient();
    wait 0.5;
    check(isDefined(player) && isDefined(otherPlayer), "two real clients");
    if(!isDefined(player) || !isDefined(otherPlayer))
    {
        return;
    }
    player initializePlayerState();
    otherPlayer initializePlayerState();

    player verifyIndependentPlayers(otherPlayer);
    player verifyAirborneBoost();
    player verifyPositionLoadCancelsBoost();
    player verifySpectatorTransition();
    player verifyRunRestoreCancelsBoost();
    player verifyNoclipCancelsBoost();
    player verifyDeathCancelsBoost();
    player verifyCooldownOwnership();

    player verifySupersededSpawn();
    player verifyFPSRegistrationCancellation();
    player verifyFailedRunRestore();
    player verifyRestoreDoesNotArchiveItself();
    player verifyEditorTravelCancelsBoost();
    player verifyMatchedTrajectories();
    printf("MOON SELFTEST COMPLETE failures=" + level.moonFailures + " checks=" + level.moonChecks +
           "\n");
}

verifyIndependentPlayers(otherPlayer)
{
    // Stationary, grounded placements inside ramp 1, separated across its width.
    self resetPlayerAt((-1000, -2200, 1669));
    otherPlayer resetPlayerAt((-1200, -2200, 1669));
    thread maps\mp\mp_to_the_moon::startBoostTrigger("svt_accelerate_1");
    trigger = getEnt("svt_accelerate_1", "targetname");
    trigger notify("trigger", self);
    trigger notify("trigger", otherPlayer);
    wait 0.1;
    level notify("moon_test_stop_listener");
    check(self.testScale == level.moonBoostScale && otherPlayer.testScale == level.moonBoostScale,
          "same production trigger boosts two players independently");
    self openCJ\mapBoost::cancel();
    wait 0.1;
    check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned) &&
              otherPlayer.testScale == level.moonBoostScale,
          "cancelling A leaves B boosted");
    check(isAlive(self) && self isOnGround(), "A ready for boost");
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    wait 0.1;
    check(self.testScale == level.moonBoostScale && otherPlayer.testScale == level.moonBoostScale,
          "A immediately reacquires without stale-thread interference");
    self openCJ\mapBoost::cancel();
    otherPlayer openCJ\mapBoost::cancel();
}

verifyAirborneBoost()
{
    self resetPlayerAt((-1000, -2200, 1900));
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    check(!isDefined(self.mapBoostOwned), "airborne touch does not consume cooldown");
}

verifyPositionLoadCancelsBoost()
{
    for(i = 0; i < 2; i++)
    {
        self resetPlayerAt((-1000, -2200, 1669));
        check(isAlive(self) && self isOnGround(), "A ready for boost");
        self thread openCJ\mapBoost::start(level.moonBoostScale);
        wait 0.1;
        self openCJ\events\eventHandler::onLoadPositionRequest(i);
        check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
              "load request cancels synchronously " + i);
        self thread openCJ\mapBoost::start(level.moonBoostScale);
        wait 0.1;
        check(self.testScale == level.moonBoostScale, "direct load begins boosted " + i);
        self openCJ\events\loadPosition::main(i);
        check(distance(self.origin, self.testSaves[i].origin) < 4,
              "real load reaches destination " + i);
        wait 0.15;
        check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
              "load cannot reapply boost " + i);
    }
}

verifySpectatorTransition()
{
    self resetPlayerAt((-1000, -2200, 1669));
    check(isAlive(self) && self isOnGround(), "A ready for boost");
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    wait 0.1;
    self openCJ\events\spawnSpectator::main();
    check(self.sessionstate == "spectator" && self.testScale == level.moonNormalScale &&
              !isDefined(self.mapBoostOwned),
          "real spectator transition clears boost");
    self openCJ\events\spawnPlayer::main(false);
    check(self.sessionstate == "playing" && self.testScale == level.moonNormalScale,
          "real respawn retains normal scale");
    wait 0.15;
    check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
          "spectator-respawn cannot revive worker");
}

verifyRunRestoreCancelsBoost()
{
    for(i = 0; i < 2; i++)
    {
        self resetPlayerAt((-1000, -2200, 1669));
        self.testNoSaves = i;
        check(isAlive(self) && self isOnGround(), "A ready for boost");
        self thread openCJ\mapBoost::start(level.moonBoostScale);
        wait 0.1;
        self openCJ\playerRuns::restoreRun(999);
        wait 0.2;
        check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
              "run restore cancels boost, empty=" + i);
        if(i == 0)
        {
            expectedOrigin = self.testSaves[0].origin;
        }
        else
        {
            expectedOrigin = self.testSpawn.origin;
        }
        check(distance(self.origin, expectedOrigin) < 6, "run restore destination, empty=" + i);
    }
}

verifyNoclipCancelsBoost()
{
    self resetPlayerAt((-1000, -2200, 1669));
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    wait 0.1;
    self openCJ\noclip::enableNoclip();
    check(self.noclip && self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
          "real noclip activation cancels boost");
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    check(!isDefined(self.mapBoostOwned), "noclip cannot acquire boost");
    self openCJ\noclip::disableNoclip();
}

verifyDeathCancelsBoost()
{
    self resetPlayerAt((-1000, -2200, 1669));
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    wait 0.1;
    self openCJ\events\playerKilled::main(self, self, 100, "MOD_SUICIDE", "none", (0, 0, 0), "none",
                                          0, 0);
    check(self.sessionstate == "dead" && self.testScale == level.moonNormalScale &&
              !isDefined(self.mapBoostOwned),
          "death clears boost");
}

verifyCooldownOwnership()
{
    // A genuine boost cooldown cannot later clear a new owner.
    self resetPlayerAt((-1000, -2200, 1669));
    check(isAlive(self) && self isOnGround(), "A ready for boost");
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    wait 0.1;
    self setOriginAndAngles((-1000, -2200, 1900), (0, 90, 0)); // test-only simulated takeoff
    wait 0.1;
    check(self.testScale == level.moonNormalScale && isDefined(self.mapBoostOwned),
          "successful attempt enters original cooldown");
    self openCJ\mapBoost::cancel();
    self resetPlayerAt((-1000, -2200, 1669));
    check(isAlive(self) && self isOnGround(), "A ready for boost");
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    wait 2.2;
    check(self.testScale == level.moonBoostScale && isDefined(self.mapBoostOwned),
          "cancelled cooldown cannot clear new owner");
    self openCJ\mapBoost::cancel();
}

verifyMatchedTrajectories()
{
    // Compare real engine movement using the original loop and production loop.
    // Automatic map boost listeners are disabled only in this fixture, so each
    // trial has exactly one known owner.
    positionToleranceUnits = 0.1;
    velocityToleranceUnitsPerSecond = 0.1;
    rampStarts = [];
    rampGoals = [];
    rampStarts[0] = (-1060, -2200, 1669);
    rampGoals[0] = (-1060, 1800, 4000);
    rampStarts[1] = (2248, -1450, 1585);
    rampGoals[1] = (1760, -2300, 1583);
    rampStarts[2] = (7740, -1150, 1989);
    rampGoals[2] = (9300, -1150, 4000);
    for(rampIndex = 0; rampIndex < 3; rampIndex++)
    {
        originalTrace =
            self captureMovementTrace(rampStarts[rampIndex], rampGoals[rampIndex], rampIndex, true);
        productionTrace = self captureMovementTrace(rampStarts[rampIndex], rampGoals[rampIndex],
                                                    rampIndex, false);
        maximumPositionDelta = 0;
        maximumVelocityDelta = 0;
        scaleMatches = true;
        airborneSamples = 0;
        boostSamples = 0;
        for(i = 0; i < originalTrace.size; i++)
        {
            maximumPositionDelta = max(
                maximumPositionDelta, distance(originalTrace[i].origin, productionTrace[i].origin));
            maximumVelocityDelta = max(maximumVelocityDelta, distance(originalTrace[i].velocity,
                                                                      productionTrace[i].velocity));
            if(originalTrace[i].scale != productionTrace[i].scale)
            {
                scaleMatches = false;
            }
            if(!originalTrace[i].grounded)
            {
                airborneSamples++;
            }
            if(originalTrace[i].scale == level.moonBoostScale)
            {
                boostSamples++;
            }
        }
        printf("MOON SELFTEST trajectory ramp=" + rampIndex + " position_delta=" +
               maximumPositionDelta + " velocity_delta=" + maximumVelocityDelta + "\n");
        check(airborneSamples > 0 && boostSamples > 0,
              "trajectory includes boost and takeoff ramp " + rampIndex);
        check(maximumPositionDelta < positionToleranceUnits &&
                  maximumVelocityDelta < velocityToleranceUnitsPerSecond && scaleMatches,
              "matched trajectory and scale timing ramp " + rampIndex);
    }
}
initializePlayerState()
{
    self.sessionTeam = "allies";
    self.sessionState = "playing";
    self.pers["team"] = "allies";
    self.noclip = false;
    self.playingDemo = false;
    self.isFirstSpawn = true;
    self.eventQueue = [];
    self.testNoSaves = false;
    self.testScale = level.moonNormalScale;
    self.testSpawn = spawnStruct();
    self.testSpawn.origin = (1760, -1290, 1585);
    self.testSpawn.angles = (0, 90, 0);
    self.testSaves = [];
    for(i = 0; i < 2; i++)
    {
        save = spawnStruct();
        save.origin = (1550 + i * 300, -1290, 1585);
        save.angles = (0, 90, 0);
        save.explosiveJumps = 0;
        save.doubleExplosives = 0;
        save.FPSMode = 125;
        save.checkpointID = 0;
        save.saveNum = i;
        self.testSaves[i] = save;
    }
}
// Reset physics and allow the test client to settle before each movement trial.
resetPlayerAt(origin)
{
    self notify("moon_test_baseline_cancel");
    self openCJ\mapBoost::cancel();
    self botStop();
    self.sessionTeam = "allies";
    self.sessionState = "playing";
    self.pers["team"] = "allies";
    self spawn(origin, (0, 90, 0));
    self.maxhealth = 100;
    self.health = 100;
    self setMoveSpeedScale(level.moonNormalScale);
    self.testScale = level.moonNormalScale;
    self setg_speed(190);
    self setOriginAndAngles(origin, (0, 90, 0));
    self setVelocity((0, 0, 0));
    settleSeconds = 0.3;
    wait settleSeconds;
}
captureMovementTrace(origin, targetOrigin, rampIndex, useOriginalLoop)
{
    self resetPlayerAt(origin);
    printf("MOON SELFTEST trial origin=" + self.origin + " alive=" + isAlive(self) + "\n");
    check(self isOnGround(), "trial starts grounded ramp " + rampIndex);
    self.testTrace = [];
    frameCount = 60;
    frameStepSeconds = 0.05;
    jumpPressFrame = 30;
    jumpReleaseFrame = 31;
    firstTurnFrame = 4;
    finalTurnFrame = 10;
    if(useOriginalLoop)
    {
        self thread originalBoost();
    }
    else
    {
        self thread openCJ\mapBoost::start(level.moonBoostScale);
    }
    if(rampIndex == 1)
    {
        self botMoveTo((2248, -1288, 1583));
    }
    else
    {
        self botMoveTo(targetOrigin);
    }
    for(i = 0; i < frameCount; i++)
    {
        if(rampIndex == 0 && i == jumpPressFrame)
        {
            self botAction("+gostand");
        }
        if(rampIndex == 0 && i == jumpReleaseFrame)
        {
            self botAction("-gostand");
        }
        if(rampIndex == 1 && i == firstTurnFrame)
        {
            self botMoveTo((1760, -1288, 1583));
        }
        if(rampIndex == 1 && i == finalTurnFrame)
        {
            self botMoveTo(targetOrigin);
        }
        sample = spawnStruct();
        sample.origin = self.origin;
        sample.velocity = self getVelocity();
        sample.scale = self.testScale;
        sample.grounded = self isOnGround();
        self.testTrace[i] = sample;
        wait frameStepSeconds;
    }
    printf("MOON SELFTEST trajectory endpoint=" + self.origin + " velocity=" + self getVelocity() +
           "\n");
    trace = self.testTrace;
    self notify("moon_test_baseline_cancel");
    self openCJ\mapBoost::cancel();
    self setMoveSpeedScale(level.moonNormalScale);
    self botStop();
    return trace;
}
// Preserve the old grounded-loop behavior as an independent movement reference.
originalBoost()
{
    self endon("disconnect");
    self endon("moon_test_baseline_cancel");
    frameStepSeconds = 0.05;
    cooldownSeconds = 2;
    while(self isOnGround())
    {
        self.testScale = level.moonBoostScale;
        self setMoveSpeedScale(level.moonBoostScale);
        wait frameStepSeconds;
    }
    self.testScale = level.moonNormalScale;
    self setMoveSpeedScale(level.moonNormalScale);
    wait cooldownSeconds;
}
check(passed, description)
{
    level.moonChecks++;
    if(!isDefined(passed) || !passed)
    {
        level.moonFailures++;
    }
    printf("MOON SELFTEST " + description + ": " + passed + "\n");
}

verifyEditorTravelCancelsBoost()
{
    self.cpc = spawnStruct();
    self.cpc.positions = [];
    self.cpc.positions[0] = self.testSaves[0];
    self.cpc.positions[1] = self.testSaves[1];
    self.cpc.travelIndex = 0;
    for(i = 0; i < 2; i++)
    {
        self resetPlayerAt((7740, -1150, 1989));
        thread maps\mp\mp_to_the_moon::startBoostTrigger("svt_accelerate_3");
        trigger = getEnt("svt_accelerate_3", "targetname");
        trigger notify("trigger", self);
        wait 0.1;
        level notify("moon_test_stop_listener");
        check(self.testScale == level.moonBoostScale && isDefined(self.mapBoostOwned),
              "editor can activate actual inter-ramp trigger " + i);
        self openCJ\events\eventHandler::onLoadPositionRequest(i);
        check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
              "editor load request cancels active boost " + i);
        self openCJ\checkpointCreation::processTravelRequests();
        check(distance(self.origin, self.testSaves[i].origin) < 4,
              "real editor load reaches destination " + i);
        wait 0.15;
        check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
              "editor teleport cannot revive boost " + i);
    }
    self resetPlayerAt((7740, -1150, 1989));
    self thread openCJ\mapBoost::start(level.moonBoostScale);
    wait 0.1;
    check(self.testScale == level.moonBoostScale, "editor can reactivate after loading");
    self.cpc.restoreOrigin = self.testSaves[0].origin;
    self.cpc.restoreAngles = self.testSaves[0].angles;
    self openCJ\checkpointCreation::processTravelRequests();
    check(self.testScale == level.moonNormalScale && !isDefined(self.mapBoostOwned),
          "editor restore-origin travel cancels boost");
    check(distance(self.origin, self.testSaves[0].origin) < 4,
          "editor restore-origin reaches destination");
    self.cpc = undefined;
}

// A failed history read must not move the player or turn the old run into a fresh one.
verifyFailedRunRestore()
{
    self resetPlayerAt((-1000, -2200, 1669));
    self.playerRuns_runID = 321;
    self.runInstanceNumber = 7;
    self.playerRuns_runStarted = false;
    self.playerRuns_runPaused = true;
    self.playerRuns_runFinished = true;
    self.testNoSaves = true;
    self.testHistoryFailure = true;
    previousOrigin = self.origin;

    self openCJ\playerRuns::restoreRun(999);

    check(distance(self.origin, previousOrigin) < 4,
          "failed history load preserves the player's position");
    check(!self.playerRuns_runStarted && self.playerRuns_runPaused && self.playerRuns_runFinished,
          "failed history load preserves the existing run flags");
    check(self.playerRuns_runID == 321 && self.runInstanceNumber == 7,
          "failed history load preserves the existing run identity");
    self.testHistoryFailure = undefined;
    self.testNoSaves = false;
}

// Restoring the current run must not archive the same run after its load succeeds.
verifyRestoreDoesNotArchiveItself()
{
    self.playerRuns_runID = 999;
    self.runInstanceNumber = 7;
    self.playerRuns_runFinishing = true;
    self.testArchivedRunID = undefined;

    self openCJ\playerRuns::restoreRun(999);
    wait .1;

    check(!isDefined(self.testArchivedRunID), "restoring a run never archives that same run");
    check(!self.playerRuns_runFinishing, "successful restoration clears the old finishing state");
}

// Pause only the equipment dependency; the actual spawn/spectator handlers remain intact.
loadEquipmentForTest()
{
    if(isDefined(self.testHoldEquipment) && self.testHoldEquipment)
    {
        // Real SQL yields before completion; let the caller observe this barrier too.
        wait 0.05;
        self notify("test_equipment_waiting");
        self waittill("test_equipment_release");
    }
    return true;
}

verifySupersededSpawn()
{
    self openCJ\events\spawnSpectator::main();
    self.testHoldEquipment = true;
    self thread openCJ\events\spawnPlayer::main(false);
    self waittill("test_equipment_waiting");
    self openCJ\events\spawnSpectator::main();
    self.testHoldEquipment = false;
    self notify("test_equipment_release");
    wait 0.1;
    check(self.sessionState == "spectator", "late equipment reply cannot undo a spectator request");

    self.testSpawnCount = 0;
    self thread observeSpawns();
    self.testHoldEquipment = true;
    self thread openCJ\events\spawnPlayer::main(false);
    self waittill("test_equipment_waiting");
    self.testHoldEquipment = false;
    self openCJ\events\spawnPlayer::main(true);
    latestSpawnOrigin = self.origin;
    self notify("test_equipment_release");
    wait 0.1;
    check(self.testSpawnCount == 1, "a superseded spawn cannot run after the newer spawn");
    check(distance(self.origin, latestSpawnOrigin) < 4,
          "late spawn cannot replace the latest saved-position destination");
    self notify("test_stop_spawn_observer");
}

observeSpawns()
{
    self endon("disconnect");
    self endon("test_stop_spawn_observer");
    for(;;)
    {
        self waittill("spawned");
        self.testSpawnCount++;
    }
}

// Registration may finish after the player changes their mind about joining.
verifyFPSRegistrationCancellation()
{
    self.testRegistrationBlocked = true;
    self openCJ\events\spawnPlayer::main(false);
    check(self.sessionState == "spectator" && self.fpsRegistrationSpawnPending,
          "registration holds an initial spawn while temporarily spectating");

    self openCJ\events\spawnSpectator::main();
    check(!self.fpsRegistrationSpawnPending,
          "explicit spectator request clears the registration-held spawn");
    self.testRegistrationBlocked = false;
    self openCJ\fpsRegistration::finish();
    check(self.sessionState == "spectator",
          "registration completion cannot undo the explicit spectator request");

    self.testRegistrationBlocked = true;
    self openCJ\events\spawnPlayer::main(false);
    self.testRegistrationBlocked = false;
    self openCJ\fpsRegistration::finish();
    check(self.sessionState == "playing" && !self.fpsRegistrationSpawnPending,
          "an uncancelled registration-held spawn still resumes");
}
