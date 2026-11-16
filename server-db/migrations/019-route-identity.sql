-- #174: stable route identity. Apply once, with OpenCJ stopped and a backup.
-- MySQL DDL commits implicitly: validate this migration on a restored copy first.
-- routes.cpID remains optional start/color metadata; it is no longer the key.
DELIMITER //
CREATE PROCEDURE preflightRoutes174()
BEGIN
 IF EXISTS(SELECT 1 FROM routes r LEFT JOIN checkpoints c USING(cpID) WHERE c.cpID IS NULL OR r.routeName IS NULL OR r.routeName='')
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Route catalog has missing checkpoint/name; repair before migration'; END IF;
 IF EXISTS(SELECT 1 FROM routes r JOIN checkpoints c USING(cpID) GROUP BY c.mapID,r.routeName HAVING COUNT(*)>1)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Duplicate map/route names; reconcile before migration'; END IF;
 IF EXISTS(SELECT 1 FROM challenges h JOIN mapids m ON m.mapname=h.mapName WHERE h.routeName IS NOT NULL AND NOT EXISTS(SELECT 1 FROM checkpoints c WHERE c.mapID=m.mapID AND c.ender=h.routeName))
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Unresolved challenge route; repair before migration'; END IF;
 IF EXISTS(SELECT 1 FROM checkpointConnections e JOIN checkpoints p ON p.cpID=e.cpID JOIN checkpoints c ON c.cpID=e.childcpID WHERE p.mapID<>c.mapID)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cross-map checkpoint connection; repair before migration'; END IF;
END//
DELIMITER ;
CALL preflightRoutes174();
DROP PROCEDURE preflightRoutes174;

ALTER TABLE routes
 ADD routeID INT NOT NULL AUTO_INCREMENT PRIMARY KEY FIRST,
 ADD mapID INT NULL AFTER routeID,
 MODIFY routeName VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 MODIFY cpID INT NULL,
 DROP INDEX cpID;
UPDATE routes r JOIN checkpoints c ON c.cpID=r.cpID SET r.mapID=c.mapID;
ALTER TABLE routes MODIFY mapID INT NOT NULL,
 ADD UNIQUE KEY map_route(mapID,routeName),
 ADD UNIQUE KEY route_map(routeID,mapID),
 ADD CONSTRAINT routes_map_fk FOREIGN KEY(mapID) REFERENCES mapids(mapID),
 ADD CONSTRAINT routes_start_fk FOREIGN KEY(cpID) REFERENCES checkpoints(cpID) ON DELETE SET NULL;
INSERT INTO routes(mapID,routeName)
 SELECT mapID,ender FROM checkpoints WHERE ender IS NOT NULL AND ender<>''
 UNION SELECT mapID,routeName FROM demoRuns
 UNION SELECT mapID,routeName FROM demoWinners
 ON DUPLICATE KEY UPDATE routeName=VALUES(routeName);

ALTER TABLE checkpoints ADD finishRouteID INT NULL,
 ADD CONSTRAINT checkpoint_finish_route_fk FOREIGN KEY(finishRouteID,mapID) REFERENCES routes(routeID,mapID);
UPDATE checkpoints c JOIN routes r ON r.mapID=c.mapID AND r.routeName=c.ender SET c.finishRouteID=r.routeID;

CREATE TABLE checkpointRoutes (
 cpID INT NOT NULL,
 routeID INT NOT NULL,
 PRIMARY KEY(cpID,routeID),
 KEY route_checkpoints(routeID,cpID),
 FOREIGN KEY(cpID) REFERENCES checkpoints(cpID) ON DELETE CASCADE,
 FOREIGN KEY(routeID) REFERENCES routes(routeID)
) ENGINE=InnoDB;

-- Called inside the existing map-locked publication transaction (never COMMIT here).
-- UNION DISTINCT also makes malformed cycles finite. Retired memberships survive.
DELIMITER //
CREATE PROCEDURE rebuildCheckpointRoutes(IN requestedMap INT)
BEGIN
 DELETE cr FROM checkpointRoutes cr JOIN checkpoints c USING(cpID)
   WHERE c.mapID=requestedMap AND c.retired=0;
 INSERT IGNORE INTO checkpointRoutes(cpID,routeID)
 WITH RECURSIVE membership(cpID,routeID) AS (
   SELECT cpID,finishRouteID FROM checkpoints
     WHERE mapID=requestedMap AND finishRouteID IS NOT NULL
   UNION DISTINCT
   SELECT e.cpID,m.routeID FROM membership m
     JOIN checkpointConnections e ON e.childcpID=m.cpID
     JOIN checkpoints p ON p.cpID=e.cpID
     JOIN checkpoints c ON c.cpID=m.cpID
     WHERE p.mapID=requestedMap AND p.retired=0 AND c.retired=0
       AND (p.finishRouteID IS NULL OR p.finishRouteID=m.routeID)
 ) SELECT cpID,routeID FROM membership;
END//
CREATE PROCEDURE backfillCheckpointRoutes174()
BEGIN
 DECLARE done INT DEFAULT 0;
 DECLARE mapNumber INT;
 DECLARE maps CURSOR FOR SELECT DISTINCT mapID FROM checkpoints;
 DECLARE CONTINUE HANDLER FOR NOT FOUND SET done=1;
 OPEN maps;
 mapLoop: LOOP
   FETCH maps INTO mapNumber;
   IF done THEN LEAVE mapLoop; END IF;
   CALL rebuildCheckpointRoutes(mapNumber);
 END LOOP;
 CLOSE maps;
 IF EXISTS(SELECT 1 FROM checkpoints c WHERE c.retired=0 AND NOT EXISTS(SELECT 1 FROM checkpointRoutes cr WHERE cr.cpID=c.cpID))
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Active checkpoint has no reachable finish; repair before removing legacy columns'; END IF;
END//
DELIMITER ;
CALL backfillCheckpointRoutes174();
DROP PROCEDURE backfillCheckpointRoutes174;

ALTER TABLE demoRuns ADD routeID INT NULL;
UPDATE demoRuns d JOIN routes r ON r.mapID=d.mapID AND r.routeName=d.routeName SET d.routeID=r.routeID;
ALTER TABLE demoRuns MODIFY routeID INT NOT NULL,
 ADD CONSTRAINT demo_route_fk FOREIGN KEY(routeID,mapID) REFERENCES routes(routeID,mapID),
 DROP COLUMN routeName;
ALTER TABLE demoWinners ADD routeID INT NULL;
UPDATE demoWinners d JOIN routes r ON r.mapID=d.mapID AND r.routeName=d.routeName SET d.routeID=r.routeID;
ALTER TABLE demoWinners DROP PRIMARY KEY, MODIFY routeID INT NOT NULL,
 ADD PRIMARY KEY(routeID,FPSMode,modeMask,kind),
 ADD CONSTRAINT demo_winner_route_fk FOREIGN KEY(routeID,mapID) REFERENCES routes(routeID,mapID),
 DROP COLUMN routeName;
ALTER TABLE challenges ADD routeID INT NULL,
 ADD CONSTRAINT challenge_route_fk FOREIGN KEY(routeID) REFERENCES routes(routeID);
UPDATE challenges h JOIN mapids m ON m.mapname=h.mapName
 JOIN routes r ON r.mapID=m.mapID AND r.routeName=h.routeName SET h.routeID=r.routeID;
-- A hint is used only to bind a previously unpublished challenge. Once bound,
-- routeID is authoritative and catalogue refresh must never overwrite it.
ALTER TABLE challenges CHANGE routeName routeHint VARCHAR(64) NULL;
ALTER TABLE checkpointAreas RENAME COLUMN routeName TO draftName;
ALTER TABLE checkpoints DROP COLUMN ender;

DROP PROCEDURE IF EXISTS publishDemo;
DELIMITER //
CREATE PROCEDURE publishDemo(IN requestedRun INT)
publication: BEGIN
    DECLARE mapNumber INT DEFAULT NULL;
    DECLARE lockedMap INT DEFAULT NULL;
    DECLARE route INT;
    DECLARE fps VARCHAR(3);
    DECLARE mask INT;
    DECLARE elapsed INT;
    DECLARE explosives INT;
    DECLARE frames INT;
    DECLARE state INT DEFAULT NULL;
    DECLARE chunks INT;
    DECLARE firstChunk INT;
    DECLARE lastChunk INT;
    DECLARE smallestChunk INT;
    DECLARE expectedChunks INT;
    DECLARE categoryNumber INT DEFAULT 0;
    DECLARE category VARCHAR(16);
    DECLARE previousTime INT;
    DECLARE previousExplosives INT;
    DECLARE better BOOLEAN;
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- Immutable run ownership identifies the lock even after payload cleanup.
    SELECT mapID INTO mapNumber FROM playerRuns WHERE runID=requestedRun;
    IF mapNumber IS NULL THEN SELECT 0, 'missing'; LEAVE publication; END IF;
    START TRANSACTION;
    SELECT mapID INTO lockedMap FROM mapids WHERE mapID=mapNumber FOR UPDATE;
    IF lockedMap IS NULL THEN ROLLBACK; SELECT 0, 'missing'; LEAVE publication; END IF;

    -- This first consistent read is after the map lock; prior publishers have
    -- committed. All publishers of this map, including other servers, serialize.
    IF EXISTS(SELECT 1 FROM demoPublications WHERE runID=requestedRun) THEN
        COMMIT;
        SELECT 1, 'already_published';
        LEAVE publication;
    END IF;

    -- Re-read mutable metadata after the lock (route renames/retirement use it).
    SELECT routeID,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount,ready
      INTO route,fps,mask,elapsed,explosives,frames,state
      FROM demoRuns WHERE runID=requestedRun AND mapID=mapNumber FOR UPDATE;
    IF state IS NULL THEN ROLLBACK; SELECT 0, 'missing'; LEAVE publication; END IF;
    IF state=2 THEN ROLLBACK; SELECT 0, 'retired'; LEAVE publication; END IF;

    SET expectedChunks=CEIL(frames/64.0);
    SELECT COUNT(*),MIN(chunkNum),MAX(chunkNum),MIN(OCTET_LENGTH(payload))
      INTO chunks,firstChunk,lastChunk,smallestChunk
      FROM demoChunks WHERE runID=requestedRun;
    IF frames<2 OR chunks<>expectedChunks OR firstChunk IS NULL OR
       firstChunk<>0 OR lastChunk<>expectedChunks-1 OR smallestChunk<=0 THEN
        ROLLBACK; SELECT 0, 'incomplete'; LEAVE publication;
    END IF;

    WHILE categoryNumber<3 DO
        SET category=CASE categoryNumber WHEN 0 THEN 'speedrun'
                     WHEN 1 THEN 'lowrpg' ELSE 'walkthrough' END;
        IF categoryNumber<2 OR (mask=0 AND fps<>'hax') THEN
            SET previousTime=NULL;
            SET previousExplosives=NULL;
            SELECT d.timePlayed,d.explosiveJumps
              INTO previousTime,previousExplosives
              FROM demoWinners w JOIN demoRuns d ON d.runID=w.runID
              WHERE w.mapID=mapNumber AND w.routeID=route AND w.FPSMode=fps
                AND w.modeMask=mask AND w.kind=category AND d.ready=1 FOR UPDATE;
            SET better=previousTime IS NULL;
            IF NOT better THEN
                SET better=CASE categoryNumber
                    WHEN 0 THEN elapsed<previousTime OR
                        (elapsed=previousTime AND explosives<previousExplosives)
                    WHEN 1 THEN explosives<previousExplosives OR
                        (explosives=previousExplosives AND elapsed<previousTime)
                    ELSE elapsed<previousTime END;
            END IF;
            IF better THEN
                INSERT INTO demoWinners(mapID,routeID,FPSMode,modeMask,kind,runID)
                  VALUES(mapNumber,route,fps,mask,category,requestedRun)
                  ON DUPLICATE KEY UPDATE runID=VALUES(runID);
            END IF;
        END IF;
        SET categoryNumber=categoryNumber+1;
    END WHILE;

    UPDATE demoRuns SET ready=1 WHERE runID=requestedRun;
    DELETE d FROM demoRuns d LEFT JOIN demoWinners w ON w.runID=d.runID
      WHERE d.mapID=mapNumber AND d.ready=1 AND w.runID IS NULL;
    INSERT INTO demoPublications(runID) VALUES(requestedRun);
    COMMIT;
    SELECT 1, 'published';
END//
DELIMITER ;
