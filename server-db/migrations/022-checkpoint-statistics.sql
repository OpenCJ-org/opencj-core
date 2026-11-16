-- Keep all fields from the same checkpoint pass. Ownership remains locked
-- until the function statement completes; older/equal passes stay unchanged.
DROP FUNCTION checkpointPassed;
DELIMITER //
CREATE FUNCTION `checkpointPassed`(
	`_runID` INT,
	`_cpID` INT,
	`_timePlayed` INT,
	`_saveCount` INT,
	`_loadCount` INT,
	`_explosiveJumps` INT,
	`_explosiveLaunches` INT,
	`_doubleExplosives` INT,
	`_FPSMode` ENUM('125','mix','hax'),
	`_usedEle` TINYINT,
	`_usedAnyPct` TINYINT,
	`_usedTAS` TINYINT,
	`__instanceNumber` INT
) RETURNS int
BEGIN
	DECLARE _instanceNumber INT DEFAULT NULL;
	SELECT instanceNumber INTO _instanceNumber FROM playerRuns WHERE runID = _runID FOR UPDATE;
	IF(__instanceNumber = _instanceNumber) THEN
		INSERT INTO checkpointStatistics (cpID, runID, timePlayed, saveCount, loadCount, explosiveJumps, explosiveLaunches, doubleExplosives, FPSMode, ele, anyPct, hardTAS) VALUES
		(_cpID, _runID, _timePlayed, _saveCount, _loadCount, _explosiveJumps, _explosiveLaunches, _doubleExplosives, _FPSMode, _usedEle, _usedAnyPct, _usedTAS) ON DUPLICATE KEY UPDATE
		saveCount = IF(timePlayed < _timePlayed, _saveCount, saveCount),
		loadCount = IF(timePlayed < _timePlayed, _loadCount, loadCount),
		explosiveJumps = IF(timePlayed < _timePlayed, _explosiveJumps, explosiveJumps),
		explosiveLaunches = IF(timePlayed < _timePlayed, _explosiveLaunches, explosiveLaunches),
		doubleExplosives = IF(timePlayed < _timePlayed, _doubleExplosives, doubleExplosives),
		FPSMode = IF(timePlayed < _timePlayed, _FPSMode, FPSMode),
		ele = IF(timePlayed < _timePlayed, _usedEle, ele),
		anyPct = IF(timePlayed < _timePlayed, _usedAnyPct, anyPct),
		hardTAS = IF(timePlayed < _timePlayed, _usedTAS, hardTAS),
		timePlayed = IF(timePlayed < _timePlayed, _timePlayed, timePlayed);
		RETURN _instanceNumber;
	END IF;
	RETURN NULL;
END//
DELIMITER ;
