# Performance workloads

## Workload and isolation

Run the synchronized stress workload from the core root:

    python3 -B dev-tools/tests/run-sql-capacity-190.py

Use the query workload for staggered hosting traffic, two shared CPU cores,
a 1 GiB engine limit and a 1.5 GiB database limit:

    python3 -B dev-tools/tests/run-query-capacity.py --mature --extended-reads

Both commands use the same maintained fixture and current production query
builders. The query profile refreshes each player's menu every ten seconds and
saves every six seconds, staggered across clients. Extended reads add record,
finish and checkpoint-notice queries every twenty seconds. The optional mature
dataset adds 250,000 finishes, 20,000 unfinished runs and two million saves
across older maps. Select another allowed core pair with --cpu-set.

For a short smoke check, use --seconds 5 --frames 256. This does not replace
the full recording-size and mature-data workload.

The harness launches a separate disposable MySQL 8.0 container and an isolated
CoD4x engine with 32 real test-client entities. Neither publishes a host port.
Only the production schema/routines are read; all records and demo payloads are
synthetic. No production grant, database record, runtime source or executable
is changed. Containers, anonymous DB storage, sampling threads and credential files are
cleaned up after success or failure. Selected sources and engine binaries are
checked for changes.

Each stress phase uses two menu refreshes and one save per player per second
(64 menu requests and 32 saves per second). Saves use the production
savePosition function and async progress policy. Menus use the production
generation/cancellation wrappers and the actual leaderboard/runs query builders. Data contains 512 synthetic accounts, 10,000 additional
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
A separate clip phase also exercises 32 concurrent native clip publications,
source ownership during upload, stale transfers and malformed payload rejection.
Production cache acquisition, native decode, encode, upload, winner promotion,
playback stepping, FPS-history processing and presentation are exercised.
Account callbacks and full menu rendering are excluded from this SQL/demo
capacity fixture; this is not a network/client-rendering performance test.

--binary and --scripts select a candidate engine and complete script tree.
The query profile's --baseline-queries option selects the preserved historical
query corpus for explicit before/current comparisons. It does not select
historical gameplay scripts. Old batch/cache override options accept only their
production defaults; they no longer patch the code under measurement.

Publication rollback, lost replies and receipt recovery remain in the SQL
adapter suite. The capacity workload measures publication under concurrent load.

## Interpreting results

Report the tested revisions, workload size, CPU/memory limits, elapsed durations, latency distributions and fixture exclusions with each run. Retain raw outputs privately. Do not copy a historical host's timings as a performance guarantee.

The current harness reads schema definitions from an initialized development database before building its disposable fixture. It is not yet a standalone fresh-checkout test. It must not be pointed at a production deployment merely to satisfy this prerequisite.

See the [test guide](testing.md) for runner requirements and the [publication reference](../reference/database/demo-publication.md) for the background publication transaction.
