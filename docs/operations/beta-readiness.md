# Beta-0.1.0 readiness

The setup entry point installs isolated instances; installation success does not
resolve every gameplay or security release risk. The following source review
supersedes the earlier pre-cleanup setup assumptions. These are current limits,
not permission to change competitive rules or delete historical player data.

| Area | Current status and remaining action |
| --- | --- |
| Fresh databases | Full baseline/migration bootstrap and restricted runtime permissions exist. The server installer reuses them and supports named schemas. Existing shared databases are checked without migration. |
| SQL queue/thread growth | Bounded worker scheduling, ordering and cancellation remain implemented. Extend policy coverage where compatibility wrappers still classify reads as writes. |
| Account secrets | `login.gsc` still logs credential-bearing queries; the native generator still uses `rand()` seeded from time/process ID. Replace the generator, remove secret logging and plan safe replacement of previously exposed privileged credentials before public access. |
| Login failure | An unavailable login lookup can still enter account creation. Distinguish unavailable storage from an unknown credential and preserve the original client credential. |
| Long recordings | Native recording memory is bounded, but the full recording remains in RAM. The per-recording GSC save-number index still grows separately from the capped native position history. Bound needed save mappings and design durable recording/upload recovery. |
| Interrupted uploads | Publication has receipts and bounded reconciliation. Chunk orchestration still depends on a map's script lifetime; map changes/process failure can lose unfinished transfers. |
| Interactive SQL | Demo publication is asynchronous. Checkpoint editor publication/network operations and clip metadata still include synchronous SQL. Move whole transactions off the game thread without splitting their connection/locking contract. |
| Checkpoint CPU | Full-layout scans, linear passed-checkpoint lookups and repeated geometry calculations remain profiling targets. Preserve exact gameplay/contact semantics when optimizing. |
| Deployment | Release instances isolate source/admin secrets, name their storage, rotate Docker logs and restart exited services. Operator monitoring, backup scheduling/off-machine recovery and final public-access policy remain necessary. |
| Acceptance | Existing engine capacity and user in-game results are useful evidence. They do not establish a complete 24/7, real-client, cross-country, mixed-feature soak. |

Runtime grants and editor role checks reduce consequences but do not repair weak
account credentials. Keeping initial installations password-protected/unlisted is
an initial deployment choice, not a fix for authentication defects.

Retain useful database save history. The bounded native save-history cache is
separate from persistent history; row-count growth alone does not justify pruning
player records. Monitor storage and query behavior using representative data.

Before declaring this beta public-ready, verify long sessions, repeated run
creation, actual save/load controls, reconnects, map changes during storage,
checkpoint publication and database interruptions on the final pinned release.
Monitor engine script allocations, native memory, frame timing, queue waits and
record integrity. Do not substitute a short capacity fixture or successful
container startup for that acceptance.
