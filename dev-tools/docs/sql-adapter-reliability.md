# SQL adapter reliability

## Runtime behavior

Four permanent pthread workers each own their connection and MySQL thread
state. A condition variable replaces the 10 ms dispatch scan and per-query
thread creation. One worker is reserved for progress operations; the remaining
three use weighted fair service across progress, reads, background writes and
menu reads. A continuously busy progress lane cannot starve background jobs.

Admission limits include queued, executing and completed-but-uncollected jobs:
512 total, 384 for non-progress work, and 64 menu jobs. Query text is stored at
its actual length, with 2 MiB overall and 1.5 MiB non-progress limits; the
existing 10 KiB maximum per query remains. These are query/job bounds, not a
claim to bound arbitrary SQL result-set sizes. GSC collects up to 64 results per
50 ms poll. Finished queries release their query text immediately.

Operations with the same non-empty ordering key dispatch in acceptance order.
Saves, checkpoints, run resume/create/finish/archive and run labels use explicit
run/player keys. Default player-bound mutations use a player key. Demo and
clip uploads are background work with per-upload keys. Policies are never
inferred from SQL verbs: SELECT savePosition(...) is a progress write.

Already accepted writes continue after player disconnect or map transitions.
This is in-process continuity, not disk-backed durability across process loss.
Each accepted job resolves to a defined outcome or explicit cancellation;
admission rejection is returned immediately.

## Cancellation and menus

Leaderboard, Runsboard, Challenges and Clips debounce/coalesce refreshes and
use request generations. A superseded or closed menu cannot apply its old
response. Cancellation is scoped, so a delayed close event for an old menu does
not cancel a newer menu. Disconnect cancels player-scoped menu reads; map
initialization discards old-map reads while retaining the workers and writes.

Queued obsolete reads are cancelled before execution. An executing read is
allowed to finish within its SQL/socket limits, then its result is discarded.
No worker invokes the GSC VM. The main game thread owns completion delivery
and frees result handles. The unused unmanaged NoRows result-pointer path now
delegates to the normal no-result wrapper.

Leaderboard, Runsboard and Challenges gained onClose notifications; Clips
already provided its close notification. The compiled asset comparison checks
the complete 275-menu inventory; only these three menu definitions change.

## Deadlines and outcomes

Workers use a 3-second connect timeout and 2-second socket read/write options.
MySQL can make multiple I/O attempts, so those option values are not a promise
of a strict 2-second wall-clock deadline. Read operations also set MySQL's
2-second SELECT execution limit. Queue deadlines are 2 seconds for menus,
10 seconds for normal/progress operations and 30 seconds for background jobs.
These are explicit failures, not silent queue removal.

A new worker connection is established before a new statement when necessary.
Automatic reconnection/replay is disabled during statement execution. A lost
reply after submitting a write is outcome UNKNOWN: the write may have committed.
Neither the adapter nor wrappers blindly retry it. Existing synchronous
transactions retain their #192 connection/error handling; async jobs may not
leave a transaction open on a pooled connection.

Outcome codes:
0 success; 1 SQL error; 2 connection unavailable before submission;
3 uncertain write outcome; 4 expired before execution; 5 cancelled;
6 admission busy; 7 invalid request.

The native submit API returns a positive job ID or a negative admission code.
The structured GSC _request helper returns rows, status, MySQL error number,
queue wait and execution time. Compatibility helpers return rows/undefined.
Empty successful statements remain empty arrays. Critical callers report
storage failures; fire-and-forget wrappers also report failures without
printing SQL or credentials. Finish/archive messages no longer claim a
definite database outcome when it could not be confirmed.

## Diagnostics and adding callers

!sqlstats requires admin level 50 and reports workers, queue/running/completed
counts, query bytes, oldest/max waits, max execution, rejections, failures and
uncertain writes. It is registered through commands_base, so !help discovers it
automatically.

Use mysqlAsyncWrite(query, key) for progress; mysqlAsyncBackground(query, key)
for uploads/maintenance; mysqlAsyncRead(query) for required reads. Menu owners
use beginMenuRead/menuReadCurrent and mysqlAsyncMenuQuery, and must stop their
render path when a result is undefined or its request token is stale.
Use explicit stable run/player/upload keys where order matters.

Implementation lives in server-ext/mysql_async_pool.cpp/.hpp, the thin
gsc_custom_mysql.cpp bridge, and server-gsc/opencj/mysql.gsc. cod4x-server's
makefile tracks the new interface/registration dependencies.

## Acceptance and deployment (2026-11-11)

- 810 native checks passed against MySQL, including four permanent OS workers,
  admission limits, key ordering, fairness, cancellation and uncertain outcomes.
- 121 game-VM checks passed, including the existing #192 regression suite and an
  actual map transition with a write and obsolete menu read in flight.
- The same four-worker, 40-menu-query benchmark improved median game-visible
  progress completion from 550 ms to 50 ms across five trials. The separate
  native saturation probe completed its progress write in 2 ms.
- All five compiled-asset comparisons passed: the 275-menu inventory is intact,
  only the three intended close notifications changed, and 272 menus are unchanged.
- The disposable schema, temporary grant, credential configs and test containers
  were removed. Test fixtures did not write production player records.

Native binary SHA-256:
4ea30ff0361b6f5d8cff488cede0eafc7e88598aa8a5d14c6d6d126e40aca75a

Compiled mod.ff SHA-256:
8f604d82671a22df6f5358ad5697ed239030f78a53395e26cabf7f48c54d24b3

## References

MySQL timeout options and their retry semantics:
https://dev.mysql.com/doc/c-api/8.0/en/mysql-options.html
