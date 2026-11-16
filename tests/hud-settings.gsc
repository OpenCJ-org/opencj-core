// Isolated engine fixture: no account/database writes.
main()
{
    level.failures = 0; level.checks = 0; level.commands = [];
    openCJ\settings::onInit();
    openCJ\menus\hudSettings::onInit();
    openCJ\checkpointPointers::onInit();
    openCJ\settings::addSettingInt("fpshud", 0, 2, 0, "", ::changed);
    openCJ\settings::addSettingBool("speedometer", false, "", ::changed);
    openCJ\settings::addSettingBool("poshud", false, "", ::changed);
    openCJ\settings::addSettingString("specfps", 3, 8, "detailed", "", ::changed);
    openCJ\settings::addSettingInt("speclisthud", 0, 5, 4, "", ::changed);
    openCJ\settings::addSettingBool("rpgtiming", false, "", ::changed);
    openCJ\settings::addSettingBool("rpgangle", false, "", ::changed);
    openCJ\settings::addSettingBool("smallcrosshair", false, "", ::changed);
    openCJ\settings::addSettingInt("notify_checkpoint", 0, 3, 1, "", ::changed);
    openCJ\settings::addSettingInt("notify_save", 0, 3, 1, "", ::changed);
    openCJ\settings::addSettingInt("notify_load", 0, 3, 1, "", ::changed);
    openCJ\settings::addSettingInt("notify_results", 1, 3, 1, "", ::changed);
    openCJ\settings::addSettingInt("notify_strength", 1, 3, 1, "", ::changed);
    keys = getArrayKeys(level.settings);
    for (i=0;i<keys.size;i++) level.settings[keys[i]].sessionOnly = true;
    wait 1;
    player = addTestClient(); wait 0.2;
    check(isDefined(player), "test client connected");
    if (!isDefined(player)) { finish(); return; }
    player openCJ\settings::onPlayerConnect();
    player openCJ\checkpointPointers::onPlayerConnect();
    player.sessionState = "spectator";
    player.changeCount = 0;
    player openCJ\menus\hudSettings::handleResponse("fpshud:1");
    check(player.settingValues["fpshud"] == false, "ignore changes before settings load");
    player.settingsLoaded = true;
    // Test the real response listener, including menu-name filtering.
    player thread openCJ\menus\hudSettings::responses();
    wait 0.05;
    player notify("menuresponse", "opencj_graphics", "fpshud:1"); wait 0.05;
    check(player.settingValues["fpshud"] == false, "ignore other menus");
    player notify("menuresponse", "OPENCJ_HUDSETTINGS", "fpshud:1"); wait 0.05;
    check(player.settingValues["fpshud"] == 2 && player.changeCount == 1, "apply one click through saved setting callback");
    player openCJ\menus\hudSettings::handleResponse("fpshud:1");
    check(player.changeCount == 1, "unchanged values do not rerun callback");
    bad = []; bad[0]="fpshud:3"; bad[1]="fpshud:-1"; bad[2]="fpshud:1.0";
    bad[3]="fpshud:01"; bad[4]="fpshud:0:1"; bad[5]="fullbright:1"; bad[6]="fpshud";
    for (i=0;i<bad.size;i++) player openCJ\menus\hudSettings::handleResponse(bad[i]);
    check(player.changeCount == 1 && player.settingValues["fpshud"], "invalid and non-whitelisted responses rejected");
    keys = getArrayKeys(level.hudMenuSettings);
    for (i=0;i<keys.size;i++)
    {
        key=keys[i];values=level.hudMenuSettings[key];
        for(j=0;j<values.size;j++)
        {
            player openCJ\menus\hudSettings::handleResponse(key+":"+j);
            check((""+player.settingValues[key]) == values[j], "choice "+key+":"+j+" applied");
        }
    }
    player openCJ\menus\hudSettings::handleResponse("fpshelper:1");
    check(!isDefined(player.settingValues["fpshelper"]), "paused helper is not exposed");
    player openCJ\menus\hudSettings::handleResponse("speclisthud:6");
    check(player.settingValues["speclisthud"] == 5, "spectator list rejects more than five");
    player openCJ\menus\hudSettings::handleResponse("notify_results:2");
    check(player.settingValues["notify_results"] == 3, "results cannot hide completion text");
    player openCJ\menus\hudSettings::handleResponse("begin");
    check(player.settingValues["notify_results"] == 3, "opening preserves current choices");
    // Real waypoint creation and cleanup, including moving checkpoints.
    player.sessionState = "playing";player.playerRuns_runID=1;player.runInstanceNumber=1;
    player.playerRuns_runFinished=false;player.anyPct=false;
    cp=spawnStruct();cp.origin=player.origin+(100,0,40);cp.endShaderColor="blue";
    cp.routeInfo=spawnStruct();cp.routeInfo.color=(0,0.8,1);
    player.checkpoints_checkpoint=spawnStruct();player.checkpoints_checkpoint.childs=[];
    player.checkpoints_checkpoint.childs[0]=cp;
    player openCJ\menus\hudSettings::handleResponse("checkpointicons:2");
    player openCJ\checkpointPointers::showCheckpointPointers();
    check(isDefined(player.checkpointPointers_huds[0]) && isDefined(player.checkpointPointers_objectives[0]), "all markers creates world and minimap icons");
    check(player.checkpointPointers_huds[0].testOffscreen, "all markers uses offscreen waypoint material");
    check(player.checkpointPointers_huds[0].testShader=="opencj_checkpoint_tint_obj", "all markers uses the 2D material");
    player openCJ\menus\hudSettings::handleResponse("checkpointicons:1");
    check(isDefined(player.checkpointPointers_huds[0]) && !isDefined(player.checkpointPointers_objectives[0]), "locations removes minimap but retains world icon");
    check(!player.checkpointPointers_huds[0].testOffscreen, "locations uses world sprite with no edge clamping");
    check(player.checkpointPointers_huds[0].testShader=="opencj_checkpoint_tint", "locations uses the renderable effect material");
    mover=spawn("script_model",cp.origin);mover.targetname="hud_settings_test_mover";
    cp.platformRef="nhud_settings_test_mover";
    player openCJ\checkpointPointers::showCheckpointPointers();
    wait 0.15;
    check(!isDefined(player.checkpointPointers_objectives[0]), "moving locations does not recreate minimap icon");
    check(!player.checkpointPointers_huds[0].testOffscreen, "moving locations stays in world-sprite mode");
    check(player.checkpointPointers_huds[0].testShader=="opencj_checkpoint_tint", "moving locations retains the effect material");
    player openCJ\menus\hudSettings::handleResponse("checkpointicons:0");
    wait 0.15;
    check(!isDefined(player.checkpointPointers_huds[0]) && !isDefined(player.checkpointPointers_objectives[0]), "off cancels moving updates and removes both icons");
    player openCJ\menus\hudSettings::handleResponse("checkpointicons:2");
    wait 0.15;
    check(isDefined(player.checkpointPointers_huds[0]) && isDefined(player.checkpointPointers_objectives[0]), "all markers restores moving icons");
    check(player.checkpointPointers_huds[0].testShader=="opencj_checkpoint_tint_obj", "switching back restores the 2D material");
    cp.routeInfo=undefined;
    player openCJ\menus\hudSettings::handleResponse("checkpointicons:1");
    check(player.checkpointPointers_huds[0].testShader=="opencj_checkpoint_blue" && !player.checkpointPointers_huds[0].testOffscreen, "legacy locations retains its world effect material");
    player openCJ\checkpointPointers::onRunStopped();
    check(!isDefined(player.checkpointPointers_huds[0]) && !isDefined(player.checkpointPointers_objectives[0]), "run end cleans icons");
    player.sessionState="spectator";
    player openCJ\checkpointPointers::showCheckpointPointers();
    check(!isDefined(player.checkpointPointers_huds[0]), "spectator does not create icons");
    mover delete();
    finish();
}
changed(value) { self.changeCount++; }
check(condition, label)
{
    level.checks++;
    if (!condition) { level.failures++; printf("HUD SELFTEST FAIL "+label+"\n"); }
}
finish()
{
    printf("HUD SELFTEST COMPLETE failures="+level.failures+" checks="+level.checks+"\n");
}

// Fixture-only observation seam forwards both forms to the real engine method.
waypoint(constantSize, offscreen)
{
    self.testOffscreen = isDefined(offscreen);
    if (isDefined(offscreen)) self setWaypoint(constantSize, offscreen);
    else self setWaypoint(constantSize);
}

recordShader(material, width, height)
{
    self.testShader = material;
    self setShader(material, width, height);
}
