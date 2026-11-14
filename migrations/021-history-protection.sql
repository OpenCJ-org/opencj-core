-- Development data safety. Apply through tools/migrate.py after 020.
-- Retain historical rows; retire/archive catalog entries instead of deleting them.
DELIMITER //
CREATE PROCEDURE preflightSafety021()
BEGIN
 IF EXISTS(SELECT 1 FROM checkpointConnections GROUP BY cpID,childcpID HAVING COUNT(*)>1)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Duplicate checkpoint links; review before migrating'; END IF;
 IF EXISTS(SELECT 1 FROM checkpointConnections e JOIN checkpoints a ON a.cpID=e.cpID JOIN checkpoints b ON b.cpID=e.childcpID WHERE a.mapID<>b.mapID OR a.cpID=b.cpID)
 OR EXISTS(SELECT 1 FROM checkpointBrothers e JOIN checkpoints a ON a.cpID=e.cpID JOIN checkpoints b ON b.cpID=e.bigBrotherID WHERE a.mapID<>b.mapID OR a.cpID=b.cpID)
 OR EXISTS(SELECT 1 FROM checkpointRoutes e JOIN checkpoints a USING(cpID) JOIN routes b USING(routeID) WHERE a.mapID<>b.mapID)
 OR EXISTS(SELECT 1 FROM routes r JOIN checkpoints c USING(cpID) WHERE r.mapID<>c.mapID)
 OR EXISTS(SELECT 1 FROM playerRuns r JOIN checkpoints c ON c.cpID=r.finishcpID WHERE r.mapID<>c.mapID)
 OR EXISTS(SELECT 1 FROM checkpointStatistics s JOIN playerRuns r USING(runID) JOIN checkpoints c USING(cpID) WHERE r.mapID<>c.mapID)
 OR EXISTS(SELECT 1 FROM demoRuns d JOIN playerRuns r USING(runID) WHERE d.mapID<>r.mapID)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Cross-map or self references; review before migrating'; END IF;
 IF EXISTS(SELECT 1 FROM playerSaves s JOIN playerRuns r USING(runID) LEFT JOIN checkpoints c ON c.cpID=s.checkpointID WHERE s.checkpointID IS NOT NULL AND (c.cpID IS NULL OR c.mapID<>r.mapID))
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Save checkpoint missing or belongs to another map'; END IF;
 IF EXISTS(SELECT 1 FROM challengeCompletions a LEFT JOIN playerInformation p USING(playerID) LEFT JOIN challenges c USING(challengeKey) LEFT JOIN playerRuns r USING(runID) WHERE p.playerID IS NULL OR c.challengeKey IS NULL OR (a.runID IS NOT NULL AND (r.runID IS NULL OR r.playerID<>a.playerID)))
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Challenge award reference missing or wrong owner'; END IF;
 IF EXISTS(SELECT 1 FROM shopPurchases s LEFT JOIN playerInformation p USING(playerID) LEFT JOIN shopCatalog c USING(itemKey) WHERE p.playerID IS NULL OR c.itemKey IS NULL)
 OR EXISTS(SELECT 1 FROM shopAccounts a LEFT JOIN playerInformation p USING(playerID) WHERE p.playerID IS NULL)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Shop reference missing; review before migrating'; END IF;
END//
DELIMITER ;
CALL preflightSafety021();
DROP PROCEDURE preflightSafety021;

ALTER TABLE playerRuns
 DROP FOREIGN KEY FK__playerInformation,
 DROP FOREIGN KEY `FK_playerRuns_openCJ_cod4.mapids`,
 DROP FOREIGN KEY `FK_playerRuns_openCJ_cod4.checkpoints`,
 ADD CONSTRAINT run_player_history_fk FOREIGN KEY(playerID) REFERENCES playerInformation(playerID),
 ADD CONSTRAINT run_map_history_fk FOREIGN KEY(mapID) REFERENCES mapids(mapID),
 ADD CONSTRAINT run_finish_history_fk FOREIGN KEY(finishcpID) REFERENCES checkpoints(cpID),
 MODIFY startTimeStamp TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP;
ALTER TABLE checkpointStatistics
 DROP FOREIGN KEY FK_checkpointStatistics_checkpoints,
 DROP FOREIGN KEY FK_checkpointStatistics_playerRuns,
 ADD CONSTRAINT stats_checkpoint_history_fk FOREIGN KEY(cpID) REFERENCES checkpoints(cpID),
 ADD CONSTRAINT stats_run_history_fk FOREIGN KEY(runID) REFERENCES playerRuns(runID);
ALTER TABLE playerSaves
 DROP FOREIGN KEY FK_playerSaves_playerRuns,
 ADD CONSTRAINT save_run_history_fk FOREIGN KEY(runID) REFERENCES playerRuns(runID),
 ADD CONSTRAINT save_checkpoint_history_fk FOREIGN KEY(checkpointID) REFERENCES checkpoints(cpID);
ALTER TABLE checkpoints
 DROP FOREIGN KEY FK_import_checkpoints_import_mapids,
 ADD CONSTRAINT checkpoint_map_history_fk FOREIGN KEY(mapID) REFERENCES mapids(mapID);
ALTER TABLE challengeCompletions
 ADD CONSTRAINT award_player_history_fk FOREIGN KEY(playerID) REFERENCES playerInformation(playerID),
 ADD CONSTRAINT award_challenge_history_fk FOREIGN KEY(challengeKey) REFERENCES challenges(challengeKey),
 ADD CONSTRAINT award_run_fk FOREIGN KEY(runID) REFERENCES playerRuns(runID) ON DELETE SET NULL;
ALTER TABLE shopPurchases
 ADD CONSTRAINT purchase_player_history_fk FOREIGN KEY(playerID) REFERENCES playerInformation(playerID),
 ADD CONSTRAINT purchase_item_history_fk FOREIGN KEY(itemKey) REFERENCES shopCatalog(itemKey);
ALTER TABLE shopAccounts ADD CONSTRAINT shop_account_player_fk
 FOREIGN KEY(playerID) REFERENCES playerInformation(playerID) ON DELETE CASCADE;
ALTER TABLE checkpointConnections
 ADD PRIMARY KEY(cpID,childcpID);

-- Parents cannot move between maps after creation. This makes the following
-- cross-map checks safe from concurrent parent moves without redundant mapID
-- columns on every child table. Ordinary geometry/name edits remain supported.
DELIMITER //
CREATE TRIGGER safety_playerRuns_insert BEFORE INSERT ON playerRuns FOR EACH ROW
BEGIN
 IF NEW.finishcpID IS NOT NULL AND (SELECT mapID FROM checkpoints WHERE cpID=NEW.finishcpID)<>NEW.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Run finish belongs to another map'; END IF;
END//
CREATE TRIGGER safety_playerRuns_update BEFORE UPDATE ON playerRuns FOR EACH ROW
BEGIN
 IF NEW.mapID<>OLD.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Map ownership is permanent; use an explicit reviewed migration'; END IF;
 IF NEW.finishcpID IS NOT NULL AND (SELECT mapID FROM checkpoints WHERE cpID=NEW.finishcpID)<>NEW.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Run finish belongs to another map'; END IF;
END//
CREATE TRIGGER safety_checkpoints_update BEFORE UPDATE ON checkpoints FOR EACH ROW
BEGIN
 IF NEW.mapID<>OLD.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Map ownership is permanent; use an explicit reviewed migration'; END IF;
END//
CREATE TRIGGER safety_routes_insert BEFORE INSERT ON routes FOR EACH ROW
BEGIN
 IF NEW.cpID IS NOT NULL AND (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>NEW.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Route start belongs to another map'; END IF;
END//
CREATE TRIGGER safety_routes_update BEFORE UPDATE ON routes FOR EACH ROW
BEGIN
 IF NEW.mapID<>OLD.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Map ownership is permanent; use an explicit reviewed migration'; END IF;
 IF NEW.cpID IS NOT NULL AND (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>NEW.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Route start belongs to another map'; END IF;
END//
CREATE TRIGGER safety_checkpointConnections_insert BEFORE INSERT ON checkpointConnections FOR EACH ROW
BEGIN
 IF NEW.cpID=NEW.childcpID OR (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM checkpoints WHERE cpID=NEW.childcpID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint connection crosses maps'; END IF;
END//
CREATE TRIGGER safety_checkpointConnections_update BEFORE UPDATE ON checkpointConnections FOR EACH ROW
BEGIN
 IF NEW.cpID=NEW.childcpID OR (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM checkpoints WHERE cpID=NEW.childcpID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint connection crosses maps'; END IF;
END//
CREATE TRIGGER safety_checkpointBrothers_insert BEFORE INSERT ON checkpointBrothers FOR EACH ROW
BEGIN
 IF NEW.cpID=NEW.bigBrotherID OR (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM checkpoints WHERE cpID=NEW.bigBrotherID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint alternatives cross maps'; END IF;
END//
CREATE TRIGGER safety_checkpointBrothers_update BEFORE UPDATE ON checkpointBrothers FOR EACH ROW
BEGIN
 IF NEW.cpID=NEW.bigBrotherID OR (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM checkpoints WHERE cpID=NEW.bigBrotherID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint alternatives cross maps'; END IF;
END//
CREATE TRIGGER safety_checkpointRoutes_insert BEFORE INSERT ON checkpointRoutes FOR EACH ROW
BEGIN
 IF (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM routes WHERE routeID=NEW.routeID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint route membership crosses maps'; END IF;
END//
CREATE TRIGGER safety_checkpointRoutes_update BEFORE UPDATE ON checkpointRoutes FOR EACH ROW
BEGIN
 IF (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM routes WHERE routeID=NEW.routeID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint route membership crosses maps'; END IF;
END//
CREATE TRIGGER safety_checkpointStatistics_insert BEFORE INSERT ON checkpointStatistics FOR EACH ROW
BEGIN
 IF (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM playerRuns WHERE runID=NEW.runID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint statistics cross maps'; END IF;
END//
CREATE TRIGGER safety_checkpointStatistics_update BEFORE UPDATE ON checkpointStatistics FOR EACH ROW
BEGIN
 IF (SELECT mapID FROM checkpoints WHERE cpID=NEW.cpID)<>(SELECT mapID FROM playerRuns WHERE runID=NEW.runID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint statistics cross maps'; END IF;
END//
CREATE TRIGGER safety_playerSaves_insert BEFORE INSERT ON playerSaves FOR EACH ROW
BEGIN
 IF NEW.checkpointID IS NOT NULL AND (SELECT mapID FROM checkpoints WHERE cpID=NEW.checkpointID)<>(SELECT mapID FROM playerRuns WHERE runID=NEW.runID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Saved checkpoint crosses maps'; END IF;
END//
CREATE TRIGGER safety_playerSaves_update BEFORE UPDATE ON playerSaves FOR EACH ROW
BEGIN
 IF NEW.checkpointID IS NOT NULL AND (SELECT mapID FROM checkpoints WHERE cpID=NEW.checkpointID)<>(SELECT mapID FROM playerRuns WHERE runID=NEW.runID) THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Saved checkpoint crosses maps'; END IF;
END//
CREATE TRIGGER safety_demoRuns_insert BEFORE INSERT ON demoRuns FOR EACH ROW
BEGIN
 IF (SELECT mapID FROM playerRuns WHERE runID=NEW.runID)<>NEW.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Demo belongs to another run map'; END IF;
END//
CREATE TRIGGER safety_demoRuns_update BEFORE UPDATE ON demoRuns FOR EACH ROW
BEGIN
 IF (SELECT mapID FROM playerRuns WHERE runID=NEW.runID)<>NEW.mapID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Demo belongs to another run map'; END IF;
END//
CREATE TRIGGER safety_challengeCompletions_insert BEFORE INSERT ON challengeCompletions FOR EACH ROW
BEGIN
 IF NEW.runID IS NOT NULL AND (SELECT playerID FROM playerRuns WHERE runID=NEW.runID)<>NEW.playerID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Challenge run belongs to another player'; END IF;
END//
CREATE TRIGGER safety_challengeCompletions_update BEFORE UPDATE ON challengeCompletions FOR EACH ROW
BEGIN
 IF NEW.runID IS NOT NULL AND (SELECT playerID FROM playerRuns WHERE runID=NEW.runID)<>NEW.playerID THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Challenge run belongs to another player'; END IF;
END//
DELIMITER ;
