# Background demo publication

[Migration 018](../../../server-db/migrations/018-demo-publication.sql) introduces
publication receipts; [migration 019](../../../server-db/migrations/019-route-identity.sql)
defines the current route-ID procedure.
[`demorecording.gsc`](../../../server-gsc/opencj/demorecording.gsc) submits
`CALL publishDemo(runID)` through the SQL adapter's four workers, under the
background policy with a shared publication ordering key. Each call stays on
one worker connection.

The procedure obtains the same map-row lock used by route publication/rename,
then reads current candidate metadata and winner rows. It validates contiguous,
nonempty chunks; preserves speedrun/low-RPG/walkthrough comparisons; updates
winners, readiness and obsolete-payload cleanup; and inserts a durable receipt
before committing. Any SQL exception rolls back and propagates an error.
Different maps can publish concurrently from independent connections.

The demoPublications table retains only runID and publishedAt. A receipt
survives removal of a losing recording, and follows its parent run's lifetime.
It makes duplicate calls and lost commit replies unambiguous. It never restores
retired footage.

The GSC caller retries only this idempotent operation, at most three attempts:
deadlock/lock-timeout errors are retried after rollback; uncertain writes first
check the receipt, then may safely re-enter the procedure, which checks again
under its map lock. Failed reconciliation remains explicitly uncertain and
retains the candidate instead of deleting it. Generic uncertain writes retain
the SQL adapter's existing no-automatic-replay policy.

Startup verifies both receipt table and procedure before enabling new recording.
An unmigrated server can still play its existing published recordings.


## Tests

The publication SQL fixture covers competing connections, duplicate calls, category rules, incomplete chunks, route changes, rollback and lost commit replies. The engine fixture checks bounded retries, receipt reconciliation and uncertain candidates. See [testing](../../development/testing.md).
