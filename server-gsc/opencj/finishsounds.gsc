onRunFinished(runID)
{
    self endon("disconnect");
    rows = self openCJ\mySQL::mysqlAsyncRead(recordQuery(runID));
    self playLocalSound(soundForResult(rows));
}

soundForResult(rows)
{
    // A failed ranking lookup still gets the ordinary completion sound.
    if (isDefined(rows) && rows.size && isDefined(rows[0][0]) && int(rows[0][0]))
        return "opencj_route_record";
    return "opencj_route_complete";
}

recordQuery(runID)
{
    // Use the saved finish, not mutable player/menu settings after an async wait.
    // Mode inclusion and time/RPG tiebreaks match the route leaderboard.
    // Older run IDs win exact ties so repeating a record does not trigger fanfare.
    // Each player occupies only one place on each of the two boards.
    // Only three distinct players ahead can disqualify a podium place.
    // An older/better own run must still prevent repeat-record fanfare.
    return "WITH finished AS ( " +
        "SELECT r.*,c.finishRouteID AS routeID  " +
        "FROM playerRuns r  " +
        "JOIN checkpoints c ON c.cpID=r.finishcpID  " +
        "WHERE r.runID=" + runID + "  " +
        "AND r.tutorial=0  " +
        "AND r.finishTimeStamp IS NOT NULL), eligible AS ( " +
        "SELECT r.runID,r.playerID,s.timePlayed,s.explosiveJumps  " +
        "FROM finished f  " +
        "JOIN playerRuns r ON r.mapID=f.mapID  " +
        "AND r.ele<=f.ele  " +
        "AND r.anyPct<=f.anyPct  " +
        "AND r.hb<=f.hb  " +
        "AND r.hardTAS<=f.hardTAS  " +
        "AND (r.FPSMode=f.FPSMode OR r.FPSMode='125' OR (f.FPSMode='hax'  " +
        "AND r.FPSMode='mix'))  " +
        "JOIN checkpoints c ON c.cpID=r.finishcpID  " +
        "AND c.finishRouteID=f.routeID  " +
        "JOIN checkpointStatistics s ON s.runID=r.runID  " +
        "AND s.cpID=r.finishcpID  " +
        "WHERE r.finishTimeStamp IS NOT NULL  " +
        "AND r.tutorial=0) " +
        ", " +
        "candidate AS (SELECT * FROM eligible WHERE runID=" + runID + ") " +
        ", " +
        "timeAhead AS (SELECT e.playerID FROM eligible e JOIN candidate f " +
        "ON e.timePlayed<f.timePlayed OR (e.timePlayed=f.timePlayed AND e.explosiveJumps<f.explosiveJumps) " +
        "OR (e.timePlayed=f.timePlayed AND e.explosiveJumps=f.explosiveJumps AND e.runID<f.runID)) " +
        ", " +
        "rpgAhead AS (SELECT e.playerID FROM eligible e JOIN candidate f " +
        "ON e.explosiveJumps<f.explosiveJumps OR (e.explosiveJumps=f.explosiveJumps AND e.timePlayed<f.timePlayed) " +
        "OR (e.explosiveJumps=f.explosiveJumps AND e.timePlayed=f.timePlayed AND e.runID<f.runID)) " +
        ", " +
        "timePlayers AS (SELECT DISTINCT playerID FROM timeAhead LIMIT 3) " +
        ", " +
        "rpgPlayers AS (SELECT DISTINCT playerID FROM rpgAhead LIMIT 3) " +
        "SELECT EXISTS(SELECT 1 FROM candidate f WHERE " +
        "(NOT EXISTS(SELECT 1 FROM timeAhead e WHERE e.playerID=f.playerID) AND (SELECT COUNT(*) FROM timePlayers)<3) " +
        "OR (NOT EXISTS(SELECT 1 FROM rpgAhead e WHERE e.playerID=f.playerID) AND (SELECT COUNT(*) FROM rpgPlayers)<3)) ";
}
