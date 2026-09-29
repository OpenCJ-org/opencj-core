main()
{
    check(!openCJ\fpsRegistration::hasReportedFPS(undefined), "undefined rejected");
    check(!openCJ\fpsRegistration::hasReportedFPS(""), "empty rejected");
    check(openCJ\fpsRegistration::hasReportedFPS("0"), "zero reported, legality separate");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 0) == "hax", "zero still hax");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 500) == "hax", "500 still hax");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 333) == "mix", "333 still mix");
    p = makePlayer("333", 0);
    p openCJ\fpsRegistration::onConnected();
    check(p openCJ\fpsRegistration::canStart(), "existing registration accepted");
    check(p.fpsTestAttempts == 0, "no menu for existing registration");

    p = makePlayer("", 2);
    p.fpsRegistrationSpawnPending = true;
    p thread openCJ\fpsRegistration::onConnected();
    wait 0.1;
    check(!p openCJ\fpsRegistration::canStart(), "pending blocks start");
    wait 3.2;
    check(p openCJ\fpsRegistration::canStart(), "second attempt succeeds");
    check(p.fpsTestAttempts == 2 && p.fpsTestCloses == 2, "bounded success attempts");
    check(p.fpsTestSpawns == 1, "held spawn resumes once");

    p = makePlayer("", 0);
    p openCJ\fpsRegistration::onConnected();
    check(!p openCJ\fpsRegistration::canStart(), "failure blocks start");
    check(p.fpsTestAttempts == 3 && p.fpsTestCloses == 3, "three attempts on failure");
    check(p.fpsTestSpawns == 0, "no spawn on failure");
    check(p.fpsTestMessage == "^1Cannot start run: FPS registration failed. Reconnect; contact an admin if it persists.", "failure guidance");
    p.fpsTestReportedFPS = "333";
    check(p openCJ\fpsRegistration::canStart(), "late real registration recovers");
    p.fpsTestReportedFPS = "";
    check(!p openCJ\fpsRegistration::canStart(), "later missing field blocks again");
    logPrint("[FPSREG_TEST] PASS all assertions" + "\n");
}
makePlayer(value, successAttempt)
{
    p = spawnStruct();
    p.fpsTestReportedFPS = value;
    p.fpsTestSuccessAttempt = successAttempt;
    p.fpsTestAttempts = 0;
    p.fpsTestCloses = 0;
    p.fpsTestSpawns = 0;
    return p;
}
check(ok, label)
{
    if (!ok)
    {
        logPrint("[FPSREG_TEST] FAIL " + label + "\n");
        assert(false);
    }
}
