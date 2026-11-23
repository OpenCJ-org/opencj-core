main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.contactFailures = 0;
    level.contactChecks = 0;
    checkContactTiming();
    checkPassedCheckpointTraversal();
    checkLeaderboardKinds();
    checkFutileContacts();
    printf("CHECKPOINT CONTACT COMPLETE failures=" + level.contactFailures +
           " checks=" + level.contactChecks + "\n");
}

checkContactTiming()
{
    player = spawnStruct();
    checkpoint = spawnStruct();
    checkpoint.onGround = true;
    fastVelocity = (351, 0, 0);
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 0, fastVelocity),
          "fast landing starts pending");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 50, fastVelocity),
          "fast 50ms insufficient");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 100, fastVelocity),
          "fast 100ms insufficient");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 149, fastVelocity),
          "fast 149ms insufficient");
    check(player openCJ\checkpoints::contactReady(checkpoint, true, 150, fastVelocity),
          "fast 150ms continuous contact awards");
    check(!player openCJ\checkpoints::contactReady(checkpoint, false, 160, (0, 0, 0)),
          "airborne never receives speed exception");
    check(!isDefined(player.checkpointContact), "airborne clears pending contact");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 200, fastVelocity),
          "new landing starts over");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 400, fastVelocity),
          "missed polls reset contact");
    otherCheckpoint = spawnStruct();
    otherCheckpoint.onGround = true;
    check(!player openCJ\checkpoints::contactReady(otherCheckpoint, true, 450, fastVelocity),
          "different area starts over");
    otherCheckpoint.onGround = false;
    check(player openCJ\checkpoints::contactReady(otherCheckpoint, false, 451, fastVelocity),
          "airborne checkpoint remains immediate");
    check(!isDefined(player.checkpointContact), "airborne award clears pending contact");

    speeds = [];
    speeds[0] = (0, 0, 0);
    speeds[1] = (190, 0, 0);
    speeds[2] = (285, 0, 0);
    speeds[3] = (320, 0, 0);
    speeds[4] = (350, 0, 0);
    speeds[5] = (210, 280, 0);
    speeds[6] = (-210, -280, 0);
    speeds[7] = (0, -350, 250);
    for(i = 0; i < speeds.size; i++)
    {
        check(player openCJ\checkpoints::contactReady(checkpoint, true, 500 + i * 50, speeds[i]),
              "ordinary speed counts at first poll " + i);
        check(!isDefined(player.checkpointContact), "immediate contact clears pending state " + i);
    }
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1000, (350.1, 0, 0)),
          "just above cutoff waits");
    player.checkpointContact = undefined;
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1100, (250, 250, 0)),
          "combined diagonal speed exceeds cutoff");
    check(player openCJ\checkpoints::contactReady(checkpoint, true, 1150, (200, 250, 0)),
          "slowing into ordinary range counts");
    check(!isDefined(player.checkpointContact), "slowing clears pending contact");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1200),
          "unknown speed retains settled landing");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1250),
          "unknown speed still waits");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1300),
          "unknown speed 100ms still waits");
    check(player openCJ\checkpoints::contactReady(checkpoint, true, 1350),
          "unknown speed 150ms counts");
}

checkLeaderboardKinds()
{
    check(openCJ\demos::leaderboardKind(true) == "walkthrough",
          "walkthrough winner takes priority");
    check(openCJ\demos::leaderboardKind(false) == "speedrun",
          "other leaderboard runs stay complete");
}

checkFutileContacts()
{
    checkpoint = spawnStruct();
    checkpoint.onGround = true;
    // Fixed Futile landing geometry; the fixture never reads or edits a database.
    areas = [];
    areas[0] = rectangle(2125.88, 2522.12, -1840.12, 1792.12, 654.125);
    areas[1] = rectangle(3119.88, 3792.12, -1520.12, 768.125, 752.125);
    areas[2] = rectangle(8689.88, 9986.12, -8846.12, -8093.88, -3887.88);
    centers = [];
    centers[0] = (2324, -24, 654.125);
    centers[1] = (3456, -375, 752.125);
    centers[2] = (9338, -8470, -3887.88);
    for(i = 0; i < areas.size; i++)
    {
        check(openCJ\checkpointArea::validate(areas[i]) == "", "Futile area valid " + i);
        check(openCJ\checkpointArea::touchesPlayer(areas[i], centers[i], true, true, 0),
              "Futile grounded center touches " + i);
        check(!openCJ\checkpointArea::touchesPlayer(areas[i], centers[i], false, true, 0),
              "Futile airborne overlap rejected " + i);
        check(
            !openCJ\checkpointArea::touchesPlayer(areas[i], centers[i] + (0, 0, 30), true, true, 0),
            "Futile wrong height rejected " + i);
    }

    checkActualGroundContacts(areas, centers, checkpoint);
}

checkActualGroundContacts(areas, centers, checkpoint)
{
    // Real engine ground/velocity samples on those platforms; no run or DB writes.
    wait 1;
    bot = addTestClient();
    wait .2;
    check(isDefined(bot), "real test client available");
    if(isDefined(bot))
    {
        bot.sessionTeam = "allies";
        bot.sessionState = "playing";
        bot.pers["team"] = "allies";
        for(i = 0; i < centers.size; i++)
        {
            bot spawn(centers[i], (0, 0, 0));
            bot freezeControls(false);
            bot botStop();
            bot setVelocity((0, 0, 0));
            wait .25;
            for(tick = 0; tick < 30; tick++)
            {
                wait .05;
                if(bot isOnGround())
                {
                    break;
                }
            }
            grounded = bot isOnGround();
            printf("CHECKPOINT CONTACT SAMPLE area=" + i + " origin=" + bot.origin +
                   " grounded=" + grounded + " velocity=" + bot getVelocity() + "\n");
            check(grounded, "actual Futile platform supports player " + i);
            check(openCJ\checkpointArea::touchesPlayer(areas[i], bot.origin, grounded, true, 0),
                  "actual Futile player touches area " + i);
            bot setVelocity((320, 0, 0));
            check(bot openCJ\checkpoints::contactReady(checkpoint, grounded, getTime(),
                                                       bot getVelocity()),
                  "real ordinary velocity counts immediately " + i);
            bot setVelocity((500, 0, 0));
            check(!bot openCJ\checkpoints::contactReady(checkpoint, grounded, getTime(),
                                                        bot getVelocity()),
                  "real excess velocity needs settled contact " + i);
            bot.checkpointContact = undefined;
        }
    }
}


rectangle(minX, maxX, minY, maxY, z)
{
    points = [];
    points[0] = (maxX, maxY, z);
    points[1] = (minX, maxY, z);
    points[2] = (minX, minY, z);
    points[3] = (maxX, minY, z);
    return points;
}

check(ok, label)
{
    level.contactChecks++;
    if(!ok)
    {
        level.contactFailures++;
        printf("CHECKPOINT CONTACT FAIL: " + label + "\n");
    }
}

// Rejoining branches must not duplicate their shared ancestors when a save is loaded.
checkPassedCheckpointTraversal()
{
    previousGraph = level.checkpoints_checkpoints;
    previousStart = level.checkpoints_startCheckpoint;
    checkpoints = [];
    for (i = 0; i < 4; i++)
    {
        checkpoint = spawnStruct();
        checkpoint.id = i + 1;
        checkpoint.childs = [];
        checkpoints[i] = checkpoint;
    }
    opening = checkpoints[0];
    leftBranch = checkpoints[1];
    rightBranch = checkpoints[2];
    finish = checkpoints[3];
    opening.childs[0] = leftBranch;
    opening.childs[1] = rightBranch;
    leftBranch.childs[0] = finish;
    rightBranch.childs[0] = finish;
    finish.ender = "synthetic";
    level.checkpoints_checkpoints = checkpoints;
    level.checkpoints_startCheckpoint = spawnStruct();

    // Keep the current checkpoint unchanged so restoration needs no HUD/event callbacks.
    player = spawnStruct();
    player.login_playerID = 1;
    player.settingsLoaded = true;
    player.sessionState = "playing";
    player.playerRuns_runID = 1;
    player.runInstanceNumber = 1;
    player.checkpoints_checkpoint = finish;
    player openCJ\checkpoints::updateCheckpointsForPlayer(finish.id);
    check(player.checkpoints_passed.size == 4, "rejoined branches retain each passed checkpoint once");
    for (i = 0; i < checkpoints.size; i++)
    {
        check(player openCJ\checkpoints::hasPassedCheckpoint(checkpoints[i]),
              "rejoined traversal retains checkpoint " + checkpoints[i].id);
    }

    // An alternative with another parent between it and its leader must still be deduplicated.
    alternative = spawnStruct();
    alternative.id = 5;
    alternative.childs = [];
    alternative.childs[0] = finish;
    alternative.bigBrother = leftBranch;
    level.checkpoints_checkpoints[4] = alternative;
    player openCJ\checkpoints::updateCheckpointsForPlayer(finish.id);
    check(player.checkpoints_passed.size == 4,
          "nonadjacent alternative parents share one passed checkpoint group");
    check(player openCJ\checkpoints::hasPassedCheckpoint(alternative),
          "alternative remains recognized as passed");

    // A malformed cycle must terminate without dropping any reachable checkpoint.
    finish.childs[0] = opening;
    player openCJ\checkpoints::updateCheckpointsForPlayer(finish.id);
    check(player.checkpoints_passed.size == 4, "cyclic ancestry visits each group only once");

    level.checkpoints_checkpoints = previousGraph;
    level.checkpoints_startCheckpoint = previousStart;
}
