#include openCJ\util;

// Tutorial-mode fixture: the tutorial save flag and the native auto-FPS script
// API on a test client. Needs an engine built with server-ext/opencj_autofps.cpp.
// Test clients never send movement commands through the engine hook, so this
// cannot observe a chosen FPS; tutorial-autofps-engine.cpp tests the rule
// itself. Neither proves that a real game client applies com_maxfps.
main()
{
    if (getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.tutorialChecks = 0;
    level.tutorialFailures = 0;

    checkSaveFlag();
    wait 1;
    checkAutoFPSOnTestClient();

    printf("TUTORIAL MODE COMPLETE failures=" + level.tutorialFailures +
           " checks=" + level.tutorialChecks + "\n");
}

checkSaveFlag()
{
    openCJ\savePosition::onInit();
    check(level.saveFlags[level.saveFlagName_tutorial] == 512, "tutorial save flag uses bit 512");

    save = spawnStruct();
    save.flags = 512 | 256 | 1;
    check(openCJ\savePosition::isTutorialRun(save), "tutorial flag read among other flags");
    save.flags = 256 | 128 | 64 | 32 | 8 | 4 | 2 | 1;
    check(!openCJ\savePosition::isTutorialRun(save), "other flags do not mean tutorial");
}

checkAutoFPSOnTestClient()
{
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "test client available");
    if (!isDefined(player))
    {
        return;
    }

    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 700), (0, 0, 0));
    wait 0.05;

    check(player getAutoFPS() == 0, "auto FPS is off by default");
    check(player setAutoFPSEnabled(true), "enabling auto FPS succeeds");
    wait 0.15;
    // Nothing is sent before the client's first movement command.
    check(player getAutoFPS() == 0, "enabled auto FPS has sent nothing yet");
    check(player notifyAutoFPSRPGFired(), "RPG shot notification accepted");
    check(player setAutoFPSEnabled(false), "disabling auto FPS succeeds");
    check(player getAutoFPS() == 0, "disabled auto FPS reports 0");
    checkCheckpointProjection(player);
}

check(passed, label)
{
    level.tutorialChecks++;
    if (passed)
    {
        printf("TUTORIAL MODE PASS: " + label + "\n");
        return;
    }
    level.tutorialFailures++;
    printf("TUTORIAL MODE FAIL: " + label + "\n");
}

// Check the landing target through the production checkpoint selection helper.
checkCheckpointProjection(player)
{
    checkpoint = spawnStruct();
    checkpoint.origin = (10, 20, 30);
    point = player openCJ\tutorial::_nearestCheckpointPoint(checkpoint);
    check(point == checkpoint.origin, "checkpoint without an area uses its origin");

    checkpoint.area = [];
    checkpoint.area[0] = (0, 0, 50);
    checkpoint.area[1] = (100, 0, 50);
    checkpoint.area[2] = (100, 100, 50);
    checkpoint.area[3] = (0, 100, 50);
    player setOrigin((-20, 30, 200));
    point = player openCJ\tutorial::_nearestCheckpointPoint(checkpoint);
    check(distanceSquared(point, (0, 30, 50)) < 0.001,
          "outside player aims at the nearest edge");

    reversedArea = [];
    for(i = 0; i < checkpoint.area.size; i++)
    {
        reversedArea[i] = checkpoint.area[checkpoint.area.size - 1 - i];
    }
    checkpoint.area = reversedArea;
    point = player openCJ\tutorial::_nearestCheckpointPoint(checkpoint);
    check(distanceSquared(point, (0, 30, 50)) < 0.001,
          "reversed polygon keeps the same landing target");

    player setOrigin((40, 60, 200));
    point = player openCJ\tutorial::_nearestCheckpointPoint(checkpoint);
    check(distanceSquared(point, (40, 60, 50)) < 0.001,
          "player above the area keeps its horizontal position");

    checkpoint.area[0] = (0, 0, 0);
    checkpoint.area[1] = (100, 0, 100);
    checkpoint.area[2] = (100, 100, 100);
    checkpoint.area[3] = (0, 100, 0);
    player setOrigin((50, -20, 200));
    point = player openCJ\tutorial::_nearestCheckpointPoint(checkpoint);
    check(distanceSquared(point, (50, 0, 50)) < 0.001,
          "sloped edge interpolates the landing height");

    point = openCJ\tutorial::_nearestPointOnCheckpointEdge(
        (20, 30, 100), (1, 2, 3), (1, 2, 3));
    check(point == (1, 2, 3), "zero-length edge avoids division");
}
