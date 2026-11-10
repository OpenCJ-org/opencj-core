# server-db
OpenCJ databasing

## Challenge catalogue and awards

Apply `migrations/009-challenges.sql` to the existing CoD4 database before deploying the Challenges scripts. This additive migration creates the catalogue and one completion per player/challenge; it does not replace existing game tables.

Definitions and eligibility rules are maintained in `server-gsc/opencj/challenges.gsc`. Keep each challenge key stable: completions refer to it permanently. A missing `routeName` leaves a challenge visible but unlinked. Startup refreshes catalogue metadata and backfills qualifying finalized runs. Removing a definition deactivates it without deleting earned completions. Rank thresholds are cumulative tier point totals, not stored player levels.

## Shop preview

Apply `migrations/010-shop-purchases.sql` before deploying the Shop menu. It adds ownership and historical spending without modifying challenge awards. Available points are the active challenge total minus the sum of prices actually paid, clamped to zero if challenge values decrease. Purchased items remain owned after repricing or retirement.

Apply `migrations/011-shop-equipment.sql` for transactional purchase handling and saved equipment. The initial catalogue in `server-gsc/opencj/shop.gsc` remains preview-only: every item is unavailable. Real items need a registered cosmetic resource and server-side availability before sales can be enabled.

Shop purchase safety: `shopBuyOrEquip` serializes requests per player inside one transaction, checks the live database catalogue and challenge balance, and records ownership, paid price and equipment together. Its unique ownership key prevents duplicate charges across servers. Equipment is keyed by the base weapon (or `player` for player models), independently of display categories. Owned items remain usable if challenge thresholds or catalogue prices change. The server-ext MySQL wrapper must drain stored-procedure results before reusing connections.

## Checkpoint layout migration

Apply `migrations/012-checkpoint-retirement.sql` before deploying the default CPC migration scripts. This additive column keeps removed checkpoint IDs and their historical statistics while excluding them from the active graph. `!cp finalize` automatically migrates supported small standalone-route edits in one transaction, retains completed results, archives unfinished old-layout runs, and marks old demos `ready=2` without deleting their payloads. See `dev-tools/CHECKPOINTS.md` for the edit limits and backups.

## Shared map pool and authors

Apply `migrations/015-alpha-map-pool.sql` to `openCJ_cod4` before deploying the
database-backed map catalogue (#203). It seeds the approved ten-map alpha pool,
historical release dates and nine original mappers. Existing map IDs, unrelated
metadata, checkpoint layouts and records are preserved. `mapMappers` links the
numeric map/mapper IDs; names are stored only in `mappers`.

`mapids.inRotation = 1` is the shared pool flag. Subsequent pool changes should
update that column directly; re-running this seed resets membership to the
initial ten maps. Changes reach voting and menus at the next map initialization.
The regular-player pool also requires installed map assets. Level-100
uber-admins can select every installed map, including ones without DB metadata.
An empty/failed catalogue read exposes no maps to regular players.

Release provenance and the future download authorization design are documented
in `dev-tools/docs/proposals/alpha-map-pool.md` and
`dev-tools/docs/proposals/203-map-download-authorization.md`.
