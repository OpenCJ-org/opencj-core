
// Isolated in-memory demo tests; never modify live runs or stored demos.
main()
{
    precacheItem("rpg_mp");
    wait 2;
    if(getCvar("opencj_isolated_demo_test") != "1")
    {
        return;
    }
    level.demoTimelineFailures = 0;
    level.demoTimelineChecks = 0;
    viewer = addTestClient();
    if(!isDefined(viewer))
    {
        check(false, "create test viewer");
        reportCompletion();
        return;
    }
    wait 1;
    viewer.sessionState = "playing";
    viewer.sessionTeam = "allies";
    viewer spawn((0, 0, 100), (0, 0, 0));
    verifyTimelineStyles(viewer);
    verifyDestinationLoad(viewer);
    verifyPhysicalSetup(viewer);
    verifyIdleTrimming(viewer);
    verifyActiveMotionRetention(viewer);
    verifyRpgShotWindow(viewer);
    verifySaveMarks();
    verifyAmmoRestoration(viewer);
    viewer openCJ\demoSelectionTest::run();
    reportCompletion();
}

// Compare original, successful-run and walkthrough timelines using the same recording.
verifyTimelineStyles(viewer)
{
    sourceDemoID = 1800000081;
    decodedDemoID = 1800000082;
    createDemo(sourceDemoID);
    createDemo(decodedDemoID);
    for(i = 0; i < 1300; i++)
    {
        flags = 8192;
        if((i >= 20 && i < 40) || (i >= 1240 && i < 1280))
        {
            flags = 0;
        }
        if(i >= 1250 && i < 1253)
        {
            flags = 8192;
        } // Short bunny-hop ground contact.
        checkpointID = 17;
        if(i >= 1280)
        {
            checkpointID = 18;
        }
        addFrameToDemo(sourceDemoID, (i % 20, 0, 100), (0, 0, 0), 1, flags, 0, int(i == 40), 0, 125,
                       checkpointID);
        if(i == 39)
        {
            check(demoMarkFailedSince(sourceDemoID, 20) == 40, "load retains failed frames");
        }
    }
    check(numberOfDemoFrames(sourceDemoID) == 1300, "speedrun retains the complete recording");
    for(i = 0; i < 1300; i += 64)
    {
        chunkFrames = 1300 - i;
        if(chunkFrames > 64)
        {
            chunkFrames = 64;
        }
        check(demoDecodeChunk(decodedDemoID, demoEncodeChunk(sourceDemoID, i, chunkFrames)) ==
                  chunkFrames,
              "chunk roundtrip");
    }
    viewer selectPlaybackDemo(decodedDemoID);
    frameRange = viewer demoPlaybackStyle(0, 0, 1299);
    playbackTiming = viewer demoPlaybackTime(0, 1299);
    check(playbackTiming[1] == 1299, "speedrun duration includes setup and failed attempts");
    viewer skipPlaybackFrames(20);
    check(viewer readPlaybackFrame_flags() == 0, "speedrun includes failed airborne attempt");
    frameRange = viewer demoPlaybackStyle(1, 0, 1299);
    playbackTiming = viewer demoPlaybackTime(0, 1299);
    check(playbackTiming[1] == 1279, "low-RPG skips failures but keeps setup");
    check(viewer skipPlaybackKeyFrames(20) == 40, "successful path crosses failed section");
    // Walkthrough: the failed attempt is cut; the 1169 frames of grounded setup between
    // the load (40) and the run-up (1210) play three times faster; the run-up, the
    // jump and its landing keep their recorded speed.
    frameRange = viewer demoPlaybackStyle(2, 0, 1299);
    playbackTiming = viewer demoPlaybackTime(0, 1299);
    check(playbackTiming[1] == 501, "walkthrough fast-forwards setup, got " + playbackTiming[1]);
    check(viewer skipPlaybackFrames(0) == 0, "walkthrough retains approach to save location");
    check(viewer skipPlaybackKeyFrames(20) == 40, "walkthrough cuts only the failed attempt");
    check(viewer skipPlaybackKeyFrames(2) == 44, "grounded setup plays three frames per step");
    check(viewer skipPlaybackKeyFrames(390) == 1210, "fast-forward ends where the run-up starts");
    check(viewer skipPlaybackKeyFrames(30) == 1240, "run-up keeps its recorded speed");
    check(viewer demoSeekCheckpoint(1) == 1280, "next checkpoint follows edited timeline");
    check(viewer demoSeekCheckpoint(-1) == 0, "previous checkpoint follows edited timeline");
    frameRange = demoFindSegment(decodedDemoID, 17, (0, 0, 100), 0, 1);
    check(isDefined(frameRange) && frameRange[1] == 1289,
          "successful checkpoint segment includes grounded landing tail");
    destroyDemo(sourceDemoID);
    destroyDemo(decodedDemoID);
}

// A later load at the destination must not remove the preceding jump's arrival.
verifyDestinationLoad(viewer)
{
    // A load at the next checkpoint must not erase the arrival of this jump.
    sourceDemoID = 1800000084;
    createDemo(sourceDemoID);
    for(i = 0; i < 120; i++)
    {
        checkpointID = 17;
        if(i >= 40)
        {
            checkpointID = 18;
        }
        flags = 8192;
        if(i >= 20 && i < 40)
        {
            flags = 0;
        }
        addFrameToDemo(sourceDemoID, (0, 0, 100), (0, 0, 0), 1, flags, 0, int(i == 80), 0, 125,
                       checkpointID);
    }
    viewer selectPlaybackDemo(sourceDemoID);
    lessonRange = demoFindSegment(sourceDemoID, 17, (0, 0, 100), 0, 1);
    check(lessonRange[1] == 49, "segment stops after arrival, before later load");
    editedRange = viewer demoPlaybackStyle(2, lessonRange[0], lessonRange[1]);
    check(editedRange[1] == 49, "walkthrough retains landing despite destination load");
    currentFrame = viewer skipPlaybackFrames(0);
    viewer skipPlaybackFrames(editedRange[1] - currentFrame);
    check((viewer readPlaybackFrame_flags() & 8192) != 0, "terminal frame is grounded");
    editedRange = viewer demoPlaybackStyle(2, 40, 119);
    check(editedRange[0] == 40,
          "starting at destination preserves successful movement before saves");
    destroyDemo(sourceDemoID);
}

// Match physical setup near a checkpoint without trusting stale finish progress.
verifyPhysicalSetup(viewer)
{
    // Large platform: entry and setup can be far apart. Unrelated alternatives
    // and airborne fly-bys must still not count as a nearby setup.
    sourceDemoID = 1800000085;
    createDemo(sourceDemoID);
    for(i = 0; i < 40; i++)
    {
        checkpointID = 17;
        if(i >= 30)
        {
            checkpointID = 18;
        }
        flags = 8192;
        if(i >= 20 && i < 30)
        {
            flags = 0;
        }
        addFrameToDemo(sourceDemoID, (i * 50, 0, 100), (0, 0, 0), 1, flags, 0, 0, 0, 125,
                       checkpointID);
    }
    check(isDefined(demoFindSegment(sourceDemoID, 17, (900, 0, 100), 0, 1)),
          "large checkpoint setup matches beyond arrival radius");
    check(!isDefined(demoFindSegment(sourceDemoID, 17, (3000, 0, 100), 0, 1)),
          "distant alternative rejected");
    check(!isDefined(demoFindSegment(sourceDemoID, 17, (1400, 0, 100), 0, 1)),
          "airborne flyby is not a setup");
    // Stale finish progress after noclip must not select the finish segment.
    checkpoint = spawnStruct();
    checkpoint.id = 17;
    checkpoint.origin = (900, 0, 100);
    checkpoint.radius = 100;
    checkpoint.onGround = true;
    finish = spawnStruct();
    finish.id = 18;
    finish.origin = (3000, 0, 100);
    finish.radius = 100;
    finish.onGround = true;
    level.checkpoints_checkpoints = [];
    level.checkpoints_checkpoints[0] = checkpoint;
    level.checkpoints_checkpoints[1] = finish;
    viewer.checkpoints_checkpoint = finish;
    viewer setOrigin((900, 0, 100));
    lessonRange = viewer openCJ\demos::segmentAtPosition(sourceDemoID, 0, 1);
    check(isDefined(lessonRange) && lessonRange[0] == 0,
          "physical checkpoint overrides stale finished run for lookup");
    check(viewer.checkpoints_checkpoint == finish, "lookup does not change run progress");
    destroyDemo(sourceDemoID);
}

// Shorten separate idle periods while preserving the movement between them.
verifyIdleTrimming(viewer)
{
    // Idle pauses on either side of real movement are shortened independently.
    sourceDemoID = 1800000086;
    createDemo(sourceDemoID);
    for(i = 0; i < 120; i++)
    {
        x = 0;
        if(i >= 50)
        {
            x = i - 49;
        }
        if(i >= 70)
        {
            x = 20;
        }
        addFrameToDemo(sourceDemoID, (x, 0, 100), (0, 0, 0), 1, 8192, 0, 0, 0, 125, 17);
    }
    viewer selectPlaybackDemo(sourceDemoID);
    viewer demoPlaybackStyle(2, 0, 119);
    playbackTiming = viewer demoPlaybackTime(0, 119);
    check(playbackTiming[1] == 26, "two long idle pauses shortened without removing repositioning");
    check(viewer skipPlaybackKeyFrames(2) == 48, "first pause retains its end pose");
    check(viewer skipPlaybackKeyFrames(1) == 49, "pause ends before movement");
    check(viewer skipPlaybackKeyFrames(1) == 50, "first moving frame retained");
    viewer demoPlaybackStyle(0, 0, 119);
    playbackTiming = viewer demoPlaybackTime(0, 119);
    check(playbackTiming[1] == 119, "speedrun retains idle pauses");
    viewer demoPlaybackStyle(1, 0, 119);
    playbackTiming = viewer demoPlaybackTime(0, 119);
    check(playbackTiming[1] == 119, "low-RPG policy unchanged");
    viewer demoPlaybackStyle(2, 25, 90);
    playbackTiming = viewer demoPlaybackTime(25, 90);
    check(playbackTiming[1] > 0, "partial checkpoint segment retains range boundaries");
    destroyDemo(sourceDemoID);
}

// Walkthroughs speed up long grounded aiming and drift without skipping more than
// three frames at once; airborne movement and brief pauses keep their speed.
verifyActiveMotionRetention(viewer)
{
    // 50 frames: the range ends stay, the 48 between them play at three frames per step.
    fastForwardedTiming = 18;
    scenarios = [];
    scenarios[0] = "aiming";
    scenarios[1] = "drift";
    scenarios[2] = "airborne";
    scenarios[3] = "brief pause";
    for(scenarioIndex = 0; scenarioIndex < scenarios.size; scenarioIndex++)
    {
        scenario = scenarios[scenarioIndex];
        sourceDemoID = 1800000086;
        createDemo(sourceDemoID);
        frameCount = 50;
        if(scenario == "brief pause")
        {
            frameCount = 10;
        }
        for(i = 0; i < frameCount; i++)
        {
            x = 0;
            yaw = 0;
            flags = 8192;
            if(scenario == "aiming")
            {
                yaw = i * 0.1;
            }
            if(scenario == "drift")
            {
                x = i * 0.005;
            }
            if(scenario == "airborne")
            {
                flags = 0;
            }
            addFrameToDemo(sourceDemoID, (x, 0, 100), (0, yaw, 0), 1, flags, 0, 0, 0, 125, 17);
        }
        viewer selectPlaybackDemo(sourceDemoID);
        viewer demoPlaybackStyle(2, 0, frameCount - 1);
        playbackTiming = viewer demoPlaybackTime(0, frameCount - 1);
        if(scenario == "aiming" || scenario == "drift")
        {
            check(playbackTiming[1] == fastForwardedTiming,
                  "walkthrough speeds up grounded " + scenario + ", got " + playbackTiming[1]);
            check(largestPlaybackStep(viewer, frameCount - 1) <= 3,
                  "sped-up " + scenario + " never skips more than three frames");
        }
        else
        {
            check(playbackTiming[1] == frameCount - 1, "walkthrough preserves " + scenario);
        }
        destroyDemo(sourceDemoID);
    }
}

// The engine remembers the recording length at each save and rewinds to it on load.
verifySaveMarks()
{
    sourceDemoID = 1800000088;
    createDemo(sourceDemoID);
    addGroundFrames(sourceDemoID, 10);
    check(demoRecordSave(sourceDemoID, 1) == 10, "a save remembers the recording length");
    addGroundFrames(sourceDemoID, 10);
    check(demoRecordSave(sourceDemoID, 2) == 20, "a later save remembers the longer length");
    addGroundFrames(sourceDemoID, 10);
    check(demoRecordSave(sourceDemoID, 3) == 30, "a third save is remembered");

    check(demoRewindToSave(sourceDemoID, 2) == 20, "loading save 2 rewinds to its length");
    check(!isDefined(demoRewindToSave(sourceDemoID, 3)),
          "a save after the loaded one is no longer on the kept path");
    check(!isDefined(demoRewindToSave(sourceDemoID, 99)), "an unknown save cannot be rewound to");
    check(demoRewindToSave(sourceDemoID, 1) == 10, "an earlier save is still available");

    addGroundFrames(sourceDemoID, 5);
    check(demoRecordSave(sourceDemoID, 4) == 35,
          "a save after a load records the full recording length, failed frames included");
    check(demoRewindToSave(sourceDemoID, 4) == 35, "the new save can be loaded");
    destroyDemo(sourceDemoID);
}

addGroundFrames(demoID, frameCount)
{
    for(i = 0; i < frameCount; i++)
    {
        addFrameToDemo(demoID, (i, 0, 100), (0, 0, 0), 1, 8192, 0, 0, 0, 125, 17);
    }
}

// RPG shots and the frames around them keep their recorded speed inside long setup.
verifyRpgShotWindow(viewer)
{
    sourceDemoID = 1800000087;
    createDemo(sourceDemoID);
    frameCount = 100;
    shotFrame = 60;
    for(i = 0; i < frameCount; i++)
    {
        addFrameToDemo(sourceDemoID, (i, 0, 100), (0, 0, 0), 1, 8192, 0, 0, int(i == shotFrame), 125,
                       17);
    }
    viewer selectPlaybackDemo(sourceDemoID);
    viewer demoPlaybackStyle(2, 0, frameCount - 1);
    frame = viewer skipPlaybackFrames(0);
    while(frame < shotFrame - 10)
    {
        frame = viewer skipPlaybackKeyFrames(1);
    }
    check(frame == shotFrame - 10, "real-time window starts ten frames before the shot");
    windowIntact = true;
    for(expected = shotFrame - 9; expected <= shotFrame + 10; expected++)
    {
        if(viewer skipPlaybackKeyFrames(1) != expected)
        {
            windowIntact = false;
        }
    }
    check(windowIntact, "every frame around the RPG shot is retained");
    destroyDemo(sourceDemoID);
}

// Largest frame gap between consecutive playback steps up to lastFrame.
largestPlaybackStep(viewer, lastFrame)
{
    viewer skipPlaybackKeyFrames(0 - lastFrame);
    previous = viewer skipPlaybackFrames(0);
    largestStep = 0;
    while(previous < lastFrame)
    {
        current = viewer skipPlaybackKeyFrames(1);
        if(current == previous)
        {
            break;
        }
        if(current - previous > largestStep)
        {
            largestStep = current - previous;
        }
        previous = current;
    }
    return largestStep;
}

// Playback supplies visible rocket ammo and restores the viewer's exact original ammo.
verifyAmmoRestoration(viewer)
{
    // No ammo bytes are recorded. The renderer gets ammo only during playback.
    sourceDemoID = 1800000083;
    createDemo(sourceDemoID);
    rpgWeapon = "rpg_mp";
    viewer giveWeapon(rpgWeapon);
    viewer setSpawnWeapon(rpgWeapon);
    viewer setWeaponAmmoClip(rpgWeapon, 0);
    addFrameToDemo(sourceDemoID, viewer.origin, viewer getPlayerAngles(), 1, 8192 | 4096, 0, 0, 0,
                   125, 17, viewer getEntityNumber());
    viewer selectPlaybackDemo(sourceDemoID);
    check(viewer demoBeginPresentation(), "save original presentation");
    check(viewer demoApplyPresentation(), "apply RPG presentation");
    check(viewer getWeaponAmmoClip(rpgWeapon) > 0, "playback supplies ammo for visible rocket");
    viewer demoEndPresentation();
    check(viewer getWeaponAmmoClip(rpgWeapon) == 0,
          "leaving playback restores exact original ammo");
    destroyDemo(sourceDemoID);
}

// Finish with the actual assertion count, including setup failures.
reportCompletion()
{
    printf("DEMO TIMELINE COMPLETE failures=" + level.demoTimelineFailures +
           " checks=" + level.demoTimelineChecks + "\n");
}

check(ok, label)
{
    level.demoTimelineChecks++;
    if(!ok)
    {
        level.demoTimelineFailures++;
        printf("DEMO TIMELINE FAIL: " + label + "\n");
    }
}
