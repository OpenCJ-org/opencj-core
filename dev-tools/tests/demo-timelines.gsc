
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
    bot = addTestClient();
    if(!isDefined(bot))
    {
        check(false, "create test viewer");
        return;
    }
    wait 1;
    bot.sessionState = "playing";
    bot.sessionTeam = "allies";
    bot spawn((0, 0, 100), (0, 0, 0));
    a = 1800000081;
    b = 1800000082;
    createDemo(a);
    createDemo(b);
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
        cp = 17;
        if(i >= 1280)
        {
            cp = 18;
        }
        addFrameToDemo(a, (i % 20, 0, 100), (0, 0, 0), 1, flags, 0, int(i == 40), 0, 125, cp);
        if(i == 39)
        {
            check(demoMarkFailedSince(a, 20) == 40, "load retains failed frames");
        }
    }
    check(numberOfDemoFrames(a) == 1300, "speedrun retains the complete recording");
    for(i = 0; i < 1300; i += 64)
    {
        count = 1300 - i;
        if(count > 64)
        {
            count = 64;
        }
        check(demoDecodeChunk(b, demoEncodeChunk(a, i, count)) == count, "chunk roundtrip");
    }
    bot selectPlaybackDemo(b);
    range = bot demoPlaybackStyle(0, 0, 1299);
    time = bot demoPlaybackTime(0, 1299);
    check(time[1] == 1299, "speedrun duration includes setup and failed attempts");
    bot skipPlaybackFrames(20);
    check(bot readPlaybackFrame_flags() == 0, "speedrun includes failed airborne attempt");
    range = bot demoPlaybackStyle(1, 0, 1299);
    time = bot demoPlaybackTime(0, 1299);
    check(time[1] == 1279, "low-RPG skips failures but keeps setup");
    check(bot skipPlaybackKeyFrames(20) == 40, "successful path crosses failed section");
    range = bot demoPlaybackStyle(2, 0, 1299);
    time = bot demoPlaybackTime(0, 1299);
    check(time[1] == 1279, "walkthrough keeps positioning and removes only failed frames");
    check(bot skipPlaybackFrames(0) == 0, "walkthrough retains approach to save location");
    check(bot skipPlaybackKeyFrames(20) == 40, "walkthrough cuts only the failed attempt");
    check(bot skipPlaybackKeyFrames(1200) == 1240, "walkthrough retains successful jump");
    check(bot demoSeekCheckpoint(1) == 1280, "next checkpoint follows edited timeline");
    check(bot demoSeekCheckpoint(-1) == 0, "previous checkpoint follows edited timeline");
    range = demoFindSegment(b, 17, (0, 0, 100), 0, 1);
    check(isDefined(range) && range[1] == 1289,
          "successful checkpoint segment includes grounded landing tail");
    destroyDemo(a);
    destroyDemo(b);

    // A load at the next checkpoint must not erase the arrival of this jump.
    a = 1800000084;
    createDemo(a);
    for(i = 0; i < 120; i++)
    {
        cp = 17;
        if(i >= 40)
        {
            cp = 18;
        }
        flags = 8192;
        if(i >= 20 && i < 40)
        {
            flags = 0;
        }
        addFrameToDemo(a, (0, 0, 100), (0, 0, 0), 1, flags, 0, int(i == 80), 0, 125, cp);
    }
    bot selectPlaybackDemo(a);
    segment = demoFindSegment(a, 17, (0, 0, 100), 0, 1);
    check(segment[1] == 49, "segment stops after arrival, before later load");
    edited = bot demoPlaybackStyle(2, segment[0], segment[1]);
    check(edited[1] == 49, "walkthrough retains landing despite destination load");
    current = bot skipPlaybackFrames(0);
    bot skipPlaybackFrames(edited[1] - current);
    check((bot readPlaybackFrame_flags() & 8192) != 0, "terminal frame is grounded");
    edited = bot demoPlaybackStyle(2, 40, 119);
    check(edited[0] == 40, "starting at destination preserves successful movement before saves");
    destroyDemo(a);

    // Large platform: entry and setup can be far apart. Unrelated alternatives
    // and airborne fly-bys must still not count as a nearby setup.
    a = 1800000085;
    createDemo(a);
    for(i = 0; i < 40; i++)
    {
        cp = 17;
        if(i >= 30)
        {
            cp = 18;
        }
        flags = 8192;
        if(i >= 20 && i < 30)
        {
            flags = 0;
        }
        addFrameToDemo(a, (i * 50, 0, 100), (0, 0, 0), 1, flags, 0, 0, 0, 125, cp);
    }
    check(isDefined(demoFindSegment(a, 17, (900, 0, 100), 0, 1)),
          "large checkpoint setup matches beyond arrival radius");
    check(!isDefined(demoFindSegment(a, 17, (3000, 0, 100), 0, 1)), "distant alternative rejected");
    check(!isDefined(demoFindSegment(a, 17, (1400, 0, 100), 0, 1)),
          "airborne flyby is not a setup");
    // Stale finish progress after noclip must not select the finish segment.
    cp = spawnStruct();
    cp.id = 17;
    cp.origin = (900, 0, 100);
    cp.radius = 100;
    cp.onGround = true;
    finish = spawnStruct();
    finish.id = 18;
    finish.origin = (3000, 0, 100);
    finish.radius = 100;
    finish.onGround = true;
    level.checkpoints_checkpoints = [];
    level.checkpoints_checkpoints[0] = cp;
    level.checkpoints_checkpoints[1] = finish;
    bot.checkpoints_checkpoint = finish;
    bot setOrigin((900, 0, 100));
    segment = bot openCJ\demos::segmentAtPosition(a, 0, 1);
    check(isDefined(segment) && segment[0] == 0,
          "physical checkpoint overrides stale finished run for lookup");
    check(bot.checkpoints_checkpoint == finish, "lookup does not change run progress");
    destroyDemo(a);

    // Idle pauses on either side of real movement are shortened independently.
    a = 1800000086;
    createDemo(a);
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
        addFrameToDemo(a, (x, 0, 100), (0, 0, 0), 1, 8192, 0, 0, 0, 125, 17);
    }
    bot selectPlaybackDemo(a);
    bot demoPlaybackStyle(2, 0, 119);
    time = bot demoPlaybackTime(0, 119);
    check(time[1] == 26, "two long idle pauses shortened without removing repositioning");
    check(bot skipPlaybackKeyFrames(2) == 48, "first pause retains its end pose");
    check(bot skipPlaybackKeyFrames(1) == 49, "pause ends before movement");
    check(bot skipPlaybackKeyFrames(1) == 50, "first moving frame retained");
    bot demoPlaybackStyle(0, 0, 119);
    time = bot demoPlaybackTime(0, 119);
    check(time[1] == 119, "speedrun retains idle pauses");
    bot demoPlaybackStyle(1, 0, 119);
    time = bot demoPlaybackTime(0, 119);
    check(time[1] == 119, "low-RPG policy unchanged");
    bot demoPlaybackStyle(2, 25, 90);
    time = bot demoPlaybackTime(25, 90);
    check(time[1] > 0, "partial checkpoint segment retains range boundaries");
    destroyDemo(a);
    // Mouse aiming, slow positional drift, airborne motion and short rests stay.
    for(test = 0; test < 4; test++)
    {
        a = 1800000086;
        createDemo(a);
        count = 50;
        if(test == 3)
        {
            count = 10;
        }
        for(i = 0; i < count; i++)
        {
            x = 0;
            yaw = 0;
            flags = 8192;
            if(test == 0)
            {
                yaw = i * 0.1;
            }
            if(test == 1)
            {
                x = i * 0.005;
            }
            if(test == 2)
            {
                flags = 0;
            }
            addFrameToDemo(a, (x, 0, 100), (0, yaw, 0), 1, flags, 0, 0, 0, 125, 17);
        }
        bot selectPlaybackDemo(a);
        bot demoPlaybackStyle(2, 0, count - 1);
        time = bot demoPlaybackTime(0, count - 1);
        check(time[1] == count - 1, "preserve aiming/drift/airborne/brief pause case " + test);
        destroyDemo(a);
    }

    // No ammo bytes are recorded. The renderer gets ammo only during playback.
    a = 1800000083;
    createDemo(a);
    rpg = "rpg_mp";
    bot giveWeapon(rpg);
    bot setSpawnWeapon(rpg);
    bot setWeaponAmmoClip(rpg, 0);
    addFrameToDemo(a, bot.origin, bot getPlayerAngles(), 1, 8192 | 4096, 0, 0, 0, 125, 17,
                   bot getEntityNumber());
    bot selectPlaybackDemo(a);
    check(bot demoBeginPresentation(), "save original presentation");
    check(bot demoApplyPresentation(), "apply RPG presentation");
    check(bot getWeaponAmmoClip(rpg) > 0, "playback supplies ammo for visible rocket");
    bot demoEndPresentation();
    check(bot getWeaponAmmoClip(rpg) == 0, "leaving playback restores exact original ammo");
    destroyDemo(a);
    bot openCJ\demoSelectionTest::run();
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
