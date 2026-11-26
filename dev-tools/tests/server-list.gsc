#include openCJ\util;

// Server browser: joinable-address checks, row decoding and sanitizing, selection
// bounds and the join decision. The database write and read are not exercised.
main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.serverListChecks = 0;
    level.serverListFailures = 0;
    setCvar("opencj_server_id", "main-eu");
    setCvar("opencj_server_address", "");
    // The compiled menu may not exist in the test assets; only configure.
    openCJ\serverList::_configure();

    checkJoinableAddresses();
    wait 1;
    player = addTestClient();
    wait .2;
    check(isDefined(player), "test client available");
    if(isDefined(player))
    {
        player.serverListRows = [];
        player.serverListSelected = -1;
        checkRowDecoding(player);
        checkSelectionAndJoin(player);
    }
    printf("SERVER LIST COMPLETE failures=" + level.serverListFailures +
           " checks=" + level.serverListChecks + "\n");
}

checkJoinableAddresses()
{
    check(openCJ\serverList::isJoinableAddress("eu.opencj.org:28960"), "host and port are joinable");
    check(openCJ\serverList::isJoinableAddress("203.0.113.7:28961"), "IPv4 and port are joinable");
    check(!openCJ\serverList::isJoinableAddress(""), "an empty address is not joinable");
    check(!openCJ\serverList::isJoinableAddress("evil.org;quit"), "a command separator is rejected");
    check(!openCJ\serverList::isJoinableAddress("evil.org\" rcon"), "quotes and spaces are rejected");
}

// Database-shaped rows: serverID, name, address, location, map, players, max players.
serverRow(serverID, name, address, location, mapName, players)
{
    row = [];
    row[0] = serverID;
    row[1] = name;
    row[2] = address;
    row[3] = location;
    row[4] = mapName;
    row[5] = players;
    row[6] = "32";
    return row;
}

checkRowDecoding(player)
{
    rows = [];
    rows[0] = serverRow("us-east", "^2OpenCJ US \"East\";", "us.opencj.org:28960", "USA", "mp_dark", "7");
    rows[1] = serverRow("bad", "Bad", "bad.org;quit", "Nowhere", "mp_dark", "3");
    rows[2] = serverRow("main-eu", "OpenCJ EU", "eu.opencj.org:28960", "Netherlands", "mp_galaxy", "2");
    player openCJ\serverList::publishServerRows(rows);
    check(player.serverListRows.size == 2, "a row with an unsafe address is never offered");
    check(player.serverListRows[0].name == "^2OpenCJ US East^7",
          "quotes and semicolons are removed from names, got " + player.serverListRows[0].name);
    check(player.serverListRows[0].players == "7/32", "players show count and maximum");
    check(isSubStr(player.serverListRows[1].name, "(this server)"), "the current server is marked");
    check(player.serverListSelected == -1, "a new list clears the selection");

    player openCJ\serverList::publishServerRows([]);
    check(player.serverListRows.size == 0, "an empty answer clears the list");
}

checkSelectionAndJoin(player)
{
    rows = [];
    rows[0] = serverRow("us-east", "OpenCJ US", "us.opencj.org:28960", "USA", "mp_dark", "7");
    rows[1] = serverRow("main-eu", "OpenCJ EU", "eu.opencj.org:28960", "Netherlands", "mp_galaxy", "2");
    player openCJ\serverList::publishServerRows(rows);

    player openCJ\serverList::_selectRow("5");
    check(player.serverListSelected == -1, "a row outside the list cannot be selected");
    player openCJ\serverList::_selectRow("1x");
    check(player.serverListSelected == -1, "a malformed row number is ignored");

    player.fixtureClientCommand = undefined;
    player openCJ\serverList::_joinSelectedServer();
    check(!isDefined(player.fixtureClientCommand), "nothing is joined without a selection");

    player openCJ\serverList::_selectRow("1");
    player openCJ\serverList::_joinSelectedServer();
    check(!isDefined(player.fixtureClientCommand), "the current server is not joined again");

    player openCJ\serverList::_selectRow("0");
    player openCJ\serverList::_joinSelectedServer();
    check(isDefined(player.fixtureClientCommand) &&
          player.fixtureClientCommand == "connect us.opencj.org:28960",
          "joining connects to the validated address");
}

// Replaces execClientCmd in the isolated copy of serverlist.gsc.
recordClientCommand(command)
{
    self.fixtureClientCommand = command;
}

check(condition, description)
{
    level.serverListChecks++;
    if(!condition)
    {
        level.serverListFailures++;
        printf("SERVER LIST FAILURE: " + description + "\n");
    }
}

