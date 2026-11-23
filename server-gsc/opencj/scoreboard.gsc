#include openCJ\util;

// Local HUD visibility follows the client's hold bind. Only visible viewers
// receive changed rows; no database queries or server HUD elements are needed.
onInit()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    if(getCvar("opencj_public_hostname") == "")
    {
        setCvar("opencj_public_hostname", "eu.opencj.org");
    }
    precacheMenu("opencj_scoreboard_setup");
    precacheMenu("opencj_scoreboard_input");
}

// A connecting client can exist before it has the "player" classname.
// Track the connect callback itself, just as the stock scoreboard tracks slots.
onPlayerConnecting()
{
    if(!isDefined(level.scoreboardClients))
    {
        level.scoreboardClients = [];
    }
    level.scoreboardClients[self getEntityNumber()] = self;
    level.scoreboardNextUpdate = 0;
}

onPlayerDisconnected()
{
    if(isDefined(level.scoreboardClients))
    {
        level.scoreboardClients[self getEntityNumber()] = undefined;
    }
    level.scoreboardNextUpdate = 0;
}

onPlayerConnected()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    self onPlayerConnecting();
    self.scoreboardCache = [];
    self setClientCvar("opencj_sb_held", 0);
    self setClientCvar("opencj_sb_active", 0);
    self thread watch();
    self thread scrollInput();
}

// Poll the held scoreboard only after client setup; send fresh values at most once a second.
watch()
{
    self endon("disconnect");
    self openCJ\clientInit::waitUntilFinished();
    refreshIntervalMs = 1000;
    inputPollSeconds = 0.2;
    nextRefreshMs = 0;
    inputMenuOpen = false;
    for(;;)
    {
        if(self getUserinfo("opencj_sb_active") == "1")
        {
            if(!inputMenuOpen)
            {
                self openMenu("opencj_scoreboard_input");
                inputMenuOpen = true;
            }
            if(getTime() >= nextRefreshMs)
            {
                self update();
                nextRefreshMs = getTime() + refreshIntervalMs;
            }
        }
        else
        {
            nextRefreshMs = 0;
            self.scoreboardOffset = 0;
            if(inputMenuOpen)
            {
                self closeMenu("opencj_scoreboard_input");
                inputMenuOpen = false;
            }
        }
        wait inputPollSeconds;
    }
}

scrollInput()
{
    self endon("disconnect");
    scrollCooldownMs = 75;
    rowsPerScroll = 3;
    for(;;)
    {
        self waittill("menuresponse", menuName, menuResponse);
        if(menuName != "opencj_scoreboard_input")
        {
            continue;
        }
        if(menuResponse == "close")
        {
            self setClientCvar("opencj_sb_held", 0);
            self setClientCvar("opencj_sb_active", 0);
            self closeMenu(menuName);
            continue;
        }
        if(self getUserinfo("opencj_sb_active") != "1")
        {
            continue;
        }
        if(menuResponse != "up" && menuResponse != "down")
        {
            continue;
        }
        if(isDefined(self.scoreboardScrollTime) &&
           getTime() - self.scoreboardScrollTime < scrollCooldownMs)
        {
            continue;
        }
        self.scoreboardScrollTime = getTime();
        if(!isDefined(self.scoreboardOffset))
        {
            self.scoreboardOffset = 0;
        }
        if(menuResponse == "up")
        {
            self.scoreboardOffset -= rowsPerScroll;
        }
        else
        {
            self.scoreboardOffset += rowsPerScroll;
        }
        self update();
    }
}

connecting(player)
{
    return !isDefined(player.isFullyConnected) || !player.isFullyConnected;
}

spectatorRow(player)
{
    // Connecting clients have not chosen a playing state yet.
    if(connecting(player))
    {
        return true;
    }
    // Playback uses spectator presentation but remains a jumper activity.
    return player.sessionState == "spectator" && !player openCJ\demos::isPlayingDemo() &&
           !isDefined(player.cpc);
}

status(player)
{
    if(connecting(player))
    {
        return "^3Connecting...";
    }
    if(isDefined(player.cpc))
    {
        return "^5CPC";
    }
    if(isDefined(player.clipEdit))
    {
        return "^5Clip editor";
    }
    if(isDefined(player.clipPreview))
    {
        return "^5Clip preview";
    }
    if(player openCJ\demos::isPlayingDemo())
    {
        if(isDefined(player.clipPlayback))
        {
            return "^5Clip";
        }
        return "^5Demo";
    }
    if(isDefined(player.isAFK) && player.isAFK)
    {
        return "^3AFK";
    }
    if(spectatorRow(player))
    {
        return "Spectating";
    }
    if(isDefined(player.clipRecording))
    {
        return "^1Recording";
    }
    if(player openCJ\playerRuns::isRunFinished())
    {
        return "^2Finished";
    }
    if(!player openCJ\playerRuns::hasRunStarted())
    {
        return "Ready";
    }
    if(player openCJ\playerRuns::isRunPaused())
    {
        return "^3Paused";
    }
    return "^2Jumping";
}

// Quoted engine dvar transport must never contain player-controlled delimiters.
clean(inputText, maxLength)
{
    if(!isDefined(inputText))
    {
        return "";
    }
    inputText = "" + inputText;
    cleanText = "";
    for(i = 0; i < inputText.size && cleanText.size < maxLength; i++)
    {
        if(inputText[i] != "\"" && inputText[i] != "\\" && inputText[i] != "\n" &&
           inputText[i] != "\r")
        {
            cleanText += inputText[i];
        }
    }
    if(cleanText.size && cleanText[cleanText.size - 1] == "^")
    {
        cleanText = getSubStr(cleanText, 0, cleanText.size - 1);
    }
    return cleanText;
}

// Safe before player initialization: no login, gameplay or network stats needed.
connectingRow(name)
{
    values = emptyRow(name);
    values["route"] = "^3Connecting...";
    return values;
}

// Reset every displayed field so a recycled viewport row cannot retain an old player's badges.
emptyRow(name)
{
    nameLengthLimit = 20;
    unavailablePing = -1;
    hiddenProgress = -1;
    values = [];
    values["name"] = clean(name, nameLengthLimit);
    values["points"] = 0;
    values["rank"] = "";
    values["country"] = "";
    countryFlag = openCJ\flagAtlas::resolve("??");
    values["flag"] = countryFlag.material;
    values["flagSelector"] = countryFlag.selector;
    values["ping"] = unavailablePing;
    values["pingText"] = "-";
    values["route"] = "-";
    values["progress"] = hiddenProgress;
    values["time"] = "-";
    values["rpg"] = "-";
    values["fps"] = 0;
    values["ele"] = 0;
    values["hb"] = 0;
    values["tas"] = 0;
    values["any"] = 0;
    return values;
}

// Build one player's row without reading gameplay state before connection setup finishes.
row(player)
{
    if(connecting(player))
    {
        return connectingRow(player.name);
    }
    values = emptyRow(player.name);
    values["points"] = points(player);
    challengeRank = 1;
    if(isDefined(player.challengeRank))
    {
        challengeRank = player.challengeRank;
    }
    values["rank"] = "opencj_rank_" + challengeRank;
    values["country"] = clean(player openCJ\country::getCountry(), 2);
    countryFlag = openCJ\flagAtlas::resolve(values["country"]);
    values["flag"] = countryFlag.material;
    values["flagSelector"] = countryFlag.selector;
    values["ping"] = "" + player getPing();
    pingVariationMs = player getPingVariation();
    values["pingText"] = values["ping"];
    if(pingVariationMs >= 0)
    {
        values["pingText"] += " (+/- " + pingVariationMs + " ms)";
    }
    if(isDefined(player.cpc))
    {
        values["route"] = player.cpc.route;
        return values;
    }
    if(player openCJ\demos::isPlayingDemo() || spectatorRow(player))
    {
        return values;
    }
    if(!player openCJ\playerRuns::hasRunID() || !player openCJ\playerRuns::hasRunStarted())
    {
        return values;
    }
    return addRunValues(values, player);
}

// Add progress and run-category badges only for a started gameplay run.
addRunValues(values, player)
{
    hiddenProgress = -1;
    if(isDefined(player.route))
    {
        values["route"] = player.route;
    }
    currentCheckpoint = player openCJ\checkpoints::getCurrentCheckpoint();
    if(isDefined(currentCheckpoint))
    {
        routeName = openCJ\checkpoints::getRouteNameForCheckpoint(currentCheckpoint);
        if(isDefined(routeName))
        {
            values["route"] = routeName;
        }
        if(!player openCJ\anyPct::hasAnyPct())
        {
            passedCount = openCJ\checkpoints::getPassedCheckpointCount(currentCheckpoint);
            remainingCount = openCJ\checkpoints::getRemainingCheckpointCount(currentCheckpoint);
            if(isDefined(remainingCount) && passedCount + remainingCount > 0)
            {
                values["progress"] = int(100.0 * passedCount / (passedCount + remainingCount));
            }
        }
    }
    if(player openCJ\anyPct::hasAnyPct())
    {
        values["progress"] = hiddenProgress;
    }
    else if(player openCJ\playerRuns::isRunFinished())
    {
        values["progress"] = 100;
    }
    values["time"] = formatTimeString(player openCJ\playTime::getTimePlayed(), true);
    values["rpg"] = player openCJ\statistics::getExplosiveJumps();
    values["fps"] = fpsBadge(player);
    values["ele"] = int(player openCJ\elevate::hasUsedEle());
    values["hb"] = int(player openCJ\halfBeat::isHalfBeatAllowed());
    values["tas"] = int(player openCJ\tas::hasHardTAS());
    values["any"] = int(player openCJ\anyPct::hasAnyPct());
    return values;
}

// These selector values are shared with the compiled scoreboard menu.
fpsBadge(player)
{
    standardFPSBadge = 1;
    mixedFPSBadge = 2;
    hackedFPSBadge = 3;
    tutorialBadge = 4;
    fpsMode = player openCJ\fps::getCurrentFPSMode();
    badge = standardFPSBadge;
    if(fpsMode == "mix")
    {
        badge = mixedFPSBadge;
    }
    if(fpsMode == "hax")
    {
        badge = hackedFPSBadge;
    }
    // The server chooses FPS for tutorial runs, so their badge replaces the usual FPS badge.
    if(player openCJ\tutorial::isTutorialRun())
    {
        badge = tutorialBadge;
    }
    return badge;
}

// A fixed viewport keeps ranks, modes and player text readable at full capacity.
viewLayout(offset, totalPlayers, jumperCount)
{
    viewport = spawnStruct();
    viewport.capacity = 15;
    viewport.rowHeight = 22;
    viewport.iconSize = 20;
    viewport.sectionGap = 17;
    headerHeight = 43;
    // Space reserved for the title, column headers and footer.
    frameHeight = 69;
    footerInset = 16;
    virtualScreenHeight = 480;
    maximumTop = 90;
    viewport.maxOffset = totalPlayers - viewport.capacity;
    if(viewport.maxOffset < 0)
    {
        viewport.maxOffset = 0;
    }
    viewport.first = offset;
    if(viewport.first < 0)
    {
        viewport.first = 0;
    }
    if(viewport.first > viewport.maxOffset)
    {
        viewport.first = viewport.maxOffset;
    }
    viewport.count = totalPlayers - viewport.first;
    if(viewport.count > viewport.capacity)
    {
        viewport.count = viewport.capacity;
    }
    viewport.split = jumperCount > viewport.first && jumperCount < viewport.first + viewport.count;
    viewport.height = frameHeight + viewport.count * viewport.rowHeight;
    if(viewport.split)
    {
        viewport.height += viewport.sectionGap;
    }
    viewport.top = (virtualScreenHeight - viewport.height) / 2;
    if(viewport.top > maximumTop)
    {
        viewport.top = maximumTop;
    }
    viewport.footer = viewport.top + viewport.height - footerInset;
    viewport.rowsTop = viewport.top + headerHeight;
    viewport.sectionTop = viewport.rowsTop + (jumperCount - viewport.first) * viewport.rowHeight;

    viewport.trackHeight = viewport.count * viewport.rowHeight;
    if(viewport.split)
    {
        viewport.trackHeight += viewport.sectionGap;
    }
    viewport.thumbHeight = viewport.trackHeight;
    if(totalPlayers > 0)
    {
        viewport.thumbHeight = viewport.trackHeight * viewport.count / totalPlayers;
    }
    viewport.thumbTop = viewport.rowsTop;
    if(viewport.maxOffset > 0)
    {
        viewport.thumbTop +=
            (viewport.trackHeight - viewport.thumbHeight) * viewport.first / viewport.maxOffset;
    }
    return viewport;
}

// Share one cached snapshot while keeping scroll position and highlighting specific to each viewer.
update()
{
    reliableBacklogLimit = 16;
    if(self getQueuedReliableMessages() > reliableBacklogLimit)
    {
        return;
    }
    if(!isDefined(level.scoreboardNextUpdate) || getTime() >= level.scoreboardNextUpdate)
    {
        buildSnapshot();
    }
    self sendChanged(level.scoreboardValues);
    if(!isDefined(self.scoreboardOffset))
    {
        self.scoreboardOffset = 0;
    }
    viewport = viewLayout(self.scoreboardOffset, level.scoreboardPlayers.size,
                          level.scoreboardJumperCount);
    self.scoreboardOffset = viewport.first;
    self sendChanged(self viewerValues(viewport));
}

// Translate the layout and visible player rows into the client menu's existing cvar names.
viewerValues(viewport)
{
    values = [];
    values["opencj_sb_rowheight"] = viewport.rowHeight;
    values["opencj_sb_iconsize"] = viewport.iconSize;
    values["opencj_sb_top"] = viewport.top;
    values["opencj_sb_height"] = viewport.height;
    values["opencj_sb_footer"] = viewport.footer;
    values["opencj_sb_spec_visible"] = int(viewport.split);
    values["opencj_sb_specy"] = viewport.sectionTop;
    sectionTitle = "Jumpers (" + level.scoreboardJumperCount + ")";
    if(viewport.first >= level.scoreboardJumperCount && viewport.count > 0)
    {
        sectionTitle = level.scoreboardValues["opencj_sb_spectators"];
    }
    values["opencj_sb_section"] = sectionTitle;
    values["opencj_sb_scroll_visible"] = int(viewport.maxOffset > 0);
    values["opencj_sb_scroll_label"] = (viewport.first + 1) + "-" +
                                       (viewport.first + viewport.count) + " / " +
                                       level.scoreboardPlayers.size + "   Mouse wheel";
    values["opencj_sb_track_y"] = viewport.rowsTop;
    values["opencj_sb_track_h"] = viewport.trackHeight;
    values["opencj_sb_thumb_h"] = viewport.thumbHeight;
    values["opencj_sb_thumb_y"] = viewport.thumbTop;
    for(i = 0; i < viewport.capacity; i++)
    {
        rowPrefix = "opencj_sb_r" + i + "_";
        values[rowPrefix + "exists"] = int(i < viewport.count);
        if(i >= viewport.count)
        {
            continue;
        }
        playerIndex = viewport.first + i;
        rowTop = viewport.rowsTop + i * viewport.rowHeight;
        if(viewport.split && playerIndex >= level.scoreboardJumperCount)
        {
            rowTop += viewport.sectionGap;
        }
        values[rowPrefix + "y"] = rowTop;
        values[rowPrefix + "self"] = int(level.scoreboardPlayers[playerIndex] == self);
        rowValues = level.scoreboardRows[playerIndex];
        fields = getArrayKeys(rowValues);
        for(j = 0; j < fields.size; j++)
        {
            values[rowPrefix + fields[j]] = rowValues[fields[j]];
        }
    }
    return values;
}

points(player)
{
    if(isDefined(player.challengePoints))
    {
        return player.challengePoints;
    }
    return 0;
}

// Stable insertion sort keeps the existing player order when point totals tie.
sortByPoints(players)
{
    for(i = 1; i < players.size; i++)
    {
        player = players[i];
        insertIndex = i;
        while(insertIndex > 0 && points(players[insertIndex - 1]) < points(player))
        {
            players[insertIndex] = players[insertIndex - 1];
            insertIndex--;
        }
        players[insertIndex] = player;
    }
    return players;
}

// Partition connected slots by activity and cache their rows for all visible scoreboards.
buildSnapshot()
{
    snapshotPlayerLimit = 32;
    refreshIntervalMs = 1000;
    players = [];
    jumpers = [];
    spectators = [];
    if(isDefined(level.scoreboardClients))
    {
        clientSlots = getArrayKeys(level.scoreboardClients);
        for(i = 0; i < clientSlots.size; i++)
        {
            if(isDefined(level.scoreboardClients[clientSlots[i]]))
            {
                players[players.size] = level.scoreboardClients[clientSlots[i]];
            }
        }
    }
    // Stable point ordering within each team; tied players retain their existing slot order.
    for(i = 0; i < players.size; i++)
    {
        if(spectatorRow(players[i]))
        {
            spectators[spectators.size] = players[i];
        }
        else
        {
            jumpers[jumpers.size] = players[i];
        }
    }
    jumpers = sortByPoints(jumpers);
    spectators = sortByPoints(spectators);
    sharedValues = [];
    level.scoreboardPlayers = [];
    level.scoreboardRows = [];
    playerCount = jumpers.size + spectators.size;
    if(playerCount > snapshotPlayerLimit)
    {
        playerCount = snapshotPlayerLimit;
    }
    level.scoreboardJumperCount = jumpers.size;
    sharedValues["opencj_sb_map"] = getCvar("mapname");
    sharedValues["opencj_sb_servername"] = getCvar("sv_hostname");
    sharedValues["opencj_sb_hostname"] =
        getCvar("opencj_public_hostname") + ":" + getCvar("net_port");
    sharedValues["opencj_sb_spectators"] = "Spectators (" + spectators.size + ")";
    for(i = 0; i < playerCount; i++)
    {
        if(i < jumpers.size)
        {
            player = jumpers[i];
        }
        else
        {
            player = spectators[i - jumpers.size];
        }
        level.scoreboardPlayers[i] = player;
        level.scoreboardRows[i] = row(player);
    }
    level.scoreboardValues = sharedValues;
    level.scoreboardNextUpdate = getTime() + refreshIntervalMs;
}

// Send only changed values, in batches kept below the reliable-command string limit.
sendChanged(cvarValues)
{
    maxValueBytes = 160;
    maxCommandBytes = 800;
    if(!isDefined(self.scoreboardCache))
    {
        self.scoreboardCache = [];
    }
    cvarNames = getArrayKeys(cvarValues);
    commandBuffer = "v";
    for(i = 0; i < cvarNames.size; i++)
    {
        cvarValue = clean(cvarValues[cvarNames[i]], maxValueBytes);
        if(isDefined(self.scoreboardCache[cvarNames[i]]) &&
           self.scoreboardCache[cvarNames[i]] == cvarValue)
        {
            continue;
        }
        assignment = " " + cvarNames[i] + " \"" + cvarValue + "\"";
        if(commandBuffer.size + assignment.size > maxCommandBytes)
        {
            self SV_GameSendServerCommand(commandBuffer, true);
            commandBuffer = "v";
        }
        commandBuffer += assignment;
        self.scoreboardCache[cvarNames[i]] = cvarValue;
    }
    if(commandBuffer != "v")
    {
        self SV_GameSendServerCommand(commandBuffer, true);
    }
}
