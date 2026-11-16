# Demo lifecycle cleanup (#205)

Issue: https://github.com/OpenCJ-dev/server-gsc/issues/205

## Purpose and ownership

Demo start/stop behavior was split between unused event dispatchers, empty
callbacks and direct playback calls. Some callbacks repeated exactly the same
HUD cleanup as run events. The obsolete FPS callbacks also used wall-clock
delays, although production playback now processes recorded time.

Playback entry and exit remain owned by startDemo/stopDemo in
server-gsc/opencj/demos.gsc. demoDisplayStart/demoDisplayStop coordinate the
presentation. They call ordinary operations in the owning modules:

- showRecords::hideForSpectators and hudStatistics::hideForSpectators are shared
  with run-event cleanup. They include both the player and people watching them.
- Checkpoint pointers, progress and speed use their existing hide operations.
- notifications::cancelAll cancels active flashes and pending checkpoint/result
  feedback; disconnection uses the same operation.
- hudTimeLimit::setPlaybackLayout selects the normal or playback layout and is
  also used during initial HUD creation.

The unused events/ondemostarted.gsc and events/ondemostopped.gsc dispatchers,
their unused callbacks, and the obsolete demo FPS string/event helpers were
removed. There is no replacement dispatcher which pretends that watching a
recording is a gameplay event.

## Recorded FPS

hudFPSHistory::applyRecordedFrame is the former onDemoFrame implementation
with an explicit operation name. Its logic is unchanged. Playback continues to
use 50 ms source samples for input confirmation, bounce boundaries, landing
expiry and chronological rebuilds after seeking or reversing.

The obsolete wall-clock onDemoBounce/onDemoLand/onDemoLeaveGround helpers are
gone. FPS regressions now exercise recorded frames, including the 3,000-change
bounded-history check, duplicate suppression, bounce markers and exactly two
seconds of recorded landing time.

## Preserved behavior

Entering playback pauses the player's run and cancels pending action feedback.
Leaving restores position, view, velocity, health, pause/timer state, live FPS
history, speed state and the normal HUD layout. Checkpoint identity, run
identity and run counters remain intact. Save requests are ignored during
playback; load requests ask playback to exit.

Normal demos, clip editing and clip-browser previews retain their existing
menu overlay policies. The refactor does not change recording storage,
database schema, native animation/presentation code or client assets.
