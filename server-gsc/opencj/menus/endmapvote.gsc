onInit()
{
    level.endVote = [];
    level.endVote["menu"] = "opencj_endmapvote";
    level.endVote["nrMaps"] = 9; // Hardcoded in menu
    level.endVote["prefix"] = "opencj_ui_end_";
    level.endVote["winning"] = undefined;

    // Define random maps for the next map vote
    level.endVote["maps"] = [];
    level.endVote["randomMaps"] = [];
    level.endVote["nominations"] = [];
    // Keep some slots random so the vote still offers variety.
    level.endVote["maxNominations"] = 6;
    level.endVote["votes"] = [];
    // These values are shared with opencj_endmapvote.menu.
    level.endVote["phaseIdle"] = 0;
    level.endVote["phaseVoting"] = 1;
    level.endVote["phaseLoading"] = 2;
    level.endVote["status"] = level.endVote["phaseIdle"];
    for (i = 0; i < level.endVote["nrMaps"]; i++)
    {
        level.endVote["votes"][i] = 0;
    }

    precacheMenu(level.endVote["menu"]);
}

// Offer ordinary players' eligible maps, excluding the current map and empty slots.
fillRandomMaps() // Called when level.maps is filled.
{
    level.endVote["maps"] = [];
    ordinaryPlayerPermissions = 0;
    eligibleMaps = openCJ\maps::voteMaps(ordinaryPlayerPermissions);
    currentMapName = getCvar("mapname");
    for (i = 0; i < eligibleMaps.size; i++)
    {
        if (level.endVote["maps"].size >= level.endVote["nrMaps"])
        {
            break;
        }

        mapName = eligibleMaps[i]["name"];
        if (mapName != currentMapName)
        {
            nextSlot = level.endVote["maps"].size;
            level.endVote["maps"][nextSlot] = mapName;
        }
    }

    _shuffleEndVoteMaps();
    level.endVote["randomMaps"] = level.endVote["maps"];
    _rebuildSlots();
}

isIdle()
{
    return level.endVote["status"] == level.endVote["phaseIdle"];
}

// Put a map into the next end-of-map vote. Each player has one nomination; a new
// one replaces their own. When all nomination slots are taken, the oldest
// nomination makes way and its nominator is told.
nominate(mapName)
{
    if (!self openCJ\login::isLoggedIn())
    {
        return;
    }
    if (!isIdle())
    {
        self openCJ\util::sendLocalChatMessage(
            "Nominations are closed: the map vote has started.", true);
        return;
    }
    // The client only lists permitted maps, but the server decides what may be named.
    if (!openCJ\maps::canVoteMap(mapName, self.permissions))
    {
        self openCJ\util::sendLocalChatMessage("That map can't be nominated.", true);
        return;
    }
    if (mapName == getCvar("mapname"))
    {
        self openCJ\util::sendLocalChatMessage("You can't nominate the current map.", true);
        return;
    }

    remaining = [];
    nominations = level.endVote["nominations"];
    for (i = 0; i < nominations.size; i++)
    {
        nomination = nominations[i];
        if (nomination.mapName == mapName)
        {
            self openCJ\util::sendLocalChatMessage(
                mapName + " was already nominated by " + nomination.playerName + "^7.", true);
            return;
        }
        if (!isDefined(nomination.player) || nomination.player != self)
        {
            remaining[remaining.size] = nomination;
        }
    }
    if (remaining.size >= level.endVote["maxNominations"])
    {
        oldest = remaining[0];
        if (isDefined(oldest.player))
        {
            oldest.player openCJ\util::sendLocalChatMessage(
                "Your nomination of " + oldest.mapName + " made way for newer nominations.");
        }
        newer = [];
        for (i = 1; i < remaining.size; i++)
        {
            newer[newer.size] = remaining[i];
        }
        remaining = newer;
    }

    nomination = spawnStruct();
    nomination.mapName = mapName;
    nomination.player = self;
    nomination.playerName = self.name;
    remaining[remaining.size] = nomination;
    level.endVote["nominations"] = remaining;
    iprintln(self.name + "^7 nominated ^3" + mapName + "^7 for the map vote");
    _rebuildSlots();
}

// Nominated maps take the first slots in nomination order; the shuffled random
// maps fill the rest. Only called before voting starts, so no ballots move.
_rebuildSlots()
{
    slots = [];
    nominations = level.endVote["nominations"];
    for (i = 0; i < nominations.size && slots.size < level.endVote["nrMaps"]; i++)
    {
        slots[slots.size] = nominations[i].mapName;
    }
    randomMaps = level.endVote["randomMaps"];
    for (i = 0; i < randomMaps.size && slots.size < level.endVote["nrMaps"]; i++)
    {
        if (!openCJ\util::isInArray(randomMaps[i], slots))
        {
            slots[slots.size] = randomMaps[i];
        }
    }
    level.endVote["maps"] = slots;

    players = getEntArray("player", "classname");
    for (playerIndex = 0; playerIndex < players.size; playerIndex++)
    {
        for (slotIndex = 0; slotIndex < level.endVote["nrMaps"]; slotIndex++)
        {
            players[playerIndex] _sendSlot(slotIndex);
        }
    }
}

// Send one slot's map name and image; an empty slot clears both.
_sendSlot(slotIndex)
{
    slotNumber = (slotIndex + 1); // Dvars for this start at 1
    mapName = "";
    mapImage = "";
    if (isDefined(level.endVote["maps"][slotIndex]))
    {
        mapName = level.endVote["maps"][slotIndex];
        mapImage = openCJ\maps::previewImage(mapName);
    }
    self setClientCvar(level.endVote["prefix"] + "mapname" + slotNumber, mapName);
    self setClientCvar(level.endVote["prefix"] + "mapimage" + slotNumber, mapImage);
}

_shuffleEndVoteMaps()
{
    size = level.endVote["maps"].size;
    if (size < 2) // Need at least 2 maps to randomly shuffle
    {
        return;
    }

    randMax = 2147483647; // INT32_MAX
    for (i = 0; i < size; i++)
    {
        j = int(i + (rand() / (randMax / (size - i) + 1)));
        tmp = level.endVote["maps"][j];
        level.endVote["maps"][j] = level.endVote["maps"][i];
        level.endVote["maps"][i] = tmp;
    }
}

// Send all menu slots so a newly joined client cannot retain an old map image.
onPlayerConnected()
{
    self.endVote = -1;

    self setClientCvar(level.endVote["prefix"] + "status", level.endVote["status"]);
    self setClientCvar(level.endVote["prefix"] + "voted", "");

    winningSlot = "";
    if (isDefined(level.endVote["winning"]))
    {
        winningSlot = (level.endVote["winning"] + 1);
    }
    self setClientCvar(level.endVote["prefix"] + "winning", winningSlot);

    for (i = 0; i < level.endVote["nrMaps"]; i++)
    {
        slotNumber = (i + 1); // Dvars for this start at 1
        self setClientCvar(level.endVote["prefix"] + "votes" + slotNumber, level.endVote["votes"][i]);
        self _sendSlot(i);
    }

    if (level.endVote["status"] > level.endVote["phaseIdle"])
    {
        self openEndMapVote();
    }

    self thread _menuResponse();
}

onPlayerDisconnect()
{
    // A nomination outlives its nominator; only the player reference is dropped.
    nominations = level.endVote["nominations"];
    for (i = 0; i < nominations.size; i++)
    {
        if (isDefined(nominations[i].player) && nominations[i].player == self)
        {
            nominations[i].player = undefined;
        }
    }

    if (!isDefined(self.endVote))
    {
        return;
    }

    vote = self.endVote;
    if (vote != -1)
    {
        removeVote(vote);
    }
}

changeMap(mapName)
{
    // Let other scripts know map is changing

    // CoD4(x) map() gsc call is broken due to fs_searchpath only containing current map path, but not the normal usermaps folder itself
    // So instead, use nextmap and exitLevel so it skips the check for SV_MapExists
    setCvar("nextmap", "map " + mapName);
    exitLevel(false);
}

onTimeLimitReached() // Called multiple times due to map vote
{
    if (level.endVote["maps"].size == 0)
    {
        changeMap(getCvar("mapname"));
        return;
    }

    level.endVote["status"]++;

    if (level.endVote["status"] == level.endVote["phaseVoting"]) // Start voting
    {
        level thread opencj\events\onMapEnded::main();
        opencj\timeLimit::muteTimerSound(true); // Mute second beep timer
        votingDurationSeconds = 20;
        opencj\timeLimit::addTimeSeconds(votingDurationSeconds);
    }
    else if (level.endVote["status"] == level.endVote["phaseLoading"]) // Start loading next map
    {
        opencj\timeLimit::muteTimerSound(false); // Unmute second beep timer
        loadingDelaySeconds = 3;
        opencj\timeLimit::addTimeSeconds(loadingDelaySeconds);
    }
    else // >=3
    {
        winnerIdx = level.endVote["winning"];
        if (!isDefined(winnerIdx))
        {
            winnerIdx = randomIntRange(0, level.endVote["maps"].size);
        }

        changeMap(level.endVote["maps"][winnerIdx]);
    }

    // Set the players' dvars and open menu if needed
    players = getEntArray("player", "classname");
    for (i = 0; i < players.size; i++)
    {
        players[i] setClientCvar(level.endVote["prefix"] + "status", level.endVote["status"]);

        if (level.endVote["status"] == level.endVote["phaseVoting"])
        {
            // End map vote is starting
            players[i] openEndMapVote();
        }
        else if (level.endVote["status"] == level.endVote["phaseLoading"])
        {
            // Tell players end map vote is over so that they draw "loading map" text instead
            players[i] setClientCvar(level.endVote["prefix"] + "active", "loading");
        }
        else
        {
            players[i] closeMenu();
            players[i] closeInGameMenu();
            players[i].sessionState = "intermission";
        }
    }
}

openEndMapVote()
{
    self closeMenu();
    self closeInGameMenu();

    self openMenu(level.endVote["menu"]);
}

removeVote(mapIdx) // When a player disconnected
{
    level.endVote["votes"][mapIdx]--;
    _updateVotes(mapIdx, -1);
}

// Move the player's ballot only while the server is still accepting votes.
onVoteChanged(slotNumber)
{
    if (level.endVote["status"] != level.endVote["phaseVoting"])
    {
        return;
    }
    if (slotNumber < 1 || slotNumber > level.endVote["maps"].size)
    {
        return;
    }

    newVoteIndex = slotNumber - 1; // The array indices are 0-based, but player votes are 1-based

    previousVoteIndex = -1;
    if ((self.endVote != -1) && (level.endVote["votes"][self.endVote] > 0))
    {
        previousVoteIndex = self.endVote;
        level.endVote["votes"][self.endVote]--;
    }

    // Update player's and total map votes
    self.endVote = newVoteIndex;
    level.endVote["votes"][newVoteIndex]++;
    self setClientCvar(level.endVote["prefix"] + "voted", slotNumber);

    _updateVotes(previousVoteIndex, newVoteIndex);
}

_updateVotes(prevVoteIdx, newVoteIdx)
{
    if ((prevVoteIdx == -1) && (newVoteIdx == -1))
    {
        return;
    }

    // Calculate current winning map
    winning = undefined;
    winningChanged = false;
    if (isDefined(level.endVote["winning"]))
    {
        winning = level.endVote["winning"];
        for (i = 0; i < level.endVote["maps"].size; i++)
        {
            // If this map now has less than another map
            if (level.endVote["votes"][i] > level.endVote["votes"][winning])
            {
                winning = i;
                winningChanged = true;
            }
        }
    }
    else if (newVoteIdx != -1)
    {
        winning = newVoteIdx;
        winningChanged = true;
    }

    if (winningChanged)
    {
        level.endVote["winning"] = winning;
    }

    players = getEntArray("player", "classname");
    for (i = 0; i < players.size; i++)
    {
        // Remove the player's previous vote if there was one
        if (isDefined(prevVoteIdx) && (prevVoteIdx != -1))
        {
            players[i] setClientCvar(level.endVote["prefix"] + "votes" + (prevVoteIdx + 1), level.endVote["votes"][prevVoteIdx]);
        }

        // Add the player's new vote if there is one
        if (isDefined(newVoteIdx) && (newVoteIdx != -1))
        {
            players[i] setClientCvar(level.endVote["prefix"] + "votes" + (newVoteIdx + 1), level.endVote["votes"][newVoteIdx]);
        }

        // Report if winning map changed
        if (winningChanged)
        {
            players[i] setClientCvar(level.endVote["prefix"] + "winning", (level.endVote["winning"] + 1));
        }
    }
}

// Accept only complete vote buttons from this menu while its voting phase is active.
_menuResponse()
{
    self endon("disconnect");
    voteButtonPrefix = "click_vote";

    for (;;)
    {
        self waittill("menuresponse", menu, response);
        if (menu != level.endVote["menu"])
        {
            continue;
        }

        if (getSubStr(response, 0, voteButtonPrefix.size) != voteButtonPrefix)
        {
            continue;
        }

        slotText = getSubStr(response, voteButtonPrefix.size);
        if (!isValidInt(slotText))
        {
            continue;
        }

        self onVoteChanged(int(slotText));
    }
}
