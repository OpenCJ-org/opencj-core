main()
{
    wait 2;
    level.connectionFailures = 0;
    level.connectionChecks = 0;
    uninitializedPlayerChecks();
    engineConnectionChecks();
    printf("CONNECTING SELFTEST COMPLETE failures=" + level.connectionFailures +
           " checks=" + level.connectionChecks + "\n");
}

// No login, run or ping fields exist while the client is still connecting.
uninitializedPlayerChecks()
{
    player = spawnStruct();
    player.name = "Loading player";
    check(openCJ\scoreboard::connecting(player), "pre-initialization client recognized");
    check(openCJ\scoreboard::spectatorRow(player), "connecting client grouped with spectators");
    values = openCJ\scoreboard::row(player);
    check(values["name"] == player.name && values["route"] == "^3Connecting...",
          "loading name and status available without initialization");
    check(values["rank"] == "" && values["flag"] == "default" && values["flagSelector"] == 0 &&
              values["pingText"] == "-" && values["progress"] == -1,
          "no invented rank country ping or progress");
    check(values["fps"] == 0 && values["ele"] == 0 && values["hb"] == 0 && values["tas"] == 0 &&
              values["any"] == 0,
          "all mode fields reset");
    player.isFullyConnected = false;
    check(openCJ\scoreboard::connecting(player), "explicit connecting state recognized");
    player.isFullyConnected = true;
    player.sessionState = "playing";
    check(!openCJ\scoreboard::connecting(player) && !openCJ\scoreboard::spectatorRow(player),
          "joined player transitions to jumpers");
    check(openCJ\scoreboard::status(player) == "Ready", "joined status restored");
}

// The runner keeps the production scoreboard hook in the real engine connect callback.
engineConnectionChecks()
{
    player = addTestClient();
    wait 0.5;
    check(isDefined(player), "engine client created");
    if(!isDefined(player))
    {
        return;
    }
    player.isFullyConnected = false;
    openCJ\scoreboard::buildSnapshot();
    check(level.scoreboardPlayers.size == 1 && level.scoreboardPlayers[0] == player,
          "engine client retained in snapshot while connecting");
    check(level.scoreboardRows.size > 0 && level.scoreboardRows[0]["route"] == "^3Connecting..." &&
              level.scoreboardJumperCount == 0,
          "connecting snapshot row displayed");
    player.isFullyConnected = true;
    openCJ\scoreboard::buildSnapshot();
    check(level.scoreboardPlayers.size == 1 &&
              level.scoreboardRows[0]["route"] != "^3Connecting...",
          "transition updates existing row without duplication");
    player openCJ\scoreboard::onPlayerDisconnected();
    openCJ\scoreboard::buildSnapshot();
    check(level.scoreboardPlayers.size == 0, "disconnect removes connecting or joined client");
}

check(passed, label)
{
    level.connectionChecks++;
    if(!passed)
    {
        level.connectionFailures++;
        printf("CONNECTING SELFTEST FAIL " + label + "\n");
    }
    else
    {
        printf("CONNECTING SELFTEST PASS " + label + "\n");
    }
}
