# Demo viewing

Recording formats and retention are described in [recording and storage](recording.md).
Automatic help selection is described in [selection](selection.md).

## Playback controls

Melee toggles pause; each strafe-left/right press steps through
-4x, -2x, -1x, 1x, 2x, 4x. Lean-left/right selects the previous/next recorded
checkpoint boundary for non-any-percent runs. Previous always selects the preceding checkpoint, even during a jump.
Reverse pauses at the start and resets to forward 1x for the next Play. Navigation
from a local jump segment opens the full recording timeline, and preserves pause.
Load still exits to the original run. Commands `!demo pause`, `!demo resume`,
`!demo speed -2`, `!demo previous` and `!demo next` provide bindable alternatives.
The time display describes retained recording time (20 frames/second), not
leaderboard time that may include discarded attempts. The normal progress bar
is hidden during playback and restored on exit.
On CoD4 a transparent mouse menu opens automatically with Pause/Resume, all six
signed speeds, checkpoint navigation, and Exit Demo. Escape hides/reopens
the controls. The menu requires matching compiled mod.ff; keyboard controls remain
available while the menu is closed. Menu responses are ignored outside playback.

## Player behavior

- Demo headings identify walkthrough, low-RPG or speedrun playback, its author,
  route, original run rules/FPS category and the run's RPG-jump count.
- Clip headings identify the clip and author. The browser retains four rows,
  each with a second line for RPG shots, airborne FPS category, elevation and
  views. Shot count is deliberately distinguished from RPG jumps.
- Viewer menus offer Original / Fullbeat / Halfbeat / Invert. The selection lasts until
  reconnecting, including between demos and clips. It does not change the
  recording, result category, route, timing, trajectory or gameplay physics.
- Camera yaw, keyboard display, third-person movement and Detailed specFPS use
  the same converted inputs. Compact continues to report FPS changes only.
- !view <player> opens a fixed copy of the player's current unfinished run,
  including unsuccessful attempts. Exact names take precedence over partial
  matches; ambiguous matches are refused.
- Fixed run history pauses on its final frame, even when !demoloop is enabled.
  The time bar shows End; review or exit remains available.
- The heading is VIEWING <player>'s RUN HISTORY, followed by Fixed copy.
  Do not add "Recorded up to <time>": the playback bar already provides timing.
- History sharing is enabled by default. !sharehistory off persists as a normal
  player setting, blocks new requests and exits existing other-player views.
  Players can still view their own history. !sharehistory on enables it again.

## Walkthrough playback

Walkthroughs play only the successful path and shorten setup time without
moving the player abruptly:

- Still waiting on the ground (same position and view) of a second or more is
  cut to 0.2 seconds; both ends of the pause stay.
- Other grounded setup of 1.5 seconds or more (walking back, lining up, turning
  the view) plays three times faster. Every retained step is at most three
  recorded frames, so playback interpolation keeps the movement continuous.
- These keep their recorded speed: anything off the ground, ladders and mantles,
  the last 1.5 seconds before leaving the ground, 0.5 seconds after landing,
  0.5 seconds around each RPG shot and checkpoint arrival, loads and the
  requested range ends.

Speedrun and low-RPG playback are unchanged. The time display counts the
shortened walkthrough.

Personal demo-type preferences, ghost racing, guided loops and combined
walkthroughs are not implemented.

## Conversion and resource boundaries

Conversion recognizes stable fullbeat phases or a repeating halfbeat pattern.
The 150 ms confirmation threshold remains. Releases alone do not establish
halfbeat. Confirmed mixed FB/HB phases normalize to the requested style;
ambiguous direction changes, loads, ladders and mantles retain the recorded
input. The initial diagonal selects the HB pattern; opposite diagonal phases
convert from their first sample, including around bounces and RPG shots.
Recorded firing aim is preserved by camera-only blending, without reverting
converted keys. The menu shows "Original section" when
conversion is unsuitable. FPS changes are never removed.

The native layer keeps one 24-byte section classification per viewer, plus its
current presented sample. Rebuilding FPS history reuses this classification
instead of rescanning a jump for every frame. Searches are bounded to 512 samples.
No extra arrays of recording frames are retained in GSC.

History copies use the existing native recording storage and cache ownership.
They are immutable, independent of the source's later loads, append operations
and disconnection, and released on playback exit/disconnect/request cancellation.
The existing shared 128 MiB native recording budget applies to creation as well
as growth and copying. Capacity refusal leaves the source recording intact.

## Clip metadata and views

Migration server-db/migrations/024-demo-viewing.sql adds nullable RPGShots,
FPSMode and eleUsed plus viewCount, and a demoClipViews receipt table.
countClipView locks one clip row and transactionally inserts a unique receipt
before increasing its count. Only EXECUTE is needed by the runtime for receipts.

A view is counted after actual, unpaused clip presentation, once per logged-in
viewer/clip/server-process session. Previews, editor playback, the owner's views
and repeated loops do not count. A process-session UUID survives map changes;
normal heartbeat cleanup removes old receipts while retaining total view counts.
The owner's original map-session clip lifetime is unchanged.

New OCJ5 chunks retain actual elevation events so trimming excludes events
outside the selected range. OCJ1-4 remain readable. Legacy elevation stays
unknown. Airborne FPS determines 125/Mix/Hax; footage with no airborne samples
has no inferred category.

## Converted camera limitations

The viewing pattern stays anchored to takeoff: WA -> D -> WA, or WD -> A -> WD.
The opposite phase converts from its first recorded sample. Bounce and RPG
events do not change the pattern or disable conversion. The existing 150 ms
history confirmation still applies. Native phase metadata accompanies history
events so Detailed follows the converted pattern while airborne. Compact
continues to describe FPS changes only. A single diagonal hop with no strafe
change has no opposite phase to convert and remains its recorded takeoff.

Camera smoothing acts only on added conversion yaw; original shot aim is locked
at the firing sample. The RPG turn is separate from ordinary strafe smoothing:
one halfway sample 50 ms before/after firing, full converted angle at 100 ms.
This avoids applying a broad smoothing filter on top of the aim flick.
Thus the displayed keys stay converted during aiming; they are an interpretation,
not the original input log. Trajectory, shot timing, FPS, boost and saved payload
are unchanged. Reverse/seek are deterministic, and load cuts are not blended.
The current camera behavior is accepted as an approximation. The synthetic
out-and-back aiming turn can differ from a real halfbeat player. During this
turn, converted keys and camera are not guaranteed to reproduce the recorded
movement if applied as real inputs. Coordinating keys, camera and strafe phase
around shots remains deferred work; numeric checks do not establish authenticity.

Invert retains the original diagonal takeoff, then uses A/D on both sides. A repeated A/D pattern can also normalize to Fullbeat/Halfbeat. The viewer fixture covers reverse and seek behavior.
