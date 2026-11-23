main()
{
    level.failures = 0;
    level.checks = 0;
    openCJ\mySQL::_initConstants();
    openCJ\savePosition::onInit();
    wait 1;
    player = addTestClient();
    check(isDefined(player), "board client connects");
    if(isDefined(player))
    {
        wait 0.2;
        player prepareBoard();
        player verifyLeaderboardRows();
        player verifyFailedReadPreservesBoard();
        player verifyDemoButtons();
        player verifyBoardListener();
        verifyFPSLabels();
        player verifyRunRows();
    }
    printf("BOARDS COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}

prepareBoard()
{
    self.currentMenu = "opencj_leaderboard";
    self.currentBoard = [];
    self.currentBoard["filter"]["route"] = 1;
    self.currentBoard["filter"]["ele"] = 1;
    self.currentBoard["filter"]["any"] = 1;
    self.currentBoard["filter"]["hb"] = 1;
    self.currentBoard["filter"]["tas"] = 1;
    self.currentBoard["filter"]["fps"] = "any";
    self.currentBoard["routes"][0] = "Fixture route";
    self.currentBoard["sortBy"] = "time";
    self.currentBoard["sort"] = 1;
    self.currentBoard["page"]["cur"] = 2;
    self.currentBoard["maxEntriesPerPage"] = 10;
    self.currentBoard["updateFunc"] = openCJ\menus\leaderboard::fetchUpdatedData;
    level.boardsDvarPrefix = "opencj_ui_board_";

    finish = spawnStruct();
    finish.id = 71;
    level.routeEnders["Fixture route"][0] = finish;
    self.fixtureRows = [];
}

// Return a database-shaped row with distinct values that expose column swaps.
leaderboardRow()
{
    row = [];
    row[0] = "13";                  // Total matching players.
    row[1] = "Fixture Player";
    row[2] = "123456";              // Elapsed milliseconds.
    row[3] = "2";                   // Explosive jumps.
    row[4] = "3";                   // Loads.
    row[5] = "2026-01-02 03:04:05";
    row[6] = "mix";
    row[7] = "1";                   // Elevate.
    row[8] = "0";                   // Any percent.
    row[9] = "1";                   // Halfbeat.
    row[10] = "0";                  // Hard TAS.
    row[11] = "901";                // Playback run ID.
    return row;
}

// Replace only the SQL boundary; row conversion still runs in production code.
boardQuery(query, menu)
{
    if(!isDefined(self.fixtureQuery))
    {
        printf("BOARDS SQL " + query + "\n");
    }
    if(self.currentMenu == "opencj_runsboard" && !isDefined(self.fixtureRunsQuery))
    {
        printf("BOARDS RUNS SQL " + query + "\n");
        self.fixtureRunsQuery = query;
    }
    self.fixtureQuery = query;
    self.fixtureQueryMenu = menu;
    return self.fixtureRows;
}

recordDemoSelection(runID, fromBoard)
{
    self.fixtureDemoID = runID;
    self.fixtureDemoFromBoard = fromBoard;
}

verifyLeaderboardRows()
{
    self.fixtureRows[0] = leaderboardRow();
    self openCJ\menus\board_base::updateBoard();
    check(self.currentBoard["nrTotalEntries"] == 13 && self.currentBoard["nrEntriesThisPage"] == 1,
          "query total and visible row count remain distinct");
    check(self.currentBoard["page"]["max"] == 2, "total rows determine maximum page");
    check(self.currentBoard["cols"][0]["nr"] == 11, "second page starts at item eleven");
    check(self.currentBoard["cols"][0]["name"] == "^7Fixture Player^7",
          "player name keeps surrounding color reset");
    check(self.currentBoard["cols"][0]["time"] == 123456 &&
          self.currentBoard["cols"][0]["rpgs"] == 2 && self.currentBoard["cols"][0]["loads"] == 3,
          "time, explosive jumps and loads decode into their own columns");
    check(self.currentBoard["cols"][0]["date"] == "2026-01-02 03:04:05" &&
          self.currentBoard["cols"][0]["fps"] == "Standard", "date and FPS label decode");
    check(self.currentBoard["cols"][0]["ele"] == "X" && self.currentBoard["cols"][0]["any"] == "^7" &&
          self.currentBoard["cols"][0]["hb"] == "X" && self.currentBoard["cols"][0]["tas"] == "^7",
          "run classifications decode separately");
    check(self.currentBoard["demoRunIDs"][0] == 901, "visible row retains its playback run ID");
    check(self.currentBoard["cols"][9]["nr"] == -1 && self.currentBoard["cols"][9]["name"] == "",
          "unused menu slots are cleared");
    check(self.fixtureQueryMenu == "board", "leaderboard query uses board ownership");

    clientValues = self openCJ\menus\board_base::buildBoardClientValues();
    check(clientValues["time"] == "00:02:03\n", "client time column rounds milliseconds to seconds");
    check(clientValues["name"] == "^7Fixture Player^7\n" && clientValues["count"] == 1,
          "client columns contain only the visible rows");
    check(clientValues["fps_icon1"] == "opencj_icon_fps_standard" &&
          clientValues["fps_icon10"] == "", "unused client icon slots are cleared");
    check(self.currentBoard["cols"][0]["time"] == 123456,
          "client time formatting leaves the source milliseconds intact");
}

verifyFailedReadPreservesBoard()
{
    self.fixtureRows = undefined;
    result = self openCJ\menus\leaderboard::fetchUpdatedData();
    check(isDefined(result) && !result, "unavailable query reports failure");
    check(self.currentBoard["demoRunIDs"][0] == 901 && self.currentBoard["nrTotalEntries"] == 13,
          "failed query preserves the last published board");

    self.fixtureRows = [];
    self openCJ\menus\leaderboard::fetchUpdatedData();
    check(self.currentBoard["nrTotalEntries"] == 0 && self.currentBoard["nrEntriesThisPage"] == 0 &&
          self.currentBoard["demoRunIDs"].size == 0, "successful empty query clears results and demo IDs");
    clientValues = self openCJ\menus\board_base::buildBoardClientValues();
    check(clientValues["count"] == 0 && clientValues["name"] == "" &&
          clientValues["fps_icon1"] == "", "empty board clears its client columns and icons");
}

verifyDemoButtons()
{
    self.currentBoard["nrEntriesThisPage"] = 1;
    self.currentBoard["demoRunIDs"][0] = 901;
    self.fixtureDemoID = undefined;
    self openCJ\menus\leaderboard::handleDemo("playdemo1junk");
    wait 0.05;
    check(!isDefined(self.fixtureDemoID), "numeric-prefix demo button is rejected");

    self.fixtureDemoID = undefined;
    self openCJ\menus\leaderboard::handleDemo("playdemo0");
    self openCJ\menus\leaderboard::handleDemo("playdemo2");
    wait 0.05;
    check(!isDefined(self.fixtureDemoID), "demo selection rejects slots outside visible rows");

    self.currentMenu = "opencj_runsboard";
    self openCJ\menus\leaderboard::handleDemo("playdemo1");
    wait 0.05;
    check(!isDefined(self.fixtureDemoID), "another board cannot select a leaderboard demo");

    self.currentMenu = "opencj_leaderboard";
    self openCJ\menus\leaderboard::handleDemo("playdemo1");
    wait 0.05;
    check(self.fixtureDemoID == 901 && self.fixtureDemoFromBoard,
          "valid demo slot forwards the published run ID and board-return flag");
}

verifyBoardListener()
{
    self.fixtureDemoID = undefined;
    self thread openCJ\menus\board_base::onMenuResponse();
    self notify("menuresponse", "unrelated_menu", "click_playdemo1");
    wait 0.05;
    check(!isDefined(self.fixtureDemoID), "unrelated menu response cannot select a board demo");

    self.fixtureDemoID = undefined;
    self notify("menuresponse", self.currentMenu, "click_playdemo1");
    wait 0.05;
    check(self.fixtureDemoID == 901, "current board response selects its visible demo");
    self notify("disconnect");
}

verifyFPSLabels()
{
    check(openCJ\menus\board_base::dbFPSToFullName("125") == "Classic", "125 maps to Classic");
    check(openCJ\menus\board_base::dbFPSToFullName("mix") == "Standard", "mix maps to Standard");
    check(openCJ\menus\board_base::dbFPSToFullName("hax") == "Any" &&
          openCJ\menus\board_base::dbFPSToFullName("unknown") == "Any", "existing FPS fallback remains Any");
    check(openCJ\menus\board_base::fpsNameToIcon("Classic") == "opencj_icon_fps_classic" &&
          openCJ\menus\board_base::fpsNameToIcon("Standard") == "opencj_icon_fps_standard",
          "competitive FPS labels select their menu materials");
    check(openCJ\menus\board_base::fpsNameToIcon("Tutorial") == "opencj_icon_fps_tutorial" &&
          openCJ\menus\board_base::fpsNameToIcon("") == "", "tutorial and empty FPS slots remain distinct");
}

check(condition, message)
{
    level.checks++;
    if(!condition)
    {
        level.failures++;
    }
    printf("BOARDS CHECK " + int(condition) + ": " + message + "\n");
}

// Match the database SELECT order while keeping distinct values for every field.
runRow(runID, label, flags)
{
    row = [];
    row[0] = "13"; // Total unfinished runs.
    row[1] = runID;
    row[2] = label;
    row[3] = "123456"; // Played milliseconds.
    row[4] = "2"; // Explosive jumps.
    row[5] = "3"; // Loads.
    row[6] = "2026-01-02 03:04:05";
    row[7] = "125";
    row[8] = flags;
    return row;
}

verifyRunRows()
{
    self prepareBoard();
    self.currentMenu = "opencj_runsboard";
    self.currentBoard["updateFunc"] = openCJ\menus\runsboard::fetchUpdatedData;
    self.login_playerID = 7;
    level.mapid_mapID = 1;
    self.fixtureRows[0] = runRow("901", "Fixture run", 160); // Elevate and halfbeat.
    self.fixtureRows[1] = runRow("902", "", 832); // Tutorial, any percent and hard TAS.
    self openCJ\menus\board_base::updateBoard();

    check(self.currentBoard["nrTotalEntries"] == 13 && self.currentBoard["nrEntriesThisPage"] == 2,
          "run query total and visible count remain distinct");
    check(self.currentBoard["page"]["max"] == 2, "run total determines maximum page");
    check(self.currentBoard["cols"][0]["nr"] == 901 && self.currentBoard["cols"][1]["nr"] == 902,
          "restore columns contain run IDs rather than page item numbers");
    check(self.currentBoard["cols"][0]["name"] == "^7Fixture run^7",
          "named run keeps surrounding color reset");
    check(self.currentBoard["cols"][1]["name"] == "^7^5[Tutorial]^7 (Unnamed run)^7",
          "unnamed tutorial run receives its badge and fallback label");
    check(self.currentBoard["cols"][0]["time"] == 123456
          && self.currentBoard["cols"][0]["rpgs"] == 2
          && self.currentBoard["cols"][0]["loads"] == 3, "run numeric columns decode separately");
    check(self.currentBoard["cols"][0]["date"] == "2026-01-02 03:04:05",
          "run start date survives conversion");
    check(self.currentBoard["cols"][0]["fps"] == "Classic"
          && self.currentBoard["cols"][1]["fps"] == "Tutorial",
          "tutorial badge replaces the server-chosen FPS category");
    check(self.currentBoard["cols"][0]["ele"] == "X"
          && self.currentBoard["cols"][0]["hb"] == "X"
          && self.currentBoard["cols"][0]["any"] == "^7"
          && self.currentBoard["cols"][0]["tas"] == "^7",
          "ordinary run flags decode independently");
    check(self.currentBoard["cols"][1]["ele"] == "^7"
          && self.currentBoard["cols"][1]["hb"] == "^7"
          && self.currentBoard["cols"][1]["any"] == "X"
          && self.currentBoard["cols"][1]["tas"] == "X",
          "tutorial run retains its other classifications");
    check(self.currentBoard["cols"][9]["nr"] == -1 && self.currentBoard["cols"][9]["name"] == "",
          "unused run slots are cleared");
    check(self.fixtureQueryMenu == "board", "run query uses board ownership");

    self.fixtureRows = undefined;
    result = self openCJ\menus\runsboard::fetchUpdatedData();
    check(isDefined(result) && !result, "unavailable run read reports failure");
    check(self.currentBoard["nrTotalEntries"] == 13 && self.currentBoard["cols"][0]["nr"] == 901,
          "unavailable run read keeps the last published page");

    self.fixtureRows = [];
    self openCJ\menus\runsboard::fetchUpdatedData();
    check(self.currentBoard["nrTotalEntries"] == 0 && self.currentBoard["nrEntriesThisPage"] == 0,
          "successful empty run read clears counts");
    check(self.currentBoard["cols"][0]["nr"] == -1
          && self.currentBoard["cols"][0]["fps"] == "",
          "successful empty run read clears restore IDs and badges");
}
