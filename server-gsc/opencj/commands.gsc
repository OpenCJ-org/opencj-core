#include openCJ\util;

onInit()
{
    openCJ\commands_base::registerCommand("sqlstats", "Show SQL queue, latency and failure diagnostics.", openCJ\mySQL::showStats, 0, 0, 50);
    cmd = openCJ\commands_base::registerCommand("kick", "Kick a specific player. Usage: !kick <playerName|playerId> [reason]", ::_onCommandKick, 1, 2, 50); // TODO: correct admin level value
    cmd = openCJ\commands_base::registerCommand("ban", "Ban a specific player. Usage: !ban <playerName|playerId> [reason]", ::_onCommandBan, 1, 2, 70); // TODO: correct admin level value

    cmd = openCJ\commands_base::registerCommand("ip", "Shows you your own ip using getip() function", ::_onCommandShowIP, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "showip");

    cmd = openCJ\commands_base::registerCommand("resetrun", "Resets your current run.", ::_onCommandResetRun, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "reset");

    cmd = openCJ\commands_base::registerCommand("toggletarget", "Toggles a reference target.", ::_onCommandToggleTarget, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "target");

    cmd = openCJ\commands_base::registerCommand("playerid", "View your playerID", ::_onCmdPID, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "pid");

    cmd = openCJ\commands_base::registerCommand("saverun", "Save your current run. Usage: !saverun [label]", ::_onCmdSaveRun, 0, 1, 0);
    cmd = openCJ\commands_base::registerCommand("pauserun", "Pause your current run", ::_onCmdPauseRun, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "p");
    cmd = openCJ\commands_base::registerCommand("resumerun", "Resume your current run", ::_onCmdResumeRun, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "r");

    cmd = openCJ\commands_base::registerCommand("restoreposition", "Restore your last used run", ::_onCmdRestorePosition, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "restorerun");
    openCJ\commands_base::addAlias(cmd, "rp");
    openCJ\commands_base::addAlias(cmd, "historyload");

    cmd = openCJ\commands_base::registerCommand("runs", "List your runs or load a specific run. Usage: !runs [runID]", ::_onCmdRuns, 0, 1, 0);
    openCJ\commands_base::addAlias(cmd, "historyloads");

    cmd = openCJ\commands_base::registerCommand("ts", "Teleport to a specific player's save", ::_onCmdTeleSave, 1, 1, 0);
    cmd = openCJ\commands_base::registerCommand("tp", "Teleport to a specific player's position", ::_onCmdTelePos, 1, 1, 0);

    cmd = openCJ\commands_base::registerCommand("maplist", "List currently available maps.", ::_onCommandMapList, 0, 0, 0);
    openCJ\commands_base::addAlias(cmd, "maps");

    // Useful admin commands for debugging maps
    cmd = openCJ\commands_base::registerCommand("ent", "Teleport to an entity", ::_onCmdEntTele, 1, 2, 90);
    cmd = openCJ\commands_base::registerCommand("setorigin", "Teleport to a position", ::_onCmdSetOrigin, 3, 3, 90);
}

onPlayerDisconnect()
{
    self cancelRestoreLookup();
    if (isDefined(self.targetRef))
    {
        self.targetRef delete();
    }
}

_onCommandMapList(args)
{
    maps = openCJ\maps::voteMaps(self.adminLevel);
    maxCharsPerLine = 100;
    mapStr = "";
    mapListNr = 1;
    for (i = 0; i < maps.size; i++)
    {
        mapName = maps[i]["name"];
        if ((mapStr.size + mapName.size) > maxCharsPerLine)
        {
            self sendLocalChatMessage("Maps (" + mapListNr + "): " + mapStr);
            mapListNr++;
            mapStr = mapName;
        }
        else
        {
            if (i != 0)
            {
                mapStr += ", ";
            }
            mapStr += mapName;
        }
    }
    self sendLocalChatMessage("Maps (" + mapListNr + "): " + mapStr);
}

_onCommandToggleTarget(args)
{
    if (isDefined(self.targetRef)) 
    {
        self.targetRef delete();
        self iPrintLn("^3[Target beta] Removed target");
    } 
    else 
    {
        targetRef = spawn("script_model", self getOrigin());
        targetRef setModel("body_mp_usmc_specops"); // @TODO: change to something simple
        targetRef hide();
        targetRef showToPlayer(self);
        self iPrintLn("^3[Target beta] Added target!");
        self.targetRef = targetRef;
    }
}

_onCommandKick(args)
{
    self sendLocalChatMessage("Not implemented yet", true); // TODO: implement
}

_onCommandBan(args)
{
    self sendLocalChatMessage("Not implemented yet", true); // TODO: implement
}

_onCommandShowIP(args)
{
    self sendLocalChatMessage("Your IP is: " + self getip());
}

_onCmdPID(args)
{
    if (self openCJ\login::isLoggedIn())
    {
        self sendLocalChatMessage("Your playerID is: " + self openCJ\login::getPlayerID());
    }
    else
    {
        self sendLocalChatMessage("^1You are not logged in");
    }
}

_onCommandResetRun(args)
{
    self thread openCJ\playerRuns::stopRun(true);
}

_onCmdSaveRun(args)
{
    runLabel = "";
    if (args.size > 0)
    {
        runLabel = args[0];
    }
    self thread openCJ\playerRuns::saveRun(runLabel);
}

_onCmdPauseRun(args)
{
    if (self openCJ\playerRuns::hasRunID())
    {
        self thread openCJ\cheating::setCheating(true);
    }
    else
    {
        self sendLocalChatMessage("You are not in a run", true);
    }
}

_onCmdResumeRun(args)
{
    failed = true;
    cheatingFlag = level.saveFlags[level.saveFlagName_cheating];
    backwardsCount = self savePosition_selectWithoutFlag(cheatingFlag);
    if (isDefined(backwardsCount)) // If not defined, could not be found
    {
        if (self openCJ\savePosition::canLoadError(backwardsCount) == 0)
        {
            self openCJ\savePosition::resetBackwardsCount();
            self openCJ\events\eventHandler::onLoadPositionRequest(backwardsCount);
            failed = false;
        }
    }

    if (failed)
    {
        info=self savePosition_historyInfo();
        if(self openCJ\historySave::maybePrefetch(info[0]-1))
        {
            self sendLocalChatMessage("Loading older saves. Try again shortly.");
            return;
        }
        self sendLocalChatMessage("Could not find a safe position in the available save history.", true);
    }
}

_onCmdRestorePosition(args)
{
    self thread _restoreLastRun();
}

_onCmdRuns(args) // TODO: support self-named runs
{
    if (args.size == 0)
    {
        // TODO: allow viewing runs via chat too
        self sendLocalChatMessage("Use the runs menu to view your runs.");
    }
    else
    {
        if (isValidInt(args[0]))
        {
            runID = int(args[0]);
            self thread openCJ\playerRuns::restoreRun(runID);
        }
    }
}

// Restore the newest eligible run only while this lookup still belongs to the player.
_restoreLastRun(excludedRunID)
{
    self endon("disconnect");
    if (isDefined(self.cpc))
    {
        self sendLocalChatMessage("Exit checkpoint editing with !cp stop before restoring a run.", true);
        return;
    }
    self endon("cpc_started");
    if (!self openCJ\playerRuns::_canAccessRuns())
    {
        return;
    }

    if (!isDefined(excludedRunID) && self openCJ\playerRuns::hasRunID())
    {
        excludedRunID = self openCJ\playerRuns::getRunID();
    }
    excludeCurrentRun = "";
    if (isDefined(excludedRunID))
    {
        excludeCurrentRun = " AND runID != " + excludedRunID;
    }
    query = "SELECT runID FROM playerRuns "
            + "WHERE playerID = " + self openCJ\login::getPlayerID()
            + " AND finishTimeStamp IS NULL"
            + " AND mapID = " + openCJ\mapID::getMapID()
            + excludeCurrentRun
            + " AND archived = False"
            + " ORDER BY lastUsedTimeStamp DESC, runID DESC LIMIT 1";

    request = self _beginRestoreLookup();
    // Scoped cancellation uses the native menu-read policy, with a scope separate from UI menus.
    result = self openCJ\mySQL::_request(query, level.sqlConstants.policyMenu, "", request.scope,
                                       level.sqlConstants.defaultQueueWaitMs, true);
    // Cancellation can arrive after SQL completion but before this thread resumes.
    if (!isDefined(self.latestRunLookup) || self.latestRunLookup != request)
    {
        return;
    }
    self.latestRunLookup = undefined;
    rows = result.rows;
    if (!isDefined(rows) || rows.size == 0 || !isDefined(rows[0][0]))
    {
        self sendLocalChatMessage("Failed to restore position, please use runs menu instead", true);
        return;
    }
    restoredRunID = int(rows[0][0]);
    if (!isDefined(excludedRunID) || restoredRunID != excludedRunID)
    {
        // The loader owns success/failure messages; selecting a row is not a successful restore.
        self openCJ\playerRuns::restoreRun(restoredRunID);
    }
}

// Give each lookup its own scope, including after an entity slot is reused.
_beginRestoreLookup()
{
    self cancelRestoreLookup();
    if (!isDefined(level.latestRunLookupSequence))
    {
        level.latestRunLookupSequence = 0;
    }
    level.latestRunLookupSequence++;
    request = spawnStruct();
    request.scope = "run-restore:" + self getEntityNumber() + ":" + level.latestRunLookupSequence;
    self.latestRunLookup = request;
    return request;
}

// Stop obsolete reads while retaining completion so waiting callers can finish normally.
cancelRestoreLookup()
{
    if (!isDefined(self.latestRunLookup))
    {
        return;
    }
    request = self.latestRunLookup;
    self.latestRunLookup = undefined;
    mysql_async_cancel(request.scope, level.sqlConstants.scopeExact,
                       level.sqlConstants.retainCompletion);
}

// Useful commands for debugging maps

// Validate the selected entity before marking the run assisted and moving the player.
_onCmdEntTele(args)
{
    if (self.sessionState != "playing")
    {
        return;
    }
    if (!isDefined(args) || args.size == 0)
    {
        return;
    }
    targetName = args[0];
    entities = getEntArray(targetName, "targetname");
    if (!isDefined(entities) || entities.size == 0)
    {
        self sendLocalChatMessage("Entity not found", true);
        return;
    }
    entityIndex = 0;
    if (args.size > 1)
    {
        entityIndex = _parseTeleportInteger(args[1]);
    }
    if (!isDefined(entityIndex) || entityIndex < 0 || entityIndex >= entities.size)
    {
        self sendLocalChatMessage("Use an entity index from 0 to " + (entities.size - 1), true);
        return;
    }

    self openCJ\cheating::setCheating(true);
    self openCJ\mapBoost::cancel();
    self setOrigin(entities[entityIndex].origin);
    self sendLocalChatMessage("Teleported you to entity: " + targetName + "[" + entityIndex + "]");
}

_onCmdSetOrigin(args)
{
    if (self.sessionState != "playing")
    {
        return;
    }
    // Command registration requires exactly three coordinate arguments.
    coordinates = [];
    for (i = 0; i < args.size; i++)
    {
        coordinates[i] = _parseTeleportInteger(args[i]);
        if (!isDefined(coordinates[i]))
        {
            self sendLocalChatMessage("Use integer coordinates, for example: !setorigin -10 20 30", true);
            return;
        }
    }

    // Administrative movement must not leave an ordinary competitive run eligible to continue.
    self openCJ\cheating::setCheating(true);
    self openCJ\mapBoost::cancel();
    self setOrigin((coordinates[0], coordinates[1], coordinates[2]));
}

// Require canonical signed decimal input: the legacy native validator also accepts numeric prefixes.
_parseTeleportInteger(text)
{
    if (!isValidInt(text))
    {
        return undefined;
    }
    value = int(text);
    if ("" + value != text)
    {
        return undefined;
    }
    return value;
}

_onCmdTeleSave(args)
{
    self thread _teleportToPlayer(args, true);
}

_onCmdTelePos(args)
{
    self thread _teleportToPlayer(args, false);
}

// Resolve command text before starting the player's teleport operation.
_teleportToPlayer(args, teleportToSave)
{
    if (args.size != 1)
    {
        return;
    }
    targetPlayer = findPlayerByArg(args[0]);
    if (!isDefined(targetPlayer))
    {
        self sendLocalChatMessage("Target player could not be found", true);
        return;
    }
    if (targetPlayer == self)
    {
        self sendLocalChatMessage("You're already at your own location..", true);
        return;
    }
    self teleportToPlayer(targetPlayer, teleportToSave);
}

// Move to a resolved target only after this operation's spawn has succeeded.
teleportToPlayer(targetPlayer, teleportToSave)
{
    self notify("command_teleport_changed");
    self endon("command_teleport_changed");
    self endon("disconnect");
    self endon("cpc_started");
    if (self.sessionState != "playing" && self.sessionState != "spectator")
    {
        return;
    }

    // Mark assistance before spawning so no intervening save can look competitive.
    self openCJ\cheating::setCheating(true);
    if (self isSpectator())
    {
        waittillframeend;
        expectedSpawnVersion = 1;
        if (isDefined(self.spawnRequestVersion))
        {
            expectedSpawnVersion = self.spawnRequestVersion + 1;
        }
        // The spawn routine has bounded SQL waits and can return without spawning.
        self openCJ\events\spawnPlayer::main();
        waittillframeend;
        if (self.sessionState != "playing" || self.spawnRequestVersion != expectedSpawnVersion)
        {
            return;
        }
    }
    if (!isDefined(targetPlayer))
    {
        self sendLocalChatMessage("Target player disconnected before teleporting", true);
        return;
    }

    useCurrentPosition = !teleportToSave;
    if (teleportToSave)
    {
        savedPositionIndex = targetPlayer openCJ\savePosition::getBackwardsCount();
        savedPosition = targetPlayer openCJ\savePosition::getSavedPosition(savedPositionIndex);
        if (isDefined(savedPosition))
        {
            self sendLocalChatMessage("Teleported you to target player's save");
            self openCJ\mapBoost::cancel();
            self setOrigin(savedPosition.origin);
            self setPlayerAngles(savedPosition.angles);
        }
        else
        {
            self sendLocalChatMessage("Target player save not available, teleporting to position", true);
            useCurrentPosition = true;
        }
    }
    if (useCurrentPosition)
    {
        self openCJ\mapBoost::cancel();
        self setOrigin(targetPlayer getOrigin());
        self setPlayerAngles(targetPlayer getPlayerAngles());
    }
}
