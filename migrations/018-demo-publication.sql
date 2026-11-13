-- One complete publication transaction per asynchronous worker request.
-- Receipts survive removal of non-winning payloads, making retries unambiguous.
CREATE TABLE IF NOT EXISTS demoPublications (
    runID INT NOT NULL PRIMARY KEY,
    publishedAt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (runID) REFERENCES playerRuns(runID) ON DELETE CASCADE
) ENGINE=InnoDB;

DROP PROCEDURE IF EXISTS publishDemo;
DELIMITER //
CREATE PROCEDURE publishDemo(IN requestedRun INT)
publication: BEGIN
    DECLARE mapNumber INT DEFAULT NULL;
    DECLARE lockedMap INT DEFAULT NULL;
    DECLARE route VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin;
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
    SELECT routeName,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount,ready
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
              WHERE w.mapID=mapNumber AND w.routeName=route AND w.FPSMode=fps
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
                INSERT INTO demoWinners(mapID,routeName,FPSMode,modeMask,kind,runID)
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
