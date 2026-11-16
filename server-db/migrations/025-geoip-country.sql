-- Country datasets are replaceable lookup data; player/history tables are untouched.
CREATE TABLE geoIPReleases (
    releaseID BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    provider VARCHAR(32) CHARACTER SET ascii NOT NULL,
    datasetVersion VARCHAR(32) CHARACTER SET ascii NOT NULL,
    sha256 CHAR(64) CHARACTER SET ascii NOT NULL,
    rangeCount INT UNSIGNED NOT NULL,
    addressCount BIGINT UNSIGNED NOT NULL,
    importedAt TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY geoIPReleaseIdentity(provider,datasetVersion,sha256)
) ENGINE=InnoDB;
CREATE TABLE geoIPRanges (
    releaseID BIGINT UNSIGNED NOT NULL,
    startIP INT UNSIGNED NOT NULL,
    endIP INT UNSIGNED NOT NULL,
    country CHAR(2) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    PRIMARY KEY(releaseID,startIP),
    CONSTRAINT geoIPRangeRelease FOREIGN KEY(releaseID) REFERENCES geoIPReleases(releaseID) ON DELETE CASCADE,
    CHECK(startIP<=endIP)
) ENGINE=InnoDB;
CREATE TABLE geoIPState (
    singleton TINYINT NOT NULL PRIMARY KEY,
    activeReleaseID BIGINT UNSIGNED NULL,
    CONSTRAINT geoIPActiveRelease FOREIGN KEY(activeReleaseID) REFERENCES geoIPReleases(releaseID),
    CHECK(singleton=1)
) ENGINE=InnoDB;
INSERT INTO geoIPState VALUES(1,NULL);

DELIMITER //
CREATE FUNCTION geoIPLookupCode(_ip INT UNSIGNED) RETURNS VARCHAR(32) CHARACTER SET ascii
READS SQL DATA SQL SECURITY DEFINER
BEGIN
    DECLARE _release BIGINT UNSIGNED DEFAULT NULL;
    DECLARE _end INT UNSIGNED DEFAULT NULL;
    DECLARE _country CHAR(2) DEFAULT NULL;
    IF _ip IS NULL THEN RETURN 'invalid_ip'; END IF;
    -- Local/shared/documentation/benchmark/multicast/reserved IPv4.
    -- 192.0.0.9 and .10 are globally reachable exceptions to 192.0.0.0/24.
    IF _ip<16777216 OR _ip BETWEEN 167772160 AND 184549375
        OR _ip BETWEEN 1681915904 AND 1686110207
        OR _ip BETWEEN 2130706432 AND 2147483647
        OR _ip BETWEEN 2851995648 AND 2852061183
        OR _ip BETWEEN 2886729728 AND 2887778303
        OR (_ip BETWEEN 3221225472 AND 3221225727 AND _ip NOT IN (3221225481,3221225482))
        OR _ip BETWEEN 3221225984 AND 3221226239
        OR _ip BETWEEN 3232235520 AND 3232301055
        OR _ip BETWEEN 3323068416 AND 3323199487
        OR _ip BETWEEN 3325256704 AND 3325256959
        OR _ip BETWEEN 3405803776 AND 3405804031
        OR _ip>=3758096384
    THEN RETURN 'non_public_ip'; END IF;
    SELECT activeReleaseID INTO _release FROM geoIPState WHERE singleton=1;
    IF _release IS NULL THEN RETURN 'database_unavailable'; END IF;
    SELECT endIP,country INTO _end,_country FROM geoIPRanges
        WHERE releaseID=_release AND startIP<=_ip ORDER BY startIP DESC LIMIT 1;
    IF _end IS NULL OR _ip>_end THEN RETURN 'range_not_found'; END IF;
    IF _country IN ('XX','ZZ') THEN RETURN 'country_not_reported'; END IF;
    RETURN _country;
END//

-- Preserve the legacy signature without the invented UK fallback or gap bug.
DROP FUNCTION IF EXISTS getCountry//
CREATE FUNCTION getCountry(_ip INT UNSIGNED) RETURNS CHAR(130) CHARACTER SET ascii
READS SQL DATA SQL SECURITY DEFINER
BEGIN
    DECLARE _country VARCHAR(32);
    DECLARE _name VARCHAR(128) DEFAULT 'Unknown';
    SET _country=geoIPLookupCode(_ip);
    IF CHAR_LENGTH(_country)<>2 THEN RETURN NULL; END IF;
    SELECT longCountry INTO _name FROM longCountry WHERE country=_country LIMIT 1;
    RETURN CONCAT(_country,COALESCE(_name,'Unknown'));
END//
DELIMITER ;
