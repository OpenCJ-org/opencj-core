# SQL adapter reliability

The adapter owns asynchronous query scheduling, worker connections, cancellation
and result delivery. It does not automatically retry arbitrary writes.
Receipt-based demo publication has its own bounded retry and reconciliation
policy; see [demo publication](demo-publication.md).

## Runtime behavior

Four permanent pthread workers each own their connection and MySQL thread
state. A condition variable replaces the 10 ms dispatch scan and per-query
thread creation. One worker is reserved for progress operations; the remaining
three use weighted fair service across progress, reads, background writes and
menu reads. A continuously busy progress lane cannot starve background jobs.
While an editor transaction is open, one of those three serves only it (see
below), so the worker and thread counts stay the same.

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

Leaderboard, Runsboard, Challenges and Clips notify their owners when closed.
Keep these close notifications in matching compiled client assets so stale menu
reads are cancelled. Verify the affected compiled menus when changing this flow;
a menu count from an earlier comparison is not a current acceptance check.

## Editor transactions

Checkpoint-editor publication and rename need several statements in one
transaction on one connection. The pool runs at most one such editor transaction
(a session) at a time:

- Its first statement binds an idle non-progress worker, which starts the
  transaction and then serves only that session, in submission order, until
  COMMIT or ROLLBACK. The progress worker is never bound.
- A statement that fails, or expires unrun after 30 seconds in the queue, fails the
  transaction: later statements complete with SQL error without running, and a
  requested COMMIT rolls back and reports an error. A lost connection is never
  replaced inside the transaction.
- COMMIT reports success, UNKNOWN when its reply was lost (it may have committed),
  or an error after a rollback.
- A session that stays silent for 10 seconds, or is open for 120 seconds, is rolled
  back and closed. A map change abandons an open session the same way; a COMMIT
  that was already requested still settles.

GSC uses `beginTransaction()` (waits up to 5 seconds while another editor's
transaction finishes), `transactionBatch(transaction, queries)`,
`transactionQuery`, `commitTransaction`, `rollbackTransaction` and
`abandonTransaction` (no wait, for a leaving owner). A batch submits up to 64
statements together, so it waits for about one 50 ms completion poll instead of
one per statement; statements can pass values such as new IDs through connection
variables. Measured on the development fixture, the first publication of a
three-checkpoint route takes 23 statements and about 350 ms, all off the game
thread.

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
Neither the adapter nor wrappers blindly retry it. Independent async jobs may
not leave a transaction open on a pooled connection; editor transactions are
the only exception.

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

!sqlstats is uber-admin only and reports workers, queue/running/completed
counts, query bytes, oldest/max waits, max execution, rejections, failures and
uncertain writes. It is registered through commands_base, so !help discovers it
automatically.

Use mysqlAsyncWrite(query, key) for progress; mysqlAsyncBackground(query, key)
for uploads/maintenance; mysqlAsyncRead(query) for required reads. Menu owners
use beginMenuRead/menuReadCurrent and mysqlAsyncMenuQuery, and must stop their
render path when a result is undefined or its request token is stale.
Use explicit stable run/player/upload keys where order matters.

Implementation: [worker pool](../../../server-ext/mysql_async_pool.cpp),
[pool interface](../../../server-ext/mysql_async_pool.hpp),
[GSC bridge](../../../server-ext/gsc_custom_mysql.cpp) and
[script wrappers](../../../server-gsc/opencj/mysql.gsc). The CoD4x makefile
tracks these interface/registration dependencies.
