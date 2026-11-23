#include openCJ\util;

onInit()
{
    setClientNameMode("auto_change");
    if(!isDefined(game["nameCooldowns"]))
    {
        game["nameCooldowns"] = [];
    }
    level.recordNameOverrides = [];
    openCJ\namePolicy::onInit();
    cmd = openCJ\commands_base::registerCommand(
        "prefname",
        "Persistent record name. Usage: !prefname [set <name>|reset] (3-15 characters, no colors; changes once per hour)",
        ::_onPreferredName, 0, undefined, 0);
    cmd.redactArgs = true;
    cmd = openCJ\commands_base::registerCommand(
        "frename", "Force/reset an online player's regular name. Usage: !frename <player> [name]",
        ::_onFRenameCommand, 1, undefined, 40);
    cmd.redactArgs = true;
    openCJ\commands_base::registerCommand(
        "resetprefname",
        "Remove an account's preferred name and start its one-hour cooldown. Usage: !resetprefname <playerID>",
        ::_onResetPreferredName, 1, 1, 40);
    openCJ\commands_base::registerCommand("reloadnamerules",
                                          "Reload the server's private name-moderation rules.",
                                          ::_onReloadRules, 0, 0, 60);
}

onPlayerConnect()
{
    self _createPlayerNameHud();
    self _hidePlayerNameHud();
    if(!isDefined(self.nameAccepted))
    {
        self onUserInfoChanged();
    }
}
onPlayerLogin()
{
    self.forcedName = undefined;
}

// GUID protects the connection before OpenCJ account login finishes; account ID
// then protects the same account even when its connection identity changes.
// Only strings/numbers/arrays are retained in game, never player entities.
_initRegularName()
{
    if(isDefined(self.nameMemoryReady))
    {
        return;
    }
    self.nameMemoryReady = true;
    guid = self getGuid();
    if(isDefined(guid) && guid != "" && guid != "0")
    {
        self.nameGuidKey = "g:" + guid;
        self _restoreRegularName(_cachedRegularName(self.nameGuidKey));
    }
}
onAccountIdentified()
{
    self _initRegularName();
    requested = self getUserInfo("name");
    self.nameAccountKey = "p:" + self openCJ\login::getPlayerID();
    self _restoreRegularName(_cachedRegularName(self.nameAccountKey));
    self _rename(requested);
    self _rememberRegularName();
    self thread _loadPreferredName();
}
_cachedRegularName(key)
{
    if(!isDefined(key) || !isDefined(game["nameCooldowns"]))
    {
        return undefined;
    }
    entry = game["nameCooldowns"][key];
    if(isDefined(entry) && getRealTime() - entry[2] < 60)
    {
        return entry;
    }
    return undefined;
}
_restoreRegularName(entry)
{
    if(!isDefined(entry))
    {
        return;
    }
    self.nameAccepted = entry[0];
    self.nameLastChange = entry[1];
}
_rememberRegularName()
{
    if(!isDefined(self.nameAccepted))
    {
        return;
    }
    now = getRealTime();
    // Drop expired disconnected entries so the cache cannot grow forever.
    if(!isDefined(game["nameCooldownPruned"]) || now - game["nameCooldownPruned"] >= 60)
    {
        keys = getArrayKeys(game["nameCooldowns"]);
        for(i = 0; i < keys.size; i++)
        {
            if(now - game["nameCooldowns"][keys[i]][2] >= 60)
            {
                game["nameCooldowns"][keys[i]] = undefined;
            }
        }
        game["nameCooldownPruned"] = now;
    }
    entry = [];
    entry[0] = self.nameAccepted;
    entry[1] = self.nameLastChange;
    entry[2] = now;
    if(isDefined(self.nameGuidKey))
    {
        game["nameCooldowns"][self.nameGuidKey] = entry;
    }
    if(isDefined(self.nameAccountKey))
    {
        game["nameCooldowns"][self.nameAccountKey] = entry;
    }
}
_loadPreferredName()
{
    self endon("disconnect");
    id = self openCJ\login::getPlayerID();
    version = _recordNameVersion(id);
    rows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT preferredName FROM playerNamePreferences WHERE playerID=" + id);
    if(!isDefined(rows) || _recordNameVersion(id) != version)
    {
        return;
    }
    name = undefined;
    if(hasResult(rows))
    {
        name = rows[0][0];
    }
    _publishPreferredName(id, name);
}
_recordNameVersion(id)
{
    entry = level.recordNameOverrides["p:" + id];
    if(!isDefined(entry))
    {
        return 0;
    }
    return entry.version;
}
_publishPreferredName(id, name, fallback)
{
    previous = level.recordNameOverrides["p:" + id];
    if(!isDefined(fallback) && isDefined(previous))
    {
        fallback = previous.fallback;
    }
    entry = spawnStruct();
    entry.version = _recordNameVersion(id) + 1;
    entry.name = name;
    entry.fallback = fallback;
    level.recordNameOverrides["p:" + id] = entry;
    openCJ\showRecords::onRecordNameChanged();
}
getRecordName()
{
    if(self openCJ\login::isLoggedIn())
    {
        return recordName(self openCJ\login::getPlayerID(), self.name);
    }
    return self.name;
}
recordName(id, fallback)
{
    entry = level.recordNameOverrides["p:" + id];
    if(isDefined(entry) && isDefined(entry.name))
    {
        return entry.name;
    }
    if(isDefined(entry) && isDefined(entry.fallback))
    {
        return entry.fallback;
    }
    return fallback;
}
_recordNameFallback(name)
{
    if(!self openCJ\login::isLoggedIn())
    {
        return;
    }
    key = "p:" + self openCJ\login::getPlayerID();
    if(!isDefined(level.recordNameOverrides[key]))
    {
        entry = spawnStruct();
        entry.version = 0;
        level.recordNameOverrides[key] = entry;
    }
    level.recordNameOverrides[key].fallback = name;
}

onUserInfoChanged()
{
    if(isDefined(self getForcedName()))
    {
        self _applyName(self.forcedName, false);
        return;
    }
    self _rename(self getUserInfo("name"));
}
_rename(newName)
{
    self _initRegularName();
    cleaned = cleanPlayerName(newName);
    if(!isDefined(cleaned))
    {
        return;
    }
    initial = !isDefined(self.nameAccepted);
    if(!initial && cleaned == self.nameAccepted)
    {
        if(newName != cleaned)
        {
            self _applyName(cleaned, false);
        }
        return;
    }
    if(!initial && isDefined(self.nameLastChange) && getRealTime() - self.nameLastChange < 60)
    {
        self _applyName(self.nameAccepted, false);
        self _nameNotice("Please wait " + (60 - (getRealTime() - self.nameLastChange)) +
                         " seconds before changing your name.");
        return;
    }
    rule = openCJ\namePolicy::blockedRule(cleaned);
    if(rule != 0)
    {
        cleaned = self openCJ\namePolicy::fallbackName();
        if(rule < 0)
        {
            self _nameNotice("Name checks are unavailable; a temporary name has been assigned.");
        }
        else
        {
            self _nameNotice(
                "That name is not allowed. A temporary name has been assigned; choose a different name.");
        }
    }
    if(!initial && cleaned == self.nameAccepted)
    {
        self _applyName(cleaned, false);
        return;
    }
    // Only a genuinely new connection identity gets the initial-name exemption.
    if(!initial)
    {
        self.nameLastChange = getRealTime();
    }
    self _applyName(cleaned, true);
}
_applyName(name, persist)
{
    self.nameAccepted = name;
    cleaned = self renameClient(name);
    if(isDefined(cleaned))
    {
        self.nameAccepted = cleaned;
    }
    self.currentName = self.nameAccepted;
    self _rememberRegularName();
    self _recordNameFallback(self.nameAccepted);
    if(self getUserInfo("name") != self.nameAccepted)
    {
        self setClientCvar("name", self.nameAccepted);
    }
    if(persist && self openCJ\login::isLoggedIn())
    {
        self thread _storeNewName(self.nameAccepted);
    }
}
_storeNewName(name)
{
    // Actual accepted changes are rate-limited before publication. Submit the
    // write immediately, so a disconnect cannot discard a debounce timer.
    self openCJ\mySQL::mysqlAsyncWriteNosave("CALL setName(" + self openCJ\login::getPlayerID() +
                                                 ", '" + openCJ\mySQL::escapeString(name) + "')",
                                             "name:" + self openCJ\login::getPlayerID());
}
_nameNotice(message)
{
    if(isDefined(self.nameNoticeTime) && getTime() - self.nameNoticeTime < 3000)
    {
        return;
    }
    self.nameNoticeTime = getTime();
    self sendLocalChatMessage(message, true);
}
getForcedName()
{
    return self.forcedName;
}
setForcedName(name)
{
    if(!self openCJ\login::isLoggedIn())
    {
        return;
    }
    if(!isDefined(name))
    {
        self.forcedName = undefined;
        return;
    }
    name = cleanPlayerName(name);
    if(openCJ\namePolicy::blockedRule(name) != 0)
    {
        name = self openCJ\namePolicy::fallbackName();
    }
    self.forcedName = name;
    self _applyName(name, true);
}
_onFRenameCommand(args)
{
    player = findPlayerByArg(args[0]);
    if(!isDefined(player) || !player openCJ\login::isLoggedIn())
    {
        self sendLocalChatMessage("Cannot find player.", true);
        return;
    }
    if(args.size < 2)
    {
        player setForcedName();
        self sendLocalChatMessage("Forced name removed.");
        return;
    }
    name = arrayConcat(subArray(args, 1));
    player setForcedName(name);
    self sendLocalChatMessage("Player name updated.");
}
_onPreferredName(args)
{
    if(!self openCJ\login::isLoggedIn())
    {
        return;
    }
    if(isDefined(self.preferredNameBusy) && self.preferredNameBusy)
    {
        self sendLocalChatMessage("A name request is already being processed.", true);
        return;
    }
    self.preferredNameBusy = true;
    self _preferredNameRequest(args);
    self.preferredNameBusy = false;
}
_preferredNameRequest(args)
{
    id = self openCJ\login::getPlayerID();
    if(args.size == 0)
    {
        rows = self openCJ\mySQL::mysqlAsyncRead(
            "SELECT n.preferredName,GREATEST(0,3600-TIMESTAMPDIFF(SECOND,n.changedAt,UTC_TIMESTAMP(6))) FROM playerInformation p LEFT JOIN playerNamePreferences n ON n.playerID=p.playerID WHERE p.playerID=" +
            id);
        if(!hasResult(rows))
        {
            self sendLocalChatMessage("Name service unavailable. Please try again.", true);
            return;
        }
        text = "No preferred name set; records use your current name.";
        if(isDefined(rows[0][0]))
        {
            text = "Preferred record name: " + rows[0][0];
        }
        if(isDefined(rows[0][1]) && int(rows[0][1]) > 0)
        {
            text += ". Next change in " + rows[0][1] + " seconds.";
        }
        self sendLocalChatMessage(text);
        return;
    }
    reset = args.size == 1 && toLower(args[0]) == "reset";
    value = "NULL";
    name = "";
    if(!reset)
    {
        offset = 0;
        if(toLower(args[0]) == "set")
        {
            offset = 1;
        }
        name = openCJ\namePolicy::preferredName(arrayConcat(subArray(args, offset)));
        if(!isDefined(name))
        {
            self sendLocalChatMessage(
                "Use 3-15 printable characters, including a letter or number. Color codes are not allowed.",
                true);
            return;
        }
        if(openCJ\namePolicy::blockedRule(name) != 0)
        {
            self sendLocalChatMessage(
                "That name cannot be used. Choose a different name or contact a moderator.", true);
            return;
        }
        value = "'" + openCJ\mySQL::escapeString(name) + "'";
    }
    rows = self openCJ\mySQL::mysqlAsyncWrite("SELECT setPreferredName(" + id + "," + value + ")",
                                              "prefname:" + id);
    if(!hasResult(rows))
    {
        self sendLocalChatMessage(
            "Name service unavailable. Please query !prefname before retrying.", true);
        return;
    }
    result = int(rows[0][0]);
    if(result == 0)
    {
        preferred = undefined;
        if(!reset)
        {
            preferred = name;
        }
        _publishPreferredName(id, preferred);
        self _recordNameFallback(self.name);
        if(reset)
        {
            self sendLocalChatMessage("Preferred name cleared. Records now use your current name.");
        }
        else
        {
            self sendLocalChatMessage("Preferred record name set to " + name + ".");
        }
    }
    else if(result == -1)
    {
        self sendLocalChatMessage("Your preferred name is already set that way.");
    }
    else if(result == -3)
    {
        self sendLocalChatMessage("That preferred name is already taken.", true);
    }
    else if(result > 0)
    {
        self sendLocalChatMessage(
            "Please wait " + result + " seconds before changing your preferred name.", true);
    }
    else if(result == -5)
    {
        self sendLocalChatMessage("That name is not allowed. Choose a different name.", true);
    }
    else
    {
        self sendLocalChatMessage("That preferred name could not be saved.", true);
    }
}
_onResetPreferredName(args)
{
    targetPlayerID = parsePlayerID(args[0]);
    if(!isDefined(targetPlayerID))
    {
        self sendLocalChatMessage("Use a playerID between 1 and 2147483647.", true);
        return;
    }
    rows = self openCJ\mySQL::mysqlAsyncWrite("SELECT resetPreferredNameByModerator(" +
                                                  self openCJ\login::getPlayerID() + "," +
                                                  targetPlayerID + ")",
                                              "prefname:" + targetPlayerID);
    if(hasResult(rows) && int(rows[0][0]) == 0)
    {
        rows = self openCJ\mySQL::mysqlAsyncRead(
            "SELECT playerName FROM playerInformation WHERE playerID=" + targetPlayerID);
        fallback = undefined;
        if(hasResult(rows))
        {
            fallback = rows[0][0];
        }
        _publishPreferredName(targetPlayerID, undefined, fallback);
        self sendLocalChatMessage("Preferred name removed; one-hour cooldown applied.");
    }
    else
    {
        self sendLocalChatMessage("Could not reset that account's preferred name.", true);
    }
}
_onReloadRules(args)
{
    if(openCJ\namePolicy::reload())
    {
        self sendLocalChatMessage("Name-moderation rules reloaded.");
        players = getEntArray("player", "classname");
        for(i = 0; i < players.size; i++)
        {
            player = players[i];
            if(isDefined(player.nameAccepted) &&
               openCJ\namePolicy::blockedRule(player.nameAccepted) > 0)
            {
                player setForcedName(player openCJ\namePolicy::fallbackName());
            }
        }
    }
    else
    {
        self sendLocalChatMessage("Could not reload rules; the last valid policy remains active.",
                                  true);
    }
}
digits(value)
{
    if(value.size == 0 || value.size > 10)
    {
        return false;
    }
    for(i = 0; i < value.size; i++)
    {
        n = getAscii(value[i]);
        if(n < 48 || n > 57)
        {
            return false;
        }
    }
    return true;
}

_createPlayerNameHud()
{
    self.playerNameHud = newClientHudElem(self);
    self.playerNameHud.horzAlign = "center_safearea";
    self.playerNameHud.vertAlign = "center_safearea";
    self.playerNameHud.alignX = "center";
    self.playerNameHud.alignY = "middle";
    self.playerNameHud.x = 0;
    self.playerNameHud.y = -50;
    self.playerNameHud.fontScale = 1.5;
    self.playerNameHud.archived = true;
    self.playerNameHud.sort = -1;
}

_hidePlayerNameHud()
{
    self.playerNameHud.alpha = 0;
}

onPlayerKilled(stuff)
{
    self _hidePlayerNameHud();
}

onSpawnSpectator()
{
    self _hidePlayerNameHud();
}

whileAlive()
{
    self _showPlayerNameHud();
}

whileSpectating()
{
    if(self.sessionTeam == "spectator" &&
       (!isDefined(self getSpectatorClient()) || self getSpectatorClient() == self))
    {
        return;
    }
    self _showPlayerNameHud();
}

_showPlayerNameHud()
{
    if(self openCJ\settings::getSetting("hideall"))
    {
        return;
    }

    players = getEntArray("player", "classname");
    showPlayer = undefined;
    showPlayerClosestDist = undefined;
    maxDistSquared = 360;
    forward = anglesToForward(self getPlayerAngles());
    hideDist = self openCJ\settings::getSetting("hideradius");
    for(i = 0; i < players.size; i++)
    {
        if(players[i] == self)
        {
            continue;
        }
        if(!players[i] openCJ\login::isLoggedIn())
        {
            continue;
        }
        if(self openCJ\chat::isIgnoring(players[i]))
        {
            continue;
        }
        if(players[i] openCJ\chat::isMuted())
        {
            continue;
        }
        if(isDefined(players[i].sessionState) && players[i].sessionState == "playing")
        {
            diff = players[i] getEyePos() - self getEyePos();
            forwardDist = vectorDot(forward, diff);
            forwardVecScaled = self getEyePos() + vectorScale(forward, forwardDist);
            dist = distancesquared(forwardVecScaled, players[i] getEyePos());
            if(dist < (maxDistSquared * (1 + forwardDist / 1000)) && forwardDist > hideDist)
            {
                if(!isDefined(showPlayer) ||
                   showPlayerClosestDist >
                       distancesquared(self getEyePos(), players[i] getEyePos()))
                {
                    showPlayerClosestDist =
                        distancesquared(self getEyePos(), players[i] getEyePos());
                    showPlayer = players[i];
                }
            }
        }
        if(isDefined(showPlayer) && isDefined(self.playerNameHud))
        {
            trace = bullettrace(self getEyePos(), showPlayer getEyePos(), false, undefined);
            if(trace["fraction"] == 1)
            {
                self.playerNameHud.alpha = 0.6;
                self.playerNameHud setPlayerNameString(showPlayer);
                return;
            }
            else
            {
                self.playerNameHud.alpha = 0;
                return;
            }
        }
        else if(isDefined(self.playerNameHud))
        {
            self.playerNameHud.alpha = 0;
            return;
        }
    }
    self.playerNameHud.alpha = 0;
}

// Validate decimal digits before int() so out-of-range input never reaches a moderation query.
// Database player IDs use a positive signed INT, matching the GSC integer range.
parsePlayerID(text)
{
    if(!isDefined(text) || !digits(text))
    {
        return undefined;
    }
    maximumPlayerIDText = "2147483647";
    if(text.size == maximumPlayerIDText.size)
    {
        for(i = 0; i < text.size; i++)
        {
            digit = getAscii(text[i]);
            maximumDigit = getAscii(maximumPlayerIDText[i]);
            if(digit < maximumDigit)
            {
                break;
            }
            if(digit > maximumDigit)
            {
                return undefined;
            }
        }
    }
    playerID = int(text);
    if(playerID <= 0)
    {
        return undefined;
    }
    return playerID;
}
