# server-db
OpenCJ databasing

## Challenge catalogue and awards

Apply `migrations/009-challenges.sql` to the existing CoD4 database before deploying the Challenges scripts. This additive migration creates the catalogue and one completion per player/challenge; it does not replace existing game tables.

Definitions and eligibility rules are maintained in `server-gsc/opencj/challenges.gsc`. Keep each challenge key stable: completions refer to it permanently. A missing `routeID` (migration 019) leaves a challenge visible but unlinked. Startup refreshes catalogue metadata and backfills qualifying finalized runs. Removing a definition deactivates it without deleting earned completions. Rank thresholds are cumulative tier point totals, not stored player levels.

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

## Preferred names and name moderation

Apply `migrations/017-preferred-names.sql` before the corresponding scripts.
It adds account-linked preferred names, a case-insensitive unique constraint,
a shared write lock for name claims, and private moderation-rule tables.
No existing player records or names are rewritten. Preferred names contain
3–15 printable ASCII characters and no color codes, matching the existing
visible engine-name budget. Changes and resets share a persistent one-hour
cooldown. `playerDisplayNames` resolves the preferred name with the existing
account name as fallback.

Rule data is operational data, not source code. Never commit database exports
containing real rule entries, raw submitted names, or private seed lists.
The matcher normalizes case, color codes, separators, common substitutions and
repeated letters. Rules are SHA-256 hashes of those normalized forms, with
whole-name/contained matching and rule-specific full-name exceptions. Hashing
avoids displaying terms; it is not encryption or a secrecy guarantee against
dictionary guessing. Administrators still control access to the database.

`tools/manage-name-rules.py` reads new terms with a hidden terminal prompt:
- `python3 tools/manage-name-rules.py --add`
- `python3 tools/manage-name-rules.py --add --mode contains`
- `python3 tools/manage-name-rules.py --exception 12`
- `python3 tools/manage-name-rules.py --disable 12`
- `python3 tools/manage-name-rules.py --list` shows numeric IDs and metadata only.
- `python3 tools/manage-name-rules.py --seed` imports the pinned English source's
  severity-4 entries. Use `--dry-run` first; seeding preserves existing disabled
  rules and never prints or saves the downloaded plaintext list.

The starter source is [dsojevic/profanity-list](https://github.com/dsojevic/profanity-list)
at commit `c27924319aa9bd6f917e3782b4f4b6604a50b652`, MIT licensed.
Its level-3 entries are largely unclassified defaults, so the starter selection
uses only explicitly severe entries. It is a limited starting policy, not a
complete or authoritative classification of abusive language. Other operators
can use their own data. See the upstream
[license](https://github.com/dsojevic/profanity-list/blob/c27924319aa9bd6f917e3782b4f4b6604a50b652/LICENSE).
Server-side name checks never send player names to an external service.

After changing rules, use `!reloadnamerules` (admin 60), or change maps normally.
A failed reload retains the last valid snapshot. A server starting without a
valid snapshot uses temporary names rather than accepting unchecked changes.
`!frename` and `!resetprefname` require moderator level 40. Existing prefname
entries are not silently bulk-deleted when rules change: moderators can reset
the relevant account by playerID. Review false positives with rule exceptions.

## Asynchronous demo publication

Apply migrations/018-demo-publication.sql before deploying the corresponding
recording scripts. It adds publishDemo(runID) and a small demoPublications
receipt table; existing recordings and winners are preserved. The existing
four-worker SQL pool executes each call as one background job on one connection.

Publication locks the map row before reading mutable candidate/winner data,
matching checkpoint publication and route rename/retirement. It validates all
chunks, updates category winners, marks the recording ready, removes unreferenced
published payloads and records success in one transaction. Errors roll back.
The receipt survives payload cleanup so repeated calls and lost commit replies
cannot republish an obsolete candidate. It is removed only when its parent
player run is deleted. Receipts do not make a retired recording playable.

See dev-tools/docs/sql-capacity-190.md for concurrency and workload verification.

## Stable route identity (#174)

After migrations 001–018, apply migrations/019-route-identity.sql once, with all
OpenCJ servers using this database stopped. Back up the database and checkpoint
drafts first. MySQL DDL commits implicitly; rehearse the migration on a restored
copy and deploy the matching GSC scripts before starting the servers again.
Do not rerun migration 018 afterwards: 019 replaces publishDemo with its
route-ID version while preserving the same transaction, lock and receipt rules.

- routes.routeID is the permanent key; (mapID, routeName) is unique.
  cpID is optional start/color metadata, not identity.
- checkpointRoutes(cpID, routeID) contains every reachable route for each
  active checkpoint, including shared openings and alternative finish areas.
- checkpoints.finishRouteID replaces ender and distinguishes finishes from
  ordinary route membership. Completed runs retain their existing finishcpID.
- demoRuns and demoWinners use routeID; recordings and winner categories are
  preserved. Challenges retain their permanent challengeKey and bind to routeID.
- challenges.routeHint is only a hint for an unbound challenge. Once linked,
  startup must preserve its routeID even if the source hint still has an old name.
  Displays resolve the current route name from routes.
- checkpointAreas.draftName replaces its old routeName column. This identifies
  the editor-owned logical chain, which can be a shared opening; sectionName
  identifies authored shared geometry. Neither is a historical route key.

rebuildCheckpointRoutes(mapID) runs inside the publisher's existing map-locked
transaction, after all graph changes. It does not commit. Retired memberships
survive, and repeated rebuilds are idempotent. Its recursive union terminates
even on cycles; the existing MySQL recursion ceiling still bounds long graphs.

Use the existing !cp rename <old> <new> command so the draft files, network
manifest and authoring labels move together. The route catalogue name changes
once; demo, challenge and run references do not change. Renaming a shared
opening leaves the names of its descendant routes alone.

See dev-tools/docs/route-identity-174.md for validation and deployment details.


## Separate database cleanup (migration 020)

Apply migrations/020-database-cleanup.sql after 019, with OpenCJ stopped and a
full backup. Deploy the matching GSC scripts before restarting. This migration
is separate from issue #174.

Run identity remains playerRuns.runID. The optional player-chosen name stays in
runLabels(runID, runLabel); only the unused duplicate playerRuns.runLabel column
is removed. Nonempty legacy labels are preserved, and conflicting copies stop
the migration rather than silently choosing a name.

Challenges now use mapID as well as routeID. Existing challenge map definitions
without catalogue entries receive map IDs with inRotation=0. This does not
publish their routes, approve them for voting, or fill unknown release/author
metadata. Existing map metadata and pool membership are unchanged. Catalogue
startup retains existing map bindings even after a map is renamed.

Removed: the empty legacy playerSaves_test, playerRecordings and demoEvents
tables, their five unused functions, unused palette-color columns (RGB remains),
and shopEquipped.category. Preflight rejects nonempty legacy tables or populated
palette fields so they cannot be silently discarded on another installation.

Retained lookup fields now have matching-reference constraints:
checkpointAreas map matches its checkpoint; a challenge route belongs to its
map; a demo winner category matches its recording; equipped item/slot matches
the catalogue. Equipment slots follow catalogue slot changes atomically.
Prices paid, saved state, checkpoint results, demo summaries and recordings
remain preserved.

See dev-tools/docs/database-cleanup.md and tests/database-cleanup.py.
