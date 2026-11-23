#include openCJ\util;

onInit()
{
    // These values are mirrored in the graphics menu's client dvar.
    level.visibilityModeNone = 0;
    level.visibilityModeNear = 1;
    level.visibilityModeAll = 2;
    maximumHideRadius = 4096;
    defaultHideRadius = 60;
    openCJ\settings::addSettingBool("hideall", false, "Hide all players", ::_onSettingHideALl);
    openCJ\settings::addSettingBool("hidenear", true, "Hide near players", ::_onSettingHideNear);
    openCJ\settings::addSettingInt(
        "hideradius", 0, maximumHideRadius, defaultHideRadius,
        "Sets your radius for hiding nearby players. Usage !hideradius [0-4096]. 0 hides nobody by proximity. Default 60",
        ::_onSettingHideRadius);
}

_onSettingHideAll(newVal)
{
    mode = level.visibilityModeNone;
    if(newVal)
    {
        mode = level.visibilityModeAll;
    }
    else if(self openCJ\settings::getSetting("hidenear"))
    {
        mode = level.visibilityModeNear;
    }
    self setClientCvar("opencj_gfx_hidemode", mode);
    if(newVal)
    {
        self setHideModeAll();
    }
    else
    {
        if(self openCJ\settings::getSetting("hidenear"))
        {
            self setHideModeNear();
        }
        else
        {
            self setHideModeNone();
        }
    }
}

_onSettingHideNear(newVal)
{
    mode = level.visibilityModeNone;
    if(self openCJ\settings::getSetting("hideall"))
    {
        mode = level.visibilityModeAll;
    }
    else if(newVal)
    {
        mode = level.visibilityModeNear;
    }
    self setClientCvar("opencj_gfx_hidemode", mode);
    if(self openCJ\settings::getSetting("hideall"))
    {
        self setHideModeAll();
    }
    else
    {
        if(newVal)
        {
            self setHideModeNear();
        }
        else
        {
            self setHideModeNone();
        }
    }
}

_onSettingHideRadius(newVal)
{
    self setHideRadius(newVal);
    self setClientCvar("opencj_gfx_hideradius", newVal);
}

onFrame()
{
    updatePlayerVisibility();
    // The native visibility pass rewrites masks every frame. Apply demo hiding
    // afterwards, including for spectators, without changing mute/ignore settings.
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        if(players[i] openCJ\demos::isPlayingDemo())
        {
            players[i] hide();
        }
    }
}

onIgnore(player) //self onIgnore(player) when self ignores a player //also called when loading ignore list from db, and should be called onconnect if someone has the player ignored
{
    self addPlayerToHideList(player getEntityNumber());
}

onUnIgnore(player) //self onUnIgnore(player) when self unignores a player
{
    self removePlayerFromHideList(player getEntityNumber());
}

onMuteChanged(newVal)
{
    self hideForAll(newVal);
}

onPlayerConnect()
{
    self initVisibility();
}