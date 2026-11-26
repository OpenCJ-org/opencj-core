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
    moderatorRank = 40;
    policyAdminRank = 60;
    command = openCJ\commands_base::registerCommand(
        "prefname",
        "Persistent record name. Usage: !prefname [set <name>|reset] (3-15 characters, no colors; changes once per hour)",
        ::_onPreferredName, 0, undefined, 0);
    command.redactArgs = true;
    command = openCJ\commands_base::registerCommand(
        "frename", "Force/reset an online player's regular name. Usage: !frename <player> [name]",
        ::_onFRenameCommand, 1, undefined, moderatorRank);
    command.redactArgs = true;
    openCJ\commands_base::registerCommand(
        "resetprefname",
        "Remove an account's preferred name and start its one-hour cooldown. Usage: !resetprefname <playerID>",
        ::_onResetPreferredName, 1, 1, moderatorRank);
    openCJ\commands_base::registerCommand("reloadnamerules",
                                          "Reload the server's private name-moderation rules.",
                                          ::_onReloadRules, 0, 0, policyAdminRank);
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
    requestedName = self getUserInfo("name");
    self.nameAccountKey = "p:" + self openCJ\login::getPlayerID();
    self _restoreRegularName(_cachedRegularName(self.nameAccountKey));
    self _rename(requestedName);
    self _rememberRegularName();
    self thread _loadPreferredName();
}

_cachedRegularName(identityKey)
{
    if(!isDefined(identityKey) || !isDefined(game["nameCooldowns"]))
    {
        return undefined;
    }
    cachedName = game["nameCooldowns"][identityKey];
    if(!isDefined(cachedName))
    {
        return undefined;
    }
    lastSeenSeconds = cachedName[2];
    cacheLifetimeSeconds = 60;
    if(getRealTime() - lastSeenSeconds < cacheLifetimeSeconds)
    {
        return cachedName;
    }
    return undefined;
}

_restoreRegularName(cachedName)
{
    if(!isDefined(cachedName))
    {
        return;
    }
    self.nameAccepted = cachedName[0];
    self.nameLastChange = cachedName[1];
}

// Plain arrays keep accepted names and cooldowns across map changes without retaining entities.
_rememberRegularName()
{
    if(!isDefined(self.nameAccepted))
    {
        return;
    }
    nowSeconds = getRealTime();
    _pruneRegularNames(nowSeconds);
    // Retain the existing cache layout: accepted name, last change, last seen.
    cachedName = [];
    cachedName[0] = self.nameAccepted;
    cachedName[1] = self.nameLastChange;
    cachedName[2] = nowSeconds;
    if(isDefined(self.nameGuidKey))
    {
        game["nameCooldowns"][self.nameGuidKey] = cachedName;
    }
    if(isDefined(self.nameAccountKey))
    {
        game["nameCooldowns"][self.nameAccountKey] = cachedName;
    }
}

// Bound disconnected-identity memory without scanning the cache on every userinfo event.
_pruneRegularNames(nowSeconds)
{
    pruneIntervalSeconds = 60;
    cacheLifetimeSeconds = 60;
    if(isDefined(game["nameCooldownPruned"]) &&
       nowSeconds - game["nameCooldownPruned"] < pruneIntervalSeconds)
    {
        return;
    }
    identityKeys = getArrayKeys(game["nameCooldowns"]);
    for(i = 0; i < identityKeys.size; i++)
    {
        cachedName = game["nameCooldowns"][identityKeys[i]];
        lastSeenSeconds = cachedName[2];
        if(nowSeconds - lastSeenSeconds >= cacheLifetimeSeconds)
        {
            game["nameCooldowns"][identityKeys[i]] = undefined;
        }
    }
    game["nameCooldownPruned"] = nowSeconds;
}

// A later successful change takes precedence over an older account-load reply.
_loadPreferredName()
{
    self endon("disconnect");
    playerID = self openCJ\login::getPlayerID();
    nameVersion = _recordNameVersion(playerID);
    rows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT preferredName FROM playerNamePreferences WHERE playerID=" + playerID);
    if(!isDefined(rows) || _recordNameVersion(playerID) != nameVersion)
    {
        return;
    }
    preferredName = undefined;
    if(hasResult(rows))
    {
        preferredName = rows[0][0];
    }
    _publishPreferredName(playerID, preferredName);
}

_recordNameVersion(playerID)
{
    nameOverride = level.recordNameOverrides["p:" + playerID];
    if(!isDefined(nameOverride))
    {
        return 0;
    }
    return nameOverride.version;
}

// Publish one account's record-name override and redraw panels that already show it.
_publishPreferredName(playerID, preferredName, fallbackName)
{
    previousOverride = level.recordNameOverrides["p:" + playerID];
    if(!isDefined(fallbackName) && isDefined(previousOverride))
    {
        fallbackName = previousOverride.fallback;
    }
    nameOverride = spawnStruct();
    nameOverride.version = _recordNameVersion(playerID) + 1;
    nameOverride.name = preferredName;
    nameOverride.fallback = fallbackName;
    level.recordNameOverrides["p:" + playerID] = nameOverride;
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

recordName(playerID, fallbackName)
{
    nameOverride = level.recordNameOverrides["p:" + playerID];
    if(isDefined(nameOverride) && isDefined(nameOverride.name))
    {
        return nameOverride.name;
    }
    if(isDefined(nameOverride) && isDefined(nameOverride.fallback))
    {
        return nameOverride.fallback;
    }
    return fallbackName;
}

_recordNameFallback(fallbackName)
{
    if(!self openCJ\login::isLoggedIn())
    {
        return;
    }
    playerKey = "p:" + self openCJ\login::getPlayerID();
    if(!isDefined(level.recordNameOverrides[playerKey]))
    {
        nameOverride = spawnStruct();
        nameOverride.version = 0;
        level.recordNameOverrides[playerKey] = nameOverride;
    }
    level.recordNameOverrides[playerKey].fallback = fallbackName;
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

// Apply moderation and the regular-name cooldown before changing the public engine name.
_rename(newName)
{
    regularCooldownSeconds = 60;
    self _initRegularName();
    cleanedName = cleanPlayerName(newName);
    if(!isDefined(cleanedName))
    {
        return;
    }
    isInitialName = !isDefined(self.nameAccepted);
    if(!isInitialName && cleanedName == self.nameAccepted)
    {
        if(newName != cleanedName)
        {
            self _applyName(cleanedName, false);
        }
        return;
    }
    if(!isInitialName && isDefined(self.nameLastChange) &&
       getRealTime() - self.nameLastChange < regularCooldownSeconds)
    {
        self _applyName(self.nameAccepted, false);
        self _nameNotice("Please wait " +
                         (regularCooldownSeconds - (getRealTime() - self.nameLastChange)) +
                         " seconds before changing your name.");
        return;
    }
    blockedRuleID = openCJ\namePolicy::blockedRule(cleanedName);
    if(blockedRuleID != 0)
    {
        cleanedName = self openCJ\namePolicy::fallbackName();
        if(blockedRuleID < 0)
        {
            self _nameNotice("Name checks are unavailable; a temporary name has been assigned.");
        }
        else
        {
            self _nameNotice(
                "That name is not allowed. A temporary name has been assigned; choose a different name.");
        }
    }
    if(!isInitialName && cleanedName == self.nameAccepted)
    {
        self _applyName(cleanedName, false);
        return;
    }
    // Only a new connection identity gets the initial-name exemption.
    if(!isInitialName)
    {
        self.nameLastChange = getRealTime();
    }
    self _applyName(cleanedName, true);
}

// Update the live name and cooldown cache; persistForRecords also schedules its database write.
_applyName(acceptedName, persistForRecords)
{
    previousName = self.currentName;
    self.nameAccepted = acceptedName;
    publishedName = self renameClient(acceptedName);
    if(isDefined(publishedName))
    {
        self.nameAccepted = publishedName;
    }
    self.currentName = self.nameAccepted;
    // Discord only saw players who logged in (the join message), so only announce their renames.
    if(isDefined(previousName) && previousName != self.currentName && self openCJ\login::isLoggedIn())
    {
        self thread openCJ\discord::onPlayerRenamed(previousName, self.currentName);
    }
    self _rememberRegularName();
    self _recordNameFallback(self.nameAccepted);
    if(self getUserInfo("name") != self.nameAccepted)
    {
        self setClientCvar("name", self.nameAccepted);
    }
    if(persistForRecords && self openCJ\login::isLoggedIn())
    {
        self thread _storeNewName(self.nameAccepted);
    }
}

_storeNewName(recordName)
{
    // Actual accepted changes are rate-limited before publication. Submit the
    // write immediately, so a disconnect cannot discard a debounce timer.
    self openCJ\mySQL::mysqlAsyncWriteNosave("CALL setName(" + self openCJ\login::getPlayerID() +
                                                 ", '" + openCJ\mySQL::escapeString(recordName) +
                                                 "')",
                                             "name:" + self openCJ\login::getPlayerID());
}

_nameNotice(message)
{
    noticeIntervalMs = 3000;
    if(isDefined(self.nameNoticeTime) && getTime() - self.nameNoticeTime < noticeIntervalMs)
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

setForcedName(forcedName)
{
    if(!self openCJ\login::isLoggedIn())
    {
        return;
    }
    if(!isDefined(forcedName))
    {
        self.forcedName = undefined;
        return;
    }
    forcedName = cleanPlayerName(forcedName);
    if(openCJ\namePolicy::blockedRule(forcedName) != 0)
    {
        forcedName = self openCJ\namePolicy::fallbackName();
    }
    self.forcedName = forcedName;
    self _applyName(forcedName, true);
}

_onFRenameCommand(args)
{
    targetPlayer = findPlayerByArg(args[0]);
    if(!isDefined(targetPlayer) || !targetPlayer openCJ\login::isLoggedIn())
    {
        self sendLocalChatMessage("Cannot find player.", true);
        return;
    }
    if(args.size < 2)
    {
        targetPlayer setForcedName();
        self sendLocalChatMessage("Forced name removed.");
        return;
    }
    forcedName = arrayConcat(subArray(args, 1));
    targetPlayer setForcedName(forcedName);
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

// Validate first, then let the database own uniqueness, moderation and cooldown enforcement.
_preferredNameRequest(args)
{
    if(args.size == 0)
    {
        self _showPreferredName();
        return;
    }
    playerID = self openCJ\login::getPlayerID();
    resetRequested = args.size == 1 && toLower(args[0]) == "reset";
    preferredName = undefined;
    preferredNameSQL = "NULL";
    if(!resetRequested)
    {
        preferredName = self _requestedPreferredName(args);
        if(!isDefined(preferredName))
        {
            return;
        }
        preferredNameSQL = "'" + openCJ\mySQL::escapeString(preferredName) + "'";
    }
    rows = self openCJ\mySQL::mysqlAsyncWrite("SELECT setPreferredName(" + playerID + "," +
                                                  preferredNameSQL + ")",
                                              "prefname:" + playerID);
    if(!hasResult(rows))
    {
        self sendLocalChatMessage(
            "Name service unavailable. Please query !prefname before retrying.", true);
        return;
    }
    resultCode = int(rows[0][0]);
    self _reportPreferredNameResult(playerID, preferredName, resultCode);
}

_showPreferredName()
{
    playerID = self openCJ\login::getPlayerID();
    preferredCooldownSeconds = 60 * 60;
    rows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT n.preferredName," + " GREATEST(0," + preferredCooldownSeconds +
        "-TIMESTAMPDIFF(SECOND,n.changedAt,UTC_TIMESTAMP(6)))" + " FROM playerInformation p" +
        " LEFT JOIN playerNamePreferences n ON n.playerID=p.playerID" +
        " WHERE p.playerID=" + playerID);
    if(!hasResult(rows))
    {
        self sendLocalChatMessage("Name service unavailable. Please try again.", true);
        return;
    }
    preferredName = rows[0][0];
    remainingSeconds = rows[0][1];
    message = "No preferred name set; records use your current name.";
    if(isDefined(preferredName))
    {
        message = "Preferred record name: " + preferredName;
    }
    if(isDefined(remainingSeconds) && int(remainingSeconds) > 0)
    {
        message += ". Next change in " + remainingSeconds + " seconds.";
    }
    self sendLocalChatMessage(message);
}

// Return the requested visible name, or explain why this request must stop.
_requestedPreferredName(args)
{
    firstNameArgument = 0;
    if(toLower(args[0]) == "set")
    {
        firstNameArgument = 1;
    }
    preferredName =
        openCJ\namePolicy::preferredName(arrayConcat(subArray(args, firstNameArgument)));
    if(!isDefined(preferredName))
    {
        self sendLocalChatMessage(
            "Use 3-15 printable characters, including a letter or number. Color codes are not allowed.",
            true);
        return undefined;
    }
    if(openCJ\namePolicy::blockedRule(preferredName) != 0)
    {
        self sendLocalChatMessage(
            "That name cannot be used. Choose a different name or contact a moderator.", true);
        return undefined;
    }
    return preferredName;
}

// Stored-function results are status codes, except positive values which are seconds remaining.
// An undefined preferredName means reset was requested; resultCode still decides success.
_reportPreferredNameResult(playerID, preferredName, resultCode)
{
    saved = 0;
    unchanged = -1;
    alreadyTaken = -3;
    blocked = -5;
    if(resultCode == saved)
    {
        _publishPreferredName(playerID, preferredName);
        self _recordNameFallback(self.name);
        if(!isDefined(preferredName))
        {
            self sendLocalChatMessage("Preferred name cleared. Records now use your current name.");
        }
        else
        {
            self sendLocalChatMessage("Preferred record name set to " + preferredName + ".");
        }
    }
    else if(resultCode == unchanged)
    {
        self sendLocalChatMessage("Your preferred name is already set that way.");
    }
    else if(resultCode == alreadyTaken)
    {
        self sendLocalChatMessage("That preferred name is already taken.", true);
    }
    else if(resultCode > 0)
    {
        remainingSeconds = resultCode;
        self sendLocalChatMessage("Please wait " + remainingSeconds +
                                      " seconds before changing your preferred name.",
                                  true);
    }
    else if(resultCode == blocked)
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
        fallbackName = undefined;
        if(hasResult(rows))
        {
            fallbackName = rows[0][0];
        }
        _publishPreferredName(targetPlayerID, undefined, fallbackName);
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

digits(decimalText)
{
    maximumDecimalDigits = 10;
    if(decimalText.size == 0 || decimalText.size > maximumDecimalDigits)
    {
        return false;
    }
    for(i = 0; i < decimalText.size; i++)
    {
        characterCode = getAscii(decimalText[i]);
        if(characterCode < getAscii("0") || characterCode > getAscii("9"))
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
