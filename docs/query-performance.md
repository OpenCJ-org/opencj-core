# Query performance and two-core hosting

The November 2026 hosting probe exposed CPU saturation in MySQL as saved history
grew. Game ticks remained steady, but menus expired and recordings queued behind
the reads. The fixes preserve query eligibility, returned fields, category rules,
existing ranking metrics, counts, and paging, with explicit exact-tie selection. They add no caching interval
and delete no player history.

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

## Reproducing validation

Run on the authoritative Linux host from dev-tools. The runner reads only the
live schema and creates separate synthetic MySQL/game containers; no live game
restart or player-data copy is performed by the tests.

    python3 tests/run-query-capacity.py --mature --seconds 60
    python3 tests/run-query-capacity.py --mature --extended-reads --seconds 60

Use --scripts with a prepared release tree to validate the exact deployed scripts.
--cpu-set defaults to physical cores 4,5 on the research host; verify topology on
another host. Both containers share that set. The game limit is 1 GiB; MySQL is
1.5 GiB, with a 512 MiB buffer pool and 64 MiB temporary-table RAM setting, swap off.
The runner imports the current schema and applies 026 only if its indexes are not
already present. Legacy route-name publication fault-injection fixtures are
excluded; this test checks current-schema upload completion and chunk integrity.

The standard workload is 32 synthetic clients, approximately 3.2 menu requests/s,
5.3 progress saves/s, simultaneous clip uploads, ten-minute recording buffers,
cold playback, 32 completed-run uploads and shared playback. --extended-reads adds
about 1.6 records/finish reads/s plus checkpoint notices during each gameplay
phase. It does not simulate player networking, client rendering or every callback.

The fixture contains roughly 281,000 runs, 2.02 million saves, 260,000 checkpoint
statistics, 10,000 players and 101 maps, including one deliberately popular map.
Resource measurements during seeding must not be confused with gameplay CPU use.

Frozen original GSC SQL expressions live in tests/fixtures/query-performance-before.json.
query-equivalence.py and query-rank-equivalence.py compare original/current queries
against synthetic edge cases; both require an explicitly named disposable DB.
Never point these fixture-writing tests at a live database.

## Deployment

Back up and restore-check through scripts/backup.py, stop OpenCJ writers after the
player/map guard, then apply through server-db/tools/migrate.py. Migration 026 only
adds two nonunique indexes; no routines, grants, columns or player records change.
Deploy only the five task-owned GSC files over the current runtime release.
Preserve unrelated deployed scripts and the current native executable. Restart
and restore the captured map, then verify startup and database errors.

## Accepted result and deployment

Applied 16 November 2026; mp_cj_sky_bounce restored. The server was already stopped
by its scheduled shutdown when work began. Backup was restore-verified at
backups/2026-11-16_17h44m. Migration 026 preserved checksums for all
43 existing gameplay base tables (the migration ledger intentionally gains 026).
The five-script overlay preserves the prior release and native executable.
All six live query builders succeeded; startup showed no script/SQL errors.

Validation: 3,101 menu/history/checkpoint comparisons, including independent
oldest-run/load/count assertions for exact ties, and 706 finish-category/tie
checks. The final extended integration test passed 41,708 checks with zero
failures. All 32 completed recordings published within about 11.1 seconds.

During the final 261.925-second game-container window:
- MySQL: 0.5725 average cores; engine: 0.0809, sharing two cores.
- Menu completion p95: 250-305 ms across phases; save p95 <=56 ms.
- Game frame p99 <=56 ms; maximum 60 ms; no interval above 75 ms.
- Combined sampled cgroup memory peak: 1,836.61 MiB; no OOM/kill.
  MySQL reclaimed cache at its 1.5 GiB cap; this is not a measured 4 GiB VM.

Repeated mature-fixture SQL timings: runs ~1.7-2.2 ms, leaderboard/HUD ~242-247 ms,
checkpoint notices ~1.5 ms, tested non-podium sound ~2-5 ms, finish notices ~147 ms.
Record-winning sound checks can do more work than an early rejected candidate.

The earlier failing probe averaged 1.85 MySQL cores, with ~3.1-second menu p95.
That probe used approximate menu projections and included concurrent diagnostics;
the final test uses full current query text and adds records/finish/checkpoint
reads. Treat this as workload evidence, not a controlled hardware speed ratio
or a netcup network/CPU benchmark. No query/pruning policy can guarantee arbitrary
future growth on a fixed server.
