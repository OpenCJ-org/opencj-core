#include openCJ\util;

// Grounded planar checkpoint routes, with alternatives and shared openings.
// A draft is private to the account/map/route. Publishing is a separate action.
onInit()
{
    if (getCodVersion() != 4)
    {
        return;
    }
    commandDefinition = openCJ\commands_base::registerCommand(
        "checkpoint",
        "!cp <route> [#RRGGBB] (start or continue your draft) | list | reset <route> | split <routes> | merge <routes> | rename <old> <new> | detect | corner | confirm | alternative | area | undo | finish | double | ele | ground | allowsave | height [units] | select <number> | new | discard | edit [number|last] | postsert | presert | insert (help) | replace | delete [area] | test | save | finalize | stop",
        ::command, 0, 17, openCJ\commands_base::checkpointEditorLevel());
    openCJ\commands_base::addAlias(commandDefinition, "cp");
    openCJ\commands_base::addAlias(commandDefinition, "cpc");
}

isEditing()
{
    return isDefined(self.cpc);
}

// Editor permissions are role-based; account IDs do not grant access.
hasEditorAccess()
{
    return self openCJ\login::isLoggedIn() && isDefined(self.adminLevel) &&
           self.adminLevel >= openCJ\commands_base::checkpointEditorLevel();
}

command(commandArguments)
{
    if (self isEditing() && isDefined(self.cpc.finalizing))
    {
        return;
    }
    if (!self hasEditorAccess())
    {
        self iprintln("Checkpoint editing requires admin level 20");
        return;
    }
    if (!getCvarInt("opencj_checkpoint_editor"))
    {
        self iprintln("Enable opencj_checkpoint_editor on the development server first");
        return;
    }
    if (commandArguments.size == 0)
    {
        if (self isEditing())
        {
            self stop();
        }
        else
        {
            self sendLocalChatMessage(
                "Start or continue a draft with !cpc <route>; use !cpc list to see your routes.");
        }
        return;
    }
    if (toLower(commandArguments[0]) == "list")
    {
        self openCJ\checkpointList::show();
        return;
    }
    if (toLower(commandArguments[0]) == "reset")
    {
        if (commandArguments.size != 2)
        {
            self sendLocalChatMessage("Use !cpc reset <route>, for example !cpc reset hard.");
            return;
        }
        self openCJ\checkpointReset::reset(toLower(commandArguments[1]));
        return;
    }
    // Non-command names open the player's existing draft or create a new one.
    commandArguments[0] = toLower(commandArguments[0]);
    commands =
        "|list|reset|rename|split|merge|edit|insert|postsert|presert|replace|deletearea|select|stop|save|finalize|publish|test|finish|double|ele|ground|allowsave|height|undo|discard|alternative|area|detect|corner|confirm|new|previous|next|delete|";
    if ((commandArguments.size == 1 || commandArguments.size == 2) && !isSubStr(commands, "|" + commandArguments[0] + "|"))
    {
        routeName = commandArguments[0];
        if (!_validName(routeName) || self.sessionState != "playing" ||
           self openCJ\demos::isPlayingDemo())
        {
            self iprintln("Spawn first; route names use 1-20 letters, digits, underscores or +");
            return;
        }
        routeHex = undefined;
        if (commandArguments.size == 2)
        {
            routeHex = toLower(commandArguments[1]);
        }
        if (isDefined(routeHex) && !isDefined(routeRGB(routeHex)))
        {
            self iprintln("Use a six-digit color, for example !cpc easy #ffffff");
            return;
        }
        previous = undefined;
        wasNetwork = false;
        if (self isEditing())
        {
            previous = self.cpc.route;
            wasNetwork = isDefined(self.cpc.network);
            if (!self stop(true))
            {
                return;
            }
        }
        self _start(routeName, routeHex);
        if (wasNetwork && self isEditing())
        {
            self sendLocalChatMessage(
                "Network draft saved. Complete all routes, then !cp finalize to make them playable.");
        }
        else if (isDefined(previous) && previous != routeName && self isEditing())
        {
            self sendLocalChatMessage("Opened " + routeName + ". " + previous +
                                      " draft saved; use !cpc " + previous +
                                      " then !cp finalize to make that draft playable.");
        }
        return;
    }
    if (commandArguments[0] == "insert")
    {
        self sendLocalChatMessage(
            "To add after the selected checkpoint, use !cpc postsert. To add before it, use !cpc presert. Select it with !cpc edit first.");
        return;
    }
    if (!self isEditing())
    {
        self iprintln("Start or continue your draft with !cpc easy or !cpc hard");
        return;
    }
    if (commandArguments[0] == "rename" && commandArguments.size == 3)
    {
        self openCJ\checkpointNetwork::rename(toLower(commandArguments[1]), toLower(commandArguments[2]));
        return;
    }
    if (isDefined(self.cpc.insertAfter) &&
       (commandArguments[0] == "split" || commandArguments[0] == "merge" || commandArguments[0] == "edit" || commandArguments[0] == "select"))
    {
        self sendLocalChatMessage("Confirm or discard the insertion first.");
        return;
    }
    if (commandArguments[0] == "split")
    {
        for (i = 1; i < commandArguments.size; i++)
        {
            commandArguments[i] = toLower(commandArguments[i]);
        }
        self openCJ\checkpointNetwork::split(commandArguments);
        return;
    }
    if (commandArguments[0] == "merge")
    {
        for (i = 1; i < commandArguments.size; i++)
        {
            commandArguments[i] = toLower(commandArguments[i]);
        }
        self openCJ\checkpointNetwork::merge(commandArguments);
        return;
    }
    if (commandArguments[0] == "edit" && commandArguments.size == 1)
    {
        if (self.cpc.testing)
        {
            self sendLocalChatMessage("Exit checkpoint testing with !cp test before editing.");
            return;
        }
        checkpointIndex = self checkpointAt(self.cpc.rows, self.origin, self isOnGround());
        if (checkpointIndex < 0)
        {
            message = "No checkpoint in the current draft at your position.";
            if (checkpointIndex == -2)
            {
                message = "Multiple checkpoints overlap here; use !cp edit <number> to select one.";
            }
            self sendLocalChatMessage(message);
            return;
        }
        if (checkpointIndex != self.cpc.selected && openCJ\checkpointNetwork::pendingEdit(self.cpc))
        {
            self sendLocalChatMessage(
                "Confirm/apply your current selection first, or Undo/Discard it before editing another checkpoint.");
            return;
        }
        if (checkpointIndex == self.cpc.selected && openCJ\checkpointNetwork::pendingEdit(self.cpc))
        {
            return;
        }
        commandArguments[1] = "" + (checkpointIndex + 1);
    }
    if ((commandArguments[0] == "select" || commandArguments[0] == "edit") && commandArguments.size == 2 &&
       (isValidInt(commandArguments[1]) || commandArguments[1] == "last"))
    {
        checkpointIndex = self.cpc.rows.size - 1;
        if (commandArguments[1] != "last")
        {
            checkpointIndex = int(commandArguments[1]) - 1;
        }
        if (checkpointIndex >= 0 && checkpointIndex < self.cpc.rows.size)
        {
            self _remember();
            self.cpc.alternativeBlocked = undefined;
            self.cpc.overlap = undefined;
            self.cpc.selected = checkpointIndex;
            self.cpc.draft = _decode(self.cpc.rows[checkpointIndex]);
            self.cpc.status = "Editing checkpoint " + (checkpointIndex + 1) + "; confirm/apply with Num Enter";
            self _save();
        }
        return;
    }
    if (commandArguments[0] == "delete" && commandArguments.size > 1)
    {
        if (commandArguments.size != 2 || toLower(commandArguments[1]) != "area")
        {
            self sendLocalChatMessage(
                "Use !cp delete area for one area, or !cp delete for the whole checkpoint.");
            return;
        }
        self _action("deletearea");
        return;
    }
    if (commandArguments[0] == "height" && commandArguments.size > 1)
    {
        if (commandArguments.size != 2 || !isValidFloat(commandArguments[1]))
        {
            self sendLocalChatMessage("Use !cpc height to toggle editing, or !cpc height <units>");
            return;
        }
        self.cpc.heightRequestValue = float(commandArguments[1]);
        self _action("heightset");
        return;
    }
    self _action(commandArguments[0]);
}

// Detection warns without selecting, overwriting or blocking intentional edits.
// Only this player's draft and public gameplay checkpoints are inspected.
detectedCheckpointWarning(points)
{
    for (i = 0; i < self.cpc.rows.size; i++)
    {
        // Editing/appending alternatives to this logical checkpoint is allowed.
        if (i == self.cpc.selected)
        {
            continue;
        }
        checkpoint = _decode(self.cpc.rows[i]);
        if (!isDefined(checkpoint))
        {
            continue;
        }
        overlapsDraft = openCJ\checkpointNetwork::areaOverlap(self.cpc.draft, checkpoint, checkpoint.points);
        for (j = 0; !overlapsDraft && j < checkpoint.alternatives.size; j++)
        {
            overlapsDraft = openCJ\checkpointNetwork::areaOverlap(self.cpc.draft, checkpoint, checkpoint.alternatives[j]);
        }
        if (overlapsDraft)
        {
            return "Checkpoint #" + (i + 1) + " already exists here in " + self.cpc.route +
                   ". Use !cp edit " + (i + 1) + " to edit it.";
        }
    }
    if (isDefined(level.checkpoints_checkpoints))
    {
        for (i = 0; i < level.checkpoints_checkpoints.size; i++)
        {
            checkpoint = level.checkpoints_checkpoints[i];
            if (!isDefined(checkpoint.area) ||
               !openCJ\checkpointNetwork::areaOverlap(self.cpc.draft, checkpoint, checkpoint.area))
            {
                continue;
            }
            routeLabel = "";
            if (isDefined(checkpoint.routeInfo))
            {
                routeLabel = " (" + checkpoint.routeInfo.name + ")";
            }
            return "Published checkpoint #" + checkpoint.id + routeLabel + " already exists here.";
        }
    }
    return "";
}

// Alternatives belong to one checkpoint; distinct overlapping checkpoints are ambiguous.
checkpointAt(rows, origin, grounded)
{
    matchingIndex = -1;
    for (i = 0; i < rows.size; i++)
    {
        checkpoint = _decode(rows[i]);
        if (!isDefined(checkpoint) || !self contains(checkpoint, origin, grounded))
        {
            continue;
        }
        if (matchingIndex >= 0)
        {
            return -2;
        }
        matchingIndex = i;
    }
    return matchingIndex;
}

_validName(routeName)
{
    if (routeName.size < 1 || routeName.size > 20)
    {
        return false;
    }
    for (i = 0; i < routeName.size; i++)
    {
        if (!isSubStr("abcdefghijklmnopqrstuvwxyz0123456789_+", routeName[i]))
        {
            return false;
        }
    }
    return true;
}

defaultRouteColor(routeName)
{
    switch (toLower(routeName))
    {
    case "easy":
        return "#00ff00";
    case "inter":
        return "#ffff00";
    case "inter+":
        return "#ff8800";
    case "hard":
        return "#ff7777";
    case "hard+":
        return "#aa0000";
    case "adv":
    case "advanced":
        return "#aa55ff";
    case "adv+":
    case "advanced+":
        return "#ff77cc";
    }
    return "#00ccff";
}

routeRGB(routeHex)
{
    if (routeHex.size != 7 || routeHex[0] != "#")
    {
        return undefined;
    }
    routeHex = toLower(routeHex);
    digits = "0123456789abcdef";
    channels = [];
    for (i = 0; i < 3; i++)
    {
        value = 0;
        for (j = 0; j < 2; j++)
        {
            for (n = 0; n < 16 && digits[n] != routeHex[1 + i * 2 + j]; n++)
            {
            }
            if (n == 16)
            {
                return undefined;
            }
            value = value * 16 + n;
        }
        channels[i] = value / 255.0;
    }
    return (channels[0], channels[1], channels[2]);
}

_empty()
{
    checkpoint = spawnStruct();
    checkpoint.points = [];
    checkpoint.alternatives = [];
    checkpoint.finish = false;
    checkpoint.double = false;
    checkpoint.onGround = true;
    checkpoint.allowSave = true;
    checkpoint.allowEle = false;
    checkpoint.heightAbove = 0;
    return checkpoint;
}

_encode(checkpoint)
{
    encodedCheckpoint = int(checkpoint.finish) + ":" + int(checkpoint.double) + ":p" + openCJ\checkpointArea::encode(checkpoint.points);
    for (i = 0; i < checkpoint.alternatives.size; i++)
    {
        encodedCheckpoint += "|p" + openCJ\checkpointArea::encode(checkpoint.alternatives[i]);
    }
    if (checkpoint.heightAbove > 0)
    {
        platformReference = "-";
        if (openCJ\checkpointMoving::isMoving(checkpoint))
        {
            platformReference = checkpoint.platformRef;
        }
        return encodedCheckpoint + ":" + int(checkpoint.onGround) + ":" + int(checkpoint.allowSave) + ":" + int(checkpoint.allowEle) +
               ":" + platformReference + ":" + floatToPreciseString(checkpoint.heightAbove);
    }
    if (openCJ\checkpointMoving::isMoving(checkpoint))
    {
        encodedCheckpoint += ":" + int(checkpoint.onGround) + ":" + int(checkpoint.allowSave) + ":" + int(checkpoint.allowEle) + ":" +
                checkpoint.platformRef;
    }
    else if (checkpoint.allowEle)
    {
        encodedCheckpoint += ":" + int(checkpoint.onGround) + ":" + int(checkpoint.allowSave) + ":1";
    }
    else if (!checkpoint.allowSave)
    {
        encodedCheckpoint += ":" + int(checkpoint.onGround) + ":0";
    }
    else if (!checkpoint.onGround)
    {
        encodedCheckpoint += ":0";
    }
    return encodedCheckpoint;
}

_decode(row)
{
    fields = strTok(row, ":");
    if ((fields.size != 3 && fields.size != 4 && fields.size != 5 && fields.size != 6 &&
        fields.size != 7 && fields.size != 8) ||
       (fields[0] != "0" && fields[0] != "1") || (fields[1] != "0" && fields[1] != "1"))
    {
        return undefined;
    }
    if (fields[2][0] != "p")
    {
        return undefined;
    }
    checkpoint = _empty();
    checkpoint.finish = int(fields[0]);
    checkpoint.double = int(fields[1]);
    if (fields.size >= 4)
    {
        if (fields[3] != "0" && fields[3] != "1")
        {
            return undefined;
        }
        checkpoint.onGround = int(fields[3]);
    }
    if (fields.size >= 5)
    {
        if (fields[4] != "0" && fields[4] != "1")
        {
            return undefined;
        }
        checkpoint.allowSave = int(fields[4]);
    }
    if (fields.size >= 6)
    {
        if (fields[5] != "0" && fields[5] != "1")
        {
            return undefined;
        }
        checkpoint.allowEle = int(fields[5]);
    }
    if (fields.size == 8)
    {
        if (!isValidFloat(fields[7]))
        {
            return undefined;
        }
        checkpoint.heightAbove = float(fields[7]);
        if (!openCJ\checkpointHeight::valid(checkpoint.heightAbove))
        {
            return undefined;
        }
    }
    if (fields.size == 7 || (fields.size == 8 && fields[6] != "-"))
    {
        if (fields[6].size < 2 || fields[6].size > 101 ||
           (fields[6][0] != "b" && fields[6][0] != "n"))
        {
            return undefined;
        }
        checkpoint.platformRef = fields[6];
    }
    encodedAreas = strTok(fields[2], "|");
    if (encodedAreas.size > 8)
    {
        return undefined;
    }
    if (openCJ\checkpointMoving::isMoving(checkpoint) && encodedAreas.size != 1)
    {
        return undefined;
    }
    checkpoint.points = openCJ\checkpointArea::decode(getSubStr(encodedAreas[0], 1));
    if (!isDefined(checkpoint.points))
    {
        return undefined;
    }
    for (i = 1; i < encodedAreas.size; i++)
    {
        if (encodedAreas[i][0] != "p")
        {
            return undefined;
        }
        points = openCJ\checkpointArea::decode(getSubStr(encodedAreas[i], 1));
        if (!isDefined(points) || openCJ\checkpointArea::validate(points) != "")
        {
            return undefined;
        }
        checkpoint.alternatives[checkpoint.alternatives.size] = points;
    }
    return checkpoint;
}

// The active area and its alternatives share requirements and one progress step.
contains(checkpoint, origin, grounded)
{
    if (openCJ\checkpointMoving::isMoving(checkpoint))
    {
        if (!isDefined(self) || !isPlayer(self))
        {
            return false;
        }
        return self openCJ\checkpointMoving::touches(checkpoint, grounded, self getGroundEntity());
    }
    if (openCJ\checkpointArea::touchesPlayer(checkpoint.points, origin, grounded, checkpoint.onGround,
                                            checkpoint.heightAbove))
    {
        return true;
    }
    for (i = 0; i < checkpoint.alternatives.size; i++)
    {
        if (openCJ\checkpointArea::touchesPlayer(checkpoint.alternatives[i], origin, grounded, checkpoint.onGround,
                                                checkpoint.heightAbove))
        {
            return true;
        }
    }
    return false;
}

_addAlternative()
{
    selected = self.cpc.selected;
    checkpoint = self.cpc.draft;
    if (selected == self.cpc.rows.size && checkpoint.points.size == 0 && checkpoint.alternatives.size == 0 &&
       self.cpc.rows.size > 0)
    {
        selected--;
        checkpoint = _decode(self.cpc.rows[selected]);
    }
    if (openCJ\checkpointMoving::isMoving(checkpoint))
    {
        self.cpc.status = "This checkpoint already covers the whole moving platform";
        return;
    }
    // Validate before reopening a confirmed area. A rejected add must never
    // turn the following Detect into an edit of the previous platform.
    if (openCJ\checkpointArea::validate(checkpoint.points) != "" || checkpoint.alternatives.size >= 7)
    {
        self.cpc.alternativeBlocked = true;
        self.cpc.status =
            "Cannot add area: confirm a valid selection first; maximum 8 areas. Use Undo or New";
        return;
    }
    self.cpc.alternativeBlocked = undefined;
    self.cpc.selected = selected;
    self.cpc.draft = checkpoint;
    checkpoint.alternatives[checkpoint.alternatives.size] = checkpoint.points;
    checkpoint.points = [];
    self.cpc.status =
        "Adding area " + (checkpoint.alternatives.size + 1) + " to checkpoint " + (selected + 1);
}

_start(routeName, routeHex)
{
    self openCJ\mapBoost::cancel();
    routeName = self openCJ\checkpointNetwork::resolve(routeName);
    if (!isDefined(routeName))
    {
        self sendLocalChatMessage(
            "Network draft files exist but cannot be read; preserved for recovery.", true);
        return;
    }
    self openCJ\historySave::cancelPendingPage();
    self notify("cpc_started");
    self.cpc = spawnStruct();
    self.cpc.route = routeName;
    self.cpc.rows = [];
    self.cpc.draft = _empty();
    self.cpc.selected = 0;
    self.cpc.revision = 0;
    self.cpc.history = [];
    self.cpc.testing = false;
    self.cpc.status = "";
    self.cpc.path = "checkpoints/drafts/" + self openCJ\login::getPlayerID() + "_" +
                    getCvar("mapname") + "_" + routeName;
    snapshotA = _read(self.cpc.path + ".a", routeName);
    snapshotB = _read(self.cpc.path + ".b", routeName);
    if (!isDefined(snapshotA) && !isDefined(snapshotB) &&
       (FS_TestFile(self.cpc.path + ".a") || FS_TestFile(self.cpc.path + ".b")))
    {
        self iprintln(
            "Draft files exist but neither is valid. They have been preserved for recovery");
        self.cpc = undefined;
        return;
    }
    latestSnapshot = snapshotA;
    if (isDefined(snapshotB) && (!isDefined(snapshotA) || snapshotB.revision > snapshotA.revision))
    {
        latestSnapshot = snapshotB;
    }
    if (isDefined(latestSnapshot))
    {
        self.cpc.sharedRoute = latestSnapshot.sharedRoute;
        self.cpc.sharedHex = latestSnapshot.sharedHex;
        self.cpc.sharedCount = latestSnapshot.sharedCount;
        self.cpc.rows = latestSnapshot.rows;
        self.cpc.draft = latestSnapshot.draft;
        self.cpc.selected = latestSnapshot.selected;
        self.cpc.insertAfter = latestSnapshot.insertAfter;
        self.cpc.revision = latestSnapshot.revision;
        self sendLocalChatMessage("Restored " + routeName + " draft (" + latestSnapshot.rows.size +
                                  " confirmed checkpoints)");
        self.cpc.savedPosition = latestSnapshot.savedPosition;
        self.cpc.restoreOrigin = restoreOrigin(latestSnapshot);
        if (isDefined(latestSnapshot.savedPosition))
        {
            self.cpc.restoreOrigin = latestSnapshot.savedPosition.origin;
            self.cpc.restoreAngles = latestSnapshot.savedPosition.angles;
        }
    }
    if (!isDefined(routeHex) && isDefined(latestSnapshot) && isDefined(latestSnapshot.routeHex))
    {
        routeHex = latestSnapshot.routeHex;
    }
    if (!isDefined(routeHex) && isDefined(level.checkpointRoutes) &&
       isDefined(level.checkpointRoutes[routeName]))
    {
        routeHex = level.checkpointRoutes[routeName].hex;
    }
    if (!isDefined(routeHex))
    {
        routeHex = defaultRouteColor(routeName);
    }
    if (isDefined(self.cpc.sharedRoute) && !isDefined(self.cpc.sharedHex))
    {
        self.cpc.sharedHex = defaultRouteColor(self.cpc.sharedRoute);
    }
    self.cpc.routeHex = routeHex;
    self.cpc.routeColor = routeRGB(routeHex);
    self openCJ\checkpointNetwork::opened();
    self.cpc.huds = [];
    for (i = 0; i < 4; i++)
    {
        if (i == 2)
        {
            continue;
        } // Properties use the client HUD for smaller, crisp text.
        self.cpc.huds[i] = newClientHudElem(self);
        self.cpc.huds[i].lastText = "";
        configureHud(self.cpc.huds[i]);
    }
    // Two compact columns: headers share the top row, body starts below them.
    self.cpc.huds[0].x = 282;
    self.cpc.huds[0].font = "objective";
    self.cpc.huds[0].color = (0.75, 0.85, 1);
    self.cpc.huds[1].y = 30;
    self.cpc.huds[3].fontScale = 1.4;
    self.cpc.huds[3].color = self.cpc.routeColor;
    self setClientCvar("developer", 1);
    self.cpc.positions = [];
    if (isDefined(self.cpcTravelPositions))
    {
        self.cpc.positions = self.cpcTravelPositions;
    }
    self.cpc.travelIndex = 0;
    // Entering the editor must not replace a manual save with the spawn position.
    if (!isDefined(self.cpc.restoreOrigin) && self.cpc.positions.size == 0)
    {
        savedPosition = spawnStruct();
        savedPosition.origin = self.origin;
        savedPosition.angles = self getPlayerAngles();
        self rememberPosition(savedPosition);
    }
    self openCJ\buttonPress::resetButtons();
    if (self openCJ\playerRuns::hasRunID())
    {
        self openCJ\playerRuns::stopRun(false);
    }
    self openCJ\huds\hudRunInfo::onRunStopped();
    self openCJ\huds\hudSpeedometer::_hideSpeedometer();
    self openCJ\huds\hudProgressBar::onRunStopped();
    // The mod's existing client-command menu applies these without a local cfg.
    self execClientCmd(
        "bind KP_INS say !cp detect; bind KP_5 say !cp detect; " +
        "bind KP_ENTER say !cp confirm; bind KP_PLUS say !cp corner; bind KP_MINUS say !cp undo; " +
        "bind KP_UPARROW say !cp ele; bind KP_END say !cp double; bind KP_PGUP say !cp finish; bind KP_DOWNARROW say !cp ground; bind KP_PGDN say !cp allowsave; " +
        "bind KP_LEFTARROW say !cp previous; bind KP_RIGHTARROW say !cp next; " +
        "bind KP_DEL say !cp discard; bind KP_HOME say !cp height; bind KP_SLASH say !cp alternative; bind KP_STAR say !cp area");
    self thread _loop();
}

restoreOrigin(draft)
{
    checkpoint = draft.draft;
    points = openCJ\checkpointMoving::points(checkpoint);
    if (openCJ\checkpointArea::validate(points) != "" && draft.draft.alternatives.size > 0)
    {
        points = draft.draft.alternatives[draft.draft.alternatives.size - 1];
    }
    if (openCJ\checkpointArea::validate(points) != "" && draft.rows.size > 0)
    {
        checkpointIndex = draft.selected;
        if (checkpointIndex >= draft.rows.size)
        {
            checkpointIndex = draft.rows.size - 1;
        }
        checkpoint = _decode(draft.rows[checkpointIndex]);
        points = openCJ\checkpointMoving::points(checkpoint);
    }
    if (openCJ\checkpointArea::validate(points) != "")
    {
        return undefined;
    }
    // _center adds 12 for labels; leave two units above the capsule support height.
    extraHeight = openCJ\checkpointHeight::above(checkpoint);
    if (extraHeight > 0)
    {
        extraHeight += 4;
    } // Resume above a curved surface, not inside its base plane.
    return _center(points) + (0, 0, openCJ\checkpointArea::supportOffset(points) - 10 + extraHeight);
}

configureHud(hudElement)
{
    // The current pool is already close to its 31-element snapshot limit.
    hudElement.archived = true;
    hudElement.x = 124;
    hudElement.y = 6;
    hudElement.font = "default";
    hudElement.sort = 1;
    hudElement.alignX = "left";
    hudElement.alignY = "top";
    hudElement.horzAlign = "left";
    hudElement.vertAlign = "top";
    hudElement.fontScale = 1.4;
    hudElement.foreground = true;
    hudElement.hideWhenInMenu = true;
    hudElement.alpha = 1;
}

// Spectating suspends the editor without closing its draft or selection.
onSpawnSpectator()
{
    if (!self isEditing() || isDefined(self.cpc.suspended))
    {
        return;
    }
    self.cpc.suspended = true;
    self.cpc.restoreOrigin = undefined;
    self.cpc.restoreAngles = undefined;
    self openCJ\buttonPress::resetButtons();
    keys = getArrayKeys(self.cpc.huds);
    for (i = 0; i < keys.size; i++)
    {
        self.cpc.huds[keys[i]].alpha = 0;
    }
    self setClientCvar("opencj_cpc_properties", "");
    self setClientCvar("opencj_cpc_panel_height", 0);
    self _save();
}

onSpawnPlayer()
{
    if (!self isEditing())
    {
        return;
    }
    self.cpc.suspended = undefined;
    // Normal spawning must not replay a pending draft-restoration teleport.
    self.cpc.restoreOrigin = undefined;
    self.cpc.restoreAngles = undefined;
    keys = getArrayKeys(self.cpc.huds);
    for (i = 0; i < keys.size; i++)
    {
        self.cpc.huds[keys[i]].alpha = 1;
    }
    self.cpc.propertiesText = undefined;
    self.cpc.panelHeight = undefined;
    self openCJ\huds\hudRunInfo::onRunStopped();
    self openCJ\huds\hudStatistics::onRunStopped();
    self openCJ\huds\hudSpeedometer::_hideSpeedometer();
    self openCJ\showRecords::onRunStopped();
}

_loop()
{
    self endon("disconnect");
    self endon("cpc_stopped");
    nextDraw = 0;
    while (self isEditing())
    {
        if (self.sessionState != "playing")
        {
            self onSpawnSpectator();
            nextDraw = 0;
            wait 0.05;
            continue;
        }
        // Starting/loading a run must not resume scoring while editing.
        if (self openCJ\playerRuns::hasRunID())
        {
            self openCJ\playerRuns::stopRun(false);
        }
        if (!self isEditing())
        {
            return;
        }
        if (self.cpc.testing)
        {
            self _testStep();
        }
        if (getTime() >= nextDraw)
        {
            nextDraw = getTime() + 500;
            self openCJ\checkpointNetwork::trackSharedLanding(self.origin, self isOnGround());
            self.cpc.drawCommands = 0;
            self _draw();
        }
        wait 0.05;
    }
}

_remember()
{
    undoSnapshot = spawnStruct();
    undoSnapshot.rows = [];
    for (i = 0; i < self.cpc.rows.size; i++)
    {
        undoSnapshot.rows[i] = self.cpc.rows[i];
    }
    undoSnapshot.draft = _encode(self.cpc.draft);
    undoSnapshot.selected = self.cpc.selected;
    undoSnapshot.insertAfter = self.cpc.insertAfter;
    if (self.cpc.history.size == 32)
    {
        for (i = 1; i < 32; i++)
        {
            self.cpc.history[i - 1] = self.cpc.history[i];
        }
        self.cpc.history[31] = undefined;
    }
    self.cpc.history[self.cpc.history.size] = undoSnapshot;
}

_action(action)
{
    if (isDefined(self.cpc.insertAfter) &&
       (action == "new" || action == "previous" || action == "next" || action == "delete" ||
        action == "alternative" || action == "finalize" || action == "publish" || action == "test"))
    {
        self.cpc.status = "Confirm or discard the insertion first";
        return;
    }
    if (action == "insert")
    {
        self.cpc.status = "After: !cpc postsert | Before: !cpc presert";
        self sendLocalChatMessage(
            "To add after the selected checkpoint, use !cpc postsert. To add before it, use !cpc presert.");
        return;
    }
    if (action == "postsert" || action == "presert")
    {
        self beginInsertion(action == "presert");
        return;
    }
    if (action == "stop")
    {
        self stop();
        return;
    }
    if (action == "save")
    {
        self _save();
        return;
    }
    if (action == "finalize" || action == "publish")
    {
        if (!isDefined(self.cpc.finalizing))
        {
            self.cpc.finalizing = true;
            self thread doNextFrame(::finalize);
        }
        return;
    }
    if (action == "test")
    {
        self.cpc.testing = !self.cpc.testing;
        self.cpc.testNext = 0;
        self.cpc.status = "Test uses confirmed checkpoints; !cp test returns to editing";
        return;
    }
    if (self.cpc.testing)
    {
        self.cpc.status = "Use !cp test to leave test mode before editing";
        return;
    }
    // When the panel shows the last checkpoint, property keys edit that checkpoint.
    if ((action == "finish" || action == "double" || action == "ele" || action == "ground" ||
        action == "allowsave" || action == "height" || action == "heightset") &&
       !isDefined(self.cpc.insertAfter) && self.cpc.selected == self.cpc.rows.size &&
       self.cpc.rows.size > 0 && self.cpc.draft.points.size == 0 &&
       self.cpc.draft.alternatives.size == 0)
    {
        self _action("previous");
    }
    if (isDefined(self.cpc.heightTarget))
    {
        if (action == "corner")
        {
            action = "heightup";
        }
        else if (action == "undo")
        {
            action = "heightdown";
        }
    }
    if (action == "undo")
    {
        self.cpc.alternativeBlocked = undefined;
        self.cpc.overlap = undefined;
        if (self.cpc.history.size == 0)
        {
            return;
        }
        undoIndex = self.cpc.history.size - 1;
        snapshot = self.cpc.history[undoIndex];
        self.cpc.rows = snapshot.rows;
        self.cpc.draft = _decode(snapshot.draft);
        self.cpc.selected = snapshot.selected;
        self.cpc.insertAfter = snapshot.insertAfter;
        self.cpc.heightTarget = undefined;
        self.cpc.history[undoIndex] = undefined;
        self.cpc.status = "Undone";
        self _save();
        return;
    }
    if (action == "discard")
    {
        self _discard();
        return;
    }
    if (isDefined(self.cpc.sharedCount) && action != "new" && action != "previous" &&
       action != "next" && action != "area")
    {
        targetIndex = self.cpc.selected;
        if (action == "alternative" && targetIndex == self.cpc.rows.size &&
           self.cpc.draft.points.size == 0)
        {
            targetIndex--;
        }
        if (targetIndex < self.cpc.sharedCount)
        {
            self.cpc.status = "Shared opening is read-only in a branch; use !cp new to continue";
            return;
        }
    }
    if (action == "new" || action == "previous" || action == "next")
    {
        self.cpc.alternativeBlocked = undefined;
        self.cpc.overlap = undefined;
    }
    if (isDefined(self.cpc.alternativeBlocked))
    {
        return;
    }
    if (action == "replace" && self.cpc.selected >= self.cpc.rows.size)
    {
        self.cpc.status = "Select an existing checkpoint with !cp edit <number> first";
        return;
    }
    self _remember();
    switch (action)
    {
    case "height":
    case "heightup":
    case "heightdown":
    case "heightset":
        self openCJ\checkpointHeight::edit(action);
        break;
    case "alternative":
        self _addAlternative();
        break;
    case "area":
        checkpoint = self.cpc.draft;
        if (checkpoint.alternatives.size > 0 && openCJ\checkpointArea::validate(checkpoint.points) == "")
        {
            points = checkpoint.points;
            checkpoint.points = checkpoint.alternatives[0];
            for (i = 1; i < checkpoint.alternatives.size; i++)
            {
                checkpoint.alternatives[i - 1] = checkpoint.alternatives[i];
            }
            checkpoint.alternatives[checkpoint.alternatives.size - 1] = points;
            self.cpc.status = "Selected another area of this checkpoint";
        }
        break;
    case "detect":
        groundEntity = self getGroundEntity();
        if (self isOnGround() && isDefined(groundEntity))
        {
            platformReference = openCJ\checkpointMoving::reference(groundEntity);
            if (!isDefined(platformReference))
            {
                self.cpc.status = "Cannot identify this platform persistently; selection unchanged";
                break;
            }
            if (self.cpc.draft.alternatives.size)
            {
                self.cpc.status = "Create a separate checkpoint for a whole moving platform";
                break;
            }
            self.cpc.draft.platformRef = platformReference;
            self.cpc.draft.points = openCJ\checkpointMoving::points(self.cpc.draft);
            self.cpc.status = "Moving platform selected: the whole platform counts";
            self.cpc.overlap = undefined;
            self openCJ\checkpointNetwork::selectDetectedShared();
            self openCJ\checkpointNetwork::checkOverlap();
            warning = self detectedCheckpointWarning(self.cpc.draft.points);
            if (warning != "")
            {
                self sendLocalChatMessage(warning, true);
            }
            break;
        }
        points = self openCJ\checkpointPlatform::getRectangularPlatformOrgs();
        if (isDefined(points))
        {
            self.cpc.draft.platformRef = undefined;
            self.cpc.draft.points = points;
            self.cpc.status = "Platform detected";
            self openCJ\checkpointNetwork::selectDetectedShared();
            self openCJ\checkpointNetwork::checkOverlap();
            if (!isDefined(self.cpc.overlap))
            {
                warning = self detectedCheckpointWarning(points);
                if (warning != "")
                {
                    self.cpc.status = warning;
                    self.cpc.lastPanelStatus = warning;
                    self sendLocalChatMessage(warning, true);
                }
            }
        }
        else
        {
            self.cpc.status = "Detection failed; selection unchanged";
        }
        break;
    case "corner":
        if (openCJ\checkpointMoving::isMoving(self.cpc.draft))
        {
            break;
        }
        if (self.cpc.draft.points.size >= 8)
        {
            break;
        }
        eyePosition = self getEyePos();
        trace = bulletTrace(eyePosition, eyePosition + vectorScale(anglesToForward(self getPlayerAngles()), 1000),
                            false, self);
        if (trace["fraction"] < 1)
        {
            self.cpc.draft.points[self.cpc.draft.points.size] = trace["position"];
            self.cpc.draft.points = openCJ\checkpointArea::orderCorners(self.cpc.draft.points);
            self.cpc.status = "Corner added (" + self.cpc.draft.points.size + "/8)";
        }
        break;
    case "confirm":
        // Repair click-order crossings in drafts saved before automatic ordering.
        self.cpc.draft.points = openCJ\checkpointArea::orderCorners(self.cpc.draft.points);
        flattenedCheckpoint = _decode(_encode(self.cpc.draft));
        if (openCJ\checkpointHeight::flatten(flattenedCheckpoint))
        {
            collision = self openCJ\checkpointHeight::conflict(flattenedCheckpoint);
            if (collision != "")
            {
                self.cpc.status = "Cannot flatten: overlaps " + collision;
                return;
            }
            self.cpc.draft = flattenedCheckpoint;
        }
        if (self.cpc.draft.heightAbove > 0)
        {
            collision = self openCJ\checkpointHeight::conflict(self.cpc.draft);
            if (collision != "")
            {
                self.cpc.status = "Cannot confirm: overlaps " + collision;
                return;
            }
        }
        self openCJ\checkpointNetwork::checkOverlap();
        if (isDefined(self.cpc.overlap))
        {
            self.cpc.status =
                "Overlapping section: merge the routes here; split where they separate";
            return;
        }
        validationError = openCJ\checkpointMoving::valid(self.cpc.draft);
        if (validationError != "")
        {
            self.cpc.status = validationError;
            return;
        }
        if (self.cpc.selected >= 256)
        {
            self.cpc.status = "Maximum 256 checkpoints per route";
            return;
        }
        followingShared = self openCJ\checkpointNetwork::followingShared();
        if (isDefined(self.cpc.insertAfter))
        {
            self confirmInsertion();
            break;
        }
        self.cpc.rows[self.cpc.selected] = _encode(self.cpc.draft);
        self.cpc.status = "";
        if (followingShared)
        {
            break;
        }
        self.cpc.selected = self.cpc.rows.size;
        self.cpc.draft = _empty();
        self.cpc.heightTarget = undefined;
        break;
    case "ele":
        self.cpc.draft.allowEle = !self.cpc.draft.allowEle;
        break;
    case "allowsave":
        self.cpc.draft.allowSave = !self.cpc.draft.allowSave;
        break;
    case "ground":
        self.cpc.draft.onGround = !self.cpc.draft.onGround;
        break;
    case "finish":
        self.cpc.draft.finish = !self.cpc.draft.finish;
        break;
    case "double":
        self.cpc.draft.double = !self.cpc.draft.double;
        break;
    case "new":
        self.cpc.selected = self.cpc.rows.size;
        self.cpc.draft = _empty();
        self.cpc.heightTarget = undefined;
        break;
    case "previous":
    case "next":
        if (self.cpc.rows.size > 0)
        {
            step = 1;
            if (action == "previous")
            {
                step = -1;
            }
            self.cpc.selected =
                (self.cpc.selected + self.cpc.rows.size + step) % self.cpc.rows.size;
            self.cpc.draft = _decode(self.cpc.rows[self.cpc.selected]);
        }
        break;
    case "replace":
        // Keep the original confirmed row until Apply succeeds. Its index,
        // requirements, incoming link and outgoing link remain unchanged.
        self.cpc.draft.platformRef = undefined;
        self.cpc.draft.points = [];
        self.cpc.draft.alternatives = [];
        self.cpc.overlap = undefined;
        self.cpc.status = "Detect replacement, then Apply; checkpoint position and links are kept";
        break;
    case "deletearea":
        // Area cycling rotates the active geometry into points. Remove only
        // that geometry, promoting an alternative when one is available.
        self.cpc.draft = removeSelectedArea(self.cpc.draft);
        self.cpc.overlap = undefined;
        self.cpc.status = "Area removed from selection; Apply to keep, or detect its replacement";
        break;
    case "delete":
        if (self.cpc.selected < self.cpc.rows.size)
        {
            for (i = self.cpc.selected + 1; i < self.cpc.rows.size; i++)
            {
                self.cpc.rows[i - 1] = self.cpc.rows[i];
            }
            self.cpc.rows[self.cpc.rows.size - 1] = undefined;
        }
        self.cpc.selected = self.cpc.rows.size;
        self.cpc.draft = _empty();
        self.cpc.status = "Removed from draft; Undo restores it";
        break;
    default:
        self.cpc.status = "Unknown action; use !help cp";
        return;
    }
    self _save();
}

// Keep pending insertion geometry outside rows until Confirm succeeds.
beginInsertion(before)
{
    if(!isDefined(before))
    {
        before = false;
    }
    if(self.cpc.testing || isDefined(self.cpc.insertAfter) ||
       self.cpc.selected >= self.cpc.rows.size)
    {
        self.cpc.status = "Select a checkpoint with !cpc edit first";
        return false;
    }
    if(openCJ\checkpointNetwork::pendingEdit(self.cpc))
    {
        self.cpc.status = "Apply or undo changes to the selected checkpoint first";
        return false;
    }
    if(self.cpc.rows.size >= 256)
    {
        self.cpc.status = "Maximum 256 checkpoints per route";
        return false;
    }
    index = self.cpc.selected + 1 - int(before);
    if(isDefined(self.cpc.sharedCount) && index < self.cpc.sharedCount)
    {
        self.cpc.status = "Edit the shared opening draft to insert there";
        return false;
    }
    if(!before && self.cpc.draft.finish)
    {
        self.cpc.status = "Select a checkpoint before the finish to insert after it";
        return false;
    }
    self _remember();
    self.cpc.insertAfter = index - 1;
    self.cpc.selected = self.cpc.rows.size;
    self.cpc.draft = _empty();
    self.cpc.heightTarget = undefined;
    self.cpc.overlap = undefined;
    self.cpc.alternativeBlocked = undefined;
    self.cpc.status =
        "Insert checkpoint " + (index + 1) + ": detect the missing landing, then confirm";
    self _save();
    return true;
}

confirmInsertion()
{
    index = self.cpc.insertAfter + 1;
    for(i = self.cpc.rows.size; i > index; i--)
    {
        self.cpc.rows[i] = self.cpc.rows[i - 1];
    }
    self.cpc.rows[index] = _encode(self.cpc.draft);
    self.cpc.selected = self.cpc.rows.size;
    self.cpc.draft = _empty();
    self.cpc.insertAfter = undefined;
    self.cpc.heightTarget = undefined;
    self.cpc.status =
        "Inserted checkpoint " + (index + 1) + "; following checkpoints shifted forward";
}

// Physical order in the draft also determines the incoming/outgoing links.
nextPreviewIndex(draft)
{
    if(isDefined(draft.insertAfter))
    {
        return draft.insertAfter + 1;
    }
    return draft.selected + 1;
}

// Geometry-only edit: callers retain the selected row and confirm explicitly.
removeSelectedArea(checkpoint)
{
    checkpoint.points = [];
    if (checkpoint.alternatives.size > 0)
    {
        checkpoint.points = checkpoint.alternatives[0];
        for (i = 1; i < checkpoint.alternatives.size; i++)
        {
            checkpoint.alternatives[i - 1] = checkpoint.alternatives[i];
        }
        checkpoint.alternatives[checkpoint.alternatives.size - 1] = undefined;
    }
    return checkpoint;
}

// Delete the selected existing checkpoint; otherwise discard the pending new
// checkpoint, or the last confirmed checkpoint when in the empty append slot.
_discard()
{
    if (isDefined(self.cpc.insertAfter))
    {
        self _remember();
        self.cpc.selected = self.cpc.insertAfter;
        if (self.cpc.selected < 0)
        {
            self.cpc.selected = 0;
        }
        self.cpc.insertAfter = undefined;
        self.cpc.draft = _decode(self.cpc.rows[self.cpc.selected]);
        self.cpc.heightTarget = undefined;
        self.cpc.overlap = undefined;
        self.cpc.status = "Insertion discarded; existing checkpoints unchanged";
        self _save();
        return;
    }
    if (self.cpc.selected < self.cpc.rows.size)
    {
        // Reuse Delete so selection, sequential links, shared protection and
        // Undo all behave identically to the explicit command.
        self _action("delete");
        return;
    }
    self.cpc.overlap = undefined;
    pending = self.cpc.selected == self.cpc.rows.size &&
              (self.cpc.draft.points.size > 0 || self.cpc.draft.alternatives.size > 0);
    if (!pending && (self.cpc.rows.size == 0 || (isDefined(self.cpc.sharedCount) &&
                                                self.cpc.rows.size <= self.cpc.sharedCount)))
    {
        self.cpc.status = "No branch checkpoint to discard; shared opening is protected";
        return;
    }
    self _remember();
    self.cpc.alternativeBlocked = undefined;
    if (pending)
    {
        self.cpc.status = "Discarded unconfirmed checkpoint; [Num -] Undo";
    }
    else
    {
        number = self.cpc.rows.size;
        self.cpc.rows[number - 1] = undefined;
        self.cpc.status = "Discarded checkpoint " + number + "; [Num -] Undo";
    }
    self.cpc.selected = self.cpc.rows.size;
    self.cpc.draft = _empty();
    self _save();
}

_save()
{
    revision = self.cpc.revision + 1;
    suffix = ".a";
    if (revision % 2)
    {
        suffix = ".b";
    }
    fileHandle = FS_FOpen(self.cpc.path + suffix, "write");
    if (!fileHandle)
    {
        self.cpc.status = "SAVE FAILED - draft remains in memory; retry !cp save";
        return false;
    }
    routeHex = self.cpc.routeHex;
    if (!isDefined(routeHex))
    {
        routeHex = defaultRouteColor(self.cpc.route);
    }
    if (isDefined(self.cpc.sharedRoute) && !isDefined(self.cpc.sharedHex))
    {
        self.cpc.sharedHex = defaultRouteColor(self.cpc.sharedRoute);
    }
    header = "CPC4 " + getCvar("mapname") + " " + self.cpc.route + " " + revision + " " +
             self.cpc.rows.size + " " + self.cpc.selected + " " + routeHex;
    if (isDefined(self.cpc.sharedRoute))
    {
        header = "CPC6 " + getCvar("mapname") + " " + self.cpc.route + " " + revision + " " +
                 self.cpc.rows.size + " " + self.cpc.selected + " " + routeHex + " " +
                 self.cpc.sharedRoute + " " + self.cpc.sharedCount + " " + self.cpc.sharedHex;
    }
    writeSucceeded = FS_WriteLine(fileHandle, header);
    for (i = 0; i < self.cpc.rows.size; i++)
    {
        if (!FS_WriteLine(fileHandle, self.cpc.rows[i]))
        {
            writeSucceeded = false;
        }
    }
    if (!FS_WriteLine(fileHandle, _encode(self.cpc.draft)))
    {
        writeSucceeded = false;
    }
    if (isDefined(self.cpc.insertAfter) && !FS_WriteLine(fileHandle, "INSERT " + self.cpc.insertAfter))
    {
        writeSucceeded = false;
    }
    if (isDefined(self.cpc.savedPosition))
    {
        savedPose = [];
        savedPose[0] = self.cpc.savedPosition.origin;
        savedPose[1] = self.cpc.savedPosition.angles;
        if (!FS_WriteLine(fileHandle, "TRAVEL " + openCJ\checkpointArea::encode(savedPose)))
        {
            writeSucceeded = false;
        }
    }
    if (!FS_WriteLine(fileHandle, "END " + revision))
    {
        writeSucceeded = false;
    }
    FS_FClose(fileHandle);
    if (writeSucceeded)
    {
        self.cpc.revision = revision;
    }
    else
    {
        self.cpc.status = "SAVE FAILED - previous complete draft retained; retry !cp save";
    }
    return writeSucceeded;
}

_read(path, routeName)
{
    fileHandle = FS_FOpen(path, "read");
    if (!fileHandle)
    {
        return undefined;
    }
    draft = _readFile(fileHandle, routeName);
    FS_FClose(fileHandle);
    return draft;
}

_readFile(fileHandle, routeName)
{
    line = FS_ReadLine(fileHandle);
    if (!isDefined(line))
    {
        return undefined;
    }
    header = strTok(line, " ");
    hasSharedColor = header.size == 10 && header[0] == "CPC6";
    hasSharedOpening = (header.size == 9 && header[0] == "CPC5") || hasSharedColor;
    hasRouteColor = (header.size == 7 && header[0] == "CPC4") || hasSharedOpening;
    isUncoloredDraft = header.size == 6 && (header[0] == "CPC2" || header[0] == "CPC3");
    if ((!hasRouteColor && !isUncoloredDraft) || header[1] != getCvar("mapname") || header[2] != routeName)
    {
        return undefined;
    }
    if (hasRouteColor && !isDefined(routeRGB(header[6])))
    {
        return undefined;
    }
    for (i = 3; i < 6; i++)
    {
        if (!isValidInt(header[i]))
        {
            return undefined;
        }
    }
    confirmedCount = int(header[4]);
    if (confirmedCount < 0 || confirmedCount > 256 || int(header[5]) < 0 || int(header[5]) > confirmedCount)
    {
        return undefined;
    }
    draft = spawnStruct();
    if (hasRouteColor)
    {
        draft.routeHex = header[6];
    }
    if (hasSharedOpening)
    {
        if (!_validName(header[7]) || header[7] == routeName || !isValidInt(header[8]) ||
           int(header[8]) < 1 || int(header[8]) > confirmedCount)
        {
            return undefined;
        }
        draft.sharedRoute = header[7];
        draft.sharedCount = int(header[8]);
        draft.sharedHex = defaultRouteColor(draft.sharedRoute);
        if (hasSharedColor)
        {
            if (!isDefined(routeRGB(header[9])))
            {
                return undefined;
            }
            draft.sharedHex = header[9];
        }
    }
    draft.revision = int(header[3]);
    draft.selected = int(header[5]);
    draft.rows = [];
    for (i = 0; i <= confirmedCount; i++)
    {
        encodedCheckpoint = FS_ReadLine(fileHandle);
        if (!isDefined(encodedCheckpoint))
        {
            return undefined;
        }
        checkpoint = _decode(encodedCheckpoint);
        if (!isDefined(checkpoint))
        {
            return undefined;
        }
        if (i < confirmedCount)
        {
            if (!openCJ\checkpointMoving::isMoving(checkpoint) &&
               openCJ\checkpointArea::validate(checkpoint.points) != "")
            {
                return undefined;
            }
            draft.rows[i] = encodedCheckpoint;
        }
        else
        {
            draft.draft = checkpoint;
        }
    }
    trailer = FS_ReadLine(fileHandle);
    if (isDefined(trailer) && getSubStr(trailer, 0, 7) == "INSERT ")
    {
        insertionIndexText = getSubStr(trailer, 7);
        if (!isValidInt(insertionIndexText) || int(insertionIndexText) < -1 || int(insertionIndexText) >= confirmedCount || draft.selected != confirmedCount)
        {
            return undefined;
        }
        draft.insertAfter = int(insertionIndexText);
        trailer = FS_ReadLine(fileHandle);
    }
    if (isDefined(trailer) && getSubStr(trailer, 0, 7) == "TRAVEL ")
    {
        savedPose = openCJ\checkpointArea::decode(getSubStr(trailer, 7));
        if (!isDefined(savedPose) || savedPose.size != 2)
        {
            return undefined;
        }
        draft.savedPosition = spawnStruct();
        draft.savedPosition.origin = savedPose[0];
        draft.savedPosition.angles = savedPose[1];
        trailer = FS_ReadLine(fileHandle);
    }
    if (!isDefined(trailer) || trailer != "END " + draft.revision)
    {
        return undefined;
    }
    return draft;
}

stop(quiet)
{
    if (!self isEditing())
    {
        return true;
    }
    if (!self _save())
    {
        self iprintln(self.cpc.status);
        return false;
    }
    self _close();
    if (!isDefined(quiet) || !quiet)
    {
        self iprintln("Checkpoint draft saved. Reset your run before normal play");
    }
    return true;
}

_close()
{
    self notify("cpc_stopped");
    self setClientCvar("developer", 0);
    self setClientCvar("opencj_cpc_properties", "");
    // Properties use a client menu, leaving a hole in the HUD array.
    keys = getArrayKeys(self.cpc.huds);
    for (i = 0; i < keys.size; i++)
    {
        if (isDefined(self.cpc.huds[keys[i]]))
        {
            self.cpc.huds[keys[i]] destroy();
        }
    }
    self.cpcTravelPositions = self.cpc.positions;
    self.cpc = undefined;
    self openCJ\huds\hudProgressBar::onRunStopped();
}

finalize()
{
    if (!self isEditing())
    {
        return;
    }
    self.cpc.finalizing = true;
    if (!self _save() || !self openCJ\checkpointPublish::publish())
    {
        self.cpc.finalizing = undefined;
        self sendLocalChatMessage(self.cpc.status, true);
        return;
    }
    routeName = self.cpc.route;
    if (isDefined(self.cpc.publishedLabel))
    {
        routeName = self.cpc.publishedLabel;
    }
    self openCJ\checkpointPublish::activate();
    // Creating the fresh run waits for SQL. Keep CPC's scoring suppression until
    // onRunCreated has reset checkpoint state and actually spawned the player.
    self openCJ\playerRuns::stopRun(true);
    self _close();
    self openCJ\huds\hudProgressBar::onSpawnPlayer();
    self openCJ\checkpointPointers::showCheckpointPointers();
    self sendLocalChatMessage("Checkpoints for " + routeName + " finalized and ready to play.");
}

onDisconnect()
{
    if (self isEditing())
    {
        self _save();
    }
}

_testStep()
{
    nextCheckpointIndex = self.cpc.testNext;
    if (nextCheckpointIndex >= self.cpc.rows.size)
    {
        return;
    }
    checkpoint = _decode(self.cpc.rows[nextCheckpointIndex]);
    if (checkpoint.finish)
    {
        for (i = nextCheckpointIndex; i < self.cpc.rows.size; i++)
        {
            finishCheckpoint = _decode(self.cpc.rows[i]);
            if (finishCheckpoint.finish && self contains(finishCheckpoint, self.origin, self isOnGround()))
            {
                self.cpc.testNext = self.cpc.rows.size;
                self.cpc.status = "TEST: FINISH " + (i + 1);
                self iprintln(self.cpc.status);
                return;
            }
        }
        return;
    }
    if (self contains(checkpoint, self.origin, self isOnGround()))
    {
        self.cpc.testNext++;
        self.cpc.status = "TEST: passed " + (nextCheckpointIndex + 1) + " / " + self.cpc.rows.size;
        if (checkpoint.finish)
        {
            self.cpc.status += " - FINISH";
        }
        self iprintln(self.cpc.status);
    }
    else
    {
        for (i = nextCheckpointIndex + 1; i < self.cpc.rows.size; i++)
        {
            laterCheckpoint = _decode(self.cpc.rows[i]);
            if (self contains(laterCheckpoint, self.origin, self isOnGround()))
            {
                self.cpc.status =
                    "TEST: out of order - expected " + (nextCheckpointIndex + 1) + ", entered " + (i + 1);
                break;
            }
        }
    }
}

// An empty next slot after a confirmed finish is a route summary, not a new area.
readyToFinalize(draft)
{
    if (isDefined(draft.insertAfter))
    {
        return false;
    }
    if (draft.selected != draft.rows.size || draft.rows.size == 0 || draft.draft.points.size > 0 ||
       draft.draft.alternatives.size > 0)
    {
        return false;
    }
    last = _decode(draft.rows[draft.rows.size - 1]);
    return isDefined(last) && last.finish;
}

_draw()
{
    checkpoint = self.cpc.draft;
    checkpointNumber = self.cpc.selected + 1;
    inserting = isDefined(self.cpc.insertAfter);
    if (inserting)
    {
        checkpointNumber = self.cpc.insertAfter + 2;
    }
    followingShared = !self.cpc.testing && self openCJ\checkpointNetwork::followingShared();
    showRouteSummary = !self.cpc.testing && !followingShared && readyToFinalize(self.cpc);
    if (showRouteSummary)
    {
        checkpointNumber = self.cpc.rows.size;
        checkpoint = _decode(self.cpc.rows[checkpointNumber - 1]);
    }
    if (self.cpc.testing && self.cpc.testNext < self.cpc.rows.size)
    {
        checkpoint = _decode(self.cpc.rows[self.cpc.testNext]);
        checkpointNumber = self.cpc.testNext + 1;
    }
    validationError = openCJ\checkpointMoving::valid(checkpoint);
    displayColor = self.cpc.routeColor;
    displayRoute = self.cpc.route;
    if (isDefined(self.cpc.displayRoutes))
    {
        displayRoute = self.cpc.displayRoutes;
    }
    if (isDefined(self.cpc.sharedCount) && checkpointNumber <= self.cpc.sharedCount)
    {
        displayColor = routeRGB(self.cpc.sharedHex);
        displayRoute = self.cpc.sharedRoute + " (shared)";
    }
    self.cpc.huds[3].color = displayColor;
    self.cpc.huds[3] _setPanelText(getSubStr(displayRoute, 0, 16) + " (" + self.cpc.rows.size +
                                   ")");
    propertyCheckpoint = checkpoint;
    heading = "Selected checkpoint";
    emptySelection = self.cpc.draft.points.size == 0 && self.cpc.draft.alternatives.size == 0;
    if (!inserting && !self.cpc.testing && !followingShared && emptySelection &&
       self.cpc.selected == self.cpc.rows.size && self.cpc.rows.size > 0)
    {
        propertyCheckpoint = _decode(self.cpc.rows[self.cpc.rows.size - 1]);
        heading = "Last checkpoint";
    }
    else if (self.cpc.selected < self.cpc.rows.size)
    {
        heading = "Checkpoint #" + checkpointNumber;
    }
    if (inserting)
    {
        heading = "Insert checkpoint " + checkpointNumber;
    }
    if (openCJ\checkpointMoving::isMoving(propertyCheckpoint))
    {
        heading = "Moving platform";
    }
    self.cpc.huds[0] _setPanelText(heading);
    doubleRPG = "Off";
    finish = "No";
    ground = "Yes";
    if (propertyCheckpoint.double)
    {
        doubleRPG = "On";
    }
    if (propertyCheckpoint.finish)
    {
        finish = "Yes";
    }
    if (!propertyCheckpoint.onGround)
    {
        ground = "No";
    }
    panelText = "Double RPG: " + doubleRPG + " [Num 1]";
    panelText += "\nFinish: " + finish + " [Num 9]";
    panelText += "\nOn ground: " + ground + " [Num 2]";
    saving = "Yes";
    if (!propertyCheckpoint.allowSave)
    {
        saving = "No";
    }
    panelText += "\nAllow save: " + saving + " [Num 3]";
    elevator = "No";
    if (propertyCheckpoint.allowEle)
    {
        elevator = "Yes";
    }
    panelText += "\nAllow ele: " + elevator + " [Num 8]";
    if (isDefined(self.cpc.heightTarget))
    {
        panelText = "Extra height: +" + openCJ\checkpointHeight::above(propertyCheckpoint) +
               " units\nStep: 4 units\nBottom: fixed\nOn ground: " + ground;
    }
    if (!isDefined(self.cpc.propertiesText) || self.cpc.propertiesText != panelText)
    {
        self setClientCvar("opencj_cpc_properties", panelText);
        self.cpc.propertiesText = panelText;
    }
    discardLabel = "^1Discard new:^7 Num Del";
    if (self.cpc.selected < self.cpc.rows.size)
    {
        discardLabel = "^1Delete selected:^7 Num Del";
    }
    else if (!inserting && (emptySelection || showRouteSummary))
    {
        discardLabel = "^1Delete last:^7 Num Del";
    }
    if (self.cpc.testing)
    {
        panelText = "Follow the outline\nExit test: !cp test";
    }
    else if (inserting)
    {
        panelText = "Before checkpoint " + (self.cpc.insertAfter + 2) + "\n^2Detect:^7 Num 0";
        if (self.cpc.insertAfter + 1 == self.cpc.rows.size)
        {
            panelText = "After checkpoint " + (self.cpc.insertAfter + 1) + "\n^2Detect:^7 Num 0";
        }
        if (!emptySelection)
        {
            panelText += "\n^2Confirm insert:^7 Num Enter";
        }
        panelText += "\n" + discardLabel;
    }
    else if (followingShared)
    {
        panelText = "Follow shared landings\n^2Detect:^7 Num 0\n^5Split:^7 !cp split <routes>";
        if (checkpoint.finish)
        {
            panelText += "\n^2Finalize:^7 !cp finalize";
        }
    }
    else if (emptySelection && self.cpc.selected < self.cpc.rows.size)
    {
        panelText = "^2Detect replacement:^7 Num 0\n^3Undo:^7 Num -";
    }
    else if (emptySelection || showRouteSummary)
    {
        panelText = "^2Detect:^7 Num 0";
        if (self.cpc.rows.size > 0)
        {
            panelText += "\n^3Edit:^7 Num 4\n" + discardLabel + "\n^5Add alternative:^7 Num /";
        }
        if (showRouteSummary)
        {
            panelText += "\n^2Finalize:^7 !cp finalize";
        }
    }
    else if (self.cpc.draft.points.size == 0)
    {
        panelText = "^2Detect alternative:^7 Num 0\n" + discardLabel;
    }
    else if (validationError != "")
    {
        panelText = "^2Corner:^7 Num +\n^3Undo:^7 Num -\n^2Detect:^7 Num 0\n" + discardLabel;
    }
    else
    {
        panelText = "^2Confirm:^7 Num Enter";
        if (self.cpc.selected < self.cpc.rows.size)
        {
            panelText = "^3Apply changes:^7 Num Enter";
        }
        panelText += "\n^2Detect again:^7 Num 0\n" + discardLabel;
        if (self.cpc.selected < self.cpc.rows.size)
        {
            panelText += "\n^3Replace:^7 !cp replace";
        }
        if (checkpoint.alternatives.size > 0)
        {
            panelText += "\n^5Cycle area:^7 Num *\n^1Remove area:^7 !cp delete area";
        }
    }
    if (isDefined(self.cpc.heightTarget))
    {
        panelText =
            "^2Raise top:^7 Num +\n^3Lower top:^7 Num -\n^5Done editing height:^7 Num 7\n^2Apply:^7 Num Enter";
    }
    else if (!emptySelection)
    {
        panelText += "\n^5Height:^7 Num 7";
    }
    self.cpc.huds[1] _setPanelText(panelText);
    // Fit the current action list; do not reserve empty rows in shorter states.
    lineCount = 1;
    for (lineIndex = 0; lineIndex < panelText.size; lineIndex++)
    {
        if (panelText[lineIndex] == "\n")
        {
            lineCount++;
        }
    }
    if (lineCount < 4)
    {
        lineCount = 4;
    }
    panelHeight = 36 + lineCount * 17;
    if (!isDefined(self.cpc.panelHeight) || self.cpc.panelHeight != panelHeight)
    {
        self setClientCvar("opencj_cpc_panel_height", panelHeight);
        self.cpc.panelHeight = panelHeight;
    }
    if (self.cpc.status != "" &&
       (!isDefined(self.cpc.lastPanelStatus) || self.cpc.lastPanelStatus != self.cpc.status))
    {
        self sendLocalChatMessage(self.cpc.status);
    }
    self.cpc.lastPanelStatus = self.cpc.status;
    outlineColor = _vec(displayColor) + " 1";
    if (inserting || self.cpc.selected == self.cpc.rows.size)
    {
        outlineColor = "0 1 0 1";
    }
    if (validationError != "")
    {
        outlineColor = "1 0.3 0.1 1";
    }
    if (self.cpc.testing && self.cpc.testNext >= self.cpc.rows.size)
    {
        return;
    }
    // Resolve the whole neighborhood before drawing: sending line batches can
    // yield, allowing another editor command to change the current selection.
    nextCheckpoint = undefined;
    previousCheckpoint = undefined;
    nextIndex = nextPreviewIndex(self.cpc);
    if (!self.cpc.testing && nextIndex < self.cpc.rows.size)
    {
        nextCheckpoint = _decode(self.cpc.rows[nextIndex]);
    }
    noSelection =
        !self.cpc.testing && !inserting && emptySelection && self.cpc.selected == self.cpc.rows.size;
    previousIndex = checkpointNumber - 2;
    if (noSelection && showRouteSummary)
    {
        previousIndex = -1;
    }
    while (previousIndex >= 0 && previousIndex < self.cpc.rows.size)
    {
        previousCheckpoint = _decode(self.cpc.rows[previousIndex]);
        if (!previousCheckpoint.finish)
        {
            break;
        }
        previousCheckpoint = undefined;
        previousIndex--;
    }
    self _outlineGroup(checkpoint, outlineColor);
    if (isDefined(nextCheckpoint))
    {
        label = "Next #" + (nextIndex + 1 + int(inserting));
        if (nextCheckpoint.finish)
        {
            label += " FINISH";
        }
        self _previewGroup(nextCheckpoint, label, "0.2 0.6 1 1");
        if (checkpoint.points.size > 0)
        {
            self _line(_center(openCJ\checkpointMoving::points(checkpoint)),
                       _center(openCJ\checkpointMoving::points(nextCheckpoint)), "0.2 0.6 1 1");
        }
    }
    if (isDefined(previousCheckpoint))
    {
        if (noSelection)
        {
            self _outlineGroup(previousCheckpoint, "0.55 0.55 0.55 1");
        }
        else
        {
            self _previewGroup(previousCheckpoint, "Previous #" + (previousIndex + 1), "0.55 0.55 0.55 1");
        }
        if (checkpoint.points.size > 0)
        {
            self _line(_center(openCJ\checkpointMoving::points(previousCheckpoint)),
                       _center(openCJ\checkpointMoving::points(checkpoint)), "1 0.8 0 1");
        }
        else if (inserting && isDefined(nextCheckpoint))
        {
            self _line(_center(openCJ\checkpointMoving::points(previousCheckpoint)),
                       _center(openCJ\checkpointMoving::points(nextCheckpoint)), "0.2 0.6 1 1");
        }
    }
    self openCJ\checkpointNetwork::drawConnections(checkpoint);
    if (isDefined(self.cpc.overlap))
    {
        self _outlineGroup(self.cpc.overlap, "1 0.2 0 1");
    }
}

// Both neighbors use the same full-volume representation as the selection.
_previewGroup(checkpoint, label, color)
{
    self _outlineGroup(checkpoint, color);
    self _drawCommand("M t " + _vec(_center(openCJ\checkpointMoving::points(checkpoint))) + ";" + color +
                      ";0.8;400;" + label);
    for(i = 0; i < checkpoint.alternatives.size; i++)
    {
        self _drawCommand("M t " + _vec(_center(checkpoint.alternatives[i])) + ";" + color + ";0.8;400;" +
                          label);
    }
}

_outlineGroup(checkpoint, color)
{
    self _outline(openCJ\checkpointMoving::points(checkpoint), color, openCJ\checkpointHeight::above(checkpoint));
    for (i = 0; i < checkpoint.alternatives.size; i++)
    {
        self _outline(checkpoint.alternatives[i], "1 0.2 1 1", openCJ\checkpointHeight::above(checkpoint));
        if (checkpoint.points.size > 0)
        {
            self _line(_center(checkpoint.points), _center(checkpoint.alternatives[i]), "1 0.2 1 1");
        }
    }
}

_center(points)
{
    center = (0, 0, 0);
    for (i = 0; i < points.size; i++)
    {
        center += points[i];
    }
    if (!points.size)
    {
        return (0, 0, 0);
    }
    return vectorScale(center, 1.0 / points.size) + (0, 0, 12);
}

_vec(coordinates)
{
    return coordinates[0] + " " + coordinates[1] + " " + coordinates[2];
}

boundedHudText(text)
{
    // Client HUD text formatting at 0x438230 silently rejects >255 characters.
    // Leave room for engine string control bytes; bound each panel block independently.
    return getSubStr(text, 0, 240);
}

_setPanelText(text)
{
    text = boundedHudText(text);
    if (text != self.lastText)
    {
        self setText(text);
        self.lastText = text;
    }
}

_line(startPoint, endPoint, color)
{
    // Durations count rendered frames; allow a larger group time to refresh.
    self _drawCommand("M l " + _vec(startPoint) + ";" + _vec(endPoint) + ";" + color + ";1;400");
}

_drawCommand(command)
{
    // At 64 unacknowledged commands CoD4x drops unsent disposable commands.
    // Yield small batches so snapshots can send them and receive acknowledgments.
    if (self.cpc.drawCommands >= 12)
    {
        wait 0.05;
        self.cpc.drawCommands = 0;
    }
    self SV_GameSendServerCommand(command, false);
    self.cpc.drawCommands++;
}

// Invalid drafts still show their edges, but have no support plane for height labels.
_outline(points, color, above)
{
    if (!isDefined(above))
    {
        above = 0;
    }

    hasValidPlane = openCJ\checkpointArea::validate(points) == "";
    supportOffset = 0;
    if (hasValidPlane)
    {
        supportOffset = openCJ\checkpointArea::supportOffset(points);
    }

    height = 6 + above + supportOffset;
    if (hasValidPlane && (above > 0 || isDefined(self.cpc.heightTarget)))
    {
        center = _center(points) - (0, 0, 12);
        upperLabel = center + (0, 0, 4 + supportOffset + above);
        baseLabel = center - (0, 0, 2);
        self _drawCommand("M t " + _vec(upperLabel) + ";0 1 1 1;0.6;400;Upper +" + above);
        self _drawCommand("M t " + _vec(baseLabel) + ";1 0.7 0 1;0.6;400;Base");
    }

    for (i = 0; i < points.size; i++)
    {
        edgeStart = points[i] - (0, 0, 2);
        edgeEnd = points[(i + 1) % points.size] - (0, 0, 2);
        self _line(edgeStart, edgeEnd, color);
        self _line(edgeStart + (0, 0, height), edgeEnd + (0, 0, height), color);
        self _line(edgeStart, edgeStart + (0, 0, height), color);
        self _drawCommand("M t " + _vec(edgeStart + (0, 0, 10)) + ";1 1 1 1;0.6;400;" + (i + 1));
    }
}

getConfirmed(index)
{
    return _decode(self.cpc.rows[index]);
}

// Editor travel saves deliberately do not carry run IDs or checkpoint progress.
processTravelRequests()
{
    if (isDefined(self.cpc.finalizing))
    {
        return;
    }
    // Teleporting inside the client-command callback can re-enter movement/VM code.
    // Match normal play: consume travel commands from the scheduled game update.
    if (isDefined(self.cpc.restoreOrigin))
    {
        savedPosition = spawnStruct();
        savedPosition.origin = self.cpc.restoreOrigin;
        savedPosition.angles = self getPlayerAngles();
        if (isDefined(self.cpc.restoreAngles))
        {
            savedPosition.angles = self.cpc.restoreAngles;
        }
        self.cpc.restoreAngles = undefined;
        self.cpc.restoreOrigin = undefined;
        self openCJ\mapBoost::cancel();
        self setoriginandangles(savedPosition.origin, savedPosition.angles);
        self setVelocity((0, 0, 0));
        self rememberPosition(savedPosition);
    }
    if (isDefined(self.eventQueue["save"]))
    {
        self savePosition();
    }
    if (isDefined(self.eventQueue["load"]))
    {
        self loadPosition(self.eventQueue["load"]);
    }
    self.eventQueue = [];
}

savePosition()
{
    if (self.sessionState != "playing" || !self isOnGround())
    {
        self iprintln("Land before saving an editor position");
        return;
    }
    savedPosition = spawnStruct();
    savedPosition.origin = self.origin;
    savedPosition.angles = self getPlayerAngles();
    self rememberPosition(savedPosition);
    self.cpc.savedPosition = savedPosition;
    if (self _save())
    {
        self openCJ\savePosition::printSaveSuccess();
    }
    else
    {
        self iprintln(
            "Position saved for this session, but draft write failed; use !cp save to retry");
    }
}

// Bound session-only travel history; no run state or database writes.
rememberPosition(savedPosition)
{
    lastHistoryIndex = self.cpc.positions.size;
    if (lastHistoryIndex > 255)
    {
        lastHistoryIndex = 255;
    }
    for (i = lastHistoryIndex; i > 0; i--)
    {
        self.cpc.positions[i] = self.cpc.positions[i - 1];
    }
    self.cpc.positions[0] = savedPosition;
    self.cpc.travelIndex = 0;
}

loadPosition(backwardsAmount)
{
    if (!isDefined(self.cpc.travelIndex) || backwardsAmount == 0)
    {
        self.cpc.travelIndex = 0;
    }
    positionIndex = self.cpc.travelIndex + backwardsAmount;
    if (positionIndex < 0)
    {
        positionIndex = 0;
    }
    savedPosition = self.cpc.positions[positionIndex];
    if (!isDefined(savedPosition))
    {
        savedPosition = self openCJ\savePosition::getSavedPosition(positionIndex - self.cpc.positions.size);
    }
    if (!isDefined(savedPosition))
    {
        self iprintln("No editor position saved in this slot");
        return false;
    }
    self.cpc.travelIndex = positionIndex;
    self openCJ\mapBoost::cancel();
    self setoriginandangles(savedPosition.origin, savedPosition.angles);
    self setVelocity((0, 0, 0));
    self openCJ\savePosition::printLoadSuccess();
    return true;
}
