#include openCJ\util;

onInit()
{
    openCJ\menus\board_base::initBoard("rn", "runsboard", "opencj_runsboard", ::fetchUpdatedData, undefined);
}

handleRestoreRun(str)
{
    // str example: loadrun1 (when clicking on the first run)
    if (str.size > 7)
    {
        nrPressed = int(getSubStr(str, 7));
        if ((nrPressed < 1) || (nrPressed > level.boards["rn"]["maxEntriesPerPage"])) // Sanity check for out of bounds
        {
            return;
        }

        idx = nrPressed -1;
        if (!isDefined(self.currentBoard) || !isDefined(self.currentBoard["cols"]) || !isDefined(self.currentBoard["cols"][idx]))
        {
            return;
        }

        runID = self.currentBoard["cols"][idx]["nr"];
        if (runID < 0) // Initialized to -1 when it doesn't contain a value
        {
            return;
        }

        query = "SELECT * FROM playerRuns WHERE runID = " + runID + " AND playerID = " + self openCJ\login::getPlayerID();
        rows = self openCJ\mySQL::mysqlAsyncQuery(query);
        if (isDefined(rows) && isDefined(rows[0]) && isDefined(rows[0][0]))
        {
            // Run is indeed by player, we can safely restore run if he's logged in
            if(self isPlayerReady(false))
            {
                self openCJ\playerRuns::restoreRun(runID);
            }
        }
    }

    self closeMenu();
}

// Keep the previous page when its owned database read fails or is cancelled.
fetchUpdatedData()
{
    query = self buildRunsQuery();
    rows = self openCJ\mySQL::mysqlAsyncMenuQuery(query, "board");
    if (!isDefined(rows))
    {
        return false;
    }

    self publishRunRows(rows);
}

// Select each owner's latest save before filtering its mode and FPS.
// An older matching save must never replace the current position of that run.
buildRunsQuery()
{
    playerID = self openCJ\login::getPlayerID();
    sortClause = getSortStr(self.currentBoard["sortBy"], self.currentBoard["sort"]);
    pageSize = self.currentBoard["maxEntriesPerPage"];
    pageOffset = openCJ\menus\board_base::getOffsetFromPage(self.currentBoard["page"]["cur"], pageSize);
    fpsModes = openCJ\menus\board_base::getFPSModeStr(self.currentBoard["filter"]["fps"]);

    query = "SELECT COUNT(*) OVER() AS totalNr, a.runID, rl.runLabel, a.timePlayed, " +
                "a.explosiveJumps, a.loadCount, a.startTimeStamp, a.FPSMode, a.flags " +
            "FROM (" +
                "SELECT 1 AS rn, pr.playerID, pr.mapID, pr.runID, pr.timePlayed, " +
                    "ps.explosiveJumps, pr.loadCount, pr.saveCount, pr.startTimeStamp, " +
                    "ps.FPSMode, ps.flags " +
                "FROM playerRuns AS pr " +
                "INNER JOIN playerSaves ps ON ps.runID = pr.runID " +
                    "AND ps.saveNumber = (" +
                        "SELECT MAX(latest.saveNumber) " +
                        "FROM playerSaves latest " +
                        "WHERE latest.runID = pr.runID" +
                    ") " +
                "WHERE pr.playerID = " + playerID +
                    " AND finishTimeStamp IS NULL AND finishcpID IS NULL " +
                    "AND archived = False AND mapID = " + openCJ\mapID::getMapID() +
                    self getRunStr() +
            ") a " +
            "LEFT JOIN runLabels rl ON a.runID = rl.runID " +
            "WHERE a.rn = 1 AND a.playerID = " + playerID +
                getFilterStr(self.currentBoard["filter"]["ele"], self.currentBoard["filter"]["any"], self.currentBoard["filter"]["hb"], self.currentBoard["filter"]["tas"]) +
                " AND a.FPSMode IN " +
                fpsModes +
                getTutorialFilterStr(self.currentBoard["filter"]["fps"]) +
            " ORDER BY " + sortClause +
            " LIMIT " + pageSize +
            " OFFSET " + pageOffset;
    return query;
}

// Replace the complete page so unused slots cannot retain a previous restore ID.
publishRunRows(rows)
{
    totalEntriesColumn = 0;
    self.currentBoard["cols"] = [];
    self.currentBoard["nrTotalEntries"] = 0;
    self.currentBoard["nrEntriesThisPage"] = 0;
    if (rows.size > 0 && isDefined(rows[0][totalEntriesColumn]))
    {
        self.currentBoard["nrTotalEntries"] = int(rows[0][totalEntriesColumn]);
        self.currentBoard["nrEntriesThisPage"] = rows.size;
    }

    for (rowIndex = 0; rowIndex < self.currentBoard["maxEntriesPerPage"]; rowIndex++)
    {
        if (rowIndex < self.currentBoard["nrEntriesThisPage"])
        {
            self.currentBoard["cols"][rowIndex] = runColumns(rows[rowIndex]);
        }
        else
        {
            self.currentBoard["cols"][rowIndex] = emptyRunColumns();
        }
    }
}

// Decode the SELECT list once, including the independent saved mode flags.
runColumns(row)
{
    runIDColumn = 1;
    labelColumn = 2;
    timePlayedColumn = 3;
    explosiveJumpsColumn = 4;
    loadsColumn = 5;
    startDateColumn = 6;
    fpsModeColumn = 7;
    flagsColumn = 8;
    flags = int(row[flagsColumn]);
    isTutorialRun = (flags & level.saveFlags[level.saveFlagName_tutorial]) != 0;
    label = row[labelColumn];
    if (!isDefined(label) || label == "")
    {
        label = "(Unnamed run)";
    }
    if (isTutorialRun)
    {
        label = "^5[Tutorial]^7 " + label;
    }

    columns = [];
    columns["nr"] = int(row[runIDColumn]);
    columns["name"] = "^7" + label + "^7";
    columns["time"] = int(row[timePlayedColumn]);
    columns["rpgs"] = int(row[explosiveJumpsColumn]);
    columns["loads"] = int(row[loadsColumn]);
    columns["date"] = row[startDateColumn];
    columns["fps"] = openCJ\menus\board_base::dbFPSToFullName(row[fpsModeColumn]);
    // The server chose tutorial FPS, so show that category instead of a competitive mode.
    if (isTutorialRun)
    {
        columns["fps"] = "Tutorial";
    }

    columns["ele"] = xOrEmpty(flags & level.saveFlags[level.saveFlagName_usedEle]);
    columns["any"] = xOrEmpty(flags & level.saveFlags[level.saveFlagName_anyPct]);
    columns["hb"] = xOrEmpty(flags & level.saveFlags[level.saveFlagName_allowHalfbeat]);
    columns["tas"] = xOrEmpty(flags & level.saveFlags[level.saveFlagName_hardTAS]);
    return columns;
}

emptyRunColumns()
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

getRunStr()
{
    str = "";
    if(self openCJ\playerRuns::hasRunID())
    {
        str = " AND pr.runID != " + self openCJ\playerRuns::getRunID();
    }

    return str;
}

// Tutorial runs have a server-chosen FPS, so only the Any FPS filter lists them.
getTutorialFilterStr(fpsFilter)
{
    if (fpsFilter == "125" || fpsFilter == "mix")
    {
        return " AND (a.flags & " + level.saveFlags[level.saveFlagName_tutorial] + ") = 0";
    }
    return "";
}

getFilterStr(ele, any, halfbeat, tas)
{
    eleVal = int(ele) * level.saveFlags[level.saveFlagName_usedEle];
    anyVal = int(any) * level.saveFlags[level.saveFlagName_anyPct];
    halfBeatVal = int(halfbeat) * level.saveFlags[level.saveFlagName_allowHalfBeat];
    tasVal = int(tas) * level.saveFlags[level.saveFlagName_hardTAS];

    flagsBeginStr = " AND (a.flags & ";
    str = flagsBeginStr + level.saveFlags[level.saveFlagName_usedEle] + ") <= " + eleVal;
    str += flagsBeginStr + level.saveFlags[level.saveFlagName_anyPct] + ") <= " + anyVal;
    str += flagsBeginStr + level.saveFlags[level.saveFlagName_allowHalfBeat] + ") <= " + halfBeatVal;
    str += flagsBeginStr + level.saveFlags[level.saveFlagName_hardTAS] + ") <= " + tasVal;

    return str;
}

getSortStr(col, order)
{
    orderTypeStr = "ASC"; // Default sort by ASC
    if (order == 2)
    {
        orderTypeStr = "DESC";
    }

    // For runsboard, date means startDate
    if (col == "date")
    {
        col = "startDate";
    }

    // First add the sort that the user specified, however we want to add more sorts to nicely sort data even if it has the same main value as the next-in-line run
    orderStr = openCJ\menus\board_base::convertSortCol(col, orderTypeStr);
    orderStr += ", " + openCJ\menus\board_base::convertSortCol("time", orderTypeStr); // It's OK to specify the same sort twice in there, at least no SQL error
    orderStr += ", " + openCJ\menus\board_base::convertSortCol("rpgs", orderTypeStr);
    orderStr += ", " + openCJ\menus\board_base::convertSortCol("loads", orderTypeStr);
    orderStr += ", " + openCJ\menus\board_base::convertSortCol("saves", orderTypeStr);
    orderStr += ", " + openCJ\menus\board_base::convertSortCol("startDate", orderTypeStr);

    return orderStr;
}

