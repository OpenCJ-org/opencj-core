main()
{
    level.scoreboardPointFailures = 0;
    level.scoreboardPointChecks = 0;
    stablePointOrderChecks();
    fullScoreboardViewportChecks();
    shrinkingViewportChecks();
    printf("SCOREBOARD POINTS COMPLETE failures=" + level.scoreboardPointFailures +
           " checks=" + level.scoreboardPointChecks + "\n");
}

stablePointOrderChecks()
{
    firstTiedPlayer = spawnStruct();
    firstTiedPlayer.challengePoints = 40;
    highScorePlayer = spawnStruct();
    highScorePlayer.challengePoints = 100;
    secondTiedPlayer = spawnStruct();
    secondTiedPlayer.challengePoints = 40;
    uninitializedPlayer = spawnStruct();
    players = [];
    players[0] = firstTiedPlayer;
    players[1] = highScorePlayer;
    players[2] = secondTiedPlayer;
    players[3] = uninitializedPlayer;

    players = openCJ\scoreboard::sortByPoints(players);
    check(players[0] == highScorePlayer && players[1] == firstTiedPlayer &&
              players[2] == secondTiedPlayer && players[3] == uninitializedPlayer,
          "descending points preserve the order of tied players");
    check(openCJ\scoreboard::points(uninitializedPlayer) == 0,
          "uninitialized player has no earned points");
}

// Cover every team split and offsets beyond both ends of the 32-player list.
fullScoreboardViewportChecks()
{
    playerCount = 32;
    visibleRows = 15;
    lastOffset = playerCount - visibleRows;
    for(jumperCount = 0; jumperCount <= playerCount; jumperCount++)
    {
        for(offset = -3; offset <= 35; offset++)
        {
            viewport = openCJ\scoreboard::viewLayout(offset, playerCount, jumperCount);
            context = " jumpers=" + jumperCount + " offset=" + offset;
            check(viewport.count == visibleRows,
                  "full list keeps 15 visible rows; actual=" + viewport.count + context);
            validRange = viewport.first >= 0 && viewport.first <= lastOffset &&
                         viewport.first + viewport.count <= playerCount;
            check(validRange,
                  "visible rows stay inside the list; first=" + viewport.first + context);
            check(viewport.top + viewport.height <= 480,
                  "scoreboard stays inside the 480-unit screen; bottom=" +
                      (viewport.top + viewport.height) + context);
            expectedSplit =
                jumperCount > viewport.first && jumperCount < viewport.first + viewport.count;
            check(viewport.split == expectedSplit,
                  "section divider appears only between visible teams" + context);
        }
    }
}

shrinkingViewportChecks()
{
    viewport = openCJ\scoreboard::viewLayout(17, 2, 1);
    check(viewport.first == 0 && viewport.count == 2 && viewport.split,
          "shrinking list resets scroll and retains the team divider");
}

check(passed, label)
{
    level.scoreboardPointChecks++;
    if(!passed)
    {
        level.scoreboardPointFailures++;
        printf("SCOREBOARD POINTS FAIL " + label + "\n");
    }
}
