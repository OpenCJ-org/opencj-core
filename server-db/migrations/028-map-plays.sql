-- One row per map session that a logged-in player joined; the website ranks
-- maps by these rows. The game inserts a row when the first player of a map
-- session logs in, so map loads on an empty server are not counted.
-- Earlier sessions were never recorded and are not reconstructed.
CREATE TABLE mapPlays (
    mapPlayID INT UNSIGNED NOT NULL AUTO_INCREMENT,
    mapID INT NOT NULL,
    startedAt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (mapPlayID),
    KEY map_plays_by_map (mapID, startedAt),
    CONSTRAINT map_play_map_fk FOREIGN KEY (mapID) REFERENCES mapids (mapID)
) ENGINE=InnoDB;
