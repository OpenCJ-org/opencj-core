#include openCJ\util;

// All challenge definitions, rules, awards, ranks and menu data live here.
// IDs are permanent, including keys whose old difficulty names were corrected.
// Map/route names bind new definitions; permanent IDs keep existing links stable.
// Mode bits: any%=1, elevators=2, halfbeat=4, TAS=8. FPS is specified separately.
definitions()
{
    level.challenges = [];
    millisecondsPerHour = 60 * 60 * 1000;
    add("spectrum.beginner", 1, "mp_spectrum", "Beginner");
    add("cj_sky_bounce.main_route", 1, "mp_cj_sky_bounce", "Main route");
    add("to_the_moon.easy", 1, "mp_to_the_moon", "Basic");
    add("palm.easy", 1, "mp_palm", "Easy");
    add("blue2.easy", 1, "mp_blue2", "Easy");
    add("spectrum.easy", 1, "mp_spectrum", "Easy");
    add("descent_v2.easy", 1, "mp_descent_v2", "Easy");
    add("mystic_v2.easy", 1, "mp_mystic_v2", "Easy");
    add("mystic_v3.easy", 1, "mp_mystic_v3", "Easy");
    add("galaxy.easy", 1, "mp_galaxy", "Easy");
    add("to_the_moon.inter", 2, "mp_to_the_moon", "Intermediate");
    add("palm.inter", 2, "mp_palm", "Intermediate");
    add("blue2.inter", 2, "mp_blue2", "Intermediate");
    add("mystic_v3.inter", 2, "mp_mystic_v3", "Intermediate");
    add("galaxy.inter", 2, "mp_galaxy", "Intermediate");
    add("to_the_moon.advanced", 3, "mp_to_the_moon", "Advanced");
    add("blue2.hard", 3, "mp_blue2", "Hard");
    add("palm.hard", 3, "mp_palm", "Hard");
    add("bone.hard", 3, "mp_bone", "Hard");
    add("insane.hard", 3, "mp_insane", "Hard");
    add("descent_v2.hard", 4, "mp_descent_v2", "Hard");
    add("descent.hard", 4, "mp_descent", "Hard");
    add("shade.advanced", 4, "mp_shade", "Advanced");
    add("dark.hard", 4, "mp_dark", "Hard");
    add("dark_v2.hard", 4, "mp_dark_v2", "Hard");
    add("mystic_v2.hard", 5, "mp_mystic_v2", "Hard");
    add("palm_v2.hard", 5, "mp_palm_v2", "Hard");
    add("qube_v2.hard", 5, "mp_qube_v2", "Hard");
    add("marble.hard", 5, "mp_marble", "Hard");
    add("restyled.hard", 5, "mp_restyled", "Hard");
    add("awe.advanced", 6, "mp_awe", "Advanced");
    add("bridge.hard", 6, "mp_bridge", "Hard");
    add("mystic_v3.hard", 6, "mp_mystic_v3", "Hard");
    add("dawn_v2.hard", 6, "mp_dawn_v2", "Hard");
    add("galaxy.hard", 6, "mp_galaxy", "Hard");
    add("edge.main_route_edge", 7, "mp_edge", "Main route (edge)");
    add("mushroom.fungal_hazards", 7, "mp_mushroom", "Fungal Hazards");
    add("heaven_v2.hard", 7, "mp_heaven_v2", "Hard");
    add("dark_v3.hard", 7, "mp_dark_v3", "Hard");
    add("sunset.hard", 7, "mp_sunset", "Hard");
    add("sunset_v2.advanced", 8, "mp_sunset_v2", "Advanced");
    add("cyber.reality_corp_advanced", 8, "mp_cyber", "Reality Corp");
    add("new_york.hard", 8, "mp_new_york", "Hard");
    add("palm_v3.advanced", 8, "mp_palm_v3", "Advanced");
    add("palm_v3.challenge", 8, "mp_palm_v3", "Challenge");
    add("dark_final.hard", 9, "mp_dark_final", "Hard");
    add("restyled_v3.hard", 9, "mp_restyled_v3", "Hard");
    add("void_v2.advanced", 9, "mp_void_v2", "Advanced");
    add("edge_v2.brutal", 9, "mp_edge_v2", "Brutal");
    add("12.advanced", 9, "mp_12", "Advanced");
    challenge = add("dark_final.hard.timed", 10, "mp_dark_final", "Hard");
    challenge.maxTime = millisecondsPerHour;
    challenge = add("restyled_v3.hard.timed", 10, "mp_restyled_v3", "Hard");
    challenge.maxTime = millisecondsPerHour;
    challenge = add("void_v2.advanced.timed", 10, "mp_void_v2", "Advanced");
    challenge.maxTime = millisecondsPerHour;
    challenge = add("edge_v2.brutal.timed", 10, "mp_edge_v2", "Brutal");
    challenge.maxTime = millisecondsPerHour;
    challenge = add("12.advanced.timed", 10, "mp_12", "Advanced");
    challenge.maxTime = 4 * millisecondsPerHour;
    challenge = add("12.challenge.timed", 10, "mp_12", "Challenge");
    challenge.maxTime = 8 * millisecondsPerHour;
    level.challenges["dark.hard"].routeName = "hard";
}

add(key, tier, mapName, routeLabel)
{
    challenge = spawnStruct();
    challenge.key = key;
    challenge.tier = tier;
    pointsPerTier = 10;
    challenge.points = tier * pointsPerTier;
    challenge.mapName = mapName;
    challenge.routeLabel = routeLabel;
    challenge.routeName = undefined;
    challenge.maxTime = 0;
    challenge.maxRPG = -1;
    challenge.allowed = 0;
    challenge.required = 0;
    challenge.fps = "125,mix";
    level.challenges[key] = challenge;
    return challenge;
}

onInit()
{
    level.challengesReady = false;
    if(getCodVersion() != 4)
    {
        return;
    }
    definitions();
    precacheMenu("opencj_challenges");
    openCJ\commands_base::registerCommand("challenges", "!challenges", ::command, 0, 0);
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery("SELECT challengeKey FROM challenges LIMIT 0")))
    {
        return;
    }
    level thread initialize();
}

// Replace the catalogue atomically, then link routes and backfill proven finishes.
initialize()
{
    challengeKeys = getArrayKeys(level.challenges);
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery("START TRANSACTION")))
    {
        return;
    }
    catalogueSaved = isDefined(openCJ\mySQL::mysqlSyncQuery("UPDATE challenges SET active=0"));
    for(i = 0; catalogueSaved && i < challengeKeys.size; i++)
    {
        catalogueSaved = saveDefinition(level.challenges[challengeKeys[i]]);
    }
    if(!catalogueSaved)
    {
        openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
        return;
    }
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery("COMMIT")))
    {
        // A failed commit cannot make the new catalogue safe to use.
        openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
        return;
    }

    // Current catalogue values determine rank; historical currency awards stay unchanged.
    level.challengeTierPoints = [];
    maximumTier = 10;
    for(tier = 1; tier <= maximumTier; tier++)
    {
        level.challengeTierPoints[tier] = 0;
    }
    for(i = 0; i < challengeKeys.size; i++)
    {
        challenge = level.challenges[challengeKeys[i]];
        level.challengeTierPoints[challenge.tier] += challenge.points;
    }
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery(routeLinkSQL())))
    {
        return;
    }
    result = openCJ\mySQL::mysqlAsyncBackground(awardSQL(""), "challenge-awards");
    if(!isDefined(result))
    {
        return;
    }
    level.challengesReady = true;
}

// Keep the stored map identity when names change; route IDs survive the same update.
saveDefinition(challenge)
{
    mapRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT COALESCE(" +
        " (SELECT mapID FROM challenges WHERE challengeKey=" + dbStr(challenge.key) + ")," +
        " getMapID(" + dbStr(challenge.mapName) + "))");
    if(!isDefined(mapRows) || mapRows.size != 1 || !isDefined(mapRows[0][0]))
    {
        return false;
    }
    mapID = int(mapRows[0][0]);
    routeHint = "NULL";
    if(isDefined(challenge.routeName))
    {
        routeHint = dbStr(challenge.routeName);
    }
    assignments =
        "tier=" + challenge.tier +
        ",points=" + challenge.points +
        ",mapID=" + mapID +
        ",routeLabel=" + dbStr(challenge.routeLabel) +
        ",routeHint=" + routeHint +
        ",maxTimeMs=" + challenge.maxTime +
        ",maxRPG=" + challenge.maxRPG +
        ",allowedModes=" + challenge.allowed +
        ",requiredModes=" + challenge.required +
        ",fpsModes=" + dbStr(challenge.fps) +
        ",active=1";
    return isDefined(openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO challenges SET challengeKey=" + dbStr(challenge.key) + "," + assignments +
        " ON DUPLICATE KEY UPDATE " + assignments));
}

// Each player/challenge pair keeps its first award even when several finished runs qualify.
awardSQL(runFilter)
{
    runModeMask = "(r.anyPct+2*r.ele+4*r.hb+8*r.hardTAS)";
    return
        "INSERT IGNORE INTO challengeCompletions(playerID,challengeKey,runID,pointsAwarded)" +
        " SELECT r.playerID,c.challengeKey,MIN(r.runID),c.points" +
        " FROM challenges c" +
        " JOIN playerRuns r ON r.mapID=c.mapID" +
        " JOIN checkpoints cp ON cp.cpID=r.finishcpID" +
        " JOIN checkpointStatistics s ON s.runID=r.runID AND s.cpID=r.finishcpID" +
        " WHERE c.active=1 AND c.routeID IS NOT NULL AND cp.finishRouteID=c.routeID" +
        " AND r.finishTimeStamp IS NOT NULL AND r.tutorial=0" +
        " AND FIND_IN_SET(r.FPSMode,c.fpsModes)>0" +
        " AND (" + runModeMask + " & c.allowedModes)=" + runModeMask +
        " AND (" + runModeMask + " & c.requiredModes)=c.requiredModes" +
        " AND (c.maxTimeMs=0 OR s.timePlayed<=c.maxTimeMs)" +
        " AND (c.maxRPG<0 OR s.explosiveJumps<=c.maxRPG) " +
        runFilter +
        " GROUP BY r.playerID,c.challengeKey";
}

rankForPoints(points)
{
    rank = 1;
    requiredPoints = 0;
    maximumRank = 10;
    for(tier = 1; tier < maximumRank; tier++)
    {
        if(level.challengeTierPoints[tier] <= 0)
        {
            break;
        }
        requiredPoints += level.challengeTierPoints[tier];
        if(points < requiredPoints)
        {
            break;
        }
        rank = tier + 1;
    }
    return rank;
}

// Pure menu projection: total points remain unchanged; the bar covers this level only.
progressForPoints(points)
{
    points = max(0, points);
    rank = rankForPoints(points);
    progress = [];
    progress["level"] = "Level " + rank;
    progress["points"] = points + " points";
    progress["next"] = "Maximum level";
    progress["remaining"] = "";
    progress["fraction"] = 1;
    maximumRank = 10;
    if(rank >= maximumRank)
    {
        return progress;
    }
    levelStartPoints = 0;
    for(tier = 1; tier < rank; tier++)
    {
        levelStartPoints += level.challengeTierPoints[tier];
    }
    nextLevelPoints = levelStartPoints + level.challengeTierPoints[rank];
    progress["next"] = "Next: Level " + (rank + 1);
    pointsRemaining = max(0, nextLevelPoints - points);
    progress["remaining"] = pointsRemaining + " points to go";
    if(pointsRemaining == 1)
    {
        progress["remaining"] = "1 point to go";
    }
    progress["fraction"] = 0;
    if(nextLevelPoints > levelStartPoints)
    {
        levelPointsEarned = points - levelStartPoints;
        levelPointsRequired = nextLevelPoints - levelStartPoints;
        progress["fraction"] = min(1, max(0, levelPointsEarned * 1.0 / levelPointsRequired));
    }
    return progress;
}

onPlayerConnected()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    self.challengeRank = 1;
    self.challengePoints = 0;
    self setClientCvar("ocj_ch_rank", self.challengeRank);
    self setClientCvar("ocj_ch_height", 388);
    self setClientCvar("ocj_ch_progress_ready", 0);
    self setClientCvar("ocj_ch_summary", "Loading your progress...");
    self thread connected();
    self thread responses();
}

connected()
{
    self endon("disconnect");
    while(!level.challengesReady || !self openCJ\login::isLoggedIn())
    {
        wait 0.25;
    }
    self refresh();
}

refresh(menu)
{
    playerID = self openCJ\login::getPlayerID();
    // Rank follows current active challenge values; currency uses pointsAwarded instead.
    query =
        "SELECT COALESCE(SUM(c.points),0)" +
        " FROM challengeCompletions a" +
        " JOIN challenges c ON c.challengeKey=a.challengeKey AND c.active=1" +
        " WHERE a.playerID=" + playerID;
    if(isDefined(menu) && menu)
    {
        rows = self openCJ\mySQL::mysqlAsyncMenuQuery(query, "challenges");
    }
    else
    {
        rows = self openCJ\mySQL::mysqlAsyncRead(query);
    }
    if(!isDefined(rows) || !rows.size || !isDefined(rows[0][0]))
    {
        return;
    }
    if(playerID != self openCJ\login::getPlayerID())
    {
        return;
    }
    self.challengePoints = int(rows[0][0]);
    self.challengeRank = rankForPoints(self.challengePoints);
    self setClientCvar("ocj_ch_rank", self.challengeRank);
    self publishProgress();
    return true;
}

publishProgress()
{
    progress = progressForPoints(self.challengePoints);
    self setClientCvar("ocj_ch_player_level", progress["level"]);
    self setClientCvar("ocj_ch_player_points", progress["points"]);
    self setClientCvar("ocj_ch_next_level", progress["next"]);
    self setClientCvar("ocj_ch_points_remaining", progress["remaining"]);
    self setClientCvar("ocj_ch_progress", progress["fraction"]);
    self setClientCvar("ocj_ch_progress_ready", 1);
}

// Keep accepted award writes alive, but let only one callback report a run's reward.
awardRun(runID)
{
    self endon("disconnect");
    if(!level.challengesReady)
    {
        return;
    }
    if(!isDefined(self.challengeAwardPending))
    {
        self.challengeAwardPending = [];
    }
    runKey = "" + runID;
    if(isDefined(self.challengeAwardPending[runKey]))
    {
        return;
    }
    self.challengeAwardPending[runKey] = true;
    playerID = self openCJ\login::getPlayerID();
    pointsBefore = self.challengePoints;

    // INSERT IGNORE also makes a later retry safe if the earlier write outcome was unknown.
    result = self openCJ\mySQL::mysqlAsyncBackground(
        awardSQL("AND r.runID=" + int(runID)), "run:" + runID);
    if(!isDefined(result) || playerID != self openCJ\login::getPlayerID())
    {
        self.challengeAwardPending[runKey] = undefined;
        return;
    }
    progressRefreshed = self refresh();
    self.challengeAwardPending[runKey] = undefined;
    if(!isDefined(progressRefreshed))
    {
        return;
    }
    if(self.challengePoints > pointsBefore)
    {
        self iprintln("Challenge complete! +" + (self.challengePoints - pointsBefore) +
                      " points. Total: " + self.challengePoints + " | Level " + self.challengeRank);
        self openCJ\notifications::result("challenge", runID);
        self announceCompletedChallenges(playerID, runID);
    }
}

// Post each challenge this run completed to Discord. Only called after the award raised the
// player's points, so a retried award (whose rows already existed) is not announced twice.
announceCompletedChallenges(playerID, runID)
{
    // One finish completes at most a few challenges of its map (for example a route and its
    // timed version); the limit keeps a catalogue mistake from flooding the channel.
    maxAnnouncedChallenges = 5;
    rows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT challengeKey" +
        " FROM challengeCompletions" +
        " WHERE playerID=" + int(playerID) +
        " AND runID=" + int(runID) +
        " ORDER BY challengeKey" +
        " LIMIT " + maxAnnouncedChallenges);
    if(!isDefined(rows) || playerID != self openCJ\login::getPlayerID())
    {
        return;
    }
    for(rowIndex = 0; rowIndex < rows.size; rowIndex++)
    {
        challengeKey = rows[rowIndex][0];
        if(!isDefined(challengeKey) || !isDefined(level.challenges[challengeKey]))
        {
            continue;
        }
        openCJ\discord::onChallengeCompleted(self.name, level.challenges[challengeKey]);
    }
}

command(args)
{
    self openMenu("opencj_challenges");
}

responses()
{
    self endon("disconnect");
    for(;;)
    {
        self waittill("menuresponse", menu, response);
        if(menu != "opencj_challenges")
        {
            continue;
        }
        requestIntervalMs = 200;
        if(isDefined(self.challengeLastRequest) &&
           getTime() - self.challengeLastRequest < requestIntervalMs)
        {
            continue;
        }
        self.challengeLastRequest = getTime();
        if(!isDefined(self.challengeTab))
        {
            self.challengeTab = 0;
            self.challengePage = 0;
        }
        if(response == "open")
        {
            self.challengeTab = 0;
            self.challengePage = 0;
        }
        else if(response == "next")
        {
            self.challengePage++;
        }
        else if(response == "previous")
        {
            if(self.challengePage > 0)
            {
                self.challengePage--;
            }
        }
        else if(isValidInt(response))
        {
            tier = int(response);
            maximumTier = 10;
            if(tier < 0 || tier > maximumTier)
            {
                continue;
            }
            self.challengeTab = tier;
            self.challengePage = 0;
        }
        else
        {
            continue;
        }
        self thread show(response == "open");
    }
}

// Fetch one current menu view, then publish its rows and geometry together.
show(refreshProgress)
{
    sqlToken = self openCJ\mySQL::beginMenuRead("challenges");
    if(!self openCJ\mySQL::menuReadCurrent(sqlToken))
    {
        return;
    }
    self endon("disconnect");
    self notify("challenge_menu_refresh");
    self endon("challenge_menu_refresh");
    self setClientCvar("ocj_ch_busy", 1);
    if(!level.challengesReady || !self openCJ\login::isLoggedIn())
    {
        self setClientCvar("ocj_ch_summary", "Challenges are loading. Reopen in a moment.");
        self setClientCvar("ocj_ch_busy", 0);
        return;
    }

    // Tab/page navigation retains the personal progress already shown above the list.
    if(isDefined(refreshProgress) && refreshProgress)
    {
        self refresh(true);
    }
    if(!self openCJ\mySQL::menuReadCurrent(sqlToken))
    {
        return;
    }
    selectedTab = self.challengeTab;
    pageIndex = self.challengePage;
    query = competitiveSQL();
    if(selectedTab != 0)
    {
        query = tierSQL(self openCJ\login::getPlayerID(), selectedTab);
    }
    rows = self openCJ\mySQL::mysqlAsyncMenuQuery(query, "challenges");
    if(!self openCJ\mySQL::menuReadCurrent(sqlToken))
    {
        return;
    }
    if(!isDefined(rows))
    {
        self setClientCvar("ocj_ch_busy", 0);
        return;
    }

    self.challengeMenuValues = [];
    self setUI("ocj_ch_tab", selectedTab);
    title = "Competitive - Top 10";
    hint = "All challenge points count. Ties share position.";
    pageCount = 1;
    rowCount = rows.size;
    if(selectedTab == 0)
    {
        self publishCompetitiveRows(rows);
    }
    else
    {
        title = "Tier " + selectedTab + " challenges";
        hint = "";
        page = self publishTierRows(rows, pageIndex);
        pageIndex = page.index;
        pageCount = page.count;
        rowCount = page.rowCount;
    }
    progressHeaderHeight = 168;
    rowHeight = 16;
    self setUI("ocj_ch_title", title);
    self setUI("ocj_ch_hint", hint);
    self setUI("ocj_ch_rows", rowCount);
    self setUI("ocj_ch_height", progressHeaderHeight + rowCount * rowHeight);
    self setUI("ocj_ch_page", pageIndex);
    self setUI("ocj_ch_pages", pageCount);
    self openCJ\scoreboard::sendChanged(self.challengeMenuValues);
    self setClientCvar("ocj_ch_busy", 0);
}

competitiveSQL()
{
    return
        "SELECT p.playerName,COALESCE(SUM(c.points),0),p.playerID" +
        " FROM playerDisplayNames p" +
        " LEFT JOIN challengeCompletions a ON a.playerID=p.playerID" +
        " LEFT JOIN challenges c ON c.challengeKey=a.challengeKey AND c.active=1" +
        " GROUP BY p.playerID,p.playerName" +
        " ORDER BY 2 DESC,p.playerID LIMIT 10";
}

tierSQL(playerID, tier)
{
    return
        "SELECT c.challengeKey,m.mapname,COALESCE(rt.routeName,c.routeLabel)," +
        " c.points,c.maxTimeMs,c.maxRPG,c.routeID,COUNT(a.playerID)," +
        " MAX(a.playerID=" + playerID + "),c.fpsModes,c.allowedModes" +
        " FROM challenges c" +
        " JOIN mapids m ON m.mapID=c.mapID" +
        " LEFT JOIN routes rt ON rt.routeID=c.routeID" +
        " LEFT JOIN challengeCompletions a ON a.challengeKey=c.challengeKey" +
        " WHERE c.active=1 AND c.tier=" + tier +
        " GROUP BY c.challengeKey ORDER BY c.challengeKey";
}

// Equal totals share the preceding position; the next distinct total skips occupied places.
publishCompetitiveRows(rows)
{
    lastPoints = -1;
    position = 0;
    playerNameLimit = 24;
    for(i = 0; i < rows.size; i++)
    {
        playerName = rows[i][0];
        points = int(rows[i][1]);
        if(points != lastPoints)
        {
            position = i + 1;
        }
        lastPoints = points;
        self setUI("ocj_ch_name" + i,
                   position + ". " + openCJ\scoreboard::clean(playerName, playerNameLimit));
        self setUI("ocj_ch_detail" + i, "Level " + rankForPoints(points));
        self setUI("ocj_ch_points" + i, "" + points + " pts");
        self setUI("ocj_ch_state" + i, "");
        self setUI("ocj_ch_count" + i, "");
        self setUI("ocj_ch_done" + i, 0);
        self setUI("ocj_ch_status" + i, 0);
    }
}

// Reserve room for the personal progress header within the engine's 256 menu items.
publishTierRows(rows, pageIndex)
{
    rowsPerPage = 15;
    page = spawnStruct();
    page.count = int((rows.size + rowsPerPage - 1) / rowsPerPage);
    if(page.count < 1)
    {
        page.count = 1;
    }
    page.index = pageIndex;
    if(page.index >= page.count)
    {
        page.index = page.count - 1;
    }
    // Keep indices as integers: the engine's min/max functions return floats.
    page.rowCount = rows.size - page.index * rowsPerPage;
    if(page.rowCount > rowsPerPage)
    {
        page.rowCount = rowsPerPage;
    }
    self.challengePage = page.index;
    for(i = 0; i < page.rowCount; i++)
    {
        challenge = challengeFromRow(rows[page.index * rowsPerPage + i]);
        self publishChallengeRow(challenge, i);
    }
    return page;
}

// Decode the tier SQL projection once; rendering uses domain fields below.
challengeFromRow(row)
{
    challenge = spawnStruct();
    challenge.key = row[0];
    challenge.mapName = row[1];
    challenge.routeLabel = row[2];
    challenge.points = row[3];
    challenge.maxTimeMs = int(row[4]);
    challenge.maxRPG = int(row[5]);
    challenge.routeID = row[6];
    challenge.completionCount = row[7];
    challenge.completed = isDefined(row[8]) && int(row[8]) != 0;
    challenge.fpsModes = row[9];
    challenge.allowedModes = int(row[10]);
    return challenge;
}

challengeTarget(challenge)
{
    target = "Finish";
    if(challenge.maxTimeMs > 0)
    {
        target = formatTimeString(challenge.maxTimeMs, true);
    }
    if(challenge.maxRPG >= 0)
    {
        if(challenge.maxTimeMs > 0)
        {
            target += " / ";
        }
        else
        {
            target = "";
        }
        target += challenge.maxRPG + " RPG";
    }
    return target;
}

// Menu status values are shared with the client challenge menu's color/visibility rules.
publishChallengeRow(challenge, rowIndex)
{
    statusIncomplete = 1;
    statusCompleted = 2;
    statusUnavailable = 3;
    status = statusIncomplete;
    stateLabel = "Incomplete";
    if(!isDefined(challenge.routeID))
    {
        stateLabel = "Not available yet";
        status = statusUnavailable;
    }
    if(challenge.completed)
    {
        stateLabel = "Completed";
        status = statusCompleted;
    }
    self setUI("ocj_ch_status" + rowIndex, status);
    self setUI("ocj_ch_target" + rowIndex, challengeTarget(challenge));
    self publishModeIcons(challenge, rowIndex);
    self setUI("ocj_ch_name" + rowIndex, challenge.mapName);
    self setUI("ocj_ch_detail" + rowIndex, challenge.routeLabel);
    self setUI("ocj_ch_points" + rowIndex, challenge.points + " pts");
    self setUI("ocj_ch_state" + rowIndex, stateLabel);
    self setUI("ocj_ch_count" + rowIndex, challenge.completionCount + " players");
    self setUI("ocj_ch_done" + rowIndex, int(challenge.completed));
}

publishModeIcons(challenge, rowIndex)
{
    icons = allowedModeIcons(challenge.fpsModes, challenge.allowedModes);
    fpsCount = 0;
    for(i = 0; i < icons.size; i++)
    {
        if(isSubStr(icons[i], "opencj_icon_fps_"))
        {
            fpsCount++;
        }
        self setUI("ocj_ch_mode" + rowIndex + "_" + i, icons[i]);
    }
    self setUI("ocj_ch_modes" + rowIndex, icons.size);
    self setUI("ocj_ch_fpscount" + rowIndex, fpsCount);
}

setUI(key, value)
{
    self.challengeMenuValues[key] = value;
}

// Display the same FPS list and mode mask used to validate this challenge.
allowedModeIcons(fpsList, allowedModes)
{
    icons = [];
    fpsModes = strTok(fpsList, ",");
    for(m = 0; m < fpsModes.size; m++)
    {
        if(fpsModes[m] == "125")
        {
            icons[icons.size] = "opencj_icon_fps_classic";
        }
        else if(fpsModes[m] == "mix")
        {
            icons[icons.size] = "opencj_icon_fps_standard";
        }
        else if(fpsModes[m] == "hax")
        {
            icons[icons.size] = "opencj_icon_fps_any";
        }
    }
    anyPercentBit = 1;
    elevatorsBit = 2;
    halfbeatBit = 4;
    tasBit = 8;
    if(allowedModes & anyPercentBit)
    {
        icons[icons.size] = "opencj_icon_anypct";
    }
    if(allowedModes & elevatorsBit)
    {
        icons[icons.size] = "opencj_icon_ele";
    }
    if(allowedModes & halfbeatBit)
    {
        icons[icons.size] = "opencj_icon_halfbeat";
    }
    if(allowedModes & tasBit)
    {
        icons[icons.size] = "opencj_icon_tas";
    }
    return icons;
}

// CPC names use underscores; UI labels use spaces. Expand only standard
// abbreviations, never infer that Basic/Easy or Hard/Advanced are equivalent.
routeKeySQL(value)
{
    normalizedName = "LOWER(REPLACE(REPLACE(" + value + ",' ',''),'_',''))";
    return "CASE " + normalizedName +
           " WHEN 'inter' THEN 'intermediate'" +
           " WHEN 'inter+' THEN 'intermediate+'" +
           " WHEN 'adv' THEN 'advanced'" +
           " WHEN 'adv+' THEN 'advanced+'" +
           " ELSE " + normalizedName + " END";
}

// Ambiguous normalized names do not link. Generic Main route labels may use the
// sole published route, but difficulty labels never use that fallback.
routeLinkSQL()
{
    publishedRoutes =
        "SELECT r.mapID," + routeKeySQL("r.routeName") + " AS routeKey," +
        " MIN(r.routeID) AS routeID,COUNT(*) AS routeCount" +
        " FROM routes r" +
        " WHERE EXISTS(" +
        " SELECT 1 FROM checkpoints cp" +
        " JOIN checkpointAreas a ON a.cpID=cp.cpID" +
        " WHERE cp.finishRouteID=r.routeID AND cp.retired=0)" +
        " GROUP BY r.mapID,routeKey";
    return
        "UPDATE challenges c" +
        " LEFT JOIN (" + publishedRoutes + ") p" +
        " ON p.mapID=c.mapID AND p.routeCount=1" +
        " AND p.routeKey=(" + routeKeySQL("COALESCE(c.routeHint,c.routeLabel)") + ")" +
        " LEFT JOIN (" +
        " SELECT mapID,MIN(routeID) AS routeID FROM (" + publishedRoutes + ") publishedRoutes" +
        " GROUP BY mapID HAVING SUM(routeCount)=1) sole ON sole.mapID=c.mapID" +
        " LEFT JOIN (" +
        " SELECT mapID,COUNT(DISTINCT LOWER(routeLabel)) AS routeCount" +
        " FROM challenges WHERE active=1 GROUP BY mapID) labels ON labels.mapID=c.mapID" +
        " SET c.routeID=COALESCE(p.routeID," +
        " CASE WHEN labels.routeCount=1 AND (" +
        " LOWER(c.routeLabel)='main route' OR LOWER(c.routeLabel) LIKE 'main route (%)')" +
        " THEN sole.routeID ELSE NULL END)" +
        " WHERE c.active=1 AND c.routeID IS NULL";
}

onRoutesPublished()
{
    if(getCodVersion() != 4 || !isDefined(level.challengesReady) || !level.challengesReady)
    {
        return;
    }
    // Snapshot unavailable challenges before linking, so re-publishing is quiet.
    unlinkedChallenges = openCJ\mySQL::mysqlSyncQuery(
        "SELECT challengeKey FROM challenges" +
        " WHERE active=1 AND routeID IS NULL AND mapID=" +
        openCJ\mapID::getMapID());
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery(routeLinkSQL())))
    {
        return;
    }
    if(isDefined(unlinkedChallenges) && unlinkedChallenges.size)
    {
        challengeKeyList = "";
        for(i = 0; i < unlinkedChallenges.size; i++)
        {
            if(i)
            {
                challengeKeyList += ",";
            }
            challengeKeyList += dbStr(unlinkedChallenges[i][0]);
        }
        linkedChallenges = openCJ\mySQL::mysqlSyncQuery(
            "SELECT r.routeName,c.tier FROM challenges c" +
            " JOIN routes r ON r.routeID=c.routeID" +
            " WHERE c.active=1 AND c.routeID IS NOT NULL" +
            " AND c.challengeKey IN (" + challengeKeyList + ")" +
            " ORDER BY tier,challengeKey");
        if(isDefined(linkedChallenges))
        {
            for(i = 0; i < linkedChallenges.size; i++)
            {
                routeName = linkedChallenges[i][0];
                tier = linkedChallenges[i][1];
                self sendLocalChatMessage("Challenge now available: " + getDvar("mapname") + " / " +
                                          routeName + " (Tier " + tier + ").");
            }
        }
    }
    level thread backfillPublishedRoutes();
}

backfillPublishedRoutes()
{
    result = openCJ\mySQL::mysqlAsyncBackground(awardSQL(""), "challenge-awards");
    if(!isDefined(result))
    {
        return;
    }
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        if(players[i] openCJ\login::isLoggedIn())
        {
            players[i] thread refresh();
        }
    }
}
