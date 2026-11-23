// Probe the reported mp_galaxy wall and place a bot to trigger native movement cases.
// Native assertions live in run-sticky-walls-native.py; these rays are diagnostics.
main()
{
    wait 1;
    wallPoint = (-16296, 100312, -24898);
    probeWallRays(wallPoint);
    player = addTestClient();
    if(!isDefined(player))
    {
        printf("STICKY SELFTEST COMPLETE failures=1 reason=missing_test_client\n");
        return;
    }
    wait 1.5;
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player probeWallMovement(wallPoint);
    printf("STICKY SELFTEST COMPLETE failures=0\n");
}

probeWallRays(wallPoint)
{
    rayLength = 128;
    for(height = 0; height <= 60; height += 30)
    {
        rayStart = wallPoint + (0, 0, height);
        for(yaw = 0; yaw < 360; yaw += 45)
        {
            direction = anglesToForward((0, yaw, 0));
            trace = bulletTrace(rayStart, rayStart + direction * rayLength, false, undefined);
            printf("STICKY SELFTEST ray z=" + height + " yaw=" + yaw +
                   " fraction=" + trace["fraction"] + " pos=" + trace["position"] +
                   " normal=" + trace["normal"] + "\n");
        }
    }
}

probeWallMovement(wallPoint)
{
    wallNormal = (0.498964, -0.866622, 0);
    yaw = 120;
    initialHorizontalSpeed = 180;
    initialVerticalSpeed = 50;
    samplesPerOffset = 12;
    sampleSeconds = 0.05;
    offsetStep = 0.125;
    for(offsetIndex = 0; offsetIndex <= 4; offsetIndex++)
    {
        wallOffset = offsetIndex * offsetStep;
        self spawn(wallPoint + wallNormal * wallOffset, (0, yaw, 0));
        self setVelocity(anglesToForward((0, yaw, 0)) * initialHorizontalSpeed +
                         (0, 0, initialVerticalSpeed));
        for(sampleIndex = 0; sampleIndex < samplesPerOffset; sampleIndex++)
        {
            wait sampleSeconds;
            printf("STICKY SELFTEST move offset=" + wallOffset + " yaw=" + yaw + " tick=" +
                   sampleIndex + " pos=" + self.origin + " vel=" + self getVelocity() + "\n");
        }
    }
}
