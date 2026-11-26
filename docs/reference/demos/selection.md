# Automatic demo selection

## Agreed behavior

No route chooser. A player can request help at a shared starting checkpoint
without first entering a route.

- `!demo` / `!demo wt`: choose an available walkthrough covering the physical
  checkpoint. Across shared routes, prefer fewer RPG shots in the matching
  segment, then fewer successful recorded samples. Exact ties keep the stable
  database ordering. This measures the segment before walkthrough compaction.
- `!srdemo` / `!demo sr`: choose the fastest compatible retained speedrun that
  actually covers the checkpoint. Outside a checkpoint, look for a recorded
  passage within the existing 256-unit spatial radius, across routes on this map.
  Playback starts at that segment. Speedrun ranking uses full-run completion time.
- `!demo rpg`: keep low-RPG winner ordering, skipping candidates that do not
  cover the physical checkpoint.
- Walkthrough/low-RPG requests outside a checkpoint ask the player to stand in
  one. Missing recordings give a local no-match message, never a route chooser.
- Existing FPS and run-mode filters still apply. Walkthroughs use clean modes;
  hax viewers use mix walkthroughs.
- Selection uses physical checkpoint pieces, normalized to their shared parent.
  It does not read a stale route to exclude other shared-start choices or modify
  checkpoint/run progress. Leaderboard selections still play the full recording.
- `!srdemo` is registered through the normal command registry, so it appears
  automatically in the command/help menu.

## Implementation

`server-gsc/opencj/demos.gsc` captures a location, queries retained winners for
all reachable routes, and checks their actual recorded segments. It retains at
most the best candidate plus the candidate being examined. Failed loads and
rejected candidates release their cache references. Cancellation/disconnect
release both pending and selected references. Playback reuses the selected
recording and range instead of loading it again.

`server-ext/opencj_demo.cpp` extends `demoFindSegment` with an optional sixth
argument: strict location matching. The original four/five-argument Any% calls
retain their whole-run fallback; automatic selection disables that fallback.
The first two return fields remain start/end frame; fields 2 and 3 contain the
segment's RPG-shot count and sample count, honoring the skip-failed-frames flag.

This uses existing `demoWinners` / `demoRuns` / `demoChunks` data. It does not
create demos, index new variations, migrate the schema, or change retained
recordings. Availability still depends on compatible recordings being retained.
