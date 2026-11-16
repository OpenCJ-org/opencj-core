-- #103: persistent record names and privately managed moderation rules.
-- Additive only: no existing player names or records are rewritten.
-- Rule data is managed separately; never commit actual blocked terms here.
CREATE TABLE IF NOT EXISTS playerNamePreferences (
    playerID INT NOT NULL PRIMARY KEY,
    preferredName VARCHAR(15) CHARACTER SET ascii COLLATE ascii_general_ci NULL,
    changedAt DATETIME(6) NULL,
    UNIQUE KEY preferredName (preferredName),
    CONSTRAINT prefname_player FOREIGN KEY (playerID) REFERENCES playerInformation(playerID)
) ENGINE=InnoDB;

-- Claims share a small namespace lock. These infrequent writes must serialize
-- before account/index locks to avoid unique-index deadlocks across accounts.
CREATE TABLE IF NOT EXISTS preferredNameWriteLock (
    singleton TINYINT NOT NULL PRIMARY KEY CHECK (singleton=1)
) ENGINE=InnoDB;
INSERT IGNORE INTO preferredNameWriteLock(singleton) VALUES(1);

CREATE TABLE IF NOT EXISTS nameModerationRules (
    ruleID INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    nameHash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    normalizedLength TINYINT UNSIGNED NOT NULL,
    matchMode ENUM('whole','contains') NOT NULL DEFAULT 'whole',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    source VARCHAR(64) CHARACTER SET ascii NOT NULL DEFAULT 'local',
    createdAt DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    UNIQUE KEY rule_match (nameHash,matchMode)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS nameModerationExceptions (
    ruleID INT NOT NULL,
    nameHash CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    PRIMARY KEY (ruleID,nameHash),
    FOREIGN KEY (ruleID) REFERENCES nameModerationRules(ruleID) ON DELETE CASCADE
) ENGINE=InnoDB;

DROP FUNCTION IF EXISTS normalizeModeratedName;
DROP FUNCTION IF EXISTS blockedNameRule;
DROP FUNCTION IF EXISTS setPreferredName;
DROP FUNCTION IF EXISTS resetPreferredNameByModerator;
DELIMITER //
CREATE FUNCTION normalizeModeratedName(_name VARCHAR(128) CHARACTER SET utf8mb4)
RETURNS VARCHAR(128) CHARACTER SET ascii DETERMINISTIC NO SQL
BEGIN
    DECLARE _i INT DEFAULT 1;
    DECLARE _ch CHAR(1) CHARACTER SET utf8mb4;
    DECLARE _last CHAR(1) DEFAULT '';
    DECLARE _out VARCHAR(128) CHARACTER SET ascii DEFAULT '';
    SET _name=LOWER(COALESCE(_name,''));
    WHILE _i<=CHAR_LENGTH(_name) DO
        SET _ch=SUBSTRING(_name,_i,1);
        IF _ch='^' THEN
            SET _i=_i+2;
        ELSE
            SET _i=_i+1;
            SET _ch=CASE _ch
                WHEN '0' THEN 'o' WHEN '1' THEN 'i' WHEN '3' THEN 'e'
                WHEN '4' THEN 'a' WHEN '5' THEN 's' WHEN '7' THEN 't'
                WHEN '@' THEN 'a' WHEN '$' THEN 's' WHEN '!' THEN 'i'
                ELSE _ch END;
            IF ASCII(_ch) BETWEEN 97 AND 122 AND CHAR_LENGTH(_ch)=OCTET_LENGTH(_ch) THEN
                IF _ch<>_last THEN SET _out=CONCAT(_out,_ch); END IF;
                SET _last=_ch;
            END IF;
        END IF;
    END WHILE;
    RETURN _out;
END//

CREATE FUNCTION blockedNameRule(_name VARCHAR(128) CHARACTER SET utf8mb4)
RETURNS INT READS SQL DATA
BEGIN
    DECLARE _normal VARCHAR(128) CHARACTER SET ascii;
    DECLARE _whole CHAR(64) CHARACTER SET ascii;
    DECLARE _size INT DEFAULT 1;
    DECLARE _pos INT;
    DECLARE _rule INT DEFAULT 0;
    SET _normal=normalizeModeratedName(_name);
    SET _whole=SHA2(_normal,256);
    SELECT COALESCE(MIN(r.ruleID),0) INTO _rule FROM nameModerationRules r
    WHERE r.enabled=1 AND r.nameHash=_whole
      AND NOT EXISTS (SELECT 1 FROM nameModerationExceptions e WHERE e.ruleID=r.ruleID AND e.nameHash=_whole);
    IF _rule<>0 THEN RETURN _rule; END IF;
    WHILE _size<=CHAR_LENGTH(_normal) DO
        IF EXISTS (SELECT 1 FROM nameModerationRules WHERE enabled=1 AND matchMode='contains' AND normalizedLength=_size) THEN
            SET _pos=1;
            WHILE _pos+_size-1<=CHAR_LENGTH(_normal) DO
                SELECT COALESCE(MIN(r.ruleID),0) INTO _rule FROM nameModerationRules r
                WHERE r.enabled=1 AND r.matchMode='contains' AND r.normalizedLength=_size
                  AND r.nameHash=SHA2(SUBSTRING(_normal,_pos,_size),256)
                  AND NOT EXISTS (SELECT 1 FROM nameModerationExceptions e WHERE e.ruleID=r.ruleID AND e.nameHash=_whole);
                IF _rule<>0 THEN RETURN _rule; END IF;
                SET _pos=_pos+1;
            END WHILE;
        END IF;
        SET _size=_size+1;
    END WHILE;
    RETURN 0;
END//

-- 0 changed; -1 unchanged; -2 invalid; -3 taken; -4 unknown player;
-- -5 blocked by policy; positive values are cooldown seconds remaining.
-- The account lock and unique index serialize changes across server instances.
CREATE FUNCTION setPreferredName(_playerID INT,_raw VARCHAR(128) CHARACTER SET utf8mb4)
RETURNS INT MODIFIES SQL DATA
BEGIN
    DECLARE _owner INT DEFAULT NULL;
    DECLARE _lock INT;
    DECLARE _name VARCHAR(128) CHARACTER SET utf8mb4;
    DECLARE _old VARCHAR(15) CHARACTER SET ascii;
    DECLARE _changed DATETIME(6);
    DECLARE _wait INT;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET _owner=NULL;
    DECLARE EXIT HANDLER FOR 1062 RETURN -3;
    SELECT singleton INTO _lock FROM preferredNameWriteLock WHERE singleton=1 FOR UPDATE;
    SELECT playerID INTO _owner FROM playerInformation WHERE playerID=_playerID FOR UPDATE;
    IF _owner IS NULL THEN RETURN -4; END IF;
    SET _name=TRIM(_raw);
    WHILE LOCATE('  ',_name)>0 DO SET _name=REPLACE(_name,'  ',' '); END WHILE;
    IF _name IS NOT NULL THEN
        IF CHAR_LENGTH(_name)<3 OR CHAR_LENGTH(_name)>15 OR
           NOT REGEXP_LIKE(_name,'^[ -~]+$','c') OR LOCATE('^',_name)>0 OR
           NOT REGEXP_LIKE(_name,'[a-zA-Z0-9]','c') THEN RETURN -2; END IF;
        IF blockedNameRule(_name)<>0 THEN RETURN -5; END IF;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM playerNamePreferences WHERE playerID=_playerID) THEN
        INSERT INTO playerNamePreferences(playerID) VALUES(_playerID);
    END IF;
    SELECT preferredName,changedAt INTO _old,_changed FROM playerNamePreferences WHERE playerID=_playerID;
    IF BINARY _name <=> BINARY _old THEN RETURN -1; END IF;
    IF _changed IS NOT NULL THEN
        SET _wait=3600-TIMESTAMPDIFF(SECOND,_changed,UTC_TIMESTAMP(6));
        IF _wait>0 THEN RETURN _wait; END IF;
    END IF;
    UPDATE playerNamePreferences SET preferredName=_name,changedAt=UTC_TIMESTAMP(6) WHERE playerID=_playerID;
    RETURN 0;
END//

CREATE FUNCTION resetPreferredNameByModerator(_actor INT,_target INT)
RETURNS INT MODIFIES SQL DATA
BEGIN
    DECLARE _level INT DEFAULT NULL;
    DECLARE _owner INT DEFAULT NULL;
    DECLARE _lock INT;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET _owner=NULL;
    SELECT singleton INTO _lock FROM preferredNameWriteLock WHERE singleton=1 FOR UPDATE;
    SELECT adminLevel INTO _level FROM playerInformation WHERE playerID=_actor;
    IF _level IS NULL OR _level<40 THEN RETURN -6; END IF;
    SELECT playerID INTO _owner FROM playerInformation WHERE playerID=_target FOR UPDATE;
    IF _owner IS NULL THEN RETURN -4; END IF;
    INSERT INTO playerNamePreferences(playerID,preferredName,changedAt)
    VALUES(_target,NULL,UTC_TIMESTAMP(6))
    ON DUPLICATE KEY UPDATE preferredName=NULL,changedAt=UTC_TIMESTAMP(6);
    RETURN 0;
END//
DELIMITER ;

CREATE OR REPLACE VIEW playerDisplayNames AS
SELECT p.playerID,COALESCE(n.preferredName,p.playerName) AS playerName
FROM playerInformation p LEFT JOIN playerNamePreferences n ON n.playerID=p.playerID;
