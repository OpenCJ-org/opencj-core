-- One row per OpenCJ game server that shares this database, for the in-game
-- server browser. Each server refreshes its own row (a heartbeat, plus player
-- joins/leaves and map changes). The browser hides rows that were not refreshed
-- recently, so a stopped or crashed server drops out without any cleanup.
CREATE TABLE gameServers (
    -- The installation's instance name, for example main-eu.
    serverID VARCHAR(32) CHARACTER SET ascii NOT NULL,
    serverName VARCHAR(64) NOT NULL,
    -- host:port that players connect to.
    address VARCHAR(64) CHARACTER SET ascii NOT NULL,
    location VARCHAR(48) NOT NULL DEFAULT '',
    mapName VARCHAR(64) NOT NULL DEFAULT '',
    playerCount TINYINT UNSIGNED NOT NULL DEFAULT 0,
    maxPlayers TINYINT UNSIGNED NOT NULL DEFAULT 0,
    -- Password-protected servers keep a row but are never listed.
    listed BOOLEAN NOT NULL DEFAULT TRUE,
    lastSeen TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (serverID),
    KEY game_servers_listed (listed, lastSeen)
) ENGINE=InnoDB;

