#include openCJ\util;

onInit()
{
    // Stock callvote bypasses OpenCJ's map-pool and cooldown checks.
    setCvar("g_allowVote", 0);
    voteCommand = openCJ\commands_base::registerCommand(
        "vote", "Vote for something. Usage: !vote <extend|end|map mp_mapname|yes|no>",
        ::vote, 1, 2);
    openCJ\commands_base::addAlias(voteCommand, "v");

    restartCommand = openCJ\commands_base::registerCommand(
        "maprestart", "Restart the current map", ::onCmdRestartMap, 0, 0, "maprestart");
    openCJ\commands_base::addAlias(restartCommand, "restartmap");

    level.vote = undefined;
    level.autoExtendThreshold = 5 * 60; // Seconds remaining before an automatic extend vote.
    thread _autoExtendTimeLoop();
}

onCmdRestartMap(args)
{
    _changeMap(getCvar("mapname"));
}

onRemainingTimeIncreased() // Also called when end map vote changes remaining time, so be wary
{
    if (level.remainingTimeSeconds >= level.autoExtendThreshold)
    {
        // Time *increased* to above the auto extend threshold, so reset variable
        level.hasRequestedAutoExtend = false;
    }
}

_autoExtendTimeLoop() // For auto extend time
{
    level endon("map_ended");
    level endon("game_ended");

    level.hasRequestedAutoExtend = false;
    while (1)
    {
        if (!level.hasRequestedAutoExtend && (level.remainingTimeSeconds < level.autoExtendThreshold))
        {
            // Always call an auto extend vote when the time is low enough
            _setupVote(undefined, "Vote: extend time (30m)", undefined);
            level.hasRequestedAutoExtend = true;
        }
        wait .1;
    }
}

voteSingleArg(arg) // Helper for externally calling vote command
{
    args = [];
    args[0] = arg;
    vote(args);
}

// Cast a ballot in the active vote, or start a permitted map/extension vote.
vote(args) // args[0] = map, extend, yes/no
{
    if(!self openCJ\login::isLoggedIn())
    {
        return;
    }

    if(isValidBool(args[0]) && isDefined(level.vote))
    {
        votesYes = strToBool(args[0]);
        if(isDefined(self.vote) && self.vote == votesYes)
        {
            return;
        }

        self.vote = votesYes;
        level _updateVoteCount();
        return;
    }

    cooldownSecondsLeft = int(self.canVoteAt - (getTime() / 1000) + 0.5);
    if(cooldownSecondsLeft > 0 && !self openCJ\permissions::isUberAdmin())
    {
        self iprintln("You can vote in another ^1" + cooldownSecondsLeft + "^7 seconds");
        return;
    }

    // Do not race a scheduled automatic vote with a player-created vote.
    if(isDefined(level.isAutoExtendQueued) && level.isAutoExtendQueued)
    {
        return;
    }

    if(args[0] == "map" && isDefined(args[1]))
    {
        requestedMapName = toLower(args[1]);
        if(getCvar("mapname") == requestedMapName)
        {
            self sendLocalChatMessage("You can't vote for the current map", true);
            return;
        }

        self thread _doVoteMap(requestedMapName);
    }
    else if(args[0] == "extend")
    {
        self thread _doVoteExtend();
    }
    else if(args[0] == "end")
    {
        self thread _doVoteEnd();
    }
}

onPlayerLogin()
{
    if(isDefined(level.vote))
    {
        self _setMapVoteImage(level.vote.mapImage);
        self _writeVoteCountString();
        self _writeVoteString();
    }
    else
    {
        self setClientCvar("openCJ_voteTimeString", "");
        self setClientCvar("openCJ_voteHeaderString", "");
        self _setMapVoteImage();
    }

    newPlayerCooldownSeconds = 5 * 60;
    self _setVoteCooldown(newPlayerCooldownSeconds);
    self thread menuResponse();
}

_setVoteCooldown(cooldownSeconds)
{
    if (self openCJ\permissions::isUberAdmin())
    {
        cooldownSeconds = 0;
    }
    self.canVoteAt = (getTime() / 1000) + cooldownSeconds;
}

menuResponse()
{
    self endon("disconnect");

    while (1)
    {
        self waittill("menuresponse", menu, response);
        if (response == "cjvoteyes")
        {
            self voteSingleArg("yes");
        }
        else if (response == "cjvoteno")
        {
            self voteSingleArg("no");
        }
    }
}

getMapImage(mapName)
{
    if(isDefined(mapName))
    {
        if(getCodVersion() == 4)
        {
            return openCJ\maps::previewImage(mapName);
        }
        switch(mapName)
        {
        case "jm_pier_2":
        {
            return "jhs_jm_pier_2";
        }
        }
    }
    return "default";
}

onPlayerDisconnect()
{
    level _updateVoteCount();
}

onAFKChanged(isNowAFK)
{
    level _updateVoteCount();
}

queueAutoExtendVote()
{
    if (!isDefined(level.hasAutoExtended) || !level.hasAutoExtended && !level.isAutoExtendQueued)
    {
        level.isAutoExtendQueued = true;
    }
}

_setMapVoteImage(image)
{
    if(isDefined(image))
    {
        self setClientCvar("openCJ_mapvoteImage", image);
    }
    else
    {
        self setClientCvar("openCJ_mapvoteImage", "");
    }
}

// Resolve the player's map request before creating any shared vote state.
_doVoteMap(requestedMapName)
{
    self endon("disconnect");

    if (isDefined(level.vote))
    {
        self iprintln("Another vote is already in progress");
        return;
    }

    selectedMapName = self _findMapByName(requestedMapName);
    if (!isDefined(selectedMapName))
    {
        return;
    }
    if (selectedMapName == getCvar("mapname"))
    {
        self sendLocalChatMessage("You can't vote for the current map", true);
        return;
    }

    _setupVote(selectedMapName, "Vote: change map\n  " + selectedMapName, self);
}

_doVoteExtend()
{
    self endon("disconnect");

    // Create the vote object that serves as a hudElem
    _setupVote(undefined, "Vote: extend time (30m)", self);
}

// Vote to end the map now; a passed vote starts the end-of-map vote at once.
_doVoteEnd()
{
    self endon("disconnect");
    if (!openCJ\menus\endMapVote::isIdle())
    {
        self iprintln("The map is already ending");
        return;
    }
    _setupVote(undefined, "Vote: end map now", self, "end");
}

// Create one shared vote, clear old ballots, and start its timer if still needed.
// A vote changes to mapName when given, ends the map for voteKind "end", and
// otherwise extends the time.
_setupVote(mapName, voteTitle, initiatingPlayer, voteKind)
{
    // Only one vote at a time
    if (isDefined(level.vote))
    {
        if (isDefined(initiatingPlayer))
        {
            initiatingPlayer iprintln("Another vote is already in progress");
        }
        return;
    }

    if (isDefined(initiatingPlayer))
    {
        repeatVoteCooldownSeconds = 2 * 60;
        initiatingPlayer _setVoteCooldown(repeatVoteCooldownSeconds);
    }

    level.vote = spawnStruct();
    level.vote.str = voteTitle;
    if (isDefined(mapName))
    {
        level.vote.map = mapName;
    }
    else if (isDefined(voteKind) && voteKind == "end")
    {
        level.vote.endMap = true;
    }
    else
    {
        level.vote.extend = true;
    }
    level.vote.mapImage = getMapImage(mapName);
    level.vote.yesCount = 0;
    level.vote.noCount = 0;
    voteDurationSeconds = 30;
    level.vote.timeLeft = voteDurationSeconds;

    // Initialize all players' initial votes
    players = getEntArray("player", "classname");
    for (i = 0; i < players.size; i++)
    {
        players[i].vote = undefined;
    }

    // Let everyone know
    if (isDefined(initiatingPlayer))
    {
        iprintln(initiatingPlayer.name + " ^7started a vote");
        initiatingPlayer.vote = true;
        // Add the player's vote
        level _updateVoteCount();
    }
    else
    {
        iprintln("Automatic extend time vote");
    }

    // Keep monitoring the vote
    if (isDefined(level.vote)) // Could have already passed/failed immediately
    {
        level thread _monitorVote();
    }
}

// Exact names take priority; partial names must identify one eligible installed map.
_findMapByName(searchText)
{
    searchText = toLower(searchText);

    // Exact names also cover maps installed since the catalogue was loaded.
    if (openCJ\maps::canVoteMap(searchText, self.permissions))
    {
        return searchText;
    }

    eligibleMaps = openCJ\maps::voteMaps(self.permissions);
    matchingMapNames = [];
    if (searchText != "")
    {
        for (i = 0; i < eligibleMaps.size; i++)
        {
            mapName = eligibleMaps[i]["name"];
            if (isSubStr(mapName, searchText))
            {
                matchingMapNames[matchingMapNames.size] = mapName;
            }
        }
    }

    if (matchingMapNames.size == 1)
    {
        return matchingMapNames[0];
    }

    // Longer lists do not fit usefully in a chat response.
    maxListedMatches = 5;
    if (matchingMapNames.size > maxListedMatches)
    {
        self sendLocalChatMessage(
            "Too many available maps match (" + matchingMapNames.size + ")", true);
    }
    else if (matchingMapNames.size > 1)
    {
        self sendLocalChatMessage(
            "Available matches: " + arrayConcat(matchingMapNames, ", "), true);
    }
    else
    {
        self sendLocalChatMessage("Map not installed or unavailable for voting", true);
    }
    return undefined;
}

_updateVoteCount()
{
    if(!isDefined(level.vote))
    {
        return;
    }

    yesCount = 0;
    noCount = 0;
    totalEligiblePlayers = 0;

    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        if(players[i] openCJ\login::isLoggedIn())
        {
            if(isDefined(players[i].vote))
            {
                if(players[i].vote)
                {
                    yesCount++;
                }
                else
                {
                    noCount++;
                }

                // Player has voted so they were eligible
                totalEligiblePlayers++;
            }
            else if (!players[i] openCJ\AFK::isAFK())
            {
                // Player has not voted and is not AFK
                totalEligiblePlayers++;
            }
        }
    }

    level.vote.yesCount = yesCount;
    level.vote.noCount = noCount;

    // Check if votes have passed a ratio to succeed or fail the vote now
    voteThreshold = int(totalEligiblePlayers / 2);
    if(noCount > voteThreshold)
    {
        _voteFailed();
    }
    else if(yesCount > voteThreshold)
    {
        _voteSuccess();
    }
    else
    {
        for(i = 0; i < players.size; i++)
        {
            if(players[i] openCJ\login::isLoggedIn())
            {
                players[i] _writeVoteCountString();
            }
        }
    }
}

_getVoteCountString()
{
    voteYesStr = "Yes: ";
    voteNoStr = "No:   ";

    if(isDefined(self.vote))
    {
        if (self.vote)
        {
            voteYesStr += "^2";
        }
        else
        {
            voteNoStr += "^1";
        }
    }
    voteYesStr += level.vote.yesCount;
    voteNoStr += level.vote.noCount;

    return voteYesStr + "^7\n" + voteNoStr + "^7";
}

_destroyVote()
{
    level.vote = undefined;

    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        players[i] _writeVoteString();
        players[i] _setMapVoteImage();
    }
    // Finish cleanup before this notification can stop the calling timer.
    level notify("vote_finished");
}

_writeVoteString()
{
    if (isDefined(level.vote))
    {
        timeStr = "" + level.vote.timeLeft;
        if (level.vote.timeLeft < 5)
        {
            timeStr = "^1" + timeStr;
        }
        self setClientCvar("openCJ_voteTimeString", timeStr);
        self setClientCvar("openCJ_voteHeaderString", level.vote.str);
    }
    else
    {
        self setClientCvar("openCJ_voteTimeString", "");
        self setClientCvar("openCJ_voteHeaderString", "");
    }
}

_writeVoteCountString()
{
    self setClientCvar("openCJ_voteCounts", self _getVoteCountString());
}

// Publish the countdown only while this timer still owns the active vote.
_monitorVote()
{
    level endon("vote_finished");
    activeVote = level.vote;
    if(!isDefined(activeVote))
    {
        return;
    }

    // Update the votes and menu for each player
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        if(!players[i] openCJ\login::isLoggedIn())
        {
            continue;
        }
        players[i] _writeVoteCountString();
    }

    // Each timer belongs to one vote, including the final check after its wait.
    for(remainingSeconds = activeVote.timeLeft; remainingSeconds > 0; remainingSeconds--)
    {
        if(!isDefined(level.vote) || level.vote != activeVote)
        {
            return;
        }

        // Update the vote string for everyone
        activeVote.timeLeft = remainingSeconds;
        players = getEntArray("player", "classname");
        for(i = 0; i < players.size; i++)
        {
            if(players[i] openCJ\login::isLoggedIn())
            {
                players[i] _setMapVoteImage(level.vote.mapImage);
                players[i] _writeVoteString();
            }
        }

        wait 1;
    }

    // The original vote failed if its full duration elapsed.
    if(isDefined(level.vote) && level.vote == activeVote)
    {
        _voteFailed();
    }
}

_voteFailed()
{
    iprintln("Vote ^1failed^7");
    _destroyVote();
}

_voteSuccess()
{
    if(isDefined(level.vote.map))
    {
        iprintln("Vote ^2passed^7: " + level.vote.map);
        thread _changeMap(level.vote.map);
    }
    else if(isDefined(level.vote.extend))
    {
        iprintln("Vote ^2passed^7: " + "extend time");
        thread _extendTime(30);
    }
    else if(isDefined(level.vote.endMap))
    {
        iprintln("Vote ^2passed^7: end map");
        thread _endMapNow();
    }

    _destroyVote();
}

_changeMap(map)
{
    if (getCvar("mapname") == map)
    {
        iprintlnbold("Current map will restart in 5 seconds..");
    }
    else
    {
        iprintlnbold("Changing map to " + map + " in 5 seconds..");
    }

    wait 5;
    self openCJ\menus\endMapVote::changeMap(map);
}

_endMapNow()
{
    if (!openCJ\menus\endMapVote::isIdle())
    {
        return;
    }
    // Dropping straight to zero time must not start the automatic extend vote.
    level.hasRequestedAutoExtend = true;
    openCJ\timeLimit::endNow();
}

_extendTime(minutes)
{
    openCJ\timeLimit::addTimeSeconds(minutes * 60);
}
