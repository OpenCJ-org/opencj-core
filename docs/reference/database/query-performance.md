# Query performance

The query changes below preserve eligibility, returned fields, category rules, counts and paging, while making exact-tie selection explicit. They add no caching interval and delete no player history.

## Changes

- Runs board: select the owner's maximum saveNumber using the existing unique
  (runID, saveNumber) index, rather than numbering every save for the map. Mode
  and FPS filters apply after the latest save is selected. Runs without saves,
  archived/finished runs, other owners/maps and the active run remain excluded.
- Leaderboard and checkpoint records HUD: rank a narrow projection from a
  covering checkpoint index, page the winners, then fetch names and extra run
  fields for only the displayed rows. The original eligible rows, selected
  metrics, mode/FPS filters, counts and pagination remain the reference.
  Exact ties now explicitly prefer the oldest run (runID), then lowest checkpoint
  ID when two checkpoint rows from that run tie. This follows the finish-ranking
  convention and prevents access-plan changes selecting a different tied run.
- Finish sound: test whether the candidate is its player's best and fewer than
  three distinct players are better, for each metric. Three qualifying opponents
  are enough to reject a podium place. Older run IDs still win exact ties.
- Finish notices: reuse the eligible set and select four top-one results
  (server/personal by time/RPG). Exact mode categories and retired-route checks
  remain unchanged.
- Checkpoint notices: seek the first result in checkpoint/metric/run-ID order.
  Migration 026 adds checkpoint_time (also covering load/save counts) and checkpoint_rpg indexes. Ordering by
  cs.runID equals ordering by r.runID because the inner join equates them.

The old leaderboard/HUD query did not define which run to display when every
ranking key tied. A join-only optimization exposed that ambiguity through
different displayed load counts. The final queries resolve it explicitly rather
than preserving an accidental query-plan choice. Competitive values and eligibility
do not change; the representative run for an exact tie is now stable. This can
replace a formerly arbitrary tied row with the oldest matching row.

The frozen-query reference tests append only these tie-breaks to the original
leaderboard/HUD SQL, then compare every returned field with the optimized query.
They do not pretend the original SQL guaranteed the same arbitrary tie choice.
Runs-board latest-save selection and finish-sound/notice tie rules are unchanged.

## Audit scope

Reviewed GSC SQL call sites, the native binary demo chunk reads/writes, and the
savePosition, historyLoad, checkpointPassed, runFinished and publishDemo routines.

Frequent save/load/restore paths use primary/unique indexes; these routines and
their ownership locks were retained. Native demo transfers remain bounded,
ordered batches with the same publication transaction and integrity checks.
Challenge award writes, points and shop ownership logic were not changed.
Representative challenge/menu totals, map/settings reads, and cleanup selection
plans were inspected and timed. Checkpoint-authoring/admin graph writes and
startup catalogue/name-rule reads were reviewed for access patterns, but are not
claimed as a mature public-load benchmark.

The growth fixture does not model millions of retained clips or challenge awards.
Challenge totals still aggregate account awards; record lists still process the
selected checkpoint's history. These are growth costs to monitor, not an assertion
that every future dataset fits two cores.
