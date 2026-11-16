# Stable route IDs and safe rename

## Current identity

Routes have permanent numeric IDs. A map/name pair identifies the editable
catalogue entry, but names no longer identify demos, winners or challenges.
Completed runs continue to reference their preserved finish checkpoint, which
now references the permanent route ID. Existing !cp rename commands move draft
files, network manifests and authoring labels together and refresh runtime/menu
names. Shared opening names remain separate from playable route names.

Every active checkpoint has route membership; shared checkpoints can belong
to several routes. Alternative finish areas share one finish route ID. Row
counts depend on the installation and are not schema guarantees.

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

Renaming preserves run IDs, demo payloads, player saves, earned completions
and checkpoint IDs. It does not rewrite user-written run labels, clip
descriptions or old chat messages.

Implementation: [migration 019](../../../server-db/migrations/019-route-identity.sql)
and [checkpoint publication](../../../server-gsc/opencj/checkpointpublish.gsc).
Use the complete [upgrade procedure](../../operations/database.md); migration
numbers identify the schema change, not commands to replay on a current database.
