menu(playerIndex, tick)
{
    level.capPending++;
    menuRequest = self openCJ\mySQL::beginMenuRead("board");
    if(self openCJ\mySQL::menuReadCurrent(menuRequest))
    {
        useLeaderboard = playerIndex % 2 == 0;
        if(!level.capQueryProfile)
        {
            useLeaderboard = int(tick / level.capMenuIntervalTicks) % 2 == 0;
        }
        if(useLeaderboard)
        {
            query = LBQUERY;
        }
        else
        {
            query = RNQUERY;
        }
        rows = self openCJ\mySQL::mysqlAsyncMenuQuery(query, "board");
        if(self openCJ\mySQL::menuReadCurrent(menuRequest))
        {
            check(isDefined(rows), "current menu query");
        }
    }
    level.capPending--;
}

auditRead(playerIndex)
{
    level.capPending++;
    if(playerIndex % 3 == 0)
    {
        query = HUDQUERY;
    }
    else if(playerIndex % 3 == 1)
    {
        query = openCJ\finishSounds::podiumQuery(10000 + playerIndex);
    }
    else
    {
        query = openCJ\recordNotices::finishQuery(10000 + playerIndex);
    }
    rows = self openCJ\mySQL::mysqlAsyncRead(query);
    check(isDefined(rows), "record and finish query");
    query =
        openCJ\recordNotices::checkpointQuery(10000 + playerIndex, 1, "mix", 0, 0, 1, 0, "time");
    rows = self openCJ\mySQL::mysqlAsyncRead(query);
    check(isDefined(rows), "checkpoint notice query");
    level.capPending--;
}
