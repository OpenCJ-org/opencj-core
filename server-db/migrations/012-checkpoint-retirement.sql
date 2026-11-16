-- Retain removed checkpoint IDs and historical statistics, excluding them from the live graph.
ALTER TABLE checkpoints ADD COLUMN retired TINYINT NOT NULL DEFAULT 0;
