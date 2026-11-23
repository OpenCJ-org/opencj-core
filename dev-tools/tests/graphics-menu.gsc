// Exercise real menu notifications and graphics callbacks without account writes.
main()
{
    level.graphicsChecks = 0;
    level.graphicsFailures = 0;
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    level.spawnpoints_player = [];
    spawnpoint = spawnStruct();
    spawnpoint.origin = (0, 0, 0);
    level.spawnpoints_player[0] = spawnpoint;
    openCJ\graphics::onInit();
    openCJ\settings::addSettingBool("hideall", false, "Fixture visibility");
    openCJ\settings::addSettingBool("hidenear", true, "Fixture visibility");
    openCJ\settings::addSettingInt("hideradius", 0, 1000, 100, "Fixture radius");
    openCJ\settings::addSettingInt("unrelated", 0, 10, 4, "Unrelated setting");
    settingNames = getArrayKeys(level.settings);
    for(i = 0; i < settingNames.size; i++)
    {
        level.settings[settingNames[i]].sessionOnly = true;
    }

    wait 1;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "synthetic client connected");
    if(!isDefined(player))
    {
        finish();
        return;
    }
    player.graphicsCvars = [];
    player openCJ\settings::onPlayerConnect();
    player.settingsLoaded = true;
    player openCJ\graphics::onPlayerConnected();
    wait 0.05;

    player verifyPendingChanges();
    player verifyRejectedInput();
    player verifyVisibilityChoices();
    player verifyGraphicsCallbacks();
    player notify("disconnect");
    finish();
}

verifyPendingChanges()
{
    self respond("begin");
    self respond("fov:110");
    check(self.settingValues["fov"] == 90, "selection stays pending before Apply");
    self respond("apply");
    check(self.settingValues["fov"] == 110, "Apply saves the pending value");
    check(self.graphicsCvars["cg_fov"] == "80", "FOV callback retains the engine base FOV");

    self respond("fov:120");
    self respond("cancel");
    self respond("apply");
    check(self.settingValues["fov"] == 110, "Cancel discards pending values");
    self respond("fov:125");
    self respond("begin");
    self respond("apply");
    check(self.settingValues["fov"] == 110, "reopening discards pending values");

    self respond("fov:130");
    self.settingsLoaded = false;
    self respond("apply");
    self.settingsLoaded = true;
    self respond("apply");
    check(self.settingValues["fov"] == 110, "Apply before settings load discards the edit");

    self notify("menuresponse", "unrelated_menu", "fov:140");
    wait 0.05;
    self respond("apply");
    check(self.settingValues["fov"] == 110, "another menu cannot set graphics preferences");
}

verifyRejectedInput()
{
    responses = [];
    responses[0] = "fov:12junk";
    responses[1] = "fov:4294967296";
    responses[2] = "fov:161";
    responses[3] = "fov:12";
    responses[4] = "fov:100:extra";
    responses[5] = "unrelated:9";
    responses[6] = "missing:1";
    for(i = 0; i < responses.size; i++)
    {
        self respond(responses[i]);
        self respond("apply");
        check(self.settingValues["fov"] == 110 && self.settingValues["unrelated"] == 4,
              "rejected response preserves settings: " + responses[i]);
    }
    self respond("hideradius:0");
    self respond("apply");
    check(self.settingValues["hideradius"] == 100, "zero is not a new menu radius");
    self respond("hideradius:1");
    self respond("apply");
    check(self.settingValues["hideradius"] == 1, "smallest menu radius accepted");
}

verifyVisibilityChoices()
{
    for(mode = 0; mode <= 2; mode++)
    {
        self respond("gfx_hidemode:" + mode);
        self respond("apply");
        check(self.settingValues["hideall"] == (mode == 2)
              && self.settingValues["hidenear"] == (mode == 1),
              "visibility choice updates both settings: " + mode);
    }
    self respond("gfx_hidemode:3");
    self respond("apply");
    check(self.settingValues["hideall"] && !self.settingValues["hidenear"],
          "invalid visibility choice preserves the last applied mode");
}

verifyGraphicsCallbacks()
{
    self respond("gfx_lod:2");
    self respond("gfx_lod:3");
    self respond("apply");
    check(self.settingValues["gfx_lod"] == -1, "current-detail choice discards pending LOD override");

    self respond("gfx_lod:2");
    self respond("gfx_specular:2");
    self respond("gfx_shadows:2");
    self respond("gfx_distance:131072");
    self respond("gfx_blur:0");
    self respond("apply");
    check(self.graphicsCvars["r_lodScaleRigid"] == "2"
          && self.graphicsCvars["r_lodScaleSkinned"] == "4",
          "low model detail uses the established scales");
    check(self.graphicsCvars["r_lodBiasRigid"] == "-100"
          && self.graphicsCvars["r_lodBiasSkinned"] == "-200",
          "low model detail uses the established biases");
    check(self.graphicsCvars["r_specularMap"] == "White", "maximum specular uses the white map");
    check(self.graphicsCvars["sm_sunEnable"] == "1"
          && self.graphicsCvars["sm_spotEnable"] == "1",
          "maximum shadows enables sun and spot shadows");
    check(self.graphicsCvars["r_zfar"] == "131072", "draw-distance upper boundary accepted");
    check(self.graphicsCvars["r_blur"] == "0", "blur can be disabled");

    self respond("gfx_distance:131073");
    self respond("apply");
    check(self.settingValues["gfx_distance"] == 131072, "distance above the limit is rejected");
    self respond("gfx_specular:-1");
    self respond("apply");
    check(self.graphicsCvars["r_specularMap"] == "White", "unset preference does not overwrite client state");
}

respond(response)
{
    self notify("menuresponse", "opencj_graphics", response);
    wait 0.05;
}

// Record the requested client value and retain the real native side effect.
recordGraphicsCvar(cvarName, value)
{
    self.graphicsCvars[cvarName] = "" + value;
    self setClientCvar(cvarName, value);
}

check(passed, description)
{
    level.graphicsChecks++;
    if(!isDefined(passed) || !passed)
    {
        level.graphicsFailures++;
        printf("GRAPHICS MENU FAIL: " + description + "\n");
    }
}

finish()
{
    printf("GRAPHICS MENU COMPLETE failures=" + level.graphicsFailures
           + " checks=" + level.graphicsChecks + "\n");
}
