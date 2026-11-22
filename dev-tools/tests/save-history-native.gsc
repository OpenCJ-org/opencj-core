// Exercise native save validation through the real engine, without database access.
main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.saveNativeChecks = 0;
    level.saveNativeFailures = 0;
    level.saveNativeFPSMix = 5;
    level.saveNativeInserted = 0;
    level.saveNativeSelected = 0;
    level.saveNativeEmpty = 1;
    level.saveNativeUnavailable = 2;
    wait 1;

    player = createTestPlayer((0, 0, 700));
    otherPlayer = createTestPlayer((30, 0, 700));
    if(isDefined(player) && isDefined(otherPlayer))
    {
        player verifyRejectedSaves();
        player verifySelectionArguments();
        player verifyUnmatchedSelections(otherPlayer);
        verifyNonPlayerCalls();
        player savePosition_initClient();
        otherPlayer savePosition_initClient();
    }
    printf("SAVE HISTORY NATIVE COMPLETE failures=" + level.saveNativeFailures
        + " checks=" + level.saveNativeChecks + "\n");
}

createTestPlayer(origin)
{
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "synthetic player created");
    if(!isDefined(player))
    {
        return undefined;
    }
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn(origin, (0, 0, 0));
    player freezeControls(true);
    return player;
}

check(passed, description)
{
    level.saveNativeChecks++;
    if(!isDefined(passed) || !passed)
    {
        level.saveNativeFailures++;
        printf("SAVE HISTORY NATIVE FAIL: " + description + "\n");
    }
}

// Each scenario begins with one selected position whose values are easy to recognize.
seedSave(flags)
{
    self savePosition_initClient();
    result = self savePosition_save((100, 200, 700), (0, 90, 0), undefined,
        2, 1, 7, level.saveNativeFPSMix, flags, 100);
    check(result == level.saveNativeInserted, "valid position inserted");
    check(self savePosition_selectSave(0) == level.saveNativeSelected, "valid position selected");
}

verifyRejectedSaves()
{
    self seedSave(0);
    originalInfo = self savePosition_historyInfo();
    originalSaveCount = originalInfo[0];
    originalGeneration = originalInfo[2];
    // The entity array bound is fixed by CoD4's ten-bit entity index.
    entityLimit = 1024;
    invalidFPSMode = 7;
    fpsMode = level.saveNativeFPSMix;

    check(!isDefined(self savePosition_save()), "missing save arguments rejected");
    check(!isDefined(self savePosition_save("bad", (0, 0, 0), undefined,
        0, 0, 1, fpsMode, 0, 101)), "invalid origin rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), "bad", undefined,
        0, 0, 1, fpsMode, 0, 101)), "invalid angles rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), -1,
        0, 0, 1, fpsMode, 0, 101)), "negative entity index rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), entityLimit,
        0, 0, 1, fpsMode, 0, 101)), "entity upper bound rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), undefined,
        "bad", 0, 1, fpsMode, 0, 101)), "invalid explosive count rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), undefined,
        0, "bad", 1, fpsMode, 0, 101)), "invalid double-explosive count rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), undefined,
        0, 0, "bad", fpsMode, 0, 101)), "invalid checkpoint rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), undefined,
        0, 0, 1, invalidFPSMode, 0, 101)), "unknown FPS mode rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), undefined,
        0, 0, 1, fpsMode, "bad", 101)), "invalid flags rejected");
    check(!isDefined(self savePosition_save((0, 0, 0), (0, 0, 0), undefined,
        0, 0, 1, fpsMode, 0, undefined)), "missing save number rejected");
    check(!isDefined(self savePosition_addOlder()), "missing older-save arguments rejected");
    check(!isDefined(self savePosition_addOlder("bad", (0, 0, 0), undefined,
        0, 0, 1, fpsMode, 0, 99)), "malformed older save rejected");

    currentInfo = self savePosition_historyInfo();
    currentSaveCount = currentInfo[0];
    currentGeneration = currentInfo[2];
    check(currentSaveCount == originalSaveCount && currentGeneration == originalGeneration,
        "rejected saves preserve history count and generation");
    check(self savePosition_getSaveNum() == 100, "rejected saves preserve selection");
    check(self savePosition_getOrigin() == (100, 200, 700),
        "rejected saves preserve position values");
}

verifySelectionArguments()
{
    self seedSave(0);
    check(self savePosition_selectSave(1) == level.saveNativeUnavailable, "selection beyond retained history fails");
    check(!isDefined(self savePosition_getOrigin()), "unavailable selection clears old origin");

    self savePosition_selectSave(0);
    check(!isDefined(self savePosition_selectSave("bad")), "invalid selection argument rejected");
    check(!isDefined(self savePosition_getSaveNum()), "invalid selection clears old number");

    self savePosition_selectSave(0);
    check(!isDefined(self savePosition_selectSave()), "missing selection argument rejected");
    check(!isDefined(self savePosition_getFlags()), "missing selection clears old flags");

    self savePosition_selectSave(0);
    check(!isDefined(self savePosition_selectWithoutFlag(0)), "empty excluded flags rejected");
    check(!isDefined(self savePosition_getOrigin()), "empty flag request clears old selection");

    self savePosition_selectSave(0);
    check(!isDefined(self savePosition_selectWithoutFlag(1, -1)), "negative source player rejected");
    check(!isDefined(self savePosition_getOrigin()), "invalid source clears old selection");

    // MAX_CLIENTS is 64 even when this fixture configures only two client slots.
    nativeClientLimit = 64;
    self savePosition_selectSave(0);
    check(!isDefined(self savePosition_selectWithoutFlag(1, nativeClientLimit)),
        "source player upper bound rejected");
    check(!isDefined(self savePosition_getOrigin()), "upper-bound failure clears old selection");
}

verifyUnmatchedSelections(otherPlayer)
{
    excludedFlag = 8;
    self seedSave(excludedFlag);
    check(!isDefined(self savePosition_selectWithoutFlag(excludedFlag)), "no matching save found");
    check(!isDefined(self savePosition_getSaveNum()), "unmatched flags leave no selected save");

    otherPlayer seedSave(0);
    self savePosition_initClient();
    check(self savePosition_selectWithoutFlag(excludedFlag, otherPlayer getEntityNumber())
        == level.saveNativeSelected,
        "another player's matching save can be selected");
    check(self savePosition_getOrigin() == (100, 200, 700), "borrowed position is readable");
    check(self savePosition_selectSave(0) == level.saveNativeEmpty, "empty own history reports empty");
    check(!isDefined(self savePosition_getOrigin()), "empty own history clears borrowed selection");

    self savePosition_selectWithoutFlag(excludedFlag, otherPlayer getEntityNumber());
    otherPlayer savePosition_initClient();
    check(!isDefined(self savePosition_getOrigin()), "freeing an owner clears borrowed selection");
}

verifyNonPlayerCalls()
{
    entity = spawn("script_origin", (0, 0, 700));
    check(!isDefined(entity savePosition_historyInfo()), "non-player history read rejected");
    check(!isDefined(entity savePosition_save()), "non-player save rejected");
    check(!isDefined(entity savePosition_addOlder()), "non-player older insertion rejected");
    check(!isDefined(entity savePosition_selectSave(0)), "non-player selection rejected");
    check(!isDefined(entity savePosition_selectWithoutFlag(1)), "non-player flag selection rejected");
    check(!isDefined(entity savePosition_getOrigin()), "non-player origin read rejected");
    check(!isDefined(entity savePosition_getAngles()), "non-player angles read rejected");
    check(!isDefined(entity savePosition_getFPSMode()), "non-player FPS read rejected");
    check(!isDefined(entity savePosition_getSaveNum()), "non-player number read rejected");
    check(!isDefined(entity savePosition_getFlags()), "non-player flags read rejected");
    check(!isDefined(entity savePosition_getGroundEntity()), "non-player ground entity read rejected");
    check(!isDefined(entity savePosition_getExplosiveJumps()), "non-player explosive count rejected");
    check(!isDefined(entity savePosition_getDoubleExplosives()), "non-player double explosives rejected");
    check(!isDefined(entity savePosition_getCheckpointID()), "non-player checkpoint read rejected");
    entity savePosition_initClient();
    entity delete();
}
