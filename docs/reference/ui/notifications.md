# Action feedback and record notices

Text is the default. Optional checkpoint/save/load flashes appear only along
the left and right screen edges. Finished-run results can use a stronger
full-screen flash, only for the player who finished. Result/error text remains
ordinary iprintln and is not hidden by action feedback settings.

## Player settings

| Command | Effect |
| --- | --- |
| !notifications | Show current choices |
| !notifications all both | Text plus edge flashes; also enable result flashes |
| !notifications text | Restore text-only feedback everywhere |
| !notifications flash | Edge flashes without routine action text; results keep text plus flashes |
| !notifications off | Disable routine action feedback and result flashes; result/error text remains |
| !notifications checkpoint both | Override checkpoint feedback |
| !notifications save text | Override save feedback |
| !notifications load flash | Override load feedback |
| !notifications results both | Enable finish/record/challenge flashes |
| !notifications results text | Keep finish/record/challenge text without flashes |
| !notifications strength low | Choose low, medium or high flash strength |

The command automatically appears in the normal help catalogue.
Existing account settings persist notify_checkpoint, notify_save and
notify_load (0 off, 1 text, 2 flash, 3 both), notify_results (1 text, 3 both)
and notify_strength (1 low, 2 medium, 3 high). No schema migration.
Defaults are text and low strength. Existing players must explicitly enable
the new result option, for example by running !notifications all both again.

## Presentation

| Event | Color | Area |
| --- | --- | --- |
| Checkpoint | Green (0.05, 1.00, 0.10) | Left and right edges |
| Save | Blue (0.05, 0.25, 1.00) | Left and right edges |
| Load | Red (1.00, 0.05, 0.05) | Left and right edges |
| Finish | Blue | Full screen |
| Personal best / server record | Green | Full screen |
| Challenge reward | Gold (1.00, 0.65, 0.05) | Full screen |

Each side glow occupies the outer 64 units of the fullscreen 640-unit space.
Its opacity fades smoothly inward and tapers near the top/bottom corners; the
central 80% stays completely clear. The pair fades in over 50 ms, holds
for 100 ms and fades out over 150 ms: 300 ms total. Low/medium/high peak opacity
is 56/255, 72/255 or 88/255 (approximately 22%, 28%, 35%).

Result feedback fades in over 100 ms, holds for 200 ms and fades out over
350 ms: 650 ms total. Peak opacity is 72/255, 88/255 or 104/255
(approximately 28%, 35%, 41%). Result text remains iprintln.

All opacity levels align to CoD4's 8/255 transmission steps. The foreground
draw pass avoids the stock HUD visibility gate. Flashes remain hidden in menus
and use a low HUD sort order. Routine feedback uses two small mirrored gradient materials. Finished-run
feedback continues to use the existing white material.

There are at most two temporary notification HUD elements per player:
a glow pair or one result overlay. Repeated actions recolor the existing pair
without extending its lifetime. Overlapping result flashes reuse one overlay,
with record > challenge > ordinary finish priority. Full-screen result feedback
never appears for other players receiving the global record text.

Confirmed finishes open a two-second window for asynchronous record/challenge
upgrades. A late result is ignored if the player has loaded, saved, passed
another checkpoint, started a new run/instance, entered a demo, changed
preferences or disconnected. Active flashes are cleared on new run, demo
entry, setting changes and disconnect. Loading replaces a result overlay with
the configured edge feedback.

## Record comparisons

A confirmed finish produces a public summary with route, category, elapsed
time and RPG count, after finish statistics and metadata are stored.

A previous result is comparable only when map, route, FPSMode (125/mix/hax),
elevator, any%, halfbeat and hard-TAS flags all match. Alternate non-retired
finish checkpoints on the same route count. This exact-category comparison
does not use the broader eligibility filters used to browse leaderboards.
An any% finish ten minutes faster than a checkpoint route finish cannot claim
that checkpoint-category record.

Time and RPG records are independent. Time ranks by elapsed time, then RPGs;
RPGs rank by RPG count, then elapsed time. Improvement messages include the
difference and describe tie-break wins. Exact ties, worse results and the
first result in a category do not claim a beaten record.

Server records use global iprintln and the player's record display name.
Personal bests and challenge rewards use private iprintln. A finish improving
both a server record and personal best produces both messages, but one result
flash. Loads and saves are not record announcement metrics. Starting another
run keeps a pending announcement for the saved finish; disconnecting cancels it.

Checkpoint text compares matching-mode splits from completed runs using
the player's time/RPG leaderboard sort. It does not claim a completed-run
record. Loading, stopping or replacing a run, changing feedback settings,
entering a demo, passing another checkpoint, or disconnecting removes obsolete
checkpoint comparisons from the SQL queue. Closing a menu leaves them active.
A running SQL read retains its connection until completion within the pool's
read deadline. Late replies still check the run, instance and checkpoint layout;
a cleared run identity is rejected safely.

## Implementation

- server-gsc/opencj/notifications.gsc: preferences, command, edge/result HUDs,
  result priority and lifecycle guards.
- server-gsc/opencj/recordnotices.gsc: exact-category queries, improvement
  formatting, audience selection and checkpoint split feedback.
- Existing save/load, checkpoint, finish, challenge, demo and disconnect hooks.
- client-mod/source/build_notification_glow.py: reproducible mirrored gradient
  IWI images and 2D alpha-blended material bindings, included by cod4/mod.csv.
The glow builder accepts an optional `--output` directory for an isolated
rebuild. It uses the existing compiled rank material and its properties as
templates, validates their layout before writing, and preserves the package
manifest entries. Rebuild the client package with `makeMod.py` when generated
assets change.
