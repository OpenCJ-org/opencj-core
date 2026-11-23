# Checkpoint editor

The editor supports published routes, alternative landing areas, moving-platform
references and saved drafts. Inspect detected geometry before confirming it.
Checkpoint data and earned player history must survive editor changes.

## Enable on a development server

Use the [fresh setup or upgrade procedure](../../setup/development.md) to bring the
database to the complete recorded migration set before enabling the editor.
Restarting a database does not apply migrations.

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
Disable the editor on normal public servers. Use matching native code, scripts
and compiled client assets; the current property panel uses client UI assets.
See [native/script deployment](../../operations/native-scripts.md).

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
| `!cp ele` | Toggle elevator permission for the checkpoint |
| `!cp ground` | Toggle required ground contact |
| `!cp allowsave` | Toggle saving permission at the checkpoint |
| `!cp height [units]` | Edit the volume's added height; no value enters interactive height editing |
| `!cp postsert` / `!cp presert` | Begin a new checkpoint after / before the selection; Confirm inserts it |
| `!cp discard` | Delete the selected confirmed checkpoint, or discard the new selection while appending |
| `!cp save` | Explicitly save the current draft, including unfinished corner placement |
| `!cp stop` | Save and leave the editor |

Drafts autosave after edits under the server's writable game directory:
`checkpoints/drafts/<playerID>_<map>_<route>.a` and `.b`.
In this Compose setup that is
`dev-tools/local/runtime/mods/opencj/checkpoints/drafts/`.
Two alternating snapshots retain the previous complete save if a write is
interrupted. Reopening validates the map, route, format and confirmed geometry.
CPC4 snapshots store the route color and alternative areas, and still read existing CPC2/CPC3 drafts. They intentionally do not claim compatibility with the old
native branch's `.cpc` format. Legacy branches use CPC6 and retain CPC5
compatibility. [Shared section networks](shared-sections.md) additionally require
their CPN1 manifests and every referenced section draft. Publishing clears none
of these recovery files.

## Runtime and publication

The `routes` table uses permanent `routeID` keys, with a unique map/name pair
and optional start-checkpoint metadata. Route names and colors are editable
metadata, not identity. Shared section colors are stored in
`checkpointSectionColors`. See [route identity](../database/route-identity.md)
and [shared sections](shared-sections.md).

Finalizing requires valid confirmed areas and at least one finish. Multiple finish checkpoints must follow all ordinary checkpoints; each is connected to the last ordinary checkpoint and can complete the route. `!cp publish` remains an alias for finalizing. Finalizing creates
normal checkpoint IDs and connections plus `checkpointAreas` geometry. The
editor and gameplay share the same convex-footprint and height test. The player's
feet must be inside the perimeter, no lower than 2 units below its plane, and
no higher than 4 units plus the slope support offset and configured added height.
The drawn volume uses the same bounds. Grounded checkpoints also apply the
[contact speed/duration rules](ground-contact.md); `!cp ground` can disable that
ground requirement while preserving containment.

`!cp height <units>` accepts an added height from 0 through 16384. Without a
value, it enters height editing; Numpad Plus/Minus adjust the height rather than
placing a corner or undoing an edit, in 4-unit steps. Select at least three valid
corners first. A nonplanar manual selection can be flattened to its lowest corner,
with height extended to cover the selected corner elevations. Whole moving
platforms do not use height offsets. Height increases and Confirm check overlap
before applying the volume. Inspect the resulting footprint and height.

Double-RPG allowance comes from the next checkpoint and does not require being
inside its area. Equivalent next landing areas share that permission; an ambiguous
next checkpoint at a distinct route choice does not grant it. `!cp ele` and
`!cp allowsave` edit elevator and saving permissions. FPS exceptions have no
editor command.

For branches that share landings, use [split/merge editing](shared-sections.md)
instead of confirming overlapping copies. The restrictions below concern small
standalone route edits; network publication has its own recorded-geometry guards.

Finalizing an edited standalone CPC route automatically replaces its layout while
retaining completed times and low-RPG results. Start and finish must remain unchanged.
Supported changes are one checkpoint's geometry/alternatives, or insertion/deletion
of up to three consecutive ordinary checkpoints. Reorders, multiple independent
edits, changed requirements, and shared route connections are refused; the draft remains.

Publication and gameplay refresh have separate outcomes. If publication commits
but a database read fails or an alternative references an invalid group leader,
the current playable graph stays active
and the editor retains the draft. Its message confirms that publication succeeded;
retry `!cp finalize` after database access or the invalid group link is repaired. Repeating an unchanged
publication retains the published checkpoint IDs. A successful refresh closes the
editor and starts a fresh run.

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

Use the full [migration procedure](../../operations/database.md) before
deploying matching scripts. Migration 012 introduced retirement; later
migrations add route identity and data-safety requirements. Restarting alone
does not apply any of them.

Editing and preview testing suppress normal checkpoint scoring. Starting or
loading a run while the editor is active does not re-enable checkpoint scoring.
Entering the editor stops the run and suppresses normal run statistics and HUD updates.
The progress bar is cyan. On leaving the editor, reset your run to start normal play.

## HUD and geometry visuals

The CoD4x server copies at most 31 current and 31 archived HUD elements per
player. Alpha-zero elements still consume slots. The editor uses three text
blocks plus the client property panel and leaves the spectator list enabled.
It does not change protocol limits. Each text block is capped at 240 characters: the
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
| + / - | Add aimed corner / undo; adjust height while height editing |
| 1 / End | Toggle approach double RPG |
| 2 / Down | Toggle ground requirement |
| 3 / Page Down | Toggle saving permission |
| 8 / Up | Toggle elevator permission |
| 9 / Page Up | Toggle finish |
| 4 / 6 | Previous / next confirmed checkpoint |
| 7 / Home | Edit height |
| Delete | Delete selected / discard new / delete last, as labeled by the HUD |
| / | Add an alternative area |
| * | Cycle the selected area |

Use `!cp new` to prepare a new checkpoint. Publishing has no default shortcut;
`!cp stop` leaves the editor. The bindings above come from
[`checkpointcreation.gsc`](../../../server-gsc/opencj/checkpointcreation.gsc).

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
needed. Republishing preserves checkpoint identity and recorded history.
Changes outside the supported standalone-layout migration rules are rejected;
shared networks retain their stricter recorded-geometry guards.
Restoring a draft announces it in chat and queues a teleport to the center of
the active landing. An unfinished alternative falls back to an existing sibling;
an empty next selection falls back to the last confirmed checkpoint. Empty drafts
do not teleport. The queued move runs during the regular game update, never
inside the command callback. The panel presents one primary NEXT action, with
optional alternatives explicitly labeled.

## Playing published routes

A fresh run shows the first checkpoint areas for all routes. After selecting a
route by landing in its first checkpoint, only its next areas are eligible. In
any% mode, markers point to routes' finishes. The display uses the first 16
eligible areas; additional areas still count for gameplay. Areas that are
alternatives share one step.

CoD4 route markers use their exact RGB tint. Location-only mode uses world
sprites; all-markers mode also shows screen-edge markers and compass arrows.
Compass arrows use the nearest available palette color because the compass
cannot apply arbitrary RGB tint. Legacy checkpoints retain their fixed-color
materials.

Finishing saves checkpoint statistics before marking the run complete. The
leaderboard uses the finish snapshot of FPS mode, elevator use, any%, halfbeat
allowance, and hard-TAS use. Paused/cheated runs are not recorded as valid finishes.
Migration 003 introduced the finish snapshot. Historical halfbeat use predating
it cannot be recovered and is treated conservatively as allowed. Installations
must use the complete migration set, not just that feature migration.

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

While editing a confirmed checkpoint, Num Del / `!cp discard` acts like
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
