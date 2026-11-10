-- #203: initial shared alpha pool and historical mapper/release metadata.
-- Apply to openCJ_cod4 only. Re-running restores this initial ten-map pool;
-- later pool maintenance should UPDATE mapids.inRotation instead.
-- Resolve existing IDs by name; never replace maps or their dependent records.
-- Futile uses its original release, not the OpenCJ repair date.
CREATE TEMPORARY TABLE alphaMapMetadata (
    mapname CHAR(128) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
    releaseDate DATE NOT NULL,
    mapperName CHAR(128) CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci NOT NULL
);
INSERT INTO alphaMapMetadata (mapname, releaseDate, mapperName) VALUES
    ('mp_dark', '2012-01-02', 'kie'),
    ('mp_cj_sky_bounce', '2013-04-24', 'SoBerries'),
    ('mp_all_in', '2010-06-11', 'all_in'),
    ('mp_bouncer_training', '2010-01-26', '[TB]Mike'),
    ('mp_futile_fixed', '2013-01-24', 'pcbouncer'),
    ('mp_blue2', '2013-05-14', 'Chucky.'),
    ('mp_descent_v2', '2014-02-02', '=.VaRtaZiaN.='),
    ('mp_to_the_moon', '2011-11-11', '=.VaRtaZiaN.='),
    ('mp_galaxy', '2015-01-02', 'ZeeZ'),
    ('mp_mystic_v3', '2013-10-25', 'Wez');

START TRANSACTION;

INSERT INTO mapids (mapname, releaseDate, inRotation)
SELECT seed.mapname, seed.releaseDate, 1
FROM alphaMapMetadata seed LEFT JOIN mapids m ON m.mapname = seed.mapname
WHERE m.mapID IS NULL;

UPDATE mapids m LEFT JOIN alphaMapMetadata seed ON seed.mapname = m.mapname
SET m.inRotation = (seed.mapname IS NOT NULL),
    m.releaseDate = CASE WHEN seed.mapname IS NOT NULL THEN seed.releaseDate ELSE m.releaseDate END;

INSERT INTO mappers (name)
SELECT DISTINCT seed.mapperName
FROM alphaMapMetadata seed LEFT JOIN mappers a ON a.name = seed.mapperName
WHERE a.mapperID IS NULL;

INSERT INTO mapMappers (mapID, mapperID)
SELECT m.mapID, a.mapperID
FROM alphaMapMetadata seed
JOIN mapids m ON m.mapname = seed.mapname
JOIN mappers a ON a.name = seed.mapperName
LEFT JOIN mapMappers existing ON existing.mapID = m.mapID AND existing.mapperID = a.mapperID
WHERE existing.mapID IS NULL;

COMMIT;
DROP TEMPORARY TABLE alphaMapMetadata;
