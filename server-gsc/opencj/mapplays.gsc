#include openCJ\util;

// Map plays feed the website's most-played ranking. A map session counts once,
// when its first logged-in player arrives. Map loads on an empty server and
// players reconnecting during the same session do not add plays.

onInit()
{
    level.mapPlays_sessionRecorded = false;
}

// Called after a player's account is identified during login.
onAccountIdentified()
{
    if(level.mapPlays_sessionRecorded)
    {
        return;
    }
    if(!openCJ\mapID::hasMapID())
    {
        return;
    }

    // Mark the session before the asynchronous insert, so a second login that
    // arrives while the write is queued cannot record the same session twice.
    level.mapPlays_sessionRecorded = true;
    query = "INSERT INTO mapPlays (mapID) VALUES (" + openCJ\mapID::getMapID() + ")";
    level thread _recordPlay(query);
}

// Runs on level so a disconnect of the logging-in player does not cancel it.
// A failed insert undercounts one session. It is not retried, because a lost
// response does not prove that the first insert failed.
_recordPlay(query)
{
    openCJ\mySQL::mysqlAsyncBackground(query, "map-plays");
}
