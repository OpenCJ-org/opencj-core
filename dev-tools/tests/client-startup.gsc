// Exercise startup waiters and disconnect/map cancellation without accounts or SQL.
main()
{
    level.startupFailures = 0;
    level.startupChecks = 0;
    wait 1;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "test client connected");
    if(!isDefined(player))
    {
        finish();
        return;
    }
    player verifyConsumerWait();
    player verifyDisconnectedCamera();
    player verifyMapChangeCancellation();
    finish();
}

verifyConsumerWait()
{
    self.clientInitPending = true;
    level.startupWaitCompleted = false;
    self thread completionWaiter();
    wait 0.1;
    check(!level.startupWaitCompleted, "startup consumers wait for acknowledgement");
    self.clientInitPending = false;
    wait 0.1;
    check(level.startupWaitCompleted, "startup consumers resume after acknowledgement");
}

verifyDisconnectedCamera()
{
    self.clientInitPending = true;
    self.startupCameraWrites = 0;
    self thread openCJ\camera::onPlayerConnected();
    wait 0.1;

    self notify("disconnect");
    self.settingValues = undefined;
    self.clientInitPending = false;
    wait 0.15;

    check(self.startupCameraWrites == 0, "disconnect prevents late camera cvar writes");
}

verifyMapChangeCancellation()
{
    self.clientInitPending = true;
    level.startupWaitCompleted = false;
    self thread completionWaiter();
    wait 0.05;

    level notify("game_ended");
    self.clientInitPending = false;
    wait 0.1;

    check(!level.startupWaitCompleted, "map change cancels pending startup work");
}

completionWaiter()
{
    self endon("disconnect");
    level endon("game_ended");
    self openCJ\clientInit::waitUntilFinished();
    level.startupWaitCompleted = true;
}

// Installed only in the fixture copy; retain the native cvar write when one occurs.
recordCameraSetting(cvarName, value)
{
    self.startupCameraWrites++;
    self setClientCvar(cvarName, value);
}

check(passed, description)
{
    level.startupChecks++;
    if(!isDefined(passed) || !passed)
    {
        level.startupFailures++;
    }
    printf("STARTUP SELFTEST " + description + ": " + passed + "\n");
}

finish()
{
    printf("STARTUP SELFTEST COMPLETE failures=" + level.startupFailures
        + " checks=" + level.startupChecks + "\n");
}
