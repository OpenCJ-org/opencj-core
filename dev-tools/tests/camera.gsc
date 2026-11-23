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
    level.mysql = mysql_init(); // Local escaping handle only; never connect to a database.
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\camera::onInit();
    check(getCvarInt("cg_thirdPerson") == 0, "server publishes first-person connection default");
    info = getConfigStringByIndex(1);
    parts = strTok(info, "\\");
    found = false;
    for(i = 0; i + 1 < parts.size; i += 2)
    {
        if(toLower(parts[i]) == "cg_thirdperson" && parts[i + 1] == "0")
        {
            found = true;
        }
    }
    check(found, "initial gamestate resets third-person before any player joins");
    bot = addTestClient();
    other = addTestClient();
    wait 1;
    if(!isDefined(bot) || !isDefined(other))
    {
        check(false, "two isolated test players");
        return;
    }
    bot.sessionState = "playing";
    bot.sessionTeam = "allies";
    bot spawn((0, 0, 100), (0, 0, 0));
    other.sessionState = "playing";
    other.sessionTeam = "allies";
    other spawn((1000, 0, 100), (0, 0, 0));
    bot.login_playerID = 7;
    bot.adminLevel = 0;
    bot openCJ\settings::onPlayerConnect();
    bot.settingsLoaded = true;
    other openCJ\settings::onPlayerConnect();
    bot initVisibility();
    other initVisibility();
    checkpoint = spawnStruct();
    bot.checkpoints_checkpoint = checkpoint;
    bot.route = "untouched";
    check(!bot openCJ\settings::getSetting("thirdperson"), "first-person default");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 120, "default distance");
    check(bot openCJ\settings::getSetting("thirdpersonangle") == 0, "default behind angle");
    check(level.commands["3p"].cmd == level.commands["thirdperson"], "toggle alias");
    check(level.commands["3pdist"].cmd == level.commands["thirdpersondistance"], "distance alias");
    check(level.commands["3pangle"].cmd == level.commands["thirdpersonangle"], "angle alias");
    entries = openCJ\commands_base::availableCommands(0, "3pangle");
    check(entries.size && entries[0].name == "thirdpersonangle", "alias listed in command help");
    bot openCJ\camera::apply();
    bot command("3p");
    check(bot openCJ\settings::getSetting("thirdperson"), "short command toggles on");
    bot command("thirdperson", "off");
    check(!bot openCJ\settings::getSetting("thirdperson"), "full command turns off");
    bot command("thirdpersondistance", "40");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 40,
          "minimum distance accepted");
    bot command("3pdist", "300");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 300,
          "maximum distance accepted");
    bot command("3pdist", "301");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 300,
          "excessive distance rejected");
    bot command("3pdist", "-1");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 300,
          "negative distance rejected");
    bot command("3pdist", "abc");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 300,
          "non-numeric distance rejected");
    bot command("thirdpersonangle", "359");
    check(bot openCJ\settings::getSetting("thirdpersonangle") == 359, "maximum angle accepted");
    bot command("3pangle", "360");
    check(bot openCJ\settings::getSetting("thirdpersonangle") == 359, "excessive angle rejected");
    bot command("3pangle", "-90");
    check(bot openCJ\settings::getSetting("thirdpersonangle") == 359, "negative angle rejected");
    bot command("3pangle", "0");
    check(bot openCJ\settings::getSetting("thirdpersonangle") == 0, "behind angle accepted");
    bot command("thirdperson", "invalid");
    check(!bot openCJ\settings::getSetting("thirdperson"), "invalid toggle rejected");
    bot.sessionState = "spectator";
    bot command("thirdperson", "on");
    check(bot openCJ\settings::getSetting("thirdperson"), "spectator may change camera");
    bot.sessionState = "playing";
    bot.playingDemo = true;
    bot command("3pdist", "180");
    bot command("3pangle", "90");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 180 &&
              bot openCJ\settings::getSetting("thirdpersonangle") == 90,
          "demo viewer may change camera");
    check(!other openCJ\settings::getSetting("thirdperson"),
          "another player's preference is unaffected");
    check(bot.route == "untouched" && bot.checkpoints_checkpoint == checkpoint,
          "camera leaves run progress untouched");
    bot.clientInitPending = true;
    bot thread openCJ\camera::onPlayerConnected();
    wait 0.1;
    bot.clientInitPending = false;
    wait 0.1;
    check(bot demoBeginPresentation(), "begin presentation for visibility test");
    bot hide();
    bot showToPlayer(bot);
    setCvar("opencj_camera_test_stage", 1);
    wait 0.2;
    bot demoEndPresentation();
    bot.playingDemo = false;
    bot show();
    bot command("3p", "off");
    // Reconnect/account load ignores an old enabled toggle but retains geometry.
    bot command("3p", "on");
    bot openCJ\settings::onPlayerConnect();
    check(!bot openCJ\settings::getSetting("thirdperson"), "reconnect resets enabled camera");
    level.cameraStoredRows = [];
    level.cameraStoredRows[0] = strTok("thirdperson,1", ",");
    level.cameraStoredRows[1] = strTok("thirdpersondistance,180", ",");
    level.cameraStoredRows[2] = strTok("thirdpersonangle,90", ",");
    bot openCJ\settings::loadSettingsFromDatabase();
    check(!bot openCJ\settings::getSetting("thirdperson"),
          "old saved toggle cannot re-enable camera on login");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 180 &&
              bot openCJ\settings::getSetting("thirdpersonangle") == 90,
          "reconnect loads saved distance and angle");
    bot command("3p", "on");
    check(bot openCJ\settings::getSetting("thirdperson"),
          "toggle still works after connection reset");
    bot command("3p", "off");
    bot animationTest();
    setCvar("opencj_camera_test_stage", 2);
    wait 0.2;
    check(!bot openCJ\settings::getSetting("thirdperson"), "return to first-person");
    check(bot openCJ\settings::getSetting("thirdpersondistance") == 180 &&
              bot openCJ\settings::getSetting("thirdpersonangle") == 90,
          "turning off retains distance and angle");
    for(i = 0; i < level.cameraWrites.size; i++)
    {
        printf("CAMERA SQL " + level.cameraWrites[i] + "\n");
    }
    mysql_close(level.mysql);
    printf("CAMERA TEST COMPLETE failures=" + level.cameraFailures +
           " checks=" + level.cameraChecks + "\n");
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
    id = 1800000034;
    createDemo(id);
    check(demoDecodeChunk(id, "BODY_FIXTURE_HEX") == 107, "read existing OCJ4 movement recording");
    self selectPlaybackDemo(id);
    linker = spawn("script_origin", self.origin);
    self linkTo(linker, "", (0, 0, 0), (0, 0, 0));
    cameraAnimationProbe(0);
    self demoBeginPresentation();
    labels = [];
    labels[0] = "stand";
    labels[1] = "walk";
    labels[2] = "run";
    labels[3] = "sprint";
    labels[4] = "run";
    labels[5] = "run";
    labels[6] = "run";
    labels[7] = "crouch";
    labels[8] = "prone";
    labels[9] = "climb";
    labels[10] = "jump";
    stage = 1;
    for(i = 0; i < labels.size; i++)
    {
        self demoApplyPresentation();
        cameraAnimationProbe(stage, labels[i]);
        stage++;
        if(i == 2)
        {
            self demoApplyPresentation();
            cameraAnimationProbe(stage, labels[i]);
            stage++;
        }
        self skipPlaybackFrames(1);
    }
    self demoApplyPresentation();
    cameraAnimationProbe(30, "land");
    self demoApplyPresentation();
    cameraAnimationProbe(31, "land");
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(42 - current);
    self demoApplyPresentation();
    cameraAnimationProbe(32, "run");
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(43 - current);
    self demoApplyPresentation();
    cameraAnimationProbe(33, "prone");
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(74 - current);
    self demoApplyPresentation();
    cameraAnimationProbe(34, "crawl");
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(75 - current);
    self demoApplyPresentation();
    cameraAnimationProbe(35, "prone");
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(106 - current);
    self demoApplyPresentation();
    cameraAnimationProbe(36, "stand");
    current = self skipPlaybackFrames(0);
    self skipPlaybackFrames(2 - current);
    self demoApplyPresentation();
    cameraAnimationProbe(20, "run");
    wait 0.1;
    cameraAnimationProbe(21, "run");
    self demoEndPresentation();
    cameraAnimationProbe(99);
    self unlink();
    linker delete();
    destroyDemo(id);
}
