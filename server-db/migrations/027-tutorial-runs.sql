-- Tutorial-mode runs, where the server sets the player's FPS, never rank.
-- The game marks a tutorial run before recording its finish; leaderboard,
-- record, finish-sound and challenge queries require tutorial = 0.
-- Existing runs were all played without tutorial mode and keep the default.
ALTER TABLE playerRuns
    ADD COLUMN tutorial TINYINT NOT NULL DEFAULT 0,
    ALGORITHM=INSTANT;
