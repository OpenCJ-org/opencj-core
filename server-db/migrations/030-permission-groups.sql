-- Grant or revoke several permission bits in one call, so a permission group such as
-- "mod" (see docs/reference/permissions.md) changes all its members or none.
-- Replaces 029's single-bit setPlayerPermission; the rules are unchanged and apply
-- to every bit in the request. No stored data changes.
DROP FUNCTION IF EXISTS setPlayerPermission;

DELIMITER //

-- Grant (_grant = TRUE) or revoke the bits in _mask and record each changed bit.
-- Returns the target's new permissions (zero or more), or a negative code:
--   -1 mask empty or outside bits 1-30   -5 only uber may change perms (bit 1)
--   -2 mask includes the uber bit         -6 target account does not exist
--   -3 actor lacks perms (bit 1)          -7 target is an uber-admin
--   -4 actor lacks one of the bits        -8 nothing would change
-- The game checks the same rules for clear messages; this function is the authority.
CREATE FUNCTION setPlayerPermissions(_actor INT, _target INT, _mask BIGINT UNSIGNED,
                                     _grant BOOLEAN)
RETURNS INT MODIFIES SQL DATA
BEGIN
    DECLARE _uberBit INT DEFAULT 0;
    DECLARE _permsBit INT DEFAULT 1;
    DECLARE _highestUsableBitIndex INT DEFAULT 30;
    DECLARE _usableMask BIGINT UNSIGNED;
    DECLARE _lockedRows INT;
    DECLARE _actorPermissions INT UNSIGNED DEFAULT NULL;
    DECLARE _targetPermissions INT UNSIGNED DEFAULT NULL;
    DECLARE _actorIsUber BOOLEAN;
    DECLARE _newPermissions INT UNSIGNED;
    DECLARE _changedMask BIGINT UNSIGNED;
    DECLARE _bitIndex INT DEFAULT 1;
    -- A missing account leaves its variable NULL; the checks below report it.
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    IF _mask IS NULL OR _mask = 0 THEN
        RETURN -1;
    END IF;
    IF (_mask & (1 << _uberBit)) <> 0 THEN
        RETURN -2;
    END IF;
    -- Bits 1-30 only: bit 0 is uber and bit 31 would be negative in GSC.
    SET _usableMask = ((1 << (_highestUsableBitIndex + 1)) - 1) & ~(1 << _uberBit);
    IF (_mask & ~_usableMask) <> 0 THEN
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
        IF (_mask & (1 << _permsBit)) <> 0 THEN
            RETURN -5;
        END IF;
        IF (_actorPermissions & _mask) <> _mask THEN
            RETURN -4;
        END IF;
    END IF;
    IF _targetPermissions IS NULL THEN
        RETURN -6;
    END IF;
    IF NOT _actorIsUber AND (_targetPermissions & 1) <> 0 THEN
        RETURN -7;
    END IF;

    IF _grant THEN
        SET _newPermissions = _targetPermissions | _mask;
    ELSE
        SET _newPermissions = _targetPermissions & ~_mask;
    END IF;
    IF _newPermissions = _targetPermissions THEN
        RETURN -8;
    END IF;

    UPDATE playerInformation
    SET permissions = _newPermissions
    WHERE playerID = _target;
    SET _changedMask = _targetPermissions ^ _newPermissions;
    WHILE _bitIndex <= _highestUsableBitIndex DO
        IF (_changedMask & (1 << _bitIndex)) <> 0 THEN
            INSERT INTO permissionChanges (actorPlayerID, targetPlayerID, permissionBit, granted)
            VALUES (_actor, _target, _bitIndex, _grant);
        END IF;
        SET _bitIndex = _bitIndex + 1;
    END WHILE;
    RETURN _newPermissions;
END//

DELIMITER ;
