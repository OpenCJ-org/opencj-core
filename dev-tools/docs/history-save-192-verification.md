# #192: save ownership, demo integrity and SQL wrapper correctness

## Behavior

- Position and checkpoint writes report another session only after confirming
  that the run's ownership generation changed. Results for a run/instance the
  player has already left are ignored. Storage errors have a separate message,
  which does not claim that an uncertain commit definitely failed.
- savePosition locks its run row, checks ownership explicitly and accepts an
  exact repeat of the latest stored save without inserting it again. Equal
  counters alone do not suppress a different saved position. Save numbering is
  serialized. No automatic write retries were added.
- An unsuccessful demo upload cannot become ready or replace a playable winner.
  Promotion also requires the expected number of contiguous, non-empty chunks.
  A failed demo upload leaves the leaderboard finish intact.

## Related SQL wrapper fixes included here

These address the correctness concerns from the earlier alpha readiness audit:

- Distinguish SQL errors (undefined) from successful no-row statements (empty
  arrays), including errors after a stored procedure's first result set.
- Publish worker completion, results and connection availability under the
  shared mutex; initialize and release MySQL state for each query thread.
- Clean up partial pool initialization and allow a later attempt. Failed
  initialization rejects new queries immediately rather than stranding waiters.
- A worker creation failure completes that task as failed and leaves the
  dispatcher running.
- Reconnect before a new asynchronous statement; disable implicit replay while
  executing it. A connection loss can leave a write's commit outcome unknown.
- Keep synchronous transactions on their original connection. After failure,
  reject further statements/commit until rollback; reconnect for subsequent
  independent work. Load MySQL library headers before engine headers that alter
  structure packing.
- Reject oversized queries. The long-query builder remembers append overflow,
  so ignoring an append failure cannot execute a truncated prefix.
- Guard existing GSC consumers that previously assumed every query succeeded.
  The no-result wrapper now returns the same success/failure distinction.

The four-connection count and per-query thread model are unchanged. Bounded
queues, priorities/coalescing, permanent workers, read/write deadlines, durable
uploads across map changes, operation IDs and automatic retry policy remain
separate work. Async transaction sequences still must not be spread across
independent queued calls; existing transactions use the synchronous wrapper.
This patch is not a general claim that every persistence issue is resolved.

## Regression checks

Run on the server:

    cd dev-tools
    python3 tests/run-history-save-192.py

The runner copies schema/routines only into a uniquely named disposable schema,
applies server-db/migrations/016-save-position-ownership.sql, creates synthetic
fixtures and starts an isolated CoD4x engine without published game ports.
It uses production GSC and native code, replacing only warning presentation
and delaying one response in the test copy. No movement simulation is used.

Coverage includes normal saves, resume ownership, wrong account/map rejection,
storage errors, stale responses, concurrent identical saves, equal counters
with different coordinates, checkpoint warning decisions, native demo
publication, failed chunks, missing/gapped/empty chunks, successful empty
queries, SQL errors, stored-procedure trailing errors, refused initialization,
killed connections, interrupted transactions, concurrent result routing and
the exact 10 KiB query boundary/overflow.

The failed-worker-creation branch is code-reviewed; thread exhaustion is not
injected into the live host. The checks use disposable connections for KILL
and disposable triggers for write failures.

Evidence is retained under dev-tools/local/history-save-192-<token>/:
result.json and restricted console.log. The runner removes its container,
temporary connection config, database grant and schema even after failure.
It never copies player records or deletes production data.

## Deployment

The native extension is compiled into cod4x-server/bin/cod4x18_dedrun:

    cd dev-tools
    docker compose run --rm --no-deps --entrypoint bash server -lc \
      'cd /workspace/cod4x-server && make DEBUG=true -j2'

Apply migration 016 to openCJ_cod4 while OpenCJ is stopped, after preserving the
current savePosition definition. This migration replaces one routine and does
not update player rows or table structures. The base CoD4 export contains the
same corrected function. Restart only when nobody except operator is connected,
and restore the captured map. No client asset build is required.

Deployment completed with the original map mp_to_the_moon restored, no occupied
slots before restart and no startup script errors. The running executable hash
matches the tested binary. The routine and original executable backups, guarded
deployment scripts and deployment-result.json are retained in
dev-tools/local/history-save-192-fix/. No production player data was migrated.
