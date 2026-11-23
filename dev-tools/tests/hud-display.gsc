// Exercise real HUD callbacks in the engine, with no account/database access.
main()
{
    level.failures = 0;
    level.checks = 0;
    level.commands = [];
    openCJ\settings::onInit();
    openCJ\huds\infiniteHuds::onInit();
    openCJ\huds\hudFps::onInit();
    openCJ\huds\hudPosition::onInit();
    openCJ\huds\hudSpectatorList::onInit();
    settingNames = getArrayKeys(level.settings);
    for(i = 0; i < settingNames.size; i++)
    {
        level.settings[settingNames[i]].sessionOnly = true;
    }
    wait 1;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "test client connected");
    if(!isDefined(player))
    {
        finish();
        return;
    }
    player.FPS = 250;
    player.isFirstSpawn = false;
    player.testClientDvars = [];
    player openCJ\settings::onPlayerConnect();
    player.settingsLoaded = true;
    player openCJ\huds\base::onPlayerConnect();
    player openCJ\huds\hudFps::onPlayerConnect();
    player openCJ\huds\hudSpectatorList::onPlayerConnected();
    player verifyFpsPreferences();
    player verifyPositionRows();
    player verifySpectatorLimits();
    finish();
}

verifyFpsPreferences()
{
    self openCJ\settings::setSettingByScript("fpshud", "0");
    check(self.hud["fps"].alpha == 0 && self.testClientDvars["cg_drawfps"] == "0",
          "Off hides both FPS overlays");
    self openCJ\settings::setSettingByScript("fpshud", "2");
    check(self.hud["fps"].alpha == 0 && self.testClientDvars["cg_drawfps"] == "1",
          "Standard enables cg_drawfps 1 only");
    self openCJ\settings::setSettingByScript("fpshud", "1");
    check(self.hud["fps"].alpha == 1 && self.testClientDvars["cg_drawfps"] == "0",
          "OpenCJ enables custom overlay only");
    check(self.hud["fps"].lastText == "250", "OpenCJ displays current FPS");
    self openCJ\settings::setSettingByScript("fpshud", "2");
    self openCJ\settings::setSettingByScript("fpshud", "0");
    check(self.hud["fps"].alpha == 0 && self.testClientDvars["cg_drawfps"] == "0",
          "Standard can switch directly to Off");
    check(openCJ\settings::parseSettingValue(level.settings["fpshud"], "0") == 0 &&
              openCJ\settings::parseSettingValue(level.settings["fpshud"], "1") == 1,
          "old saved FPS preferences retain meanings");
}

verifyPositionRows()
{
    self openCJ\huds\hudPosition::_createPositionHud();
    rowNames = [];
    rowNames[0] = "x";
    rowNames[1] = "y";
    rowNames[2] = "z";
    rowNames[3] = "angle";
    for(i = 0; i < rowNames.size; i++)
    {
        hud = self.hudPos[rowNames[i]];
        check(hud.x == 80 && hud.y == 8 + 16 * i && abs(hud.fontscale - 1.4) < 0.001 &&
                  hud.font == "default",
              "compact position row " + rowNames[i]);
        check(hud.horzalign == "left" && hud.vertalign == "top" && hud.hideWhenInMenu,
              "position shares minimap anchors and menu visibility");
    }
    self openCJ\huds\hudPosition::_destroyPositionHud();
    check(!isDefined(self.hudPos), "position HUD cleans up");
}

verifySpectatorLimits()
{
    check(level.settings["speclisthud"].maxVal == 5, "spectator command capped at five");
    check(!isDefined(openCJ\settings::parseSettingValue(level.settings["speclisthud"], "6")),
          "new spectator limits above five rejected");
    for(i = 6; i <= 10; i++)
    {
        check(openCJ\settings::normalizeStoredValue("speclisthud", "" + i) == "5",
              "legacy spectator limit " + i + " becomes five");
    }
    check(openCJ\settings::normalizeStoredValue("speclisthud", "0") == "0", "legacy Off preserved");
    check(openCJ\settings::normalizeStoredValue("speclisthud", "4") == "4",
          "legacy default preserved");
    check(openCJ\settings::normalizeStoredValue("unrelated", "8") == "8",
          "unrelated stored settings preserved");
    spectators = [];
    for(i = 0; i < 10; i++)
    {
        spectator = spawnStruct();
        spectator.name = "Spec" + (i + 1);
        spectators[i] = spectator;
    }
    self.settingValues["speclisthud"] = 5;
    self openCJ\huds\hudSpectatorList::_updateSpecListHud(spectators);
    spectatorText = self.hud["speclist"].lastText;
    check(isSubStr(spectatorText, "Spec5") && !isSubStr(spectatorText, "Spec6")
          && isSubStr(spectatorText, "and 5 more"),
          "only five names rendered with remaining count");
}

recordClientCvar(name, value)
{
    self.testClientDvars[name] = "" + value;
    self setClientCvar(name, value);
}

check(passed, label)
{
    level.checks++;
    if(!passed)
    {
        level.failures++;
    }
    printf("DISPLAY SELFTEST " + label + ": " + passed + "\n");
}

finish()
{
    printf("DISPLAY SELFTEST COMPLETE failures=" + level.failures + " checks=" + level.checks +
           "\n");
}
