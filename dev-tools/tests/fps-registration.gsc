// Run each handshake scenario in the real VM with only client IO replaced.
main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.fpsRegistrationChecks = 0;
    level.fpsRegistrationFailures = 0;
    verifyReportedFPSClassification();
    verifyExistingRegistration();
    verifyFastFirstReply();
    verifyDelayedReply();
    verifyLostFirstRequest();
    verifyAcknowledgementWithoutFPS();
    verifyTemporaryFPSValue();
    verifyFailureAndLateRecovery();
    verifyStaleReadyFlags();
    printf("FPS REGISTRATION COMPLETE failures=" + level.fpsRegistrationFailures +
           " checks=" + level.fpsRegistrationChecks + "\n");
}

verifyReportedFPSClassification()
{
    check(!openCJ\fpsRegistration::hasReportedFPS(undefined), "undefined rejected");
    check(!openCJ\fpsRegistration::hasReportedFPS(""), "empty rejected");
    check(openCJ\fpsRegistration::hasReportedFPS("0"), "zero reported, legality separate");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 0) == "hax", "zero still hax");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 500) == "hax", "500 still hax");
    check(openCJ\fps::getNewFPSModeStrByFPS(undefined, 333) == "mix", "333 still mix");
}

verifyExistingRegistration()
{
    player = makePlayer("333", 1);
    player openCJ\clientInit::onConnected();
    check(player openCJ\fpsRegistration::canStart(), "existing registration accepted");
    check(!player.fpsRegistrationRequested, "existing FPS not changed by cosmetic setup");
    check(player.clientInitReady && player.fpsTestAttempts == 1, "one combined setup request");
}

verifyFastFirstReply()
{
    player = makePlayer("", 1);
    fastReplyDeadlineMs = 300;
    startedAtMs = getTime();
    player openCJ\clientInit::onConnected();
    check(getTime() - startedAtMs < fastReplyDeadlineMs,
          "first attempt has no fixed startup delay");
    check(player openCJ\fpsRegistration::canStart() && player.clientInitReady,
          "fresh FPS and acknowledgement accepted");
    check(player.fpsTestAttempts == 1, "one fast attempt");
}

verifyDelayedReply()
{
    player = makePlayer("", 1);
    player.fpsTestReplyDelaySeconds = 0.3;
    player thread openCJ\clientInit::onConnected();
    wait 0.1;
    check(!player openCJ\fpsRegistration::canStart(), "pending blocks spawn");
    player openCJ\fpsRegistration::explainBlocked();
    wait 0.4;
    check(player openCJ\fpsRegistration::canStart(), "response promptly releases spawn");
    check(player.fpsTestMessage == "^2FPS verified. Ready to play.",
          "waiting has success endpoint");
}

verifyLostFirstRequest()
{
    player = makePlayer("", 2);
    player.fpsRegistrationSpawnPending = true;
    player thread openCJ\clientInit::onConnected();
    wait 0.1;
    check(!player openCJ\fpsRegistration::canStart(), "lost first request keeps gate closed");
    wait 1.2;
    check(player openCJ\fpsRegistration::canStart(), "second attempt succeeds");
    check(player.fpsTestAttempts == 2 && player.fpsTestSpawns == 1, "held spawn resumes once");
    check(player.fpsTestCvarWrites == 2, "retry does not rearm one-time setup");
}

verifyAcknowledgementWithoutFPS()
{
    player = makePlayer("", 1);
    player.fpsTestReplyValue = "";
    player openCJ\clientInit::onConnected();
    check(player.clientInitAcknowledged, "menu acknowledgement received");
    check(!player.clientInitReady && !player openCJ\fpsRegistration::canStart(),
          "acknowledgement alone cannot bypass missing FPS");
}

verifyTemporaryFPSValue()
{
    player = makePlayer("", 1);
    player.fpsTestReplyValue = "999";
    player openCJ\clientInit::onConnected();
    check(!player openCJ\fpsRegistration::canStart(), "temporary sentinel cannot enable run");
}

verifyFailureAndLateRecovery()
{
    player = makePlayer("", 0);
    player thread openCJ\clientInit::onConnected();
    wait 0.1;
    player openCJ\fpsRegistration::explainBlocked();
    wait 3.2;
    check(!player openCJ\fpsRegistration::canStart(), "failure blocks start");
    check(player.fpsTestAttempts == 3, "three bounded attempts");
    check(player.fpsTestSpawns == 0 && !player.clientInitPending,
          "failure terminates without spawning");
    check(
        player.fpsTestMessage ==
            "^1Cannot start run: FPS registration failed. Reconnect; contact an admin if it persists.",
        "terminal failure replaces pending guidance");
    player.fpsTestReportedFPS = "333";
    check(player openCJ\fpsRegistration::canStart(), "late real registration recovers");
    player.fpsTestReportedFPS = "";
    check(!player openCJ\fpsRegistration::canStart(), "later missing field blocks again");
}

verifyStaleReadyFlags()
{
    // A ready flag from an earlier connection is not an acknowledgement event.
    player = makePlayer("333", 0);
    player.clientInitAcknowledged = true;
    player.clientInitReady = true;
    player openCJ\clientInit::onConnected();
    check(!player.clientInitReady && !player.clientInitAcknowledged,
          "stale readiness does not complete setup");
    check(player openCJ\fpsRegistration::canStart(),
          "cosmetic failure does not invalidate existing FPS");
}
makePlayer(reportedFPS, successAttempt)
{
    player = spawnStruct();
    player.fpsTestReportedFPS = reportedFPS;
    player.fpsTestSuccessAttempt = successAttempt;
    player.fpsTestAttempts = 0;
    player.fpsTestSpawns = 0;
    player.fpsTestCvarWrites = 0;
    player.fpsTestReplyDelaySeconds = 0;
    player.fpsTestReplyValue = "333";
    return player;
}
check(passed, description)
{
    level.fpsRegistrationChecks++;
    if(!isDefined(passed) || !passed)
    {
        level.fpsRegistrationFailures++;
    }
    printf("FPS REGISTRATION " + description + ": " + passed + "\n");
}
