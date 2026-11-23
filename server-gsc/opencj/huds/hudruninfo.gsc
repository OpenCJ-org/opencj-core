#include openCJ\util;

onInit()
{
    level.runInfoShader["fps_any"] = "opencj_icon_fps_any";
    level.runInfoShader["fps_classic"] = "opencj_icon_fps_classic";
    level.runInfoShader["fps_standard"] = "opencj_icon_fps_standard";
    level.runInfoShader["fps_tutorial"] = "opencj_icon_fps_tutorial";
    level.runInfoShader["ele"] = "opencj_icon_ele";
    level.runInfoShader["anyPct"] = "opencj_icon_anypct";
    level.runInfoShader["halfBeat"] = "opencj_icon_halfbeat";
    level.runInfoShader["hardTAS"] = "opencj_icon_tas";
    level.iconWidth = 16;
    level.fpsIconWidth = 24;
    level.iconHeight = 20;
    // Reserve the statistics column for route names and checkpoint counts.
    // Match its left-aligned UI scale so this gap holds on widescreen too.
    level.firstIconX = 128;
    level.spaceBetweenIcons = 5;
    precacheShader(level.runInfoShader["fps_any"]);
    precacheShader(level.runInfoShader["fps_classic"]);
    precacheShader(level.runInfoShader["fps_standard"]);
    precacheShader(level.runInfoShader["fps_tutorial"]);
    precacheShader(level.runInfoShader["ele"]);
    precacheShader(level.runInfoShader["anyPct"]);
    precacheShader(level.runInfoShader["halfBeat"]);
    precacheShader(level.runInfoShader["hardTAS"]);
}

onRunCreated()
{
}

onRunStarted()
{
}

onRunStopped()
{
    spectators = self getSpectatorList(true);
    for(i = 0; i < spectators.size; i++)
    {
        spectators[i] _hideRunIcons();
        spectators[i] _hideRunStatus();
    }
}

onRunRestored()
{
}

onRunPaused()
{
}

onRunResumed()
{
}

whileAlive()
{
    shouldShowIcons =
        (self openCJ\playerRuns::hasRunID()) && (self openCJ\playerRuns::hasRunStarted());

    spectators = getSpectatorList(true); // true -> also consider yourself a spectator
    for(i = 0; i < spectators.size; i++)
    {
        // Show run status
        spectators[i] _showRunStatus(self);

        // Check if icons should be shown
        if(shouldShowIcons)
        {
            spectators[i] _showRunIcons(self);
        }
        else
        {
            spectators[i] _hideRunIcons();
        }
    }
}

onSpectatorClientChanged(newClient)
{
    if(isDefined(newClient))
    {
        self _showRunIcons(newClient);
        self _showRunStatus(newClient);
    }
    else
    {
        self _hideRunStatus();
        self _hideRunIcons();
    }
}

onSpawnSpectator()
{
    self _hideRunIcons();
    self _hideRunStatus();
}

onSpawnPlayer()
{
    self _showRunIcons(self);
    self _showRunStatus(self);
}

onPlayerConnect()
{
    self _createRunInfoHud();
}

onPlayerKilled(inflictor, attacker, damage, meansOfDeath, weapon, vDir, hitLoc, psOffsetTime,
               deathAnimDuration)
{
    spectators = getSpectatorList(false);
    for(i = 0; i < spectators.size; i++)
    {
        spectators[i] _hideRunIcons();
        spectators[i] _hideRunStatus();
    }
}

_showRunStatus(player)
{
    if(player openCJ\checkpointCreation::isEditing())
    {
        self _hideRunStatus();
        return;
    }
    // Run status
    if(player.sessionState == "playing")
    {
        if(!player openCJ\playerRuns::hasRunID())
        {
            self.hudRunInfo["status"] setText("^1Not in a run");
            self.hudRunInfo["status"].alpha = 1;
        }
        else if(player openCJ\playerRuns::isRunPaused())
        {
            self.hudRunInfo["status"] setText("^5Run is paused");
            self.hudRunInfo["status"].alpha = 1;
        }
        else
        {
            self.hudRunInfo["status"].alpha = 0;
        }
    }
    else
    {
        self.hudRunInfo["status"].alpha = 0;
    }
}

_hideRunStatus()
{
    self.hudRunInfo["status"].alpha = 0;
}

// Keep the FPS badge first, then pack the enabled run modifiers into adjacent slots.
_showRunIcons(player)
{
    if(player openCJ\checkpointCreation::isEditing())
    {
        self _hideRunIcons();
        return;
    }

    FPSMode = player openCJ\fps::getCurrentFPSMode();
    shaderName = "fps_classic";
    // Tutorial chooses FPS for the player, so its badge replaces the FPS category.
    if(player openCJ\tutorial::isTutorialRun())
    {
        shaderName = "fps_tutorial";
    }
    else if(FPSMode == "hax")
    {
        shaderName = "fps_any";
    }
    else if(FPSMode == "mix")
    {
        shaderName = "fps_standard";
    }
    self.hudRunInfo["fps"] setShader(
        level.runInfoShader[shaderName], level.fpsIconWidth, level.iconHeight);
    self.hudRunInfo["fps"].alpha = 1;

    nextIconIndex = 1;
    nextIconIndex = self _updateRunModifier(
        "ele", player openCJ\elevate::hasUsedEle(), nextIconIndex);
    nextIconIndex = self _updateRunModifier(
        "anyPct", player openCJ\anyPct::hasAnyPct(), nextIconIndex);
    nextIconIndex = self _updateRunModifier(
        "halfBeat", player openCJ\halfBeat::isHalfBeatAllowed(), nextIconIndex);
    self _updateRunModifier("hardTAS", player openCJ\tas::hasHardTAS(), nextIconIndex);
}

// Hidden modifiers keep their old position; visible ones consume the next free slot.
_updateRunModifier(iconName, visible, iconIndex)
{
    if(!visible)
    {
        self.hudRunInfo[iconName].alpha = 0;
        return iconIndex;
    }
    self.hudRunInfo[iconName].x = _modifierIconX(iconIndex);
    self.hudRunInfo[iconName].alpha = 1;
    return iconIndex + 1;
}

_modifierIconX(iconIndex)
{
    // The wider FPS badge takes the first slot; later badges use the normal width.
    return level.firstIconX + level.fpsIconWidth - level.iconWidth +
           (level.spaceBetweenIcons + level.iconWidth) * iconIndex;
}

_hideRunIcons()
{
    self.hudRunInfo["fps"].alpha = 0;
    self.hudRunInfo["ele"].alpha = 0;
    self.hudRunInfo["anyPct"].alpha = 0;
    self.hudRunInfo["halfBeat"].alpha = 0;
    self.hudRunInfo["hardTAS"].alpha = 0;
}

_createRunInfoHud()
{
    self.hudRunInfo = [];

    // The following is a HUD in the top of your screen that shows the current run status of the
    // player (Not in a run or Paused. Otherwise nothing is shown)
    self.hudRunInfo["status"] = newClientHudElem(self);
    self.hudRunInfo["status"].horzAlign = "center_safearea";
    self.hudRunInfo["status"].vertAlign = "center_safearea";
    self.hudRunInfo["status"].alignX = "center";
    self.hudRunInfo["status"].alignY = "top";
    self.hudRunInfo["status"].x = 0;
    self.hudRunInfo["status"].y = -150;
    self.hudRunInfo["status"].alpha = 0;
    self.hudRunInfo["status"].archived = false;
    self.hudRunInfo["status"].fontScale = 1.6;
    self.hudRunInfo["status"].hideWhenInMenu = true;

    self _createRunIcon("fps", "fps_classic", level.firstIconX, level.fpsIconWidth);
    self _createRunIcon("ele", "ele", _modifierIconX(1), level.iconWidth);
    self _createRunIcon("anyPct", "anyPct", _modifierIconX(2), level.iconWidth);
    self _createRunIcon("halfBeat", "halfBeat", _modifierIconX(3), level.iconWidth);
    self _createRunIcon("hardTAS", "hardTAS", _modifierIconX(4), level.iconWidth);
}

// Use the normal 640x480 HUD width scale; fullscreen X would stretch icons on widescreen.
_createRunIcon(iconName, shaderName, x, width)
{
    yAboveProgressBar = 467;
    icon = newClientHudElem(self);
    icon.horzAlign = "left";
    icon.vertAlign = "fullscreen";
    icon.alignX = "left";
    icon.alignY = "bottom";
    icon.x = x;
    icon.y = yAboveProgressBar;
    icon.alpha = 0;
    icon.archived = false;
    icon.hideWhenInMenu = true;
    icon setShader(level.runInfoShader[shaderName], width, level.iconHeight);
    self.hudRunInfo[iconName] = icon;
}
