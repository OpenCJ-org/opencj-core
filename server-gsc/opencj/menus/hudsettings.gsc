#include openCJ\util;

onInit()
{
    if (getCodVersion() == 4)
    {
        precacheMenu("opencj_hudsettings");
        precacheMenu("opencj_exitconfirm");
    }
    // Register after the final settings reset; checkpointPointers already defines these modes.
    openCJ\settings::addSettingInt(
        "checkpointicons", level.checkpointIconsOff, level.checkpointIconsAll,
        level.checkpointIconsAll, "Checkpoint icons: 0 off, 1 locations only, 2 all markers.",
        openCJ\checkpointPointers::onIconSetting);
    // Choice order matches the client menu. These strings are stored setting values,
    // while responses contain their zero-based positions in each row.
    level.hudMenuSettings = [];
    addRow("fpshud", "0 2 1");
    addRow("speedometer", "0 1");
    addRow("poshud", "0 1");
    addRow("specfps", "off compact detailed");
    addRow("speclisthud", "0 1 2 3 4 5");
    addRow("rpgtiming", "0 1");
    addRow("rpgangle", "0 1");
    addRow("smallcrosshair", "0 1");
    addRow("notify_checkpoint", "0 1 2 3");
    addRow("notify_save", "0 1 2 3");
    addRow("notify_load", "0 1 2 3");
    addRow("notify_results", "1 3");
    addRow("notify_strength", "1 2 3");
    addRow("checkpointicons", "0 1 2");
}

addRow(settingName, choiceValues)
{
    level.hudMenuSettings[settingName] = strTok(choiceValues, " ");
}

responses()
{
    self endon("disconnect");
    level endon("game_ended");
    for (;;)
    {
        self waittill("menuresponse", menu, response);
        if (toLower(menu) == "opencj_hudsettings")
        {
            self handleResponse(response);
        }
    }
}

// Accept only a registered setting row and a canonical choice index.
handleResponse(response)
{
    if (!self openCJ\settings::areSettingsLoaded())
    {
        return;
    }
    if (response == "begin")
    {
        self publish();
        return;
    }
    responseParts = strTok(response, ":");
    if (responseParts.size != 2 || response != responseParts[0] + ":" + responseParts[1] ||
       !isDefined(level.hudMenuSettings[responseParts[0]]))
    {
        return;
    }
    settingName = responseParts[0];
    choiceValues = level.hudMenuSettings[settingName];
    // Match a canonical index, rejecting floats, extra arguments and arbitrary settings.
    for (i = 0; i < choiceValues.size; i++)
    {
        if (responseParts[1] == "" + i)
        {
            selectedValue = choiceValues[i];
            if (("" + self openCJ\settings::getSetting(settingName)) != selectedValue)
            {
                self openCJ\settings::setSettingByScript(settingName, selectedValue);
            }
            self publishRow(settingName);
            self setClientCvar("opencj_hud_ready", 1);
            return;
        }
    }
}

publish()
{
    settingNames = getArrayKeys(level.hudMenuSettings);
    for (i = 0; i < settingNames.size; i++)
    {
        self publishRow(settingNames[i]);
    }
    self setClientCvar("opencj_hud_ready", 1);
}

publishRow(settingName)
{
    choiceValues = level.hudMenuSettings[settingName];
    currentValue = "" + self openCJ\settings::getSetting(settingName);
    if (settingName == "specfps" && currentValue == "live")
    {
        currentValue = "detailed";
    }
    for (j = 0; j < choiceValues.size; j++)
    {
        if (currentValue == choiceValues[j])
        {
            self setClientCvar("opencj_hud_edit_" + settingName, j);
        }
    }
}
