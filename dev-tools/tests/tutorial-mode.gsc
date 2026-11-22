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
