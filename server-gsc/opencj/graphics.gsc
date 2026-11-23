#include openCJ\util;

_configureMinimap()
{
    level.minimapMaxRange = 2500;
    if(!isDefined(getConfigStringByIndex(823))) // 823 is minimap config string number
    {
        setconfigstringbyindex(822, "90"); // Sets north yaw so we can calculate things with it

        minimapTileCount = 2.5; // TODO: dynamically per map
        minimapTileSize = level.minimapMaxRange / minimapTileCount / 2;
        northvector = (cos(getnorthyaw()), sin(getnorthyaw()), 0);
        eastvector = (northvector[1], 0 - northvector[0], 0);
        northwest = VectorScale(northvector, minimapTileSize) +
                    VectorScale(eastvector, -1 * minimapTileSize) +
                    level.spawnpoints_player[0].origin;
        southeast = VectorScale(northvector, -1 * minimapTileSize) +
                    VectorScale(eastvector, minimapTileSize) + level.spawnpoints_player[0].origin;

        setMiniMap("opencj_minimapbg", northwest[0], northwest[1], southeast[0], southeast[1]);
    }
}

onInit()
{
    if(getCodVersion() == 4)
    {
        precacheMenu("opencj_graphics");
    }

    // If map doesn't have a custom minimap, then we set a default
    if(getCodVersion() == 4)
    {
        _configureMinimap();
    }

    underlyingCmd = openCJ\settings::addSettingInt(
        "fov", 13, 160, 90, "Set your field-of-view. Usage: !fov [value between 13 and 160]",
        ::_onSettingFOV);
    underlyingCmd = openCJ\settings::addSettingBool(
        "fullbright", false, "Enable/disable fullbright. Usage: !fullbright [on/off]",
        ::_onSettingFullbright);
    underlyingCmd = openCJ\settings::addSettingBool(
        "hidecollidingplayers", false,
        "Hide colliding players. Usage: !hidecollidingplayers [on/off]");
    underlyingCmd = openCJ\settings::addSettingBool(
        "viewbob", false, "Change view bobbing. Usage: !viewbob [on/off]", ::_onSettingViewBob);
    underlyingCmd = openCJ\settings::addSettingBool("fx", true, "fx_enable. Usage: !fx [on/off]",
                                                    ::_onSettingFX);
    // Negative preferences leave the player's captured client/map defaults alone.
    unsetPreference = -1;
    maximumSpecularMode = 2;
    maximumShadowMode = 2;
    lowestModelDetail = 2;
    maximumMenuDistance = 131072; // Largest draw-distance choice in the graphics menu.
    openCJ\settings::addSettingInt("gfx_specular", unsetPreference, maximumSpecularMode,
                                   unsetPreference, "Graphics menu: specular", ::_gfx_specular);
    openCJ\settings::addSettingInt("gfx_shadows", unsetPreference, maximumShadowMode,
                                   unsetPreference, "Graphics menu: shadows", ::_gfx_shadows);
    openCJ\settings::addSettingInt("gfx_glow", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: glow", ::_gfx_glow);
    openCJ\settings::addSettingInt("gfx_dof", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: dof", ::_gfx_dof);
    openCJ\settings::addSettingInt("gfx_decals", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: decals", ::_gfx_decals);
    openCJ\settings::addSettingInt("gfx_fog", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: fog", ::_gfx_fog);
    openCJ\settings::addSettingInt("gfx_sun", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: sun", ::_gfx_sun);
    openCJ\settings::addSettingInt("gfx_water", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: water", ::_gfx_water);
    openCJ\settings::addSettingInt("gfx_normal", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: normal", ::_gfx_normal);
    openCJ\settings::addSettingInt("gfx_detail", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: detail", ::_gfx_detail);
    openCJ\settings::addSettingInt("gfx_blur", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: blur", ::_gfx_blur);
    openCJ\settings::addSettingInt("gfx_entities", unsetPreference, 1, unsetPreference,
                                   "Graphics menu: entities", ::_gfx_entities);
    openCJ\settings::addSettingInt("gfx_distance", unsetPreference, maximumMenuDistance,
                                   unsetPreference, "Graphics menu: distance", ::_gfx_distance);
    openCJ\settings::addSettingInt("gfx_lod", unsetPreference, lowestModelDetail, unsetPreference,
                                   "Graphics menu: model detail", ::_gfx_lod);
}

onPlayerConnected()
{
    if(getCodVersion() == 4)
    {
        self setClientCvar("compassMaxRange", level.minimapMaxRange);
        self setClientCvar("opencj_gfx_fov", self openCJ\settings::getSetting("fov"));
        self setClientCvar("opencj_gfx_hideradius", self openCJ\settings::getSetting("hideradius"));
        unsetPreference = -1;
        self setClientCvar("opencj_gfx_specular", unsetPreference);
        self setClientCvar("opencj_gfx_shadows", unsetPreference);
        self setClientCvar("opencj_gfx_blur", 1);
        showAllPlayers = 0;
        hideNearbyPlayers = 1;
        hideAllPlayers = 2;
        hideMode = showAllPlayers;
        if(self openCJ\settings::getSetting("hideall"))
        {
            hideMode = hideAllPlayers;
        }
        else if(self openCJ\settings::getSetting("hidenear"))
        {
            hideMode = hideNearbyPlayers;
        }
        self setClientCvar("opencj_gfx_hidemode", hideMode);
        // Map defaults are captured by the acknowledged client startup menu.
        self thread _graphicsMenuResponses();
    }
}

_onSettingFOV(newVal)
{
    self setClientCvar("opencj_gfx_fov", newVal);
    if(newVal > 80)
    {
        self setClientCvar("cg_fovscale", (newVal / 80));
        self setClientCvar("cg_fov", 80);
    }
    else if(newVal < 65)
    {
        self setClientCvar("cg_fovscale", (newVal / 65));
        self setClientCvar("cg_fov", 65);
    }
    else
    {
        self setClientCvar("cg_fovscale", 1);
        self setClientCvar("cg_fov", newVal);
    }
}

_onSettingFullbright(newVal)
{
    if(newVal > 0)
    {
        newVal = 1;
    }
    self setClientCvar("r_fullbright", newVal);
}

_onSettingViewBob(newVal)
{
    if(newVal > 0)
    {
        newVal = 8;
    }
    self setClientCvar("bg_bobmax", newVal);
}

_onSettingFX(newVal)
{
    if(newVal > 0)
    {
        newVal = 1;
    }
    self setClientCvar("fx_enable", newVal);
}

// Keep choices local to this menu listener; reopening or Cancel discards them.
_graphicsMenuResponses()
{
    self endon("disconnect");
    pendingSettings = [];
    for(;;)
    {
        self waittill("menuresponse", menuName, response);
        if(toLower(menuName) != "opencj_graphics")
        {
            continue;
        }
        if(response == "begin" || response == "cancel")
        {
            pendingSettings = [];
            continue;
        }
        if(response == "apply")
        {
            self _applyGraphicsChoices(pendingSettings);
            pendingSettings = [];
            continue;
        }
        pendingSettings = _queueGraphicsChoice(pendingSettings, response);
    }
}

// Settings may still be loading when the menu opens. Never overwrite them early.
_applyGraphicsChoices(pendingSettings)
{
    if(!self openCJ\settings::areSettingsLoaded())
    {
        return;
    }
    settingNames = getArrayKeys(pendingSettings);
    for(i = 0; i < settingNames.size; i++)
    {
        settingName = settingNames[i];
        if(isDefined(pendingSettings[settingName]))
        {
            self openCJ\settings::setSettingByScript(settingName, pendingSettings[settingName]);
        }
    }
}

// Validate one menu selection without changing the player's applied settings.
_queueGraphicsChoice(pendingSettings, response)
{
    responseParts = strTok(response, ":");
    if(responseParts.size != 2 || !isValidInt(responseParts[1]))
    {
        return pendingSettings;
    }
    settingName = responseParts[0];
    valueText = responseParts[1];
    if(settingName == "gfx_hidemode")
    {
        showAllPlayers = 0;
        hideNearbyPlayers = 1;
        hideAllPlayers = 2;
        hideMode = int(valueText);
        if(hideMode >= showAllPlayers && hideMode <= hideAllPlayers)
        {
            pendingSettings["hideall"] = (hideMode == hideAllPlayers);
            pendingSettings["hidenear"] = (hideMode == hideNearbyPlayers);
        }
        return pendingSettings;
    }
    if(!_isGraphicsMenuSetting(settingName))
    {
        return pendingSettings;
    }
    // Zero remains readable for old saved settings, but is not a menu choice.
    if(settingName == "hideradius" && int(valueText) < 1)
    {
        return pendingSettings;
    }
    // The menu's "Current" choice leaves model detail as it was on opening.
    currentModelDetailChoice = "3";
    if(settingName == "gfx_lod" && valueText == currentModelDetailChoice)
    {
        pendingSettings[settingName] = undefined;
        return pendingSettings;
    }
    value = openCJ\settings::parseSettingValue(level.settings[settingName], valueText);
    if(isDefined(value))
    {
        pendingSettings[settingName] = value;
    }
    return pendingSettings;
}

// A registered setting alone does not make it writable through this menu.
_isGraphicsMenuSetting(settingName)
{
    switch(settingName)
    {
        case "fullbright":
        case "fx":
        case "viewbob":
        case "fov":
        case "hideradius":
        case "gfx_specular":
        case "gfx_shadows":
        case "gfx_glow":
        case "gfx_dof":
        case "gfx_decals":
        case "gfx_fog":
        case "gfx_sun":
        case "gfx_water":
        case "gfx_lod":
        case "gfx_normal":
        case "gfx_detail":
        case "gfx_blur":
        case "gfx_entities":
        case "gfx_distance":
        {
            return true;
        }
    }
    return false;
}

_gfx_specular(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("opencj_gfx_specular", value);
    self setClientCvar("r_specular", value != 0);
    whiteSpecularMap = 2;
    if(value == whiteSpecularMap)
    {
        self setClientCvar("r_specularMap", "White");
    }
    else
    {
        self setClientCvar("r_specularMap", "Unchanged");
    }
}

_gfx_shadows(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("opencj_gfx_shadows", value);
    self setClientCvar("sm_enable", value != 0);
    allDynamicShadows = 2;
    if(value == allDynamicShadows)
    {
        self setClientCvar("sm_sunEnable", 1);
        self setClientCvar("sm_spotEnable", 1);
    }
    else
    {
        self execClientCmd(
            "setfromdvar sm_sunEnable opencj_gfx_map_sunShadow; setfromdvar sm_spotEnable opencj_gfx_map_spotShadow");
    }
}

_gfx_glow(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_glow_allowed", value);
}

_gfx_dof(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_dof_enable", value);
}

_gfx_decals(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_drawDecals", value);
    self setClientCvar("fx_marks", value);
}

_gfx_fog(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_fog", value);
}

_gfx_sun(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_drawSun", value);
}

_gfx_water(value)
{
    // No override until the player chooses one.
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_drawWater", value);
}

_gfx_lod(value)
{
    if(value < 0)
    {
        return;
    }
    mediumModelDetail = 1;
    lowModelDetail = 2;
    // Preserve the menu presets: larger scales select simpler distant models.
    rigidScale = 1;
    skinnedScale = 1;
    rigidBias = 0;
    skinnedBias = 0;
    if(value == mediumModelDetail)
    {
        rigidScale = 1.5;
        skinnedScale = 2;
    }
    else if(value == lowModelDetail)
    {
        rigidScale = 2;
        skinnedScale = 4;
        rigidBias = -100;
        skinnedBias = -200;
    }
    self setClientCvar("r_lodScaleRigid", rigidScale);
    self setClientCvar("r_lodScaleSkinned", skinnedScale);
    self setClientCvar("r_lodBiasRigid", rigidBias);
    self setClientCvar("r_lodBiasSkinned", skinnedBias);
}

_gfx_normal(value)
{
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_normal", value);
}

_gfx_detail(value)
{
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_detail", value);
}

_gfx_entities(value)
{
    if(value < 0)
    {
        return;
    }
    self setClientCvar("dynEnt_active", value);
}

_gfx_distance(value)
{
    if(value < 0)
    {
        return;
    }
    self setClientCvar("r_zfar", value);
}

_gfx_blur(value)
{
    if(value < 0)
    {
        return;
    }
    self setClientCvar("opencj_gfx_blur", value);
    if(value == 0)
    {
        self setClientCvar("r_blur", 0);
    }
    else
    {
        self execClientCmd("setfromdvar r_blur opencj_gfx_map_blur");
    }
}
