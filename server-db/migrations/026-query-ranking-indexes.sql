-- Checkpoint record queries filter cpID and seek the first time/RPG result.
-- Cover the narrow leaderboard projection as well; preserve all existing rows/keys.
ALTER TABLE checkpointStatistics
    ADD INDEX checkpoint_time (cpID, timePlayed, explosiveJumps, runID, loadCount, saveCount),
    ADD INDEX checkpoint_rpg (cpID, explosiveJumps, timePlayed, runID),
    ALGORITHM=INPLACE, LOCK=NONE;
