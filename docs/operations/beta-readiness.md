# Beta-0.1.0 readiness

The setup entry point installs isolated instances; installation success does not
resolve every gameplay or security release risk. The following source review
supersedes the earlier pre-cleanup setup assumptions. These are current limits,
not permission to change competitive rules or delete historical player data.

| Area | Current status and remaining action |
| --- | --- |
| Fresh databases | Full baseline/migration bootstrap and restricted runtime permissions exist. The server installer reuses them and supports named schemas. Existing shared databases are checked without migration. |
| SQL queue/thread growth | Bounded worker scheduling, ordering and cancellation remain implemented. Extend policy coverage where compatibility wrappers still classify reads as writes. |
| Account secrets | Fixed: login no longer logs credential-bearing queries, and new account credentials come from the kernel's secure random source (account creation refuses to continue without it). Credentials issued earlier came from the old time-seeded generator; logs that recorded them were deleted. |
| Login failure | Fixed: an unanswered account lookup retries until the database answers and never creates an account or overwrites the client's stored credential. Only a client without a stored credential, or one the database reports as unknown, gets a new account. |
| Long recordings | Native recording memory is bounded, but the full recording remains in RAM. The save positions used to rewind a recording on load are kept by the engine inside the same 128 MB demo budget, so endless saving stops the recording instead of exhausting script variables. Design durable recording/upload recovery. |
| Interrupted uploads | Publication has receipts and bounded reconciliation. The chunk upload loop still runs in a map-lifetime script thread: a map change or process failure loses that demo (unfinished candidates are reclaimed later), never the finish itself. |
| Interactive SQL | Gameplay paths (login, saves, checkpoints, runs, demo publication, clip transfers, menus) and checkpoint-editor publication, rename, reset and list are asynchronous; editor transactions keep one connection and lock order on a bound pool worker. Synchronous SQL remains for loading the checkpoint graph (map start and after publication), and at map start for clip sessions and the challenge catalogue; a slow database stalls the server frame during those reads. |
| Checkpoint CPU | Full-layout scans, linear passed-checkpoint lookups and repeated geometry calculations remain profiling targets. Preserve exact gameplay/contact semantics when optimizing. |
| Deployment | Release instances isolate source/admin secrets, name their storage, rotate Docker logs and restart exited services. Setup schedules local and off-site database backups, a health watchdog with Discord alerts (crashes, failed jobs, low disk), weekly housekeeping and security updates. The final public-access policy remains to be decided. |
| Acceptance | Existing engine capacity and user in-game results are useful evidence. They do not establish a complete 24/7, real-client, cross-country, mixed-feature soak. |

Accounts created before the secure generator keep their existing credentials; they
were not rotated. Keeping initial installations password-protected/unlisted is an
initial deployment choice, not a substitute for those fixes.

Retain useful database save history. The bounded native save-history cache is
separate from persistent history; row-count growth alone does not justify pruning
player records. Monitor storage and query behavior using representative data.

Before declaring this beta public-ready, verify long sessions, repeated run
creation, actual save/load controls, reconnects, map changes during storage,
checkpoint publication and database interruptions on the final pinned release.
Monitor engine script allocations, native memory, frame timing, queue waits and
record integrity. Do not substitute a short capacity fixture or successful
container startup for that acceptance.
