-- #24: nullable historical clip details and server-session view deduplication.
ALTER TABLE demoClips
 ADD RPGShots SMALLINT UNSIGNED NULL,
 ADD FPSMode ENUM('125','mix','hax') NULL,
 ADD eleUsed BOOLEAN NULL,
 ADD viewCount BIGINT UNSIGNED NOT NULL DEFAULT 0;

CREATE TABLE demoClipViews (
 sessionID CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 clipID INT NOT NULL,
 playerID INT NOT NULL,
 PRIMARY KEY(sessionID,clipID,playerID),
 FOREIGN KEY(sessionID) REFERENCES demoClipSessions(sessionID) ON DELETE CASCADE,
 FOREIGN KEY(clipID) REFERENCES demoClips(clipID) ON DELETE CASCADE,
 FOREIGN KEY(playerID) REFERENCES playerInformation(playerID)
) ENGINE=InnoDB;

DELIMITER //
CREATE PROCEDURE countClipView(IN viewingSession CHAR(36),IN viewedClip INT,IN viewer INT)
SQL SECURITY DEFINER
proc: BEGIN
 DECLARE ownerID INT DEFAULT NULL;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;
 START TRANSACTION;
 -- Lock the clip before the receipt so concurrent viewers cannot lose increments.
 SELECT playerID INTO ownerID FROM demoClips WHERE clipID=viewedClip AND ready=1 FOR UPDATE;
 IF ownerID IS NOT NULL AND ownerID<>viewer
    AND EXISTS(SELECT 1 FROM demoClipSessions WHERE sessionID=viewingSession) THEN
  INSERT IGNORE INTO demoClipViews(sessionID,clipID,playerID) VALUES(viewingSession,viewedClip,viewer);
  IF ROW_COUNT()=1 THEN
   UPDATE demoClips SET viewCount=viewCount+1 WHERE clipID=viewedClip;
  END IF;
 END IF;
 COMMIT;
END//
DELIMITER ;
