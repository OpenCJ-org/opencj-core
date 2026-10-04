main()
{
    check(!openCJ\fpsRegistration::hasReportedFPS(undefined), "undefined rejected");
    check(!openCJ\fpsRegistration::hasReportedFPS(""), "empty rejected");
    check(openCJ\fpsRegistration::hasReportedFPS("0"), "zero reported, legality separate");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 0) == "hax", "zero still hax");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 500) == "hax", "500 still hax");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 333) == "mix", "333 still mix");

    p = makePlayer("333", 1);
    p openCJ\clientInit::onConnected();
    check(p openCJ\fpsRegistration::canStart(), "existing registration accepted");
    check(!p.fpsRegistrationRequested, "existing FPS not changed by cosmetic setup");
    check(p.clientInitReady && p.fpsTestAttempts == 1, "one combined setup request");

    p = makePlayer("", 1);
    started = getTime();
    p openCJ\clientInit::onConnected();
    check(getTime() - started < 300, "first attempt has no fixed startup delay");
    check(p openCJ\fpsRegistration::canStart() && p.clientInitReady, "fresh FPS and acknowledgement accepted");
    check(p.fpsTestAttempts == 1, "one fast attempt");

    p = makePlayer("", 1);
    p.fpsTestReplyDelay = 0.3;
    p thread openCJ\clientInit::onConnected();
    wait 0.1;
    check(!p openCJ\fpsRegistration::canStart(), "pending blocks spawn");
    p openCJ\fpsRegistration::explainBlocked();
    wait 0.4;
    check(p openCJ\fpsRegistration::canStart(), "response promptly releases spawn");
    check(p.fpsTestMessage == "^2FPS verified. Ready to play.", "waiting has success endpoint");

    p = makePlayer("", 2);
    p.fpsRegistrationSpawnPending = true;
    p thread openCJ\clientInit::onConnected();
    wait 0.1;
    check(!p openCJ\fpsRegistration::canStart(), "lost first request keeps gate closed");
    wait 1.2;
    check(p openCJ\fpsRegistration::canStart(), "second attempt succeeds");
    check(p.fpsTestAttempts == 2 && p.fpsTestSpawns == 1, "held spawn resumes once");
    check(p.fpsTestCvarWrites == 2, "retry does not rearm one-time setup");

    p = makePlayer("", 1);
    p.fpsTestReplyValue = "";
    p openCJ\clientInit::onConnected();
    check(p.clientInitAcknowledged, "menu acknowledgement received");
    check(!p.clientInitReady && !p openCJ\fpsRegistration::canStart(), "acknowledgement alone cannot bypass missing FPS");

    p = makePlayer("", 1);
    p.fpsTestReplyValue = "999";
    p openCJ\clientInit::onConnected();
    check(!p openCJ\fpsRegistration::canStart(), "temporary sentinel cannot enable run");

    p = makePlayer("", 0);
    p thread openCJ\clientInit::onConnected();
    wait 0.1;
    p openCJ\fpsRegistration::explainBlocked();
    wait 3.2;
    check(!p openCJ\fpsRegistration::canStart(), "failure blocks start");
    check(p.fpsTestAttempts == 3, "three bounded attempts");
    check(p.fpsTestSpawns == 0 && !p.clientInitPending, "failure terminates without spawning");
    check(p.fpsTestMessage == "^1Cannot start run: FPS registration failed. Reconnect; contact an admin if it persists.", "terminal failure replaces pending guidance");
    p.fpsTestReportedFPS = "333";
    check(p openCJ\fpsRegistration::canStart(), "late real registration recovers");
    p.fpsTestReportedFPS = "";
    check(!p openCJ\fpsRegistration::canStart(), "later missing field blocks again");

    // A ready flag from an earlier connection is not an acknowledgement event.
    p = makePlayer("333", 0);
    p.clientInitAcknowledged = true;
    p.clientInitReady = true;
    p openCJ\clientInit::onConnected();
    check(!p.clientInitReady && !p.clientInitAcknowledged, "stale readiness does not complete setup");
    check(p openCJ\fpsRegistration::canStart(), "cosmetic failure does not invalidate existing FPS");
    logPrint("[FPSREG_TEST] PASS all assertions" + "\n");
}
makePlayer(value, successAttempt)
{
    p = spawnStruct();
    p.fpsTestReportedFPS = value;
    p.fpsTestSuccessAttempt = successAttempt;
    p.fpsTestAttempts = 0;
    p.fpsTestSpawns = 0;
    p.fpsTestCvarWrites = 0;
    p.fpsTestReplyDelay = 0;
    p.fpsTestReplyValue = "333";
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
