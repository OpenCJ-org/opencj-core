# Demo viewing (#24)

## Accepted behavior

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

## Deployment incident and follow-up

## Camera, live Detailed labels and toolbar revision

The viewing pattern now stays anchored to takeoff: WA -> D -> WA, or WD -> A -> WD.
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

Reference definitions:
- [CoDJumper / 3xP Viruz: Lets do it Halfbeat](https://www.youtube.com/watch?v=fxbg-JJSgkA):
  the creator describes alternating WA/D or WD/A, with a diagonal takeoff because
  CoD4 cannot sprint sideways.
- [Seren: CoD4 Halfbeat CJ / DR Advanced Strafe](https://www.youtube.com/watch?v=ATk8Imx8fj0):
  distinguishes the no-W A/D alternation as invert. Bounce contact alone does not
  prescribe which halfbeat phase should be held; that follows from the pattern.
Public descriptions were read directly; no claim is made to have watched footage.

The purple viewing-technique button sits inside the original 37-unit bar.
It is 46 units wide (matching Normal) with 24 units of space to both neighbors.
Hover says "Switch viewing technique"; no implementation detail is included.
The Original-section indicator cannot overlap the hint.
Both time and checkpoint text moved down two menu units after screenshot review.
Checkpoint progress comes from the recorded CP and selected published route,
including shared checkpoints and seeks; start is zero. Any%, history and clips
omit the fraction. No extra DB table or per-player checkpoint array is used.

Runtime scripts remained pinned while editing. Matching binary/scripts/assets
are deployed together after the player check, restoring the captured map.
The client build changes only the intended toolbar; the IWD is preserved with
its license. No game process control is used.

Invert retains the original diagonal takeoff, then uses A/D on both sides.
A confirmed repeated A/D pattern in source footage can also be normalized to
Fullbeat/Halfbeat. Detailed uses an explicit Invert style; Compact is unchanged.
The four-state cycle and reverse/seek behavior are covered by the viewer fixture.
