#include openCJ\util;

onInit()
{
    level.nrRecords = 5;
    level.showRecordsPrefetch = 0;
    level.showRecordsCheckpointFlash = 1;
    level.showRecordsFinished = 2;
    level.showRecordsFlashMs = 2000;
    // These dimensions match the client record panel's virtual-screen layout.
    level.showRecordsTopY = 50;
    level.showRecordsRowHeight = 12;
    level.showRecordsHighlightAlpha = 0.30;
    level.showRecordsHighlightShader = "white";
    precacheShader(level.showRecordsHighlightShader);
}

onPlayerConnect()
{
    self.showRecords_nameString = "";
    self.showRecords_timeString = "";

    self.showRecordsHighlight = newClientHudElem(self);
    self.showRecordsHighlight.horzAlign = "right";
    self.showRecordsHighlight.vertAlign = "top";
    self.showRecordsHighlight.alignX = "left";
    self.showRecordsHighlight.alignY = "bottom";
    self.showRecordsHighlight.x = -202;
    self.showRecordsHighlight.y = level.showRecordsTopY;
    self.showRecordsHighlight.archived = false;
    self.showRecordsHighlight.sort = -98;
    self.showRecordsHighlight.color = (0.00, 0.80, 0.85);
    self.showRecordsHighlight.hideWhenInMenu = true;
    self.showRecordsHighlight setShader(level.showRecordsHighlightShader, 195, 11);
    self _hideRecords(true);
}

onSortingChanged()
{
    if(!self isSpectator())
    {
        self thread _getRecords(self openCJ\checkpoints::getCurrentChildCheckpoints(),
                                level.showRecordsPrefetch);
    }
}

onCheckpointsChanged()
{
    self thread _getRecords(self openCJ\checkpoints::getCurrentChildCheckpoints(),
                            level.showRecordsPrefetch);
}

onCheckpointPassed(checkpoint, timePlayedMs)
{
    checkpoints = [];
    checkpoints[0] = checkpoint;
    self thread _getRecords(checkpoints, level.showRecordsCheckpointFlash, timePlayedMs);
}

onRunRestored()
{
    self _runChanged();
}

onRunStarted()
{
    self _runChanged();
}

onRunCreated()
{
    self _runChanged();
}

onRunStopped()
{
    self hideForSpectators();
}

hideForSpectators()
{
    spectators = self getSpectatorList(true); // true -> include self as spectator
    for(i = 0; i < spectators.size; i++)
    {
        spectators[i] _hideRecords(true);
    }
}

onSpawnSpectator()
{
    self _hideRecords(true);
}

onSpawnPlayer()
{
    spectators = self getSpectatorList(true);
    for(i = 0; i < spectators.size; i++)
    {
        if(self openCJ\playerRuns::isRunFinished())
        {
            timePlayedMs = self openCJ\playTime::getTimePlayed();
            spectators[i] _updateRecords(self, self.showRecords_rows, timePlayedMs, false);
        }
        else if(self openCJ\playerRuns::hasRunID() && self openCJ\playerRuns::hasRunStarted())
        {
            spectators[i] _updateRecords(self, self.showRecords_rows, undefined, false);
        }
        else
        {
            spectators[i] _hideRecords(true);
        }
    }
}

onRunFinished(checkpoint)
{
    checkpoints = [];
    checkpoints[0] = checkpoint;
    timePlayedMs = self openCJ\playTime::getTimePlayed();
    self thread _getRecords(checkpoints, level.showRecordsFinished, timePlayedMs);
}

onSpectatorClientChanged(newClient)
{
    if(!isDefined(newClient))
    {
        self _hideRecords(true);
    }
    else
    {
        if(newClient openCJ\demos::isPlayingDemo())
        {
            self _hideRecords(true);
        }
        else if(newClient openCJ\playerRuns::isRunFinished())
        {
            timePlayedMs = newClient openCJ\playTime::getTimePlayed();
            self _updateRecords(newClient, newClient.showRecords_rows, timePlayedMs, true);
        }
        else if(newClient openCJ\playerRuns::hasRunID())
        {
            self _updateRecords(newClient, newClient.showRecords_rows, undefined, true);
        }
    }
}

onPlayerKilled(inflictor, attacker, damage, meansOfDeath, weapon, vDir, hitLoc, psOffsetTime,
               deathAnimDuration)
{
    self _hideRecords(false);
}

_runChanged()
{
    self.showRecords_rows = [];
    spectators = self getSpectatorList(true); // true -> include self as spectator
    for(i = 0; i < spectators.size; i++)
    {
        spectators[i] _hideRecords(true);
    }
    self thread _getRecords(self openCJ\checkpoints::getCurrentChildCheckpoints(),
                            level.showRecordsPrefetch);
}

_hideRecords(force)
{
    if(force || self.showRecords_nameString != "")
    {
        self setClientCvar("openCJ_records_names", "");
    }
    if(force || self.showRecords_timeString != "")
    {
        self setClientCvar("openCJ_records_times", "");
    }
    self.showRecords_nameString = "";
    self.showRecords_timeString = "";
    self.showRecords_visibleClient = undefined;
    self.showRecordsHighlight.alpha = 0;
}

// Fetch upcoming records, briefly flash a passed checkpoint, or retain finish records.
_getRecords(checkpoints, recordMode, timePlayedMs)
{
    self endon("disconnect");
    if(!self openCJ\playerRuns::hasRunID())
    {
        return;
    }

    if(recordMode != level.showRecordsCheckpointFlash)
    {
        self notify("writeRecordsRunning");
        self endon("writeRecordsRunning");
    }

    query = self recordQuery(checkpoints);

    rows = self openCJ\mySQL::mysqlAsyncRead(query);
    if(!isDefined(rows))
    {
        return;
    }

    if(!self openCJ\playerRuns::isRunFinished())
    {
        if(recordMode == level.showRecordsPrefetch)
        {
            self.showRecords_rows = rows;
        }
        else if(recordMode == level.showRecordsCheckpointFlash)
        {
            self.showRecords_persistTime = getTime() + level.showRecordsFlashMs;
        }
        else
        {
            return;
        }
    }
    else if(recordMode == level.showRecordsFinished)
    {
        self.showRecords_rows = rows;
    }
    else
    {
        return;
    }

    if(recordMode != level.showRecordsPrefetch)
    {
        spectators = self getSpectatorList(true);
        for(i = 0; i < spectators.size; i++)
        {
            spectators[i] _updateRecords(self, rows, timePlayedMs, false);
        }
    }
}

// Build the record panel query using the player's current mode and sort settings.
recordQuery(checkpoints)
{
    checkpointIDs = "(NULL";
    checkpoints = openCJ\checkpoints::filterOutBrothers(checkpoints);
    for(i = 0; i < checkpoints.size; i++)
    {
        checkpointID = openCJ\checkpoints::getCheckpointID(checkpoints[i]);
        if(isDefined(checkpointID))
        {
            checkpointIDs += ", " + checkpointID;
        }
    }
    checkpointIDs += ")";

    leaderboardSort = self openCJ\settings::getSetting("lbsort");
    sortParts = strTok(leaderboardSort, ":");
    sortClause =
        self openCJ\menus\leaderBoard::getSortStr(_toSupportedSortType(sortParts[0]), sortParts[1]);

    // Pick one best finished run per player, then limit the displayed page.
    // Exact ties use the oldest run and checkpoint, as finish ranking does.
    query =
        "SELECT a.totalNr, b.playerName, a.timePlayed, a.explosiveJumps, " +
        "a.loadCount, a.playerID " + "FROM (" + "SELECT COUNT(*) OVER() AS totalNr, a.* " +
        "FROM (" + "SELECT pr.playerID, cs.timePlayed, cs.explosiveJumps, cs.loadCount, " +
        "pr.finishTimeStamp, cs.runID, cs.cpID, cs.saveCount, (" +
        "ROW_NUMBER() OVER (PARTITION BY pr.playerID " + "ORDER BY playerID, " + sortClause +
        ", cs.runID ASC, cs.cpID ASC)) AS rn " +
        "FROM checkpointStatistics cs FORCE INDEX (checkpoint_time) " +
        "STRAIGHT_JOIN playerRuns pr ON pr.runID = cs.runID " + "WHERE cs.cpID IN " +
        checkpointIDs + " AND pr.finishcpID IS NOT NULL" + " AND pr.finishTimeStamp IS NOT NULL" +
        " AND pr.runID != " + self openCJ\playerRuns::getRunID() +
        " AND pr.ele <= " + self openCJ\elevate::hasUsedEle() +
        " AND pr.anyPct <= " + self openCJ\anyPct::hasAnyPct() +
        " AND pr.hb <= " + self openCJ\halfBeat::isHalfBeatAllowed() +
        " AND pr.hardTAS <= " + self openCJ\tas::hasHardTAS() + " AND pr.tutorial = 0" +
        " AND pr.FPSMode IN " +
        openCJ\menus\board_base::getFPSModeStr(self openCJ\fps::getCurrentFPSMode()) + ") a " +
        "WHERE a.rn = 1 " + "ORDER BY " + sortClause + ", a.runID ASC, a.cpID ASC" + " LIMIT " +
        level.nrRecords + ") a " + "INNER JOIN playerDisplayNames b ON a.playerID = b.playerID " +
        "ORDER BY " + sortClause + ", a.runID ASC, a.cpID ASC";
    return query;
}

_toSupportedSortType(sortType)
{
    if((sortType != "time") && (sortType != "rpgs") &&
       (sortType != "loads")) // Other types not supported (for now)
    {
        sortType = "time"; // Default to time for sorting that isn't easy to compare
    }
    return sortType;
}

// Compare the selected metric; descending ties retain the existing live-row priority.
_betterThanRecord(sortType, sortOrder, row, timePlayedMs, explosiveJumps, loadCount)
{
    record = _decodeRecordRow(row);
    currentValue = timePlayedMs;
    recordValue = int(record.timePlayedMs);
    if(sortType == "rpgs")
    {
        currentValue = explosiveJumps;
        recordValue = int(record.explosiveJumps);
    }
    else if(sortType == "loads")
    {
        currentValue = loadCount;
        recordValue = int(record.loadCount);
    }

    if(sortOrder == "asc")
    {
        return currentValue < recordValue;
    }
    return currentValue >= recordValue;
}

// Keep the SQL column order at one boundary; the first column is an unused total count.
_decodeRecordRow(row)
{
    record = spawnStruct();
    record.playerName = row[1];
    record.timePlayedMs = row[2];
    record.explosiveJumps = row[3];
    record.loadCount = row[4];
    record.playerID = row[5];
    return record;
}

// Insert a live row into a private array copy; retain the untouched rows for name refreshes.
_updateRecords(client, rows, overrideTimeMs, force)
{
    // An asynchronous records query may finish after the editor opens.
    if(client openCJ\checkpointCreation::isEditing())
    {
        return;
    }
    if(!force && (!isDefined(overrideTimeMs) && isDefined(client.showRecords_persistTime) &&
                  client.showRecords_persistTime > getTime()))
    {
        return;
    }
    if(client.sessionState != "playing")
    {
        return;
    }

    self.showRecords_visibleClient = client;
    self.showRecords_visibleRows = rows;
    self.showRecords_visibleTime = overrideTimeMs;
    explosiveJumps = client openCJ\statistics::getExplosiveJumps();
    loadCount = client openCJ\statistics::getLoadCount();
    if(!isDefined(overrideTimeMs))
    {
        timePlayedMs = client openCJ\playTime::getTimePlayed();
    }
    else
    {
        timePlayedMs = overrideTimeMs;
    }

    // Determine how the player wants their records sorted
    leaderboardSort = toLower(client openCJ\settings::getSetting("lbsort"));
    sortParts = strTok(leaderboardSort, ":");
    sortType = _toSupportedSortType(sortParts[0]);
    sortOrder = sortParts[1];

    i = 0;
    if(isDefined(rows))
    {
        for(; i < rows.size; i++)
        {
            if(client _betterThanRecord(sortType, sortOrder, rows[i], timePlayedMs, explosiveJumps,
                                        loadCount))
            {
                for(j = rows.size; j > i; j--)
                {
                    rows[j] = rows[j - 1];
                }
                break;
            }
        }
    }
    else
    {
        rows = [];
        rows[0] = [];
    }

    currentRunIndex = i;
    // The highlighted row represents the live player, not a stored record.
    rows[i][1] = client.name;
    rows[i][5] = client openCJ\login::getPlayerID();
    rows[i][2] = timePlayedMs;
    rows[i][3] = explosiveJumps;
    rows[i][4] = loadCount;
    self.showRecordsHighlight.y =
        level.showRecordsTopY + level.showRecordsRowHeight * currentRunIndex;
    self.showRecordsHighlight.alpha = level.showRecordsHighlightAlpha;

    if((rows.size > level.nrRecords) && (currentRunIndex < level.nrRecords))
    {
        rows[level.nrRecords] = undefined;
    }
    self _renderRows(rows, currentRunIndex, sortType);
}

// Compose the two client text columns and send only values that actually changed.
_renderRows(rows, currentRunIndex, sortType)
{
    nameString = "";
    timeString = "";
    for(i = 0; i < rows.size; i++)
    {
        if((i == currentRunIndex) && (i == level.nrRecords))
        {
            nameString += "??. ";
        }
        else
        {
            nameString += (i + 1) + ". ";
        }
        record = _decodeRecordRow(rows[i]);
        recordName = record.playerName;
        if(i != currentRunIndex && isDefined(record.playerID))
        {
            recordName = openCJ\playerNames::recordName(int(record.playerID), recordName);
        }
        nameString += recordName + "^7\n";
        extraInfo = record.explosiveJumps;
        if(sortType == "loads")
        {
            extraInfo = record.loadCount;
        }
        timeString +=
            formatTimeString(int(record.timePlayedMs), true) + " (" + extraInfo + ")" + "\n";
    }
    if(self.showRecords_nameString != nameString)
    {
        self setClientCvar("openCJ_records_names", nameString);
        self.showRecords_nameString = nameString;
    }
    if(self.showRecords_timeString != timeString)
    {
        self setClientCvar("openCJ_records_times", timeString);
        self.showRecords_timeString = timeString;
    }
}

whileAlive()
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    if(self openCJ\playerRuns::isRunFinished() || !self openCJ\playerRuns::hasRunID() ||
       !self openCJ\playerRuns::hasRunStarted())
    {
        return;
    }
    if(!isDefined(self.showRecords_rows))
    {
        return;
    }

    spectators = self getSpectatorList(true);
    for(i = 0; i < spectators.size; i++)
    {
        spectators[i] _updateRecords(self, self.showRecords_rows, undefined, false);
    }
}

onRecordNameChanged()
{
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        player = players[i];
        if(isDefined(player.showRecords_visibleClient))
        {
            player _updateRecords(player.showRecords_visibleClient, player.showRecords_visibleRows,
                                  player.showRecords_visibleTime, true);
        }
    }
}
