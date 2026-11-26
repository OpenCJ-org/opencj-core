#include openCJ\util;

onInit()
{
    // First, register leaderboard specific setting(s)
    openCJ\settings::addSettingString("lbsort", 1, 25, "time:asc", "Set persistent sorting for leaderboard", ::_onLBSortSettingChange);

    // Then, do common board initialization
    openCJ\menus\board_base::initBoard("lb", "leaderboard", "opencj_leaderboard", ::fetchUpdatedData, ::onBoardSortChange);
}

onBoardSortChange(sortType, sortOrder)
{
    sortOrderStr = "asc";
    if (sortOrder == 2)
    {
        sortOrderStr = "desc";
    }

    fullSortStr = sortType + ":" + sortOrderStr;
    if ((sortType == "time") || (sortType == "rpgs") || (sortType == "loads")) // These sorts are supported for records HUD
    {
        self sendLocalChatMessage("Applying sort " + fullSortStr + " to records HUD", false);
    }
    else
    {
        self sendLocalChatMessage("Not applying sort " + fullSortStr + " to records HUD", false);
    }

    self openCJ\settings::setSettingByScript("lbsort", fullSortStr);
    self openCJ\showRecords::onSortingChanged(); // Re-determine the records based on new sorting
}

_onLBSortSettingChange(newSortStr)
{
    newSortStr = toLower(newSortStr);
    if (newSortStr.size < 3) // x:x
    {
        return false;
    }
    if (!isSubStr(newSortStr, ":"))
    {
        return false;
    }

    arr = strTok(newSortStr, ":");
    if (arr.size != 2)
    {
        return false;
    }
    if ((arr[1] != "asc") && (arr[1] != "desc"))
    {
        return false;
    }
    if (!openCJ\menus\board_base::isValidSortCol(arr[0]) && (arr[0] != "date")) // "date" gets converted to "startDate" or "finishDate"
    {
        return false;
    }

    return true;
}

// Publish only a completed board read; missing routes produce an empty board.
fetchUpdatedData()
{
    routeIndex = self.currentBoard["filter"]["route"] - 1;
    routeName = undefined;
    if (routeIndex >= 0 && routeIndex < self.currentBoard["routes"].size)
    {
        routeName = self.currentBoard["routes"][routeIndex];
    }
    finishCheckpointIDs = undefined;
    otherMap = self.currentBoard["otherMap"];
    if (!isDefined(otherMap))
    {
        finishCheckpointIDs = getEndCheckpointIdsForRoute(routeName);
    }
    else if (isDefined(routeName) && isDefined(otherMap.finishCheckpointIDs[routeName]))
    {
        finishCheckpointIDs = "(" + otherMap.finishCheckpointIDs[routeName] + ")";
    }

    rows = [];
    if (isDefined(finishCheckpointIDs))
    {
        query = self buildLeaderboardQuery(finishCheckpointIDs);
        rows = self openCJ\mySQL::mysqlAsyncMenuQuery(query, "board");
        if (!isDefined(rows))
        {
            return false;
        }
    }

    self publishLeaderboardRows(rows);
}

// Rank narrow indexed rows before loading names and details for the visible page.
// Equal scores keep the oldest run, then checkpoint ID, matching finish ranking.
buildLeaderboardQuery(finishCheckpointIDs)
{
    sortClause = getSortStr(self.currentBoard["sortBy"], self.currentBoard["sort"]);
    pageSize = self.currentBoard["maxEntriesPerPage"];
    pageOffset = openCJ\menus\board_base::getOffsetFromPage(self.currentBoard["page"]["cur"], pageSize);
    fpsModes = openCJ\menus\board_base::getFPSModeStr(self.currentBoard["filter"]["fps"]);

    query = "SELECT a.totalNr, b.playerName, a.timePlayed, a.explosiveJumps, a.loadCount,"
                + " a.finishTimeStamp, r.FPSMode, r.ele, r.anyPct, r.hb, r.hardTAS, a.runID "
            + "FROM ("
                + "SELECT COUNT(*) OVER() AS totalNr, a.* "
                + "FROM ("
                    + "SELECT pr.playerID, cs.timePlayed, cs.explosiveJumps, cs.loadCount,"
                        + " pr.finishTimeStamp, cs.runID, cs.cpID, cs.saveCount, ("
                        + "ROW_NUMBER() OVER (PARTITION BY pr.playerID ORDER BY " + sortClause
                            + ", cs.runID ASC, cs.cpID ASC)) AS rn "
                    + "FROM checkpointStatistics cs FORCE INDEX (checkpoint_time) "
                    + "STRAIGHT_JOIN playerRuns pr ON pr.runID = cs.runID "
                    + "WHERE cs.cpID IN " + finishCheckpointIDs
                        + " AND pr.finishcpID IS NOT NULL"
                        + " AND pr.finishTimeStamp IS NOT NULL"
                        + " AND pr.ele <= " + self.currentBoard["filter"]["ele"]
                        + " AND pr.anyPct <= " + self.currentBoard["filter"]["any"]
                        + " AND pr.hb <= " + self.currentBoard["filter"]["hb"]
                        + " AND pr.hardTAS <= " + self.currentBoard["filter"]["tas"]
                        + " AND pr.tutorial = 0"
                        + " AND pr.FPSMode IN " + fpsModes
                + ") a "
                + "WHERE a.rn = 1 "
                + "ORDER BY " + sortClause + ", a.runID ASC, a.cpID ASC"
                + " LIMIT " + pageSize
                + " OFFSET " + pageOffset
            + ") a "
            + "INNER JOIN playerDisplayNames b ON a.playerID = b.playerID "
            + "INNER JOIN (SELECT runID, FPSMode, ele, anyPct, hb, hardTAS FROM playerRuns) r"
                + " ON r.runID = a.runID "
            + "ORDER BY " + sortClause + ", a.runID ASC, a.cpID ASC";
    return query;
}

// Replace the full page, including empty slots and the run IDs used by demo buttons.
publishLeaderboardRows(rows)
{
    totalEntriesColumn = 0;
    runIDColumn = 11;
    self.currentBoard["demoRunIDs"] = [];
    self.currentBoard["cols"] = [];
    self.currentBoard["nrTotalEntries"] = 0;
    self.currentBoard["nrEntriesThisPage"] = 0;
    if (rows.size > 0 && isDefined(rows[0][totalEntriesColumn]))
    {
        self.currentBoard["nrTotalEntries"] = int(rows[0][totalEntriesColumn]);
        self.currentBoard["nrEntriesThisPage"] = rows.size;
    }

    firstItemNumber = openCJ\menus\board_base::getAbsFirstItemNrCurrentPage(
        self.currentBoard["page"]["cur"], self.currentBoard["maxEntriesPerPage"]);
    for (rowIndex = 0; rowIndex < self.currentBoard["maxEntriesPerPage"]; rowIndex++)
    {
        if (rowIndex < self.currentBoard["nrEntriesThisPage"])
        {
            row = rows[rowIndex];
            self.currentBoard["demoRunIDs"][rowIndex] = int(row[runIDColumn]);
            self.currentBoard["cols"][rowIndex] = leaderboardColumns(row, firstItemNumber + rowIndex);
        }
        else
        {
            self.currentBoard["cols"][rowIndex] = emptyLeaderboardColumns();
        }
    }
}

// Decode the SELECT list once at the database boundary.
leaderboardColumns(row, itemNumber)
{
    playerNameColumn = 1;
    timePlayedColumn = 2;
    explosiveJumpsColumn = 3;
    loadsColumn = 4;
    finishDateColumn = 5;
    fpsModeColumn = 6;
    elevateColumn = 7;
    anyPercentColumn = 8;
    halfbeatColumn = 9;
    hardTASColumn = 10;

    columns = [];
    columns["nr"] = itemNumber;
    columns["name"] = "^7" + row[playerNameColumn] + "^7";
    columns["time"] = int(row[timePlayedColumn]);
    columns["rpgs"] = int(row[explosiveJumpsColumn]);
    columns["loads"] = int(row[loadsColumn]);
    columns["date"] = row[finishDateColumn];
    columns["fps"] = openCJ\menus\board_base::dbFPSToFullName(row[fpsModeColumn]);
    columns["ele"] = xOrEmpty(int(row[elevateColumn]));
    columns["any"] = xOrEmpty(int(row[anyPercentColumn]));
    columns["hb"] = xOrEmpty(int(row[halfbeatColumn]));
    columns["tas"] = xOrEmpty(int(row[hardTASColumn]));
    return columns;
}

emptyLeaderboardColumns()
{
    columns = [];
    columns["nr"] = -1;
    columns["name"] = "";
    columns["time"] = 0;
    columns["rpgs"] = 0;
    columns["loads"] = 0;
    columns["date"] = "";
    columns["fps"] = "";
    columns["ele"] = false;
    columns["any"] = false;
    columns["hb"] = false;
    columns["tas"] = false;
    return columns;
}

getSortStr(col, order) // Also used by showRecords.gsc for top-right records sorting
{
    orderTypeStr = "ASC"; // Default sort by ASC

    // Some scripts provide "ASC", "DESC". Some provide 1, 2
    if (isString(order))
    {
        order = toLower(order);
        if (order == "desc")
        {
            orderTypeStr = "DESC";
        }
    }
    else if (order == 2)
    {
        orderTypeStr = "DESC";
    }

    // For leaderboard, date means finishDate
    if (col == "date")
    {
        col = "finishDate";
    }

    // First add the sort that the user specified, however we want to add more sorts to nicely sort data even if it has the same main value as the next-in-line run
    orderStr = openCJ\menus\board_base::convertSortCol(col, orderTypeStr);
    orderStr += ", " + openCJ\menus\board_base::convertSortCol("time", orderTypeStr); // It's OK to specify the same sort twice in there, at least no SQL error
    orderStr += ", " + openCJ\menus\board_base::convertSortCol("rpgs", orderTypeStr);
    //orderStr += ", " + openCJ\menus\board_base::convertSortCol("loads", orderTypeStr);
    //orderStr += ", " + openCJ\menus\board_base::convertSortCol("saves", orderTypeStr);
    //orderStr += ", " + openCJ\menus\board_base::convertSortCol("finishDate", orderTypeStr);

    return orderStr;
}

// Open the leaderboard for a map chosen in the map list. Only the current map's
// checkpoints are loaded, so another map's routes come from the database.
openForMap(mapName)
{
    self endon("disconnect");
    self.boardPendingMap = undefined;
    // Never reveal records for maps outside this player's map pool (uber sees all).
    if (!openCJ\maps::canVoteMap(mapName, self.permissions))
    {
        self sendLocalChatMessage("Records for that map are not available.", true);
        return;
    }
    if (mapName != getCvar("mapname"))
    {
        otherMap = self _readMapRoutes(mapName);
        if (!isDefined(otherMap))
        {
            self sendLocalChatMessage("Could not load records for " + mapName + ". Try again later.",
                                      true);
            return;
        }
        if (otherMap.routes.size == 0)
        {
            self sendLocalChatMessage(mapName + " has no checkpointed routes yet.", true);
            return;
        }
        otherMap.requestedAt = getTime();
        self.boardPendingMap = otherMap;
    }
    self closeMenu();
    self openMenu("opencj_leaderboard");
}

// A map's route names with their active finish checkpoint IDs, or undefined
// when the database does not answer.
_readMapRoutes(mapName)
{
    query = "SELECT r.routeName, c.cpID FROM routes r"
            + " JOIN mapids m ON m.mapID = r.mapID"
            + " JOIN checkpoints c ON c.finishRouteID = r.routeID AND c.retired = 0"
            + " WHERE m.mapname = '" + openCJ\mySQL::escapeString(mapName) + "'"
            + " ORDER BY r.routeName, c.cpID";
    rows = self openCJ\mySQL::mysqlAsyncRead(query);
    if (!isDefined(rows))
    {
        return undefined;
    }

    routeNameColumn = 0;
    checkpointIDColumn = 1;
    otherMap = spawnStruct();
    otherMap.mapName = mapName;
    otherMap.routes = [];
    otherMap.finishCheckpointIDs = [];
    for (i = 0; i < rows.size; i++)
    {
        routeName = rows[i][routeNameColumn];
        checkpointID = int(rows[i][checkpointIDColumn]);
        if (!isDefined(otherMap.finishCheckpointIDs[routeName]))
        {
            otherMap.routes[otherMap.routes.size] = routeName;
            otherMap.finishCheckpointIDs[routeName] = "" + checkpointID;
        }
        else
        {
            otherMap.finishCheckpointIDs[routeName] += ", " + checkpointID;
        }
    }
    return otherMap;
}

getEndCheckpointIdsForRoute(routeName)
{
    if (!isDefined(routeName) || !isDefined(level.routeEnders[routeName]))
    {
        return undefined;
    }

    cpSqlStr = "";
    isFirstCp = true;
    for (i = 0; i < level.routeEnders[routeName].size; i++)
    {
        cpID = openCJ\checkpoints::getCheckpointID(level.routeEnders[routeName][i]);
        if (isDefined(cpID))
        {
            if (!isFirstCp)
            {
                cpSqlStr += ", ";
            }

            cpSqlStr += cpID;
            isFirstCp = false;
        }
    }

    if (cpSqlStr.size <= 0)
    {
        return undefined;
    }

    return "(" + cpSqlStr + ")";
}

// Resolve the complete client slot before cancelling or starting demo playback.
handleDemo(button)
{
    if(self.currentMenu != "opencj_leaderboard")
    {
        return;
    }

    demoButtonPrefix = "playdemo";
    if(getSubStr(button, 0, demoButtonPrefix.size) != demoButtonPrefix)
    {
        return;
    }

    slotText = getSubStr(button, demoButtonPrefix.size);
    if(!isValidInt(slotText))
    {
        return;
    }

    rowIndex = int(slotText) - 1;
    if(rowIndex < 0 || rowIndex >= self.currentBoard["nrEntriesThisPage"])
    {
        return;
    }
    if(isDefined(self.currentBoard["otherMap"]))
    {
        self sendLocalChatMessage("Demos only play on their own map.", true);
        return;
    }

    runID = self.currentBoard["demoRunIDs"][rowIndex];
    if(!isDefined(runID))
    {
        return;
    }

    self openCJ\demos::cancelRequest();
    self closeMenu();
    returnToBoard = true;
    self thread openCJ\demos::playRun(runID, returnToBoard);
}
