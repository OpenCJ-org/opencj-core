-- NULL preserves existing stationary geometry. References resolve once per map.
ALTER TABLE checkpointAreas ADD COLUMN platformRef VARCHAR(101) CHARACTER SET ascii COLLATE ascii_bin NULL;
