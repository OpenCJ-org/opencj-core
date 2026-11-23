#include openCJ\util;

onInit()
{
    // Match the 16 compass slots and leave room in the 31-element HUD snapshot for other UI.
    level.maxCheckpointPointers = 16;
    level.checkpointIconsOff = 0;
    level.checkpointIconsLocations = 1;
    level.checkpointIconsAll = 2;
    if (getCodVersion() == 4)
    {
        precacheShader("opencj_checkpoint_tint");
        precacheShader("opencj_checkpoint_tint_obj");
        level.checkpointPalette = [];
        addPalette("aqua", (0, 0.8, 1));
        addPalette("lime", (0, 1, 0));
        addPalette("gold", (1, 1, 0));
        addPalette("orng", (1, 0.5333, 0));
        addPalette("soft", (1, 0.4667, 0.4667));
        addPalette("dark", (0.6667, 0, 0));
        addPalette("lila", (0.6667, 0.3333, 1));
        addPalette("pink", (1, 0.4667, 0.8));
        addPalette("tint", (1, 1, 1));
    }
    level.checkpointShaders = [];
    level.checkpointShaders["blue"] = "opencj_checkpoint_blue";
    level.checkpointShaders["cyan"] = "opencj_checkpoint_cyan";
    level.checkpointShaders["green"] = "opencj_checkpoint_green";
    level.checkpointShaders["orange"] = "opencj_checkpoint_orange";
    level.checkpointShaders["purple"] = "opencj_checkpoint_purple";
    level.checkpointShaders["red"] = "opencj_checkpoint_red";
    level.checkpointShaders["yellow"] = "opencj_checkpoint_yellow";
    level.checkpointShaders["default"] = level.checkpointShaders["blue"];

    level.checkpointShadersObjective = [];
    keys = GetArrayKeys(level.checkpointShaders);
    for (i = 0; i < keys.size; i++)
    {
        level.checkpointShadersObjective[keys[i]] = level.checkpointShaders[keys[i]];
        if (getCodVersion() == 4)
        {
            level.checkpointShadersObjective[keys[i]] += "_obj";
        }
    }

    colors = getArrayKeys(level.checkpointShaders);
    for (i = 0; i < colors.size; i++)
    {
        precacheShader(level.checkpointShaders[colors[i]]);
        precacheShader(level.checkpointShadersObjective[colors[i]]);
    }
}

onPlayerConnect()
{
    if (getCodVersion() == 4)
    {
        // Scale only the offscreen icon away; the engine draws its direction
        // pointer separately. Scale length must be positive (use subpixel fade).
        self setClientCvars("waypointOffscreenScaleLength", "0.001",
                            "waypointOffscreenScaleSmallest", "0", "waypointOffscreenPointerWidth",
                            "25", "waypointOffscreenPointerHeight", "12");
    }
    self.checkpointIconMode = level.checkpointIconsAll;
    self.checkpointPointers_huds = [];
    self.checkpointPointers_objectives = [];
    for (i = 0; i < level.maxCheckpointPointers; i++)
    {
        self objective_player_delete(i);
    }
}

onRunCreated()
{
    // The checkpoint-change callback shows the new run's markers after its graph is ready.
    self _hideCheckpointPointers();
}

onRunStopped()
{
    self _hideCheckpointPointers();
}

onSpawnSpectator()
{
    self _hideCheckpointPointers();
}

onPlayerKilled(inflictor, attacker, damage, meansOfDeath, weapon, vDir, hitLoc, psOffsetTime,
               deathAnimDuration)
{
    self _hideCheckpointPointers();
}

onCheckpointsChanged()
{
    self showCheckpointPointers();
}

onRunFinished(checkpoint)
{
    self _hideCheckpointPointers();
}

showCheckpointPointers()
{
    self notify("checkpoint_pointer_refresh");
    if (isDefined(self.checkpointIconMode) && self.checkpointIconMode == level.checkpointIconsOff)
    {
        self _hideCheckpointPointers();
        return;
    }
    if (self.sessionState != "playing" || self openCJ\checkpointCreation::isEditing() ||
       self openCJ\demos::isPlayingDemo() || !self openCJ\playerRuns::hasRunID() ||
       self openCJ\playerRuns::isRunFinished())
    {
        self _hideCheckpointPointers();
        return;
    }
    checkpoints = self nextVisibleCheckpoints();
    if (checkpoints.size > level.maxCheckpointPointers)
    {
        displayedCheckpoints = [];
        for (i = 0; i < level.maxCheckpointPointers; i++)
        {
            displayedCheckpoints[i] = checkpoints[i];
        }
        // Limit only the view. The full checkpoint graph still controls gameplay.
        checkpoints = displayedCheckpoints;
    }

    for (i = 0; i < checkpoints.size; i++)
    {
        if (i >= self.checkpointPointers_huds.size)
        {
            self.checkpointPointers_huds[self.checkpointPointers_huds.size] =
                self _createNewCheckpointPointerHud();
        }

        appearance = self checkpointAppearance(checkpoints[i]);
        self.checkpointPointers_huds[i] setShader(appearance.worldShader, appearance.markerSize,
                                                  appearance.markerSize);
        self.checkpointPointers_huds[i].color = appearance.color;
        self.checkpointPointers_huds[i].alpha = appearance.alpha;

        // A second material selects DrawOffscreenViewableWaypoint, which clamps
        // icons to the screen. Omitting it selects the actual world-space sprite
        // (CG_AddDrawSurfsFor3dHudElems), clipped by the client's view frustum.
        if (getCodVersion() == 4 && self.checkpointIconMode == level.checkpointIconsAll)
        {
            self.checkpointPointers_huds[i] setWaypoint(true, appearance.worldShader);
        }
        else
        {
            self.checkpointPointers_huds[i] setWaypoint(true);
        }

        if (openCJ\checkpointMoving::isMoving(checkpoints[i]))
        {
            position = openCJ\checkpointMoving::center(checkpoints[i]);
            if (isDefined(position))
            {
                checkpoints[i].origin = position;
            }
        }
        self.checkpointPointers_huds[i].x = checkpoints[i].origin[0];
        self.checkpointPointers_huds[i].y = checkpoints[i].origin[1];
        self.checkpointPointers_huds[i].z = checkpoints[i].origin[2] + 10;

        self updateCompassPointer(i, checkpoints[i].origin, appearance.compassShader);
    }

    self thread _followMovingPointers(checkpoints);

    self removePointersFrom(checkpoints.size);
}

// Route colors choose both a world material and the nearest fixed compass palette entry.
checkpointAppearance(checkpoint)
{
    appearance = spawnStruct();
    shaderColor = openCJ\checkpoints::getCheckpointShaderColor(checkpoint);
    appearance.worldShader = _getShaderHud(shaderColor);
    appearance.compassShader = _getShaderObjective(shaderColor);
    appearance.color = (1, 1, 1);
    routeColored = getCodVersion() == 4 && isDefined(checkpoint.routeInfo);
    if (routeColored)
    {
        // World sprites require an effect material; the 2D material only
        // works in the screen/edge-marker renderer selected below.
        appearance.worldShader = "opencj_checkpoint_tint";
        if (self.checkpointIconMode == level.checkpointIconsAll)
        {
            appearance.worldShader = "opencj_checkpoint_tint_obj";
        }
        appearance.compassShader = paletteShader(checkpoint.routeInfo.color);
        appearance.color = checkpoint.routeInfo.color;
    }

    appearance.markerSize = 5;
    if (routeColored)
    {
        appearance.markerSize = 10;
        if (self.checkpointIconMode == level.checkpointIconsLocations)
        {
            // World sprites appear larger than screen markers at the same size.
            appearance.markerSize = 7;
        }
    }
    if (routeColored)
    {
        appearance.alpha = 1;
    }
    else
    {
        appearance.alpha = 0.5;
    }
    return appearance;
}

// Compass slots are fixed; route tint is represented by the selected palette material.
updateCompassPointer(pointerIndex, position, compassShader)
{
    // Stock compass objectives have no RGB field. Default route colors have
    // matching materials; custom RGB uses the nearest palette arrow here.
    if (pointerIndex < level.maxCheckpointPointers &&
       self.checkpointIconMode == level.checkpointIconsAll)
    {
        self.checkpointPointers_objectives[pointerIndex] = true;
        if (getCodVersion() == 2)
        {
            self objective_player_add(pointerIndex, "current", position, compassShader);
        }
        else
        {
            self objective_player_add(pointerIndex, "active", position, compassShader);
        }
    }
}

// Destroy only this player's surplus indicators, including their compass slots.
removePointersFrom(firstUnusedIndex)
{
    for (i = self.checkpointPointers_huds.size - 1; i >= firstUnusedIndex; i--)
    {
        self.checkpointPointers_huds[i] destroy();
        self.checkpointPointers_huds[i] = undefined;
        if (isDefined(self.checkpointPointers_objectives[i]))
        {
            self objective_player_delete(i);
            self.checkpointPointers_objectives[i] = undefined;
        }
    }
}

// Filter the next areas to the chosen route; any-percent runs can target every finish.
nextVisibleCheckpoints()
{
    if (self openCJ\anyPct::hasAnyPct())
    {
        return openCJ\checkpoints::getAllEndCheckpoints();
    }
    nextCheckpoints = self openCJ\checkpoints::getCurrentChildCheckpoints();
    visibleCheckpoints = [];
    if (!isDefined(nextCheckpoints))
    {
        return visibleCheckpoints;
    }
    for (i = 0; i < nextCheckpoints.size; i++)
    {
        routeName = openCJ\checkpoints::getRouteNameForCheckpoint(nextCheckpoints[i]);
        if (!isDefined(self.route) || !isDefined(routeName) || self.route == routeName)
        {
            visibleCheckpoints[visibleCheckpoints.size] = nextCheckpoints[i];
        }
    }
    return visibleCheckpoints;
}

_getShaderHud(color)
{
    if(isDefined(color) && isDefined(level.checkpointShaders[color]))
    {
        return level.checkpointShaders[color];
    }
    return level.checkpointShaders["default"];
}

_getShaderObjective(color)
{
    if(isDefined(color) && isDefined(level.checkpointShadersObjective[color]))
    {
        return level.checkpointShadersObjective[color];
    }
    return level.checkpointShadersObjective["default"];
}

_hideCheckpointPointers()
{
    self notify("checkpoint_pointer_refresh");
    self removePointersFrom(0);
}

_createNewCheckpointPointerHud()
{
    markerHud = newClientHudElem(self);
    markerHud.alpha = 0.5;
    // Let menus cover world checkpoint indicators, like the stock scoreboard.
    markerHud.foreground = false;
    markerHud.aligny = "top";
    markerHud.alignx = "center";
    return markerHud;
}

addPalette(name, color)
{
    entry = spawnStruct();
    entry.shader = "opencj_checkpoint_" + name + "_obj";
    entry.color = color;
    precacheShader(entry.shader);
    level.checkpointPalette[level.checkpointPalette.size] = entry;
}

paletteShader(color)
{
    nearestColorIndex = 0;
    nearestColorDistanceSquared = 100; // Normalized RGB distances are at most three.
    for(i = 0; i < level.checkpointPalette.size; i++)
    {
        colorDistanceSquared = distanceSquared(color, level.checkpointPalette[i].color);
        if(colorDistanceSquared < nearestColorDistanceSquared)
        {
            nearestColorDistanceSquared = colorDistanceSquared;
            nearestColorIndex = i;
        }
    }
    return level.checkpointPalette[nearestColorIndex].shader;
}

// Update only visible moving markers. Refresh or disconnect cancels this loop before
// its next lookup; HUD coordinates use snapshot deltas, not reliable client commands.
_followMovingPointers(checkpoints)
{
    self endon("disconnect");
    self endon("checkpoint_pointer_refresh");
    movingPointerIndices = [];
    for (i = 0; i < checkpoints.size; i++)
    {
        if (openCJ\checkpointMoving::isMoving(checkpoints[i]))
        {
            movingPointerIndices[movingPointerIndices.size] = i;
        }
    }
    if (!movingPointerIndices.size)
    {
        return;
    }
    movingPointerIntervalSeconds = 0.1;
    while (true)
    {
        wait movingPointerIntervalSeconds;
        for (j = 0; j < movingPointerIndices.size; j++)
        {
            pointerIndex = movingPointerIndices[j];
            checkpoint = checkpoints[pointerIndex];
            position = openCJ\checkpointMoving::center(checkpoint);
            if (!isDefined(self.checkpointPointers_huds[pointerIndex]))
            {
                return;
            }
            if (!isDefined(position))
            {
                self.checkpointPointers_huds[pointerIndex].alpha = 0;
                if (pointerIndex < level.maxCheckpointPointers &&
                   isDefined(self.checkpointPointers_objectives[pointerIndex]))
                {
                    self objective_player_delete(pointerIndex);
                    self.checkpointPointers_objectives[pointerIndex] = undefined;
                }
                continue;
            }
            checkpoint.origin = position;
            self.checkpointPointers_huds[pointerIndex].alpha = 1;
            self.checkpointPointers_huds[pointerIndex].x = position[0];
            self.checkpointPointers_huds[pointerIndex].y = position[1];
            self.checkpointPointers_huds[pointerIndex].z = position[2] + 10;
            compassShader =
                _getShaderObjective(openCJ\checkpoints::getCheckpointShaderColor(checkpoint));
            if (isDefined(checkpoint.routeInfo))
            {
                compassShader = paletteShader(checkpoint.routeInfo.color);
            }
            if (pointerIndex < level.maxCheckpointPointers &&
               self.checkpointIconMode == level.checkpointIconsAll)
            {
                self objective_player_add(pointerIndex, "active", position, compassShader);
                self.checkpointPointers_objectives[pointerIndex] = true;
            }
        }
    }
}

// Recreate the HUDs when switching between world sprites and edge markers,
// and clear compass objectives before creating the selected representation.
onIconSetting(value)
{
    self.checkpointIconMode = value;
    if (!isDefined(self.checkpointPointers_huds))
    {
        return;
    }
    self _hideCheckpointPointers();
    self showCheckpointPointers();
}
