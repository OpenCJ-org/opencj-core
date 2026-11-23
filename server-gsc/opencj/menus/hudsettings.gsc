#include openCJ\util;

onInit()
{
    if(getCodVersion() == 4)
    {
        precacheMenu("opencj_hudsettings");
        precacheMenu("opencj_exitconfirm");
    }
    // Register after the final settings registry reset in events/init.
    openCJ\settings::addSettingInt("checkpointicons", 0, 2, 2,
                                   "Checkpoint icons: 0 off, 1 locations only, 2 all markers.",
                                   openCJ\checkpointPointers::onIconSetting);
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

addRow(key, values)
{
    level.hudMenuSettings[key] = strTok(values, " ");
}

responses()
{
    self endon("disconnect");
    level endon("game_ended");
    for(;;)
    {
        self waittill("menuresponse", menu, response);
        if(toLower(menu) == "opencj_hudsettings")
        {
            self handleResponse(response);
        }
    }
}

handleResponse(response)
{
    if(!self openCJ\settings::areSettingsLoaded())
    {
        return;
    }
    if(response == "begin")
    {
        self publish();
        return;
    }
    parts = strTok(response, ":");
    if(parts.size != 2 || response != parts[0] + ":" + parts[1] ||
       !isDefined(level.hudMenuSettings[parts[0]]))
    {
        return;
    }
    key = parts[0];
    values = level.hudMenuSettings[key];
    // Match a canonical index, rejecting floats, extra arguments and arbitrary settings.
    for(i = 0; i < values.size; i++)
    {
        if(parts[1] == "" + i)
        {
            value = values[i];
            if(("" + self openCJ\settings::getSetting(key)) != value)
            {
                self openCJ\settings::setSettingByScript(key, value);
            }
            self publishRow(key);
            self setClientCvar("opencj_hud_ready", 1);
            return;
        }
    }
}

publish()
{
    keys = getArrayKeys(level.hudMenuSettings);
    for(i = 0; i < keys.size; i++)
    {
        self publishRow(keys[i]);
    }
    self setClientCvar("opencj_hud_ready", 1);
}

publishRow(key)
{
    values = level.hudMenuSettings[key];
    value = "" + self openCJ\settings::getSetting(key);
    if(key == "specfps" && value == "live")
    {
        value = "detailed";
    }
    for(j = 0; j < values.size; j++)
    {
        if(value == values[j])
        {
            self setClientCvar("opencj_hud_edit_" + key, j);
        }
    }
}
