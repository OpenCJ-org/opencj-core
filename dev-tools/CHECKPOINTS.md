# Checkpoint editor: first CoD4 milestone

The first version supports independent sequential routes such as `easy` and
`hard` on `mp_dark`. A checkpoint is a stationary, planar convex landing area
with 3–8 perimeter corners. A multi-bounce jump sequence gets one checkpoint
at its final landing. Moving platforms, airborne checkpoints, route merges,
and multi-step branches are not implemented by this editor. A checkpoint can have up to four alternative landing areas with shared requirements; landing in any one completes that step.

## Enable on a development server

Apply `server-db/migrations/001-checkpoint-areas.sql`, then `002-route-colors.sql` and `003-finish-settings.sql`, to `openCJ_cod4` once.
New Compose databases apply it after the base schema. Existing databases need
the migration explicitly; restarting does not run initialization SQL again.
The table is additive; existing radius checkpoints keep their existing behavior.

Add these settings to the game server configuration, then reload the map:

```text
set opencj_checkpoint_editor 1
```

A logged-in account needs admin level **20** or higher for checkpoint editing.
Levels are cumulative: 20 = checkpoint editor, 40 = moderator (mute/unmute),
60 = map administrator, 100 = uber-admin. These are permission levels, not
achievement points. Set the account's playerInformation.adminLevel in the
OpenCJ database; reconnect to reload the role. Per-player editor allowlists
are no longer used. The editor still requires opencj_checkpoint_editor 1.
Disable the editor on normal public servers. No client-mod rebuild is needed.

## Create a route

`!cp start <route> [#RRGGBB]` chooses the selected area's editor color. Route names
are normalized to lowercase and may include `+`. With no explicit hex color,
reopening uses the saved draft color, then the published route color, then the name-based palette below. An explicit color overrides it
and is retained in the draft and stored on finalization. The route heading uses this exact color. Gameplay waypoints use a stock neutral waypoint icon tinted with the saved route color.

| Route | Default |
| --- | --- |
| easy | Green `#00ff00` |
| inter | Yellow `#ffff00` |
| inter+ | Orange `#ff8800` |
| hard | Light red `#ff7777` |
| hard+ | Dark red `#aa0000` |
| adv / advanced | Purple `#aa55ff` |
| adv+ / advanced+ | Pink `#ff77cc` |
| Other names | Cyan `#00ccff` |

For example, `!cp start EASY #ffffff` edits `easy` with a white selection.
Previous areas remain gray, connections yellow, and alternatives magenta.
Checkpoint connections run from center to center.

1. Spawn and enter `!cp start easy` in chat. This reopens your saved draft when
   one exists for this account, map, and route.
2. Stand on a platform and use `!cp detect`. Inspect the proposed boundary.
   Detection follows flat or sloped rectangular tops (including rotated slopes).
   Detection uses collision normals to orient the rectangle, accepts both drops
   and adjoining walls as boundaries, and checks corners and edge midpoints.
   If a wall overlaps part of an edge, detection trims the rectangle to that
   wall face and verifies it again. This can exclude a narrow usable strip
   elsewhere on the same edge; inspect the proposed boundary before confirming.
   It rejects surfaces it cannot verify. `!cp corner` adds the surface
   point under your crosshair instead; select corners around the perimeter.
3. Use `!cp confirm` to keep the checkpoint. The editor prepares the next one,
   connected sequentially to the previous checkpoint.
4. At the last landing, use `!cp finish` **before** confirming it.
5. Use `!cp test` to follow the confirmed route. It reports each landing and
   out-of-order areas. `!cp test` again returns to editing.
6. `!cp finalize` stores the route in the database and activates it immediately. It exits CPC,
   confirms completion in chat, and returns you to spawn with a fresh run. Marking Finish alone only saves a draft.
7. Continue with `!cp start hard`. Switching directly from another route saves that draft and warns that it still needs `!cp finalize` to become playable. `!cp stop` saves and closes the editor without publishing.

The panel sits lower on the left to leave room for chat. Status and actions are separate from compact checkpoint properties using the regular crisp font (Double RPG, Finish, and onGround). It identifies new versus confirmed
checkpoints, and guides detection, review, and confirmation. Gameplay
buttons and existing save/load binds retain their normal meaning during CPC.
Use `!cp detect`, `!cp confirm`, etc. for editor actions; the editor does not
intercept Melee, Use, Aim, or Fire. Its temporary travel saves carry no run IDs
or scoring, and travel requests use the regular scheduled update rather than
teleporting inside the client-command callback.

Additional commands:

| Command | Behavior |
| --- | --- |
| `!cp select 3` | Edit checkpoint 3; Confirm applies the edit |
| `!cp new` | Start a new checkpoint after the last confirmed one |
| `!cp previous` / `!cp next` | Select a confirmed checkpoint |
| `!cp undo` | Undo the last draft edit; up to 32 edits in this session |
| `!cp replace` | Clear all areas in the selection while retaining this checkpoint's route position and requirements; Detect then Confirm applies the replacement |
| `!cp delete area` | Remove only the currently selected/cycled area; Confirm applies it. Removing the last area leaves this checkpoint selected for replacement |
| `!cp delete` | Delete the selected checkpoint from the draft; later checkpoints reconnect sequentially |
| `!cp double` | Toggle double-RPG permission **while approaching this checkpoint**; Confirm applies it |
| `!cp save` | Explicitly save the current draft, including unfinished corner placement |
| `!cp stop` | Save and leave the editor |

Drafts autosave after edits under the server's writable game directory:
`checkpoints/drafts/<playerID>_<map>_<route>.a` and `.b`.
In this Compose setup that is
`dev-tools/local/runtime/mods/opencj/checkpoints/drafts/`.
Two alternating snapshots retain the previous complete save if a write is
interrupted. Reopening validates the map, route, format and confirmed geometry.
CPC4 snapshots store the route color and alternative areas, and still read existing CPC2/CPC3 drafts. They intentionally do not claim compatibility with the old
native branch's `.cpc` format. Neither export nor publishing clears the draft.

## Runtime and publication

The existing `routes` table stores one `colorRGB` (unsigned 24-bit integer) per route, keyed by the first checkpoint ID. No color is duplicated in `checkpointAreas`. Runtime `checkpoint.routeInfo` references shared metadata containing the start ID, route name, hex color, and RGB vector. Existing published editor routes receive their name-based default when migration 002 is applied.

Finalizing requires valid confirmed areas and at least one finish. Multiple finish checkpoints must follow all ordinary checkpoints; each is connected to the last ordinary checkpoint and can complete the route. `!cp publish` remains an alias for finalizing. Finalizing creates
normal checkpoint IDs and connections plus `checkpointAreas` geometry. The
editor and gameplay share the same grounded point-in-polygon and height test:
the player's feet must be within the perimeter and between 2 units below and
4 units above the surface plane at their position. On slopes, the upper bound also includes the player's capsule support offset, so standing on the landing is sufficient. Corners must share one walkable plane; vertical faces and warped surfaces are rejected. The drawn volume uses the same bounds. Area checkpoints honor the existing `onGround` flag: airborne checkpoints skip ground contact, but still require containment. This editor currently creates grounded checkpoints only. Timing uses observed contact, without
the old radius-based interpolation. Old radius checkpoints are unchanged.

Double-RPG allowance comes from the next checkpoint and does not require being
inside its area. Equivalent next landing areas share that permission. An ambiguous next checkpoint at a distinct route choice does not grant
the exception. Split-route allowance policy is deferred. Elevator and FPS
exceptions are not exposed by this initial editor.

Finalizing an edited standalone CPC route automatically replaces its layout while
retaining completed times and low-RPG results. Start and finish must remain unchanged.
Supported changes are one checkpoint's geometry/alternatives, or insertion/deletion
of up to three consecutive ordinary checkpoints. Reorders, multiple independent
edits, changed requirements, and shared route connections are refused; the draft remains.

Unchanged checkpoints keep their IDs. Removed IDs and historical statistics remain
stored with the checkpoint marked retired. Before migration the old geometry is
saved beside the draft as `.before-migration-<time>.b`. The layout replacement and
history changes share the publication transaction, so failures roll everything back.
Unfinished old-layout runs are archived; their saves remain stored but cannot resume.
Old demos and winner references remain stored (`ready=2`) but are excluded from
playback and future winner comparison. A new recording can become the demo winner
without beating the retained historical result. Other players must reset an open
run on this route before it can be migrated. In-flight demo saves briefly block
migration; retry finalizing after they finish.

Apply `server-db/migrations/012-checkpoint-retirement.sql` before loading these
scripts. Restarting alone does not apply database migrations.

Editing and preview testing suppress normal checkpoint scoring. Starting or
loading a run while the editor is active does not re-enable checkpoint scoring.
Entering the editor stops the run and suppresses normal run statistics and HUD updates.
The progress bar is cyan. On leaving the editor, reset your run to start normal play.

## HUD and geometry visuals

The CoD4x server copies at most 31 current and 31 archived HUD elements per
player. Alpha-zero elements still consume slots. The old branch disabled the
spectator-list HUD, plausibly freeing the slot its CPC HUD needed. This editor
uses four archived text elements and leaves the spectator list enabled. It does
not change protocol limits. Each text block is capped at 240 characters: the
client HUD formatter silently rejects strings longer than 255 characters even
though the server accepts them. World outlines and corner labels use CoD4x debug
drawing commands sent only to the editor. The previous checkpoint is gray and
the connection is yellow; the selected area uses the chosen route color, or orange when invalid. Alternative areas and the links joining their centers are magenta: either landing counts as the same checkpoint.
CPC sets client `developer` to `1` when it starts and to `0` when it stops,
because the client renderer requires it for debug shapes.

World drawing yields after every 12 commands so the server can send and
acknowledge them. Sending a large group in one frame can hit CoD4x's 64-command
threshold and discard unsent disposable outlines. Shape lifetimes allow for
the paced refresh of larger groups.

## Validation

`tests/checkpoints.gsc` exercises geometry, both winding orders, landing rules,
serialization, snapshot recovery, and transactional publication/rollback inside
the actual GSC VM. It must run only on an isolated smoke server after OpenCJ
initialization. Its scratch files are `checkpoints/selftest.a` and `.b`; it uses
the reserved test route name `cpc_selftest`, and rolls back database changes.
In-game testing has covered editor rendering, save/load controls, draft reopening,
alternative areas, flat and sloped platform detection, and finalizing both Easy
and Hard on `mp_dark`. Gameplay finish detection was also confirmed. Automatic
numpad bindings on CPC startup were confirmed working on 2026-09-24.
The most recent regression run passed with zero failures. The subsequent fixes
for the duplicate finish-record HUD row and checkpoint progress flash still need
explicit in-game confirmation; the suite does not verify their appearance.

## Automatic numpad shortcuts

Starting CPC (`!cp start <route>`) applies the numpad bindings through the existing
OpenCJ client-command menu. No separate client cfg installation or manual exec
is needed. These replace the listed numpad bindings and remain set after leaving
CPC, just as with the old cfg. Normal save/load bindings are untouched.
`opencj_cpc_keys.cfg` remains available as a manual fallback.

| Numpad key | Action |
| --- | --- |
| 0 / Insert (also 5) | Detect platform |
| Enter | Confirm selection |
| + / - | Add aimed corner / undo |
| 8 / 9 | Toggle approach double RPG / finish |
| 4 / 6 | Previous / next confirmed checkpoint |
| 7 | New checkpoint |
| / | Add an alternative to the selected checkpoint (or the last confirmed one when preparing a new step) |
| * | Cycle the selected area within the current checkpoint |

Publishing and deletion have no default shortcuts. Use `!cp stop` to leave.

## Alternative landing areas

For a single-jump split that immediately merges, confirm the left landing,
press Numpad `/` (`!cp alternative`), stand on the right landing, detect it,
and confirm. Then create the shared next landing normally. The panel stays on
the same checkpoint number while adding an alternative; either area counts.
Double RPG and finish settings belong to the whole checkpoint.

An alternative may also be added before confirming the first area, or after
selecting an earlier checkpoint. Undo reverses the addition. Numpad `*`
(`!cp area`) cycles existing areas for editing; detect replaces only the active
area. Confirm applies the group edit. `!cp delete` deletes the entire step.

Publication uses the existing `checkpointBrothers` relationship. Each landing
has its own geometry and physical location; records use the canonical checkpoint.
All previous areas connect to all areas of the next step. No schema change is
needed. Published groups with recorded runs cannot be changed, and republishing
requires the same area counts and grouping to preserve checkpoint identities.
Restoring a draft announces it in chat and queues a teleport to the center of
the active landing. An unfinished alternative falls back to an existing sibling;
an empty next selection falls back to the last confirmed checkpoint. Empty drafts
do not teleport. The queued move runs during the regular game update, never
inside the command callback. The panel presents one primary NEXT action, with
optional alternatives explicitly labeled.

## Playing published routes

A fresh run shows the first checkpoint areas for all routes. After selecting a
route by landing in its first checkpoint, only its next areas are shown. In any%
mode, all routes' finishes are shown. Areas that are alternatives share one step.
CoD4 routes use a neutral waypoint HUD material with exact RGB tint; fixed-color
compass objectives are omitted for these routes because they cannot carry RGB.
Legacy checkpoints retain their old shader behavior.

Finishing saves checkpoint statistics before marking the run complete. The
leaderboard uses the finish snapshot of FPS mode, elevator use, any%, halfbeat
allowance, and hard-TAS use. Paused/cheated runs are not recorded as valid finishes.
Migration 003 adds those fields and updates the database finish function; apply it
as the database owner. Historical halfbeat use cannot be recovered and is treated
conservatively as allowed. The regression suite uses transaction/rollback for
synthetic normal and any% finishes, so no test results remain in the leaderboard.

## Replace a multi-area checkpoint in the middle of a route

Use `!cp edit <number>` (or `!cp edit` while standing in either area), then
`!cp replace`. Move to the replacement landing, use `!cp detect`, and
`!cp confirm`. This replaces all alternatives with one area in the same route
position, preserving the preceding/following checkpoints and checkpoint
properties. Until Confirm, the old confirmed geometry is retained. Undo
restores the previous selection. Autosave also retains an unconfirmed replacement.

`!cp area` only changes which alternative is selected. `!cp delete area` removes
that area from the pending edit; bare `!cp delete` removes the entire checkpoint
and returns to append mode. Do not use bare Delete to replace a middle checkpoint.

## Reset a draft to the finalized route

`!cpc reset hard` (also `!cp reset hard`) replaces your current-map Hard draft
with the active finalized CPC route and opens it for editing. It restores all
confirmed checkpoints, alternative areas, finish markers, requirements and route
color. The previous draft snapshots are backed up beside the draft as
`.before-reset-<revision>-<number>.a/.b`. It does not publish or change records.

Missing routes, invalid geometry, legacy non-area routes, shared branch/network
drafts, or failed backups are refused. This version supports standalone CPC
routes; shared networks need a separate network-aware restore.

### Num Del follows the selection

While editing a confirmed checkpoint, Num Del / `!cp discard` now acts like
`!cp delete`: it deletes the selected checkpoint and reconnects its neighbors.
While appending, it discards unconfirmed new geometry first; only an empty new
slot offers **Delete last**. The HUD labels these targets explicitly. Use
`!cp replace` to change geometry without removing the checkpoint slot.

### Listing current-map checkpoint work

Use `!cpc list` (or `!cp list`) without entering the editor. Red entries are your
private drafts or unpublished changes; green entries are finalized playable
routes. A finalized route with pending changes appears in both states. Retained
drafts matching the published checkpoints are not listed as unfinished. Shared
network sections are grouped under their route names. The command is read-only.
