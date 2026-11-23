main()
{
    precacheItem("rpg_mp");
    wait 2;
    if(getCvarInt("opencj_isolated_camera_test") != 1)
    {
        return;
    }
    level.cameraChecks = 0;
    level.cameraFailures = 0;
    level.cameraWrites = [];
    presentationStage = 1;
    restoredStage = 2;
    level.mysql = mysql_init(); // Local escaping handle only; never connect to a database.
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\camera::onInit();
    verifyConnectionDefaults();
    player = addTestClient();
    observer = addTestClient();
    wait 1;
    if(!isDefined(player) || !isDefined(observer))
    {
        check(false, "two isolated test players");
        return;
    }
    player.sessionState = "playing";
    player.sessionTeam = "allies";
    player spawn((0, 0, 100), (0, 0, 0));
    observer.sessionState = "playing";
    observer.sessionTeam = "allies";
    observer spawn((1000, 0, 100), (0, 0, 0));
    player.login_playerID = 7;
    player.adminLevel = 0;
    player openCJ\settings::onPlayerConnect();
    player.settingsLoaded = true;
    observer openCJ\settings::onPlayerConnect();
    player initVisibility();
    observer initVisibility();
    checkpoint = spawnStruct();
    player.checkpoints_checkpoint = checkpoint;
    player.route = "untouched";
    player verifyDefaultsAndHelp();
    player verifyCameraCommands();
    player verifyModesAndProgress(observer, checkpoint);
    player.clientInitPending = true;
    player thread openCJ\camera::onPlayerConnected();
    wait 0.1;
    player.clientInitPending = false;
    wait 0.1;
    check(player demoBeginPresentation(), "begin presentation for visibility test");
    player hide();
    player showToPlayer(player);
    setCvar("opencj_camera_test_stage", presentationStage);
    wait 0.2;
    player demoEndPresentation();
    player.playingDemo = false;
    player show();
    player command("3p", "off");
    player verifyReconnectSettings();
    player animationTest();
    setCvar("opencj_camera_test_stage", restoredStage);
    wait 0.2;
    check(!player openCJ\settings::getSetting("thirdperson"), "return to first-person");
    check(player openCJ\settings::getSetting("thirdpersondistance") == 180 &&
              player openCJ\settings::getSetting("thirdpersonangle") == 90,
          "turning off retains distance and angle");
    for(i = 0; i < level.cameraWrites.size; i++)
    {
        printf("CAMERA SQL " + level.cameraWrites[i] + "\n");
    }
    mysql_close(level.mysql);
    printf("CAMERA TEST COMPLETE failures=" + level.cameraFailures +
           " checks=" + level.cameraChecks + "\n");
}

verifyConnectionDefaults()
{
    check(getCvarInt("cg_thirdPerson") == 0, "server publishes first-person connection default");
    systeminfoConfigstring = 1;
    systeminfo = getConfigStringByIndex(systeminfoConfigstring);
    fields = strTok(systeminfo, "\\");
    firstPersonPublished = false;
    for(i = 0; i + 1 < fields.size; i += 2)
    {
        if(toLower(fields[i]) == "cg_thirdperson" && fields[i + 1] == "0")
        {
            firstPersonPublished = true;
        }
    }
    check(firstPersonPublished, "initial gamestate resets third-person before any player joins");
}

// Exercise default values and the public chat aliases before changing settings.
verifyDefaultsAndHelp()
{
    check(!self openCJ\settings::getSetting("thirdperson"), "first-person default");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 120, "default distance");
    check(self openCJ\settings::getSetting("thirdpersonangle") == 0, "default behind angle");
    check(level.commands["3p"].cmd == level.commands["thirdperson"], "toggle alias");
    check(level.commands["3pdist"].cmd == level.commands["thirdpersondistance"], "distance alias");
    check(level.commands["3pangle"].cmd == level.commands["thirdpersonangle"], "angle alias");
    entries = openCJ\commands_base::availableCommands(0, "3pangle");
    check(entries.size && entries[0].name == "thirdpersonangle", "alias listed in command help");
}

// Boundary values are independent expectations for the public camera commands.
verifyCameraCommands()
{
    self openCJ\camera::apply();
    self command("3p");
    check(self openCJ\settings::getSetting("thirdperson"), "short command toggles on");
    self command("thirdperson", "off");
    check(!self openCJ\settings::getSetting("thirdperson"), "full command turns off");
    self command("thirdpersondistance", "40");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 40,
          "minimum distance accepted");
    self command("3pdist", "300");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 300,
          "maximum distance accepted");
    self command("3pdist", "301");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 300,
          "excessive distance rejected");
    self command("3pdist", "-1");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 300,
          "negative distance rejected");
    self command("3pdist", "abc");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 300,
          "non-numeric distance rejected");
    self command("thirdpersonangle", "359");
    check(self openCJ\settings::getSetting("thirdpersonangle") == 359, "maximum angle accepted");
    self command("3pangle", "360");
    check(self openCJ\settings::getSetting("thirdpersonangle") == 359, "excessive angle rejected");
    self command("3pangle", "-90");
    check(self openCJ\settings::getSetting("thirdpersonangle") == 359, "negative angle rejected");
    self command("3pangle", "0");
    check(self openCJ\settings::getSetting("thirdpersonangle") == 0, "behind angle accepted");
    self command("thirdperson", "invalid");
    check(!self openCJ\settings::getSetting("thirdperson"), "invalid toggle rejected");
}

verifyModesAndProgress(observer, checkpoint)
{
    self.sessionState = "spectator";
    self command("thirdperson", "on");
    check(self openCJ\settings::getSetting("thirdperson"), "spectator may change camera");
    self.sessionState = "playing";
    self.playingDemo = true;
    self command("3pdist", "180");
    self command("3pangle", "90");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 180 &&
              self openCJ\settings::getSetting("thirdpersonangle") == 90,
          "demo viewer may change camera");
    check(!observer openCJ\settings::getSetting("thirdperson"),
          "another player's preference is unaffected");
    check(self.route == "untouched" && self.checkpoints_checkpoint == checkpoint,
          "camera leaves run progress untouched");
}

// Login may restore geometry, but must never restore the session-only enabled toggle.
verifyReconnectSettings()
{
    self command("3p", "on");
    self openCJ\settings::onPlayerConnect();
    check(!self openCJ\settings::getSetting("thirdperson"), "reconnect resets enabled camera");
    level.cameraStoredRows = [];
    level.cameraStoredRows[0] = strTok("thirdperson,1", ",");
    level.cameraStoredRows[1] = strTok("thirdpersondistance,180", ",");
    level.cameraStoredRows[2] = strTok("thirdpersonangle,90", ",");
    self openCJ\settings::loadSettingsFromDatabase();
    check(!self openCJ\settings::getSetting("thirdperson"),
          "old saved toggle cannot re-enable camera on login");
    check(self openCJ\settings::getSetting("thirdpersondistance") == 180 &&
              self openCJ\settings::getSetting("thirdpersonangle") == 90,
          "reconnect loads saved distance and angle");
    self command("3p", "on");
    check(self openCJ\settings::getSetting("thirdperson"),
          "toggle still works after connection reset");
    self command("3p", "off");
}

command(name, value)
{
    args = [];
    args[0] = "say";
    args[1] = "!" + name;
    if(isDefined(value))
    {
        args[2] = value;
    }
    check(self openCJ\commands_base::onPlayerCommand(args), "chat dispatch " + name);
}
check(ok, label)
{
    level.cameraChecks++;
    if(!ok)
    {
        level.cameraFailures++;
    }
    printf("CAMERA TEST " + int(ok) + ": " + label + "\n");
}

// Stored OCJ4 animation reconstruction, including pause/repeated frames,
// backwards seeking, strafe direction and exact restoration after playback.
animationTest()
{
    demoID = 1800000034; // Reserved fixture ID; no gameplay recording is loaded.
    expectedFrameCount = 107; // Eleven movements plus three 32-frame steady segments.
    captureOriginalProbe = 0;
    restoreOriginalProbe = 99;
    landingProbe = 30;
    repeatedLandingProbe = 31;
    runningAfterLandingProbe = 32;
    enterProneProbe = 33;
    crawlingProbe = 34;
    leaveProneProbe = 35;
    standingProbe = 36;
    backwardsSeekProbe = 20;
    pausedProbe = 21;

    createDemo(demoID);
    check(demoDecodeChunk(demoID, "BODY_FIXTURE_HEX") == expectedFrameCount,
          "read existing OCJ4 movement recording");
    self selectPlaybackDemo(demoID);
    presentationAnchor = spawn("script_origin", self.origin);
    self linkTo(presentationAnchor, "", (0, 0, 0), (0, 0, 0));
    cameraAnimationProbe(captureOriginalProbe);
    self demoBeginPresentation();

    expectedAnimations = [];
    expectedAnimations[0] = "stand";
    expectedAnimations[1] = "walk";
    expectedAnimations[2] = "run";
    expectedAnimations[3] = "sprint";
    expectedAnimations[4] = "run";
    expectedAnimations[5] = "run";
    expectedAnimations[6] = "run";
    expectedAnimations[7] = "crouch";
    expectedAnimations[8] = "prone";
    expectedAnimations[9] = "climb";
    expectedAnimations[10] = "jump";
    probeStage = 1;
    firstRunningFrame = 2;
    for(i = 0; i < expectedAnimations.size; i++)
    {
        self demoApplyPresentation();
        cameraAnimationProbe(probeStage, expectedAnimations[i]);
        probeStage++;
        if(i == firstRunningFrame)
        {
            self demoApplyPresentation();
            cameraAnimationProbe(probeStage, expectedAnimations[i]);
            probeStage++;
        }
        self skipPlaybackFrames(1);
    }

    self demoApplyPresentation();
    cameraAnimationProbe(landingProbe, "land");
    self demoApplyPresentation();
    cameraAnimationProbe(repeatedLandingProbe, "land");

    lastLandingRunFrame = 42;
    firstProneFrame = 43;
    lastProneFrame = 74;
    firstStandingFrame = 75;
    lastStandingFrame = 106;
    self seekAndCheckAnimation(lastLandingRunFrame, runningAfterLandingProbe, "run");
    self seekAndCheckAnimation(firstProneFrame, enterProneProbe, "prone");
    self seekAndCheckAnimation(lastProneFrame, crawlingProbe, "crawl");
    self seekAndCheckAnimation(firstStandingFrame, leaveProneProbe, "prone");
    self seekAndCheckAnimation(lastStandingFrame, standingProbe, "stand");
    self seekAndCheckAnimation(firstRunningFrame, backwardsSeekProbe, "run");
    wait 0.1;
    cameraAnimationProbe(pausedProbe, "run");

    self demoEndPresentation();
    cameraAnimationProbe(restoreOriginalProbe);
    self unlink();
    presentationAnchor delete();
    destroyDemo(demoID);
}

// The native seek accepts a relative offset; scenarios identify absolute fixture frames.
seekAndCheckAnimation(frameIndex, probeStage, expectedAnimation)
{
    currentFrame = self skipPlaybackFrames(0);
    self skipPlaybackFrames(frameIndex - currentFrame);
    self demoApplyPresentation();
    cameraAnimationProbe(probeStage, expectedAnimation);
}

// SQL is observed at the boundary so production builders and settings logic still run.
recordSettingWrite(query)
{
    level.cameraWrites[level.cameraWrites.size] = query;
}

readStoredSettings(query)
{
    return level.cameraStoredRows;
}
