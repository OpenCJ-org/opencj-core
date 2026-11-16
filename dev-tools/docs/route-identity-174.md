# Stable route IDs and safe rename (#174)

## Result

Routes have permanent numeric IDs. A map/name pair identifies the editable
catalogue entry, but names no longer identify demos, winners or challenges.
Completed runs continue to reference their preserved finish checkpoint, which
now references the permanent route ID. Existing !cp rename commands move draft
files, network manifests and authoring labels together and refresh runtime/menu
names. Shared opening names remain separate from playable route names.

The migration preserved all 2,119 checkpoint rows, including 2 retired rows.
All 2,117 active checkpoints have membership: 2,155 links, including 38 shared
checkpoints. The catalogue retains 30 entries (29 completed routes and one
shared-opening metadata entry). Alternative finish areas share a route ID.

## Storage and transactions

- routes: routeID primary key, mapID, unique map/name, optional start cpID and
  existing type, difficulty and color metadata.
- checkpointRoutes: many-to-many membership, rebuilt from reachable finishes
  inside the publisher's map-locked transaction; retired memberships survive.
- checkpoints.finishRouteID: nullable finish identity, replacing ender text.
- demoRuns/demoWinners: routeID replaces routeName. Existing publication locks,
  four-worker behavior, category ordering and retry receipts are preserved.
- challenges.routeID: permanent binding; routeHint/routeLabel only help bind an
  unpublished challenge. Startup refresh never replaces an existing binding.
  Challenge display names come from the route catalogue once bound.
- checkpointAreas.draftName: editor chain ownership, formerly routeName.
  sectionName still identifies shared authored geometry. These are not duplicate
  historical route keys.

Runs, demo payloads, player saves, earned completions and cpIDs were not rewritten.
User-written run labels/clip descriptions and old chat messages are not renamed.

## Deployment

Applied 2026-11-14, after checking only operator was connected. OpenCJ was stopped
for the schema change, backed up, restarted and restored to mp_futile_fixed.
Post-migration data hashes matched and startup reported no script/SQL errors.
