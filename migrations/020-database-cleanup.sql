-- Apply after 019, with OpenCJ stopped and a full backup.
-- This removes avoidable copies, preserving saved-state and demo summaries.
-- Refuse ambiguous or nonempty legacy data rather than discarding it.
DELIMITER //
CREATE PROCEDURE preflightCleanup020()
BEGIN
 IF EXISTS(SELECT 1 FROM playerRuns r JOIN runLabels l USING(runID) WHERE r.runLabel<>'' AND BINARY r.runLabel<>BINARY l.runLabel)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Conflicting run labels: reconcile before cleanup'; END IF;
 IF EXISTS(SELECT 1 FROM playerSaves_test) OR EXISTS(SELECT 1 FROM playerRecordings) OR EXISTS(SELECT 1 FROM demoEvents)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Legacy tables contain data: archive/reconcile before cleanup'; END IF;
 IF EXISTS(SELECT 1 FROM routes WHERE routeShaderColor IS NOT NULL) OR EXISTS(SELECT 1 FROM checkpoints WHERE endShaderColor IS NOT NULL)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Legacy palette colors exist: convert them to RGB before cleanup'; END IF;
 IF EXISTS(SELECT 1 FROM challenges c JOIN routes r USING(routeID) JOIN mapids m ON m.mapID=r.mapID WHERE BINARY c.mapName<>BINARY m.mapname)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Challenge map differs from linked route map'; END IF;
 IF EXISTS(SELECT 1 FROM checkpointAreas a JOIN checkpoints c USING(cpID) WHERE a.mapID<>c.mapID)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Checkpoint area belongs to a different map'; END IF;
 IF EXISTS(SELECT 1 FROM demoWinners w JOIN demoRuns d USING(runID) WHERE w.mapID<>d.mapID OR w.routeID<>d.routeID OR w.FPSMode<>d.FPSMode OR w.modeMask<>d.modeMask)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Demo winner category differs from its recording'; END IF;
 IF EXISTS(SELECT 1 FROM shopEquipped e LEFT JOIN shopCatalog c USING(itemKey) WHERE c.itemKey IS NULL OR e.slot<>c.slot OR e.category<>c.category)
 THEN SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='Equipped item metadata differs from catalogue'; END IF;
END//
DELIMITER ;
CALL preflightCleanup020();
DROP PROCEDURE preflightCleanup020;

INSERT INTO runLabels(runID,runLabel)
 SELECT r.runID,r.runLabel FROM playerRuns r LEFT JOIN runLabels l USING(runID)
 WHERE r.runLabel<>'' AND l.runID IS NULL;
ALTER TABLE playerRuns DROP COLUMN runLabel;

-- Register existing challenge definitions only; this does not approve a map
-- for voting, install it, or change release/author metadata on existing maps.
INSERT INTO mapids(mapname)
 SELECT DISTINCT c.mapName FROM challenges c LEFT JOIN mapids m ON m.mapname=c.mapName
 WHERE m.mapID IS NULL;
ALTER TABLE challenges ADD mapID INT NULL;
UPDATE challenges c JOIN mapids m ON m.mapname=c.mapName SET c.mapID=m.mapID;
ALTER TABLE challenges MODIFY mapID INT NOT NULL,
 ADD CONSTRAINT challenge_map_fk FOREIGN KEY(mapID) REFERENCES mapids(mapID),
 ADD CONSTRAINT challenge_route_map_fk FOREIGN KEY(routeID,mapID) REFERENCES routes(routeID,mapID),
 ADD KEY challenge_map(mapID),
 DROP COLUMN mapName;

ALTER TABLE routes DROP COLUMN routeShaderColor;
ALTER TABLE checkpoints DROP COLUMN endShaderColor;

-- These empty tables and functions belong to the superseded recording/test
-- system. Current GSC/native code has no references to them.
DROP FUNCTION createEvent;
DROP FUNCTION prepareAllDemos;
DROP FUNCTION prepareDemo;
DROP FUNCTION savePosition_test;
DROP FUNCTION storeDemoFrame;
DROP TABLE playerRecordings;
DROP TABLE demoEvents;
DROP TABLE playerSaves_test;

-- Retain IDs needed by indexes and enforce that each copy agrees with its owner.
ALTER TABLE checkpoints ADD UNIQUE KEY checkpoint_map(cpID,mapID);
ALTER TABLE checkpointAreas ADD CONSTRAINT area_checkpoint_map_fk
 FOREIGN KEY(cpID,mapID) REFERENCES checkpoints(cpID,mapID);
ALTER TABLE demoRuns ADD UNIQUE KEY demo_category(runID,mapID,routeID,FPSMode,modeMask);
ALTER TABLE demoWinners ADD CONSTRAINT winner_demo_category_fk
 FOREIGN KEY(runID,mapID,routeID,FPSMode,modeMask)
 REFERENCES demoRuns(runID,mapID,routeID,FPSMode,modeMask);
ALTER TABLE shopCatalog ADD UNIQUE KEY item_slot(itemKey,slot);
ALTER TABLE shopEquipped DROP COLUMN category,
 ADD CONSTRAINT equipped_catalog_slot_fk FOREIGN KEY(itemKey,slot)
 REFERENCES shopCatalog(itemKey,slot) ON UPDATE CASCADE;

DROP PROCEDURE IF EXISTS shopBuyOrEquip;
DELIMITER //
CREATE PROCEDURE shopBuyOrEquip(IN accountID INT, IN requestedKey VARCHAR(64), IN equipOnly BOOLEAN, IN quotedPrice INT)
shop: BEGIN
 DECLARE lockedID INT;
 DECLARE itemPrice INT DEFAULT NULL;
 DECLARE itemSlot VARCHAR(64);
 DECLARE enabled BOOLEAN;
 DECLARE earned BIGINT DEFAULT 0;
 DECLARE spent BIGINT DEFAULT 0;
 DECLARE owned BOOLEAN DEFAULT FALSE;
 DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SELECT 'error'; END;
 IF NOT EXISTS(SELECT 1 FROM playerInformation WHERE playerID=accountID) THEN SELECT 'account'; LEAVE shop; END IF;
 START TRANSACTION;
 INSERT INTO shopAccounts(playerID) VALUES(accountID) ON DUPLICATE KEY UPDATE playerID=VALUES(playerID);
 SELECT playerID INTO lockedID FROM shopAccounts WHERE playerID=accountID FOR UPDATE;
 SELECT price,slot,available INTO itemPrice,itemSlot,enabled FROM shopCatalog WHERE itemKey=requestedKey LOCK IN SHARE MODE;
 IF itemPrice IS NULL THEN ROLLBACK; SELECT 'unavailable'; LEAVE shop; END IF;
 SELECT EXISTS(SELECT 1 FROM shopPurchases WHERE playerID=accountID AND itemKey=requestedKey) INTO owned;
 IF equipOnly AND NOT owned THEN ROLLBACK; SELECT 'not_owned'; LEAVE shop; END IF;
 IF NOT equipOnly THEN
  IF owned THEN ROLLBACK; SELECT 'owned'; LEAVE shop; END IF;
  IF NOT enabled THEN ROLLBACK; SELECT 'unavailable'; LEAVE shop; END IF;
  IF itemPrice<>quotedPrice THEN ROLLBACK; SELECT 'price_changed'; LEAVE shop; END IF;
  SELECT COALESCE(SUM(c.points),0) INTO earned FROM challengeCompletions a JOIN challenges c ON c.challengeKey=a.challengeKey AND c.active=1 WHERE a.playerID=accountID;
  SELECT COALESCE(SUM(pointsSpent),0) INTO spent FROM shopPurchases WHERE playerID=accountID;
  IF earned-spent<itemPrice THEN ROLLBACK; SELECT 'balance'; LEAVE shop; END IF;
  INSERT INTO shopPurchases(playerID,itemKey,pointsSpent) VALUES(accountID,requestedKey,itemPrice);
 END IF;
 INSERT INTO shopEquipped(playerID,slot,itemKey) VALUES(accountID,itemSlot,requestedKey) ON DUPLICATE KEY UPDATE itemKey=VALUES(itemKey);
 COMMIT;
 SELECT 'ok';
END//
DELIMITER ;
