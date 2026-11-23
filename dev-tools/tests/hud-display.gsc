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
    keys = getArrayKeys(level.settings);
    for(i = 0; i < keys.size; i++)
    {
        level.settings[keys[i]].sessionOnly = true;
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
    player openCJ\settings::setSettingByScript("fpshud", "0");
    check(player.hud["fps"].alpha == 0 && player.testClientDvars["cg_drawfps"] == "0",
          "Off hides both FPS overlays");
    player openCJ\settings::setSettingByScript("fpshud", "2");
    check(player.hud["fps"].alpha == 0 && player.testClientDvars["cg_drawfps"] == "1",
          "Standard enables cg_drawfps 1 only");
    player openCJ\settings::setSettingByScript("fpshud", "1");
    check(player.hud["fps"].alpha == 1 && player.testClientDvars["cg_drawfps"] == "0",
          "OpenCJ enables custom overlay only");
    check(player.hud["fps"].lastText == "250", "OpenCJ displays current FPS");
    player openCJ\settings::setSettingByScript("fpshud", "2");
    player openCJ\settings::setSettingByScript("fpshud", "0");
    check(player.hud["fps"].alpha == 0 && player.testClientDvars["cg_drawfps"] == "0",
          "Standard can switch directly to Off");
    check(openCJ\settings::parseSettingValue(level.settings["fpshud"], "0") == 0 &&
              openCJ\settings::parseSettingValue(level.settings["fpshud"], "1") == 1,
          "old saved FPS preferences retain meanings");

    player openCJ\huds\hudPosition::_createPositionHud();
    names = [];
    names[0] = "x";
    names[1] = "y";
    names[2] = "z";
    names[3] = "angle";
    for(i = 0; i < names.size; i++)
    {
        hud = player.hudPos[names[i]];
        check(hud.x == 80 && hud.y == 8 + 16 * i && abs(hud.fontscale - 1.4) < 0.001 &&
                  hud.font == "default",
              "compact position row " + names[i]);
        check(hud.horzalign == "left" && hud.vertalign == "top" && hud.hideWhenInMenu,
              "position shares minimap anchors and menu visibility");
    }
    player openCJ\huds\hudPosition::_destroyPositionHud();
    check(!isDefined(player.hudPos), "position HUD cleans up");
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
    specs = [];
    for(i = 0; i < 10; i++)
    {
        spec = spawnStruct();
        spec.name = "Spec" + (i + 1);
        specs[i] = spec;
    }
    player.settingValues["speclisthud"] = 5;
    player openCJ\huds\hudSpectatorList::_updateSpecListHud(specs);
    text = player.hud["speclist"].lastText;
    check(isSubStr(text, "Spec5") && !isSubStr(text, "Spec6") && isSubStr(text, "and 5 more"),
          "only five names rendered with remaining count");
    finish();
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
