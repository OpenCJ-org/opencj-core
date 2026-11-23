main()
{
    wait 1;
    level.failures = 0;
    level.teleportChecks = 0;
    // Measured mp_dark fixtures: a flat platform and a sloped landing.
    floorOrigin = (21168.140625, 383.943176, -2415.875);
    slopeOrigin = (4392.528320, 4160.322266, -735.972107);
    checkFragTapTiming();
    checkPlatformDestinations(floorOrigin, slopeOrigin);
    directions = [];
    directions[0] = (1, 0, 0);
    directions[1] = (-1, 0, 0);
    directions[2] = (0, 1, 0);
    directions[3] = (0, -1, 0);
    checkWallDestinations(slopeOrigin, directions);
    checkLowWallDestinations(floorOrigin, slopeOrigin, directions);
    checkQueuedPlayerTeleport(floorOrigin);
    printf("TELEPORT SELFTEST COMPLETE failures=" + level.failures
           + " checks=" + level.teleportChecks + "\n");
}

checkFragTapTiming()
{
    input = spawnStruct();
    check(!(input openCJ\buttonPress::registerFragTap(1000)), "first tap waits");
    check(input openCJ\buttonPress::registerFragTap(1300), "300 ms accepted");
    check(!(input openCJ\buttonPress::registerFragTap(1400)), "third tap starts new pair");
    check(!(input openCJ\buttonPress::registerFragTap(1701)), "301 ms rejected");
    check(input openCJ\buttonPress::registerFragTap(1800), "late tap starts next pair");
    input openCJ\buttonPress::registerFragTap(2000);
    input openCJ\buttonPress::resetButtons();
    check(!(input openCJ\buttonPress::registerFragTap(2100)), "spawn/demo reset clears pair");
}

checkPlatformDestinations(floorOrigin, slopeOrigin)
{
    noIgnoredEntity = 1023;
    eye = floorOrigin + (0, 0, 60);
    destination = aimTeleportDestination(eye, floorOrigin - (0, 0, 20), noIgnoredEntity);
    check(isDefined(destination), "platform top has safe destination");
    if(isDefined(destination))
    {
        check(abs(destination[0] - floorOrigin[0]) < 0.1
              && abs(destination[1] - floorOrigin[1]) < 0.1, "platform retains aimed XY");
        check(destination[2] > floorOrigin[2] - 0.2 && destination[2] < floorOrigin[2] + 2,
              "feet land just above platform");
    }
    check(!isDefined(aimTeleportDestination(eye, eye + (0, 0, 1), noIgnoredEntity)),
          "no hit does not teleport");
    check(!isDefined(aimTeleportDestination(floorOrigin - (0, 0, 4), eye, noIgnoredEntity)),
          "start in solid rejected");

    // Check the support plane on a slope, where a flat-floor height assertion is wrong.
    eye = slopeOrigin + (0, 0, 60);
    hit = bulletTrace(eye, slopeOrigin - (0, 0, 20), false, undefined);
    destination = aimTeleportDestination(eye, slopeOrigin - (0, 0, 20), noIgnoredEntity);
    check(isDefined(destination), "sloped platform destination found");
    if(isDefined(destination))
    {
        surfaceNormal = hit["normal"];
        centerOffset = destination + (0, 0, 35) - hit["position"];
        clearance = centerOffset[0] * surfaceNormal[0] + centerOffset[1] * surfaceNormal[1]
                    + centerOffset[2] * surfaceNormal[2];
        hullSupport = 15 * (abs(surfaceNormal[0]) + abs(surfaceNormal[1]))
                      + 35 * abs(surfaceNormal[2]);
        check(clearance >= hullSupport + 0.5, "slope leaves full standing hull above surface");
    }
}

checkWallDestinations(slopeOrigin, directions)
{
    noIgnoredEntity = 1023;
    eye = slopeOrigin + (0, 0, 60);
    testedWalls = 0;
    for(i = 0; i < directions.size; i++)
    {
        traceEnd = eye + vectorScale(directions[i], 10000);
        hit = bulletTrace(eye, traceEnd, false, undefined);
        destination = aimTeleportDestination(eye, traceEnd, noIgnoredEntity);
        if(isDefined(destination) && hit["fraction"] < 1 && abs(hit["normal"][2]) < 0.01)
        {
            offset = destination - hit["position"];
            separation = offset[0] * hit["normal"][0] + offset[1] * hit["normal"][1];
            check(separation >= 15.9, "wall destination leaves full hull clearance");
            testedWalls++;
        }
    }
    check(testedWalls > 0, "wall geometry exercised");
}

// Low wall hits above a supporting floor used to leave the feet embedded.
checkLowWallDestinations(floorOrigin, slopeOrigin, directions)
{
    noIgnoredEntity = 1023;
    testedLowWalls = 0;
    probes = [];
    probes[0] = slopeOrigin;
    probes[1] = floorOrigin;
    probes[2] = (-4947.176758, -987.563171, -535.875);
    probes[3] = (-554.897949, -46.286156, -697.875);
    for(probeIndex = 0; probeIndex < probes.size; probeIndex++)
    {
        for(directionIndex = 0; directionIndex < directions.size; directionIndex++)
        {
            eye = probes[probeIndex] + (0, 0, 4);
            traceEnd = eye + vectorScale(directions[directionIndex], 1000);
            hit = bulletTrace(eye, traceEnd, false, undefined);
            if(hit["fraction"] >= 1 || abs(hit["normal"][2]) > 0.01)
            {
                continue;
            }
            destination = aimTeleportDestination(eye, traceEnd, noIgnoredEntity);
            if(!isDefined(destination) || destination[2] <= hit["position"][2] - 34)
            {
                continue;
            }
            supportHit = bulletTrace(
                destination + (0, 0, 1), destination - (0, 0, 4), false, undefined);
            if(supportHit["fraction"] >= 1 || supportHit["normal"][2] < 0.7)
            {
                continue;
            }
            offset = destination - hit["position"];
            clearance = offset[0] * hit["normal"][0] + offset[1] * hit["normal"][1];
            check(clearance >= 15.9, "low wall keeps body outside wall");
            check(destination[2] >= supportHit["position"][2],
                  "low wall feet above supporting platform");
            testedLowWalls++;
        }
    }
    check(testedLowWalls > 0, "low wall and supporting platform exercised");
}

checkQueuedPlayerTeleport(floorOrigin)
{
    player = addTestClient();
    check(isDefined(player), "real test client created");
    if(!isDefined(player))
    {
        return;
    }
    wait 0.2;
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn(floorOrigin + (0, 0, 100), (90, 0, 0));
    player.login_playerID = 1;
    player.settingsLoaded = true;
    player.cheating = false;
    player.eventQueue = [];
    player openCJ\noclip::onPlayerConnect();
    player openCJ\noclip::enableNoclip();
    check(player.noclip && player.cheating, "real player linked in noclip");
    originBefore = player.origin;
    player openCJ\buttonPress::onFragButton();
    player openCJ\buttonPress::onFragButton();
    check(isDefined(player.eventQueue["aimTeleport"]), "double frag queues request");
    check(player.noclip && distance(player.origin, originBefore) < 0.01,
          "input callback does not move or unlink player");
    request = player.eventQueue["aimTeleport"];
    expectedDestination = aimTeleportDestination(
        request.eye, request.eye + vectorScale(anglesToForward(request.angles), 100000),
        player getEntityNumber());
    check(isDefined(expectedDestination), "queued aim has clear destination");
    wait 0.05;
    player openCJ\buttonPress::processFragTeleport();
    check(!player.noclip && player.cheating, "queued teleport exits noclip and retains cheating");
    check(isDefined(expectedDestination) && distance(player.origin, expectedDestination) < 3,
          "real player reaches collision-checked destination");
    check(!isDefined(player.eventQueue["aimTeleport"]), "request consumed once");
    wait 0.1;
    check(isDefined(player), "server survives subsequent movement frames");

    player setOriginAndAngles(floorOrigin + (0, 0, 100), (85, 0, 0));
    player.cheating = false;
    player openCJ\buttonPress::onFragButton();
    player openCJ\buttonPress::onFragButton();
    check(!player.cheating && !player.noclip, "ordinary input callback only queues");
    wait 0.05;
    player openCJ\buttonPress::processFragTeleport();
    check(player.cheating && !player.noclip, "ordinary teleport marks cheating");
    player openCJ\buttonPress::onFragButton();
    player openCJ\buttonPress::onFragButton();
    player openCJ\buttonPress::resetButtons();
    check(!isDefined(player.eventQueue["aimTeleport"]), "lifecycle reset cancels queued teleport");
}

check(passed, message)
{
    level.teleportChecks++;
    if(!passed)
    {
        level.failures++;
    }
    printf("TELEPORT SELFTEST " + message + ": " + passed + "\n");
}
