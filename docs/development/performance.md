# Performance workloads

## Workload and isolation

Run from dev-tools:

    python3 tests/run-sql-capacity-190.py

The harness launches a separate disposable MySQL 8.0 container and an isolated
CoD4x engine with 32 real test-client entities. Neither publishes a host port.
Only the production schema/routines are read; all records and demo payloads are
synthetic. No production grant, database record, runtime source or executable
is changed. Containers, anonymous DB storage and credential files are removed
in a finally block. The engine binary is checked for changes.

Each phase uses two menu refreshes and one save per player per second
(64 menu requests and 32 saves per second). Saves use the production
savePosition function and async progress policy. Menus use the production
generation/cancellation wrappers with representative leaderboard/runs SQL joins
and window functions. Data contains 512 synthetic accounts, 10,000 additional
finishes on one route, 1,000 unfinished runs and 20,000 historical saves.

Phases:

1. All 32 players record through demoRecording::capture at the 20 Hz server rate.
2. 16 record while 16 load different demos and play them with native presentation
   and Detailed spectator FPS.
3. All 32 upload completed recordings while loading 32 different demos.
   Menu/save traffic continues until the uploads have finished.
4. All 32 watch the same demo, exercising shared-cache reuse.

The default recording length is 12,000 frames (10 minutes). Upload buffers are
prefilled with native frames before the upload burst; each steady phase runs
for 30 seconds, rather than simulating ten minutes of elapsed gameplay.
Distinct playback payloads are generated in the native OCJ4 wire format.
Production cache acquisition, native decode, encode, upload, winner promotion,
playback stepping, FPS-history processing and presentation are exercised.
Account callbacks and full menu rendering are excluded from this SQL/demo
capacity fixture; this is not a network/client-rendering performance test.

## Interpreting results

Report the tested revisions, workload size, CPU/memory limits, elapsed durations, latency distributions and fixture exclusions with each run. Retain raw outputs privately. Do not copy a historical host's timings as a performance guarantee.

The current harness reads schema definitions from an initialized development database before building its disposable fixture. It is not yet a standalone fresh-checkout test. It must not be pointed at a production deployment merely to satisfy this prerequisite.

See the [test guide](testing.md) for runner requirements and the [publication reference](../reference/database/demo-publication.md) for the background publication transaction.
