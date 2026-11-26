#include openCJ\util;

// In-game server browser. Every OpenCJ server that shares this database keeps one
// gameServers row up to date (a heartbeat). The browser lists rows refreshed
// recently, so a stopped or crashed server drops out on its own. Servers with a
// join password keep a row but are never listed.

onInit()
{
    precacheMenu("opencj_servers");
    _configure();
}

// Read this server's browser settings and start publishing when it can be joined.
_configure()
{
    level.serverList = spawnStruct();
    level.serverList.menu = "opencj_servers";
    level.serverList.dvarPrefix = "opencj_ui_servers_";
    level.serverList.maxRows = 10; // Rows in opencj_servers.menu.
    level.serverList.heartbeatSeconds = 60;
    // Joins and leaves within this time share one database write.
    level.serverList.minimumRefreshSeconds = 10;
    // Three missed heartbeats: a stopped server leaves the list within three minutes.
    level.serverList.staleSeconds = 180;
    level.serverList.maxAddressLength = 64;
    level.serverList.maxNameLength = 64;
    level.serverList.maxLocationLength = 48;
    level.serverList.refreshRequested = false;
    level.serverList.serverID = getCvar("opencj_server_id");
    level.serverList.address = getCvar("opencj_server_address");
    level.serverList.location = getCvar("opencj_server_location");

    // Without an ID and a joinable address this server can browse but is not listed.
    if (level.serverList.serverID != "" && isJoinableAddress(level.serverList.address))
    {
        level thread _publishLoop();
    }
}

onPlayerConnected()
{
    level.serverList.refreshRequested = true;
    self.serverListRows = [];
    self.serverListSelected = -1;
    self thread _menuResponse();
}

// Called after a player has left, so the player count already excludes them.
onPlayerCountChanged()
{
    level.serverList.refreshRequested = true;
}

// Addresses come from other servers' rows and end up in a client "connect"
// command, so only host names, IPv4 addresses and a port are accepted.
isJoinableAddress(address)
{
    if (!isDefined(address) || address.size < 3 || address.size > level.serverList.maxAddressLength)
    {
        return false;
    }
    allowedCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:";
    return cleanCharacters(address, allowedCharacters, address.size) == address;
}

// Publish now, then on the heartbeat or soon after a player joins or leaves.
_publishLoop()
{
    level endon("game_ended");
    heartbeatMs = level.serverList.heartbeatSeconds * 1000;
    minimumRefreshMs = level.serverList.minimumRefreshSeconds * 1000;
    for (;;)
    {
        level.serverList.refreshRequested = false;
        lastPublishMs = getTime();
        _publish();
        for (;;)
        {
            wait 1;
            elapsedMs = getTime() - lastPublishMs;
            if (elapsedMs >= heartbeatMs)
            {
                break;
            }
            if (level.serverList.refreshRequested && elapsedMs >= minimumRefreshMs)
            {
                break;
            }
        }
    }
}

// Write this server's row. Repeating the write is harmless, so a lost reply needs
// no recovery: the next heartbeat writes the same values again.
_publish()
{
    playerCount = 0;
    if (isDefined(level.playerCount))
    {
        playerCount = level.playerCount;
    }
    listed = int(getCvar("g_password") == "");
    serverName = getSubStr(getCvar("sv_hostname"), 0, level.serverList.maxNameLength);
    location = getSubStr(level.serverList.location, 0, level.serverList.maxLocationLength);
    query = "INSERT INTO gameServers"
            + " (serverID, serverName, address, location, mapName, playerCount, maxPlayers, listed)"
            + " VALUES ("
            + dbStr(openCJ\mySQL::escapeString(level.serverList.serverID)) + ", "
            + dbStr(openCJ\mySQL::escapeString(serverName)) + ", "
            + dbStr(openCJ\mySQL::escapeString(level.serverList.address)) + ", "
            + dbStr(openCJ\mySQL::escapeString(location)) + ", "
            + dbStr(openCJ\mySQL::escapeString(getCvar("mapname"))) + ", "
            + playerCount + ", " + getCvarInt("sv_maxclients") + ", " + listed + ")"
            + " ON DUPLICATE KEY UPDATE serverName = VALUES(serverName), address = VALUES(address),"
            + " location = VALUES(location), mapName = VALUES(mapName),"
            + " playerCount = VALUES(playerCount), maxPlayers = VALUES(maxPlayers),"
            + " listed = VALUES(listed), lastSeen = NOW()";
    openCJ\mySQL::mysqlAsyncBackground(query, "server-list");
}

_menuResponse()
{
    self endon("disconnect");
    rowButtonPrefix = "click_server";
    for (;;)
    {
        self waittill("menuresponse", menu, response);
        if (menu != level.serverList.menu)
        {
            continue;
        }
        if (response == "open_servers" || response == "click_refresh")
        {
            self thread _loadServers();
        }
        else if (response == "click_join")
        {
            self _joinSelectedServer();
        }
        else if (getSubStr(response, 0, rowButtonPrefix.size) == rowButtonPrefix)
        {
            self _selectRow(getSubStr(response, rowButtonPrefix.size));
        }
    }
}

// Read the listed servers that refreshed recently; the newest request wins.
_loadServers()
{
    self endon("disconnect");
    self notify("server_list_load");
    self endon("server_list_load");
    self setClientCvar(level.serverList.dvarPrefix + "status", "Loading servers...");

    query = "SELECT serverID, serverName, address, location, mapName, playerCount, maxPlayers"
            + " FROM gameServers"
            + " WHERE listed = TRUE"
            + " AND lastSeen > NOW() - INTERVAL " + level.serverList.staleSeconds + " SECOND"
            + " ORDER BY playerCount DESC, serverName"
            + " LIMIT " + level.serverList.maxRows;
    rows = self openCJ\mySQL::mysqlAsyncRead(query);
    if (!isDefined(rows))
    {
        self setClientCvar(level.serverList.dvarPrefix + "status",
                           "Could not load the server list. Try Refresh.");
        return;
    }
    self publishServerRows(rows);
}

// Decode the rows, drop any that cannot be joined safely and fill every menu row.
publishServerRows(rows)
{
    serverIDColumn = 0;
    nameColumn = 1;
    addressColumn = 2;
    locationColumn = 3;
    mapColumn = 4;
    playerCountColumn = 5;
    maxPlayersColumn = 6;

    self.serverListRows = [];
    for (i = 0; i < rows.size && self.serverListRows.size < level.serverList.maxRows; i++)
    {
        row = rows[i];
        if (!isJoinableAddress(row[addressColumn]))
        {
            continue;
        }
        entry = spawnStruct();
        entry.serverID = row[serverIDColumn];
        entry.address = row[addressColumn];
        entry.name = _displayText(row[nameColumn]) + "^7";
        if (entry.serverID == level.serverList.serverID)
        {
            entry.name += " ^3(this server)";
        }
        entry.location = _displayText(row[locationColumn]);
        entry.mapName = _displayText(row[mapColumn]);
        entry.players = row[playerCountColumn] + "/" + row[maxPlayersColumn];
        self.serverListRows[self.serverListRows.size] = entry;
    }

    clientValues = [];
    prefix = level.serverList.dvarPrefix;
    for (rowIndex = 0; rowIndex < level.serverList.maxRows; rowIndex++)
    {
        name = "";
        location = "";
        mapName = "";
        players = "";
        if (rowIndex < self.serverListRows.size)
        {
            entry = self.serverListRows[rowIndex];
            name = entry.name;
            location = entry.location;
            mapName = entry.mapName;
            players = entry.players;
        }
        clientValues[prefix + "name" + rowIndex] = name;
        clientValues[prefix + "location" + rowIndex] = location;
        clientValues[prefix + "map" + rowIndex] = mapName;
        clientValues[prefix + "players" + rowIndex] = players;
    }
    self.serverListSelected = -1;
    clientValues[prefix + "selected"] = "";
    status = self.serverListRows.size + " servers online";
    if (self.serverListRows.size == 1)
    {
        status = "1 server online";
    }
    else if (self.serverListRows.size == 0)
    {
        status = "No servers are online right now.";
    }
    clientValues[prefix + "status"] = status;
    self thread setALotOfCvars(clientValues, "serverlist");
}

// Text from other servers' rows is shown in client dvars; drop the characters
// that could end a quoted value or start another console command.
_displayText(text)
{
    unsafeCharacters = "\"\\;\n";
    safeText = "";
    for (i = 0; i < text.size; i++)
    {
        if (!isSubStr(unsafeCharacters, text[i]))
        {
            safeText += text[i];
        }
    }
    return safeText;
}

_selectRow(rowText)
{
    if (!isValidInt(rowText))
    {
        return;
    }
    rowIndex = int(rowText);
    if (rowIndex < 0 || rowIndex >= self.serverListRows.size)
    {
        return;
    }
    self.serverListSelected = rowIndex;
    self setClientCvar(level.serverList.dvarPrefix + "selected", rowIndex);
}

// Connect only to an address this server validated when it published the list.
_joinSelectedServer()
{
    rowIndex = self.serverListSelected;
    if (!isDefined(rowIndex) || rowIndex < 0 || rowIndex >= self.serverListRows.size)
    {
        return;
    }
    entry = self.serverListRows[rowIndex];
    if (entry.serverID == level.serverList.serverID)
    {
        self sendLocalChatMessage("You are already on this server.", true);
        return;
    }
    self closeMenu();
    self closeInGameMenu();
    self execClientCmd("connect " + entry.address);
}

