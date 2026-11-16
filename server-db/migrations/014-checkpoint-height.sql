-- Extra height above the existing landing plane/tolerance; bottom stays fixed.
-- Zero preserves every existing checkpoint's behavior.
ALTER TABLE checkpointAreas ADD COLUMN heightAbove FLOAT NOT NULL DEFAULT 0;
