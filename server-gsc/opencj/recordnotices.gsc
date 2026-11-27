#include openCJ\util;

// Record announcements compare exact categories. Broader leaderboard filters
// must never turn an any% result into an improvement over a checkpoint run.
finishQuery(runID)
{
    // Reuse eligible rows. Keep each server/personal time/RPG winner separate.
    return "WITH finished AS ( " +
        "SELECT r.runID,r.playerID,r.mapID,r.FPSMode,r.ele,r.anyPct,r.hb,r.hardTAS, " +
        "c.finishRouteID AS routeID,route.routeName,s.timePlayed,s.explosiveJumps,p.playerName " +
        "FROM playerRuns r " +
        "JOIN checkpoints c ON c.cpID=r.finishcpID " +
        "AND c.retired=0 " +
        "JOIN routes route ON route.routeID=c.finishRouteID " +
        "JOIN checkpointStatistics s ON s.runID=r.runID " +
        "AND s.cpID=r.finishcpID " +
        "JOIN playerDisplayNames p ON p.playerID=r.playerID " +
        "WHERE r.runID=" + runID + " " +
        "AND r.tutorial=0 " +
        "AND r.finishTimeStamp IS NOT NULL), " +
        "eligible AS ( " +
        "SELECT r.runID,r.playerID,s.timePlayed,s.explosiveJumps " +
        "FROM finished f " +
        "JOIN playerRuns r ON r.mapID=f.mapID " +
        "AND r.FPSMode=f.FPSMode " +
        "AND r.ele=f.ele " +
        "AND r.anyPct=f.anyPct " +
        "AND r.hb=f.hb " +
        "AND r.hardTAS=f.hardTAS " +
        "JOIN checkpoints c ON c.cpID=r.finishcpID " +
        "AND c.finishRouteID=f.routeID " +
        "AND c.retired=0 " +
        "JOIN checkpointStatistics s ON s.runID=r.runID " +
        "AND s.cpID=r.finishcpID " +
        "WHERE r.finishTimeStamp IS NOT NULL " +
        "AND r.tutorial=0 " +
        "AND r.runID<>f.runID) , " +
        "prior AS ( ( " +
        "SELECT /*+ NO_MERGE(e) */ 0 AS scope,0 AS metric,e.timePlayed,e.explosiveJumps " +
        "FROM eligible e " +
        "ORDER BY e.timePlayed,e.explosiveJumps,e.runID " +
        "LIMIT 1) " +
        "UNION ALL ( " +
        "SELECT /*+ NO_MERGE(e) */ 0 AS scope,1 AS metric,e.timePlayed,e.explosiveJumps " +
        "FROM eligible e " +
        "ORDER BY e.explosiveJumps,e.timePlayed,e.runID " +
        "LIMIT 1) " +
        "UNION ALL ( " +
        "SELECT /*+ NO_MERGE(e) */ 1 AS scope,0 AS metric,e.timePlayed,e.explosiveJumps " +
        "FROM eligible e " +
        "JOIN finished f ON e.playerID=f.playerID " +
        "ORDER BY e.timePlayed,e.explosiveJumps,e.runID " +
        "LIMIT 1) " +
        "UNION ALL ( " +
        "SELECT /*+ NO_MERGE(e) */ 1 AS scope,1 AS metric,e.timePlayed,e.explosiveJumps " +
        "FROM eligible e " +
        "JOIN finished f ON e.playerID=f.playerID " +
        "ORDER BY e.explosiveJumps,e.timePlayed,e.runID " +
        "LIMIT 1) ) , " +
        "boards AS ( " +
        "SELECT 0 AS scope,0 AS metric " +
        "UNION ALL " +
        "SELECT 0,1 " +
        "UNION ALL " +
        "SELECT 1,0 " +
        "UNION ALL " +
        "SELECT 1,1) " +
        "SELECT b.scope,b.metric,f.routeName,f.FPSMode,f.ele,f.anyPct,f.hb,f.hardTAS,f.timePlayed, " +
        "f.explosiveJumps, " +
        "old.timePlayed,old.explosiveJumps,f.playerName,f.playerID,f.runID " +
        "FROM finished f " +
        "CROSS " +
        "JOIN boards b " +
        "LEFT " +
        "JOIN prior old ON old.scope=b.scope " +
        "AND old.metric=b.metric " +
        "ORDER BY b.scope,b.metric ";
}

category(fpsMode, usedElevators, anyPercent, halfbeat, hardTAS)
{
    categoryLabel = "Standard FPS";
    if(fpsMode == "125")
    {
        categoryLabel = "125 FPS";
    }
    if(fpsMode == "hax")
    {
        categoryLabel = "Any FPS";
    }
    if(anyPercent)
    {
        categoryLabel += ", any%";
    }
    else
    {
        categoryLabel += ", checkpoints";
    }
    if(usedElevators)
    {
        categoryLabel += ", elevators";
    }
    if(halfbeat)
    {
        categoryLabel += ", halfbeat";
    }
    if(hardTAS)
    {
        categoryLabel += ", TAS";
    }
    return categoryLabel;
}
// Decode the fixed query result once; absent prior values mean a first finish.
decodeRecord(row)
{
    recordColumnCount = 15;
    if(!isDefined(row) || row.size != recordColumnCount)
    {
        return undefined;
    }
    record = spawnStruct();
    record.scope = "server";
    if(int(row[0]) == 1)
    {
        record.scope = "personal";
    }
    record.metric = "time";
    if(int(row[1]) != 0)
    {
        record.metric = "rpgs";
    }
    record.routeName = row[2];
    record.fpsMode = row[3];
    record.usedElevators = int(row[4]);
    record.anyPercent = int(row[5]);
    record.halfbeat = int(row[6]);
    record.hardTAS = int(row[7]);
    record.timeMs = int(row[8]);
    record.rpgCount = int(row[9]);
    record.priorTimeMs = row[10];
    record.priorRpgCount = row[11];
    record.playerName = row[12];
    record.playerID = int(row[13]);
    record.runID = int(row[14]);
    return record;
}

improvement(row)
{
    record = decodeRecord(row);
    if(!isDefined(record))
    {
        return "";
    }
    return describeImprovement(record);
}

describeImprovement(record)
{
    // A first finish establishes a record; it has not beaten a previous one.
    if(!isDefined(record.priorTimeMs) || !isDefined(record.priorRpgCount))
    {
        return "";
    }
    priorTimeMs = int(record.priorTimeMs);
    priorRpgCount = int(record.priorRpgCount);
    if(record.metric == "time")
    {
        if(record.timeMs < priorTimeMs)
        {
            return "time: " + formatTimeString(priorTimeMs - record.timeMs, false) + " faster";
        }
        if(record.timeMs == priorTimeMs && record.rpgCount < priorRpgCount)
        {
            return "time: tied, " + (priorRpgCount - record.rpgCount) + " fewer RPGs";
        }
    }
    else
    {
        if(record.rpgCount < priorRpgCount)
        {
            return "RPGs: " + (priorRpgCount - record.rpgCount) + " fewer";
        }
        if(record.rpgCount == priorRpgCount && record.timeMs < priorTimeMs)
        {
            return "RPGs: tied, " + formatTimeString(priorTimeMs - record.timeMs, false) + " faster";
        }
    }
    return "";
}

details(records, scope)
{
    description = "";
    for(i = 0; i < records.size; i++)
    {
        if(records[i].scope != scope)
        {
            continue;
        }
        improvementText = describeImprovement(records[i]);
        if(improvementText == "")
        {
            continue;
        }
        if(description != "")
        {
            description += "; ";
        }
        description += improvementText;
    }
    return description;
}

// Validate every row before printing any part of the announcement.
decodeRecords(rows)
{
    expectedBoardCount = 4; // Server and personal boards, each ranked by time and RPGs.
    if(!isDefined(rows) || rows.size != expectedBoardCount)
    {
        return undefined;
    }
    records = [];
    for(i = 0; i < rows.size; i++)
    {
        record = decodeRecord(rows[i]);
        if(!isDefined(record))
        {
            return undefined;
        }
        records[i] = record;
    }
    return records;
}
// A saved record can still be announced after a new run starts; its overlay cannot.
onRunFinished(runID)
{
    self endon("disconnect");
    if(isDefined(self.notificationFinishedRun) && self.notificationFinishedRun == runID)
    {
        return;
    }
    self.notificationFinishedRun = runID;
    ownerPlayerID = self openCJ\login::getPlayerID();
    // This saved finish still matters after a new run starts, but not after disconnect.
    self.notificationRecordScope = "record-notice:" + self getEntityNumber();
    result = self openCJ\mySQL::_request(
        finishQuery(runID), level.sqlConstants.policyMenu, "", self.notificationRecordScope,
        level.sqlConstants.defaultQueueWaitMs, true);
    rows = undefined;
    if(isDefined(result))
    {
        rows = result.rows;
    }
    records = decodeRecords(rows);
    if(!isDefined(records))
    {
        return;
    }
    finishedRun = records[0];
    if(finishedRun.playerID != ownerPlayerID || finishedRun.runID != runID)
    {
        return;
    }
    categoryLabel = category(finishedRun.fpsMode, finishedRun.usedElevators,
                             finishedRun.anyPercent, finishedRun.halfbeat, finishedRun.hardTAS);
    routeLabel = finishedRun.routeName + " [" + categoryLabel + "]";
    serverImprovement = details(records, "server");
    personalImprovement = details(records, "personal");
    if(serverImprovement != "" || personalImprovement != "")
    {
        self openCJ\notifications::result("record", runID);
    }
    if(serverImprovement != "")
    {
        iprintln(finishedRun.playerName + "^7 | " + routeLabel +
                 " | ^2Server record: ^7" + serverImprovement);
        // Discord is public: hard TAS (tool-assisted) records stay in game. Tutorial runs never
        // get here (finishQuery skips them), nor do assisted ones (events\runFinished returns
        // early for noclip, speed mode, teleports and paused runs).
        if(!finishedRun.hardTAS)
        {
            openCJ\discord::onServerRecord(finishedRun.playerName, finishedRun.routeName, categoryLabel,
                                           finishedRun.timeMs, finishedRun.rpgCount, serverImprovement);
        }
    }
    if(personalImprovement != "" && self openCJ\login::getPlayerID() == ownerPlayerID)
    {
        self iprintln(routeLabel + " | ^2Personal best: ^7" + personalImprovement);
    }
}

checkpointQuery(runID, cpID, fps, ele, any, hb, tas, metric)
{
    sort = "cs.timePlayed,cs.explosiveJumps";
    if(metric == "rpgs")
    {
        sort = "cs.explosiveJumps,cs.timePlayed";
    }
    return "SELECT cs.timePlayed,cs.explosiveJumps " +
           "FROM checkpointStatistics cs " +
           "STRAIGHT_JOIN playerRuns r ON r.runID=cs.runID " +
           "WHERE cs.cpID=" + cpID +
           " AND r.runID<>" + runID +
           " AND r.finishTimeStamp IS NOT NULL " +
           "AND r.tutorial=0 " +
           "AND r.FPSMode=" + dbStr(fps) +
           " AND r.ele=" + int(ele) +
           " AND r.anyPct=" + int(any) +
           " AND r.hb=" + int(hb) +
           " AND r.hardTAS=" + int(tas) +
           " ORDER BY " + sort + ",cs.runID LIMIT 1";
}

checkpoint(runID, cpID, timePlayed)
{
    self endon("disconnect");
    self openCJ\notifications::cancelCheckpoint();
    self endon("notificationCheckpointStop");
    self openCJ\notifications::action("checkpoint");
    if(!self openCJ\notifications::wantsText("checkpoint"))
    {
        return;
    }
    runInstance = self openCJ\playerRuns::getRunInstanceNumber();
    layoutEpoch = level.checkpointLayoutEpoch;
    fpsMode = self openCJ\fps::getCurrentFPSMode();
    usedElevators = self openCJ\elevate::hasUsedEle();
    anyPercent = self openCJ\anyPct::hasAnyPct();
    halfbeat = self openCJ\halfBeat::isHalfBeatAllowed();
    hardTAS = self openCJ\tas::hasHardTAS();
    rpgCount = self openCJ\statistics::getExplosiveJumps();
    leaderboardSort = self openCJ\settings::getSetting("lbsort");
    metric = "time";
    if(isDefined(leaderboardSort))
    {
        sortParts = strTok(leaderboardSort, ":");
        if(sortParts[0] == "rpgs")
        {
            metric = "rpgs";
        }
    }
    // Closing a menu must not cancel the checkpoint comparison for the current run.
    self.notificationCheckpointScope = "checkpoint-notice:" + self getEntityNumber();
    query = checkpointQuery(runID, cpID, fpsMode, usedElevators, anyPercent, halfbeat, hardTAS, metric);
    result = self openCJ\mySQL::_request(
        query, level.sqlConstants.policyMenu, "", self.notificationCheckpointScope,
        level.sqlConstants.defaultQueueWaitMs, true);
    self.notificationCheckpointScope = undefined;
    rows = undefined;
    if(isDefined(result))
    {
        rows = result.rows;
    }
    currentRunID = self openCJ\playerRuns::getRunID();
    currentInstance = self openCJ\playerRuns::getRunInstanceNumber();
    if(!isDefined(currentRunID) || !isDefined(currentInstance))
    {
        return;
    }
    if(currentRunID != runID || currentInstance != runInstance ||
       level.checkpointLayoutEpoch != layoutEpoch || self openCJ\demos::isPlayingDemo() ||
       !self openCJ\notifications::wantsText("checkpoint"))
    {
        return;
    }
    message = checkpointMessage(rows, metric, timePlayed, rpgCount);
    self iprintln(message);
}

// An unavailable comparison still reports the checkpoint itself.
checkpointMessage(rows, metric, timePlayed, rpgCount)
{
    message = "Checkpoint passed";
    if(isDefined(rows) && rows.size && rows[0].size == 2)
    {
        if(metric == "rpgs")
        {
            difference = rpgCount - int(rows[0][1]);
            if(difference < 0)
            {
                message += " | ^2" + (0 - difference) + " fewer RPGs";
            }
            else if(difference > 0)
            {
                message += " | ^1" + difference + " more RPGs";
            }
            else
            {
                message += " | same RPG count";
            }
        }
        else
        {
            difference = timePlayed - int(rows[0][0]);
            if(difference < 0)
            {
                message += " | ^2" + formatTimeString(0 - difference, false) + " ahead";
            }
            else if(difference > 0)
            {
                message += " | ^1" + formatTimeString(difference, false) + " behind";
            }
            else
            {
                message += " | same split time";
            }
        }
    }
    return message;
}

// The scope covers every outstanding finish read owned by this connection.
cancelFinishReads()
{
    if(isDefined(self.notificationRecordScope))
    {
        mysql_async_cancel(self.notificationRecordScope, level.sqlConstants.scopeExact,
                           level.sqlConstants.retainCompletion);
        self.notificationRecordScope = undefined;
    }
}
