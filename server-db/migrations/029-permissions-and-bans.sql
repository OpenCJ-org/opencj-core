-- Replace numeric admin levels with independent permission bits, and add bans.
-- docs/reference/permissions.md lists every bit; server-gsc/opencj/permissions.gsc
-- uses the same numbers. Bit 0 is uber-admin: it implies every permission and can
-- only be set directly in the database, never through the game.
--
-- Only uber-admins (old level 100 or higher) keep access. Lower levels are cleared
-- because they do not map onto the new individual permissions; grant those again
-- in the game with !permissions grant.
UPDATE playerInformation
SET adminLevel = IF(adminLevel >= 100, 1, 0);

-- lastIP and lastClientID record what an account last connected with, so a ban on
-- an offline account can also cover its address and CoD4x player ID.
ALTER TABLE playerInformation
    CHANGE COLUMN adminLevel permissions INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN lastIP VARCHAR(45) CHARACTER SET ascii COLLATE ascii_bin NULL,
    ADD COLUMN lastClientID VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NULL;

-- One row per permission granted or revoked in the game.
CREATE TABLE permissionChanges (
    changeID INT UNSIGNED NOT NULL AUTO_INCREMENT,
    actorPlayerID INT NOT NULL,
    targetPlayerID INT NOT NULL,
    permissionBit TINYINT UNSIGNED NOT NULL,
    granted BOOLEAN NOT NULL,
    changedAt DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
    PRIMARY KEY (changeID),
    KEY permission_changes_by_target (targetPlayerID, changedAt),
    CONSTRAINT permission_change_actor FOREIGN KEY (actorPlayerID)
        REFERENCES playerInformation (playerID),
    CONSTRAINT permission_change_target FOREIGN KEY (targetPlayerID)
        REFERENCES playerInformation (playerID)
) ENGINE=InnoDB;

-- Every ban ever made. A ban is active while liftedAt is NULL and expiresAt is
-- NULL (permanent) or in the future. Rows are kept after expiry or lifting.
CREATE TABLE playerBans (
    banID INT UNSIGNED NOT NULL AUTO_INCREMENT,
    bannedPlayerID INT NOT NULL,
    bannedIP VARCHAR(45) CHARACTER SET ascii COLLATE ascii_bin NULL,
    bannedClientID VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NULL,
    expiresAt DATETIME(6) NULL,
    reason VARCHAR(150) NOT NULL,
    bannedByPlayerID INT NOT NULL,
    createdAt DATETIME(6) NOT NULL DEFAULT (UTC_TIMESTAMP(6)),
    liftedAt DATETIME(6) NULL,
    liftedByPlayerID INT NULL,
    PRIMARY KEY (banID),
    KEY player_bans_by_player (bannedPlayerID, liftedAt),
    KEY player_bans_by_ip (bannedIP),
    KEY player_bans_by_client (bannedClientID),
    CONSTRAINT player_ban_reason CHECK (CHAR_LENGTH(TRIM(reason)) > 0),
    CONSTRAINT player_ban_target FOREIGN KEY (bannedPlayerID)
        REFERENCES playerInformation (playerID),
    CONSTRAINT player_ban_actor FOREIGN KEY (bannedByPlayerID)
        REFERENCES playerInformation (playerID),
    CONSTRAINT player_ban_lifter FOREIGN KEY (liftedByPlayerID)
        REFERENCES playerInformation (playerID)
) ENGINE=InnoDB;

DROP FUNCTION IF EXISTS resetPreferredNameByModerator;

DELIMITER //

-- True when the account holds the uber bit (bit 0) or the requested bit.
CREATE FUNCTION playerHasPermission(_playerID INT, _permissionBit INT)
RETURNS BOOLEAN READS SQL DATA
BEGIN
    DECLARE _permissions INT UNSIGNED DEFAULT NULL;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET _permissions = NULL;
    SELECT permissions INTO _permissions
    FROM playerInformation
    WHERE playerID = _playerID;
    IF _permissions IS NULL THEN
        RETURN FALSE;
    END IF;
    RETURN (_permissions & 1) <> 0 OR (_permissions & (1 << _permissionBit)) <> 0;
END//

-- Grant (_grant = TRUE) or revoke one permission bit and record the change.
-- Returns the target's new permissions (zero or more), or a negative code:
--   -1 bit outside 1-30          -5 only uber may change perms (bit 1)
--   -2 uber bit is database-only -6 target account does not exist
--   -3 actor lacks perms (bit 1) -7 target is an uber-admin
--   -4 actor lacks that bit      -8 target already in the requested state
-- The game checks the same rules for clear messages; this function is the authority.
CREATE FUNCTION setPlayerPermission(_actor INT, _target INT, _permissionBit INT, _grant BOOLEAN)
RETURNS INT MODIFIES SQL DATA
BEGIN
    DECLARE _uberBit INT DEFAULT 0;
    DECLARE _permsBit INT DEFAULT 1;
    DECLARE _highestUsableBitIndex INT DEFAULT 30;
    DECLARE _lockedRows INT;
    DECLARE _actorPermissions INT UNSIGNED DEFAULT NULL;
    DECLARE _targetPermissions INT UNSIGNED DEFAULT NULL;
    DECLARE _actorIsUber BOOLEAN;
    DECLARE _flag INT UNSIGNED;
    DECLARE _newPermissions INT UNSIGNED;
    -- A missing account leaves its variable NULL; the checks below report it.
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    IF _permissionBit = _uberBit THEN
        RETURN -2;
    END IF;
    IF _permissionBit IS NULL OR _permissionBit < 1 OR _permissionBit > _highestUsableBitIndex THEN
        RETURN -1;
    END IF;

    -- Lock both accounts in primary-key order so two simultaneous changes between
    -- the same accounts cannot deadlock, and neither can act on stale permissions.
    SELECT COUNT(*) INTO _lockedRows
    FROM playerInformation
    WHERE playerID IN (_actor, _target)
    FOR UPDATE;

    SELECT permissions INTO _actorPermissions
    FROM playerInformation
    WHERE playerID = _actor;
    SELECT permissions INTO _targetPermissions
    FROM playerInformation
    WHERE playerID = _target;

    SET _actorIsUber = _actorPermissions IS NOT NULL AND (_actorPermissions & 1) <> 0;
    IF NOT _actorIsUber THEN
        IF _actorPermissions IS NULL OR (_actorPermissions & (1 << _permsBit)) = 0 THEN
            RETURN -3;
        END IF;
        IF _permissionBit = _permsBit THEN
            RETURN -5;
        END IF;
        IF (_actorPermissions & (1 << _permissionBit)) = 0 THEN
            RETURN -4;
        END IF;
    END IF;
    IF _targetPermissions IS NULL THEN
        RETURN -6;
    END IF;
    IF NOT _actorIsUber AND (_targetPermissions & 1) <> 0 THEN
        RETURN -7;
    END IF;

    SET _flag = 1 << _permissionBit;
    IF _grant THEN
        SET _newPermissions = _targetPermissions | _flag;
    ELSE
        SET _newPermissions = _targetPermissions & ~_flag;
    END IF;
    IF _newPermissions = _targetPermissions THEN
        RETURN -8;
    END IF;

    UPDATE playerInformation
    SET permissions = _newPermissions
    WHERE playerID = _target;
    INSERT INTO permissionChanges (actorPlayerID, targetPlayerID, permissionBit, granted)
    VALUES (_actor, _target, _permissionBit, _grant);
    RETURN _newPermissions;
END//

-- Same behavior as migration 017, except that the moderator check now uses the
-- names permission (bit 4), and only an uber-admin may reset an uber-admin's name.
CREATE FUNCTION resetPreferredNameByModerator(_actor INT, _target INT)
RETURNS INT MODIFIES SQL DATA
BEGIN
    DECLARE _uberBit INT DEFAULT 0;
    DECLARE _namesBit INT DEFAULT 4;
    DECLARE _owner INT DEFAULT NULL;
    DECLARE _lock INT;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET _owner = NULL;
    SELECT singleton INTO _lock FROM preferredNameWriteLock WHERE singleton = 1 FOR UPDATE;
    IF NOT playerHasPermission(_actor, _namesBit) THEN
        RETURN -6;
    END IF;
    SELECT playerID INTO _owner FROM playerInformation WHERE playerID = _target FOR UPDATE;
    IF _owner IS NULL THEN
        RETURN -4;
    END IF;
    IF playerHasPermission(_target, _uberBit) AND NOT playerHasPermission(_actor, _uberBit) THEN
        RETURN -6;
    END IF;
    INSERT INTO playerNamePreferences (playerID, preferredName, changedAt)
    VALUES (_target, NULL, UTC_TIMESTAMP(6))
    ON DUPLICATE KEY UPDATE preferredName = NULL, changedAt = UTC_TIMESTAMP(6);
    RETURN 0;
END//

-- Ban an account, plus the IP address and CoD4x player ID it last used.
-- _durationSeconds NULL is a permanent ban (uber-admins only); otherwise a
-- temporary ban of 1 minute to 7 days (tempban permission, bit 8).
-- A new ban replaces the account's active bans, but a temporary ban never
-- replaces a permanent one. Returns the new banID, or a negative code:
--   -1 actor not allowed         -5 target is an uber-admin
--   -2 duration outside 60s-7d   -6 actor and target are the same account
--   -3 reason empty or too long  -7 an active permanent ban stands
--   -4 target account does not exist
CREATE FUNCTION banPlayer(_actor INT, _target INT, _durationSeconds INT,
                          _reason VARCHAR(255))
RETURNS INT MODIFIES SQL DATA
BEGIN
    DECLARE _uberBit INT DEFAULT 0;
    DECLARE _tempBanBit INT DEFAULT 8;
    DECLARE _minimumSeconds INT DEFAULT 60;
    DECLARE _maximumSeconds INT DEFAULT 7 * 24 * 60 * 60;
    DECLARE _maximumReasonLength INT DEFAULT 150;
    DECLARE _lockedRows INT;
    DECLARE _targetExists INT DEFAULT 0;
    DECLARE _targetIP VARCHAR(45) DEFAULT NULL;
    DECLARE _targetClientID VARCHAR(32) DEFAULT NULL;
    DECLARE _permanentBanCount INT DEFAULT 0;
    DECLARE _isPermanent BOOLEAN;
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    SET _isPermanent = _durationSeconds IS NULL;
    IF _actor = _target THEN
        RETURN -6;
    END IF;
    IF _isPermanent AND NOT playerHasPermission(_actor, _uberBit) THEN
        RETURN -1;
    END IF;
    IF NOT _isPermanent AND NOT playerHasPermission(_actor, _tempBanBit) THEN
        RETURN -1;
    END IF;
    IF NOT _isPermanent AND
       (_durationSeconds < _minimumSeconds OR _durationSeconds > _maximumSeconds) THEN
        RETURN -2;
    END IF;
    IF _reason IS NULL OR CHAR_LENGTH(TRIM(_reason)) = 0 OR
       CHAR_LENGTH(_reason) > _maximumReasonLength THEN
        RETURN -3;
    END IF;

    -- Lock both accounts in primary-key order (see setPlayerPermission), so the
    -- target's permissions and bans cannot change while this ban is decided.
    SELECT COUNT(*) INTO _lockedRows
    FROM playerInformation
    WHERE playerID IN (_actor, _target)
    FOR UPDATE;
    SELECT 1, lastIP, lastClientID INTO _targetExists, _targetIP, _targetClientID
    FROM playerInformation
    WHERE playerID = _target;
    IF _targetExists = 0 THEN
        RETURN -4;
    END IF;
    IF playerHasPermission(_target, _uberBit) AND NOT playerHasPermission(_actor, _uberBit) THEN
        RETURN -5;
    END IF;

    SELECT COUNT(*) INTO _permanentBanCount
    FROM playerBans
    WHERE bannedPlayerID = _target AND liftedAt IS NULL AND expiresAt IS NULL;
    IF NOT _isPermanent AND _permanentBanCount > 0 THEN
        RETURN -7;
    END IF;

    UPDATE playerBans
    SET liftedAt = UTC_TIMESTAMP(6), liftedByPlayerID = _actor
    WHERE bannedPlayerID = _target
      AND liftedAt IS NULL
      AND (expiresAt IS NULL OR expiresAt > UTC_TIMESTAMP(6));
    INSERT INTO playerBans (bannedPlayerID, bannedIP, bannedClientID, expiresAt, reason,
                            bannedByPlayerID)
    VALUES (_target, _targetIP, _targetClientID,
            IF(_isPermanent, NULL, UTC_TIMESTAMP(6) + INTERVAL _durationSeconds SECOND),
            _reason, _actor);
    RETURN LAST_INSERT_ID();
END//

-- Lift an account's active temporary (_permanent = FALSE, tempban permission) or
-- permanent (_permanent = TRUE, uber-admins only) bans. Returns how many bans were
-- lifted, or a negative code: -1 actor not allowed, -4 target account does not
-- exist, -8 no active ban of that kind.
CREATE FUNCTION liftPlayerBan(_actor INT, _target INT, _permanent BOOLEAN)
RETURNS INT MODIFIES SQL DATA
BEGIN
    DECLARE _uberBit INT DEFAULT 0;
    DECLARE _tempBanBit INT DEFAULT 8;
    DECLARE _targetExists INT DEFAULT 0;
    DECLARE _liftedCount INT;
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    IF _permanent AND NOT playerHasPermission(_actor, _uberBit) THEN
        RETURN -1;
    END IF;
    IF NOT _permanent AND NOT playerHasPermission(_actor, _tempBanBit) THEN
        RETURN -1;
    END IF;
    SELECT 1 INTO _targetExists
    FROM playerInformation
    WHERE playerID = _target
    FOR UPDATE;
    IF _targetExists = 0 THEN
        RETURN -4;
    END IF;

    UPDATE playerBans
    SET liftedAt = UTC_TIMESTAMP(6), liftedByPlayerID = _actor
    WHERE bannedPlayerID = _target
      AND liftedAt IS NULL
      AND ((_permanent AND expiresAt IS NULL) OR
           (NOT _permanent AND expiresAt > UTC_TIMESTAMP(6)));
    SET _liftedCount = ROW_COUNT();
    IF _liftedCount = 0 THEN
        RETURN -8;
    END IF;
    RETURN _liftedCount;
END//

DELIMITER ;
