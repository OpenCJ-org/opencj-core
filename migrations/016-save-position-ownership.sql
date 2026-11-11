-- #192: distinguish ownership from affected-row count and serialize duplicate saves.
-- No player data or table structure is changed.
DROP FUNCTION IF EXISTS savePosition;
DELIMITER //
CREATE FUNCTION `savePosition`(
	`_runID` INT,
	`_instanceNumber` INT,
	`_x` DECIMAL(10,4),
	`_y` DECIMAL(10,4),
	`_z` DECIMAL(10,4),
	`_alpha` INT,
	`_beta` INT,
	`_gamma` INT,
	`_timePlayed` INT,
	`_saveCount` INT,
	`_loadCount` INT,
	`_explosiveLaunches` INT,
	`_explosiveJumps` INT,
	`_doubleExplosives` INT,
	`_checkpointID` INT,
	`_FPSMode` ENUM('125','mix', 'hax'),
	`_flags` INT,
	`_entTargetName` CHAR(64),
	`_numOfEnt` INT
) RETURNS int
MODIFIES SQL DATA
BEGIN
    DECLARE _owner INT DEFAULT NULL;
    DECLARE _savedCount INT DEFAULT NULL;
    DECLARE _saveNumber INT DEFAULT NULL;

    -- Lock the owning run for the whole statement, including save numbering.
    SELECT instanceNumber, saveCount INTO _owner, _savedCount
    FROM playerRuns WHERE runID = _runID FOR UPDATE;
    IF _owner IS NULL OR _owner <> _instanceNumber THEN
        RETURN NULL;
    END IF;

    -- Only an identical latest save is a replay. Checkpoints also update the
    -- run counters, so matching saveCount alone must not discard a new position.
    IF _saveCount = _savedCount AND EXISTS (
        SELECT 1 FROM playerRuns
        WHERE runID = _runID AND timePlayed = _timePlayed
          AND loadCount = _loadCount AND explosiveLaunches = _explosiveLaunches
    ) AND EXISTS (
        SELECT 1 FROM playerSaves
        WHERE runID = _runID
          AND saveNumber = (SELECT MAX(s.saveNumber) FROM playerSaves s WHERE s.runID = _runID)
          AND x <=> _x AND y <=> _y AND z <=> _z
          AND alpha <=> _alpha AND beta <=> _beta AND gamma <=> _gamma
          AND explosiveJumps <=> _explosiveJumps AND doubleExplosives <=> _doubleExplosives
          AND checkpointID <=> _checkpointID AND FPSMode <=> _FPSMode
          AND flags <=> _flags AND entTargetName <=> _entTargetName AND numOfEnt <=> _numOfEnt
    ) THEN
        RETURN _instanceNumber;
    END IF;

    UPDATE playerRuns
    SET timePlayed = _timePlayed, saveCount = _saveCount,
        loadCount = _loadCount, explosiveLaunches = _explosiveLaunches
    WHERE runID = _runID;
    SELECT COALESCE(MAX(saveNumber) + 1, 0) INTO _saveNumber
    FROM playerSaves WHERE runID = _runID;
    INSERT INTO playerSaves
        (saveNumber, runID, x, y, z, alpha, beta, gamma, explosiveJumps,
         doubleExplosives, checkpointID, FPSMode, flags, entTargetName, numOfEnt)
    VALUES
        (_saveNumber, _runID, _x, _y, _z, _alpha, _beta, _gamma, _explosiveJumps,
         _doubleExplosives, _checkpointID, _FPSMode, _flags, _entTargetName, _numOfEnt);
    RETURN _instanceNumber;
END//
DELIMITER ;
