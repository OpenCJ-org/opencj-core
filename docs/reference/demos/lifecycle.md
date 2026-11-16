# Demo playback lifecycle

## Ownership

`startDemo` and `stopDemo` in
[`demos.gsc`](../../../server-gsc/opencj/demos.gsc) own playback entry and exit.
`demoDisplayStart` and `demoDisplayStop` coordinate presentation through the
modules that own each HUD:

- `showRecords::hideForSpectators` and `hudStatistics::hideForSpectators`
  include both the player and people watching them.
- Checkpoint pointers, progress and speed use their own hide operations.
- `notifications::cancelAll` cancels flashes and pending checkpoint/result
  feedback; disconnection uses the same operation.
- `hudTimeLimit::setPlaybackLayout` selects the normal or playback layout,
  including during initial HUD creation.

Playback does not dispatch the removed `ondemostarted`/`ondemostopped` event
modules. New integrations belong in the explicit lifecycle above, rather than
reviving those old callbacks.

## Recorded FPS

`hudFPSHistory::applyRecordedFrame` uses 50 ms source samples for input
confirmation, bounce boundaries, landing expiry and chronological rebuilds
after seeking or reversing. Wall-clock delays must not advance a paused
recording's input history. See [FPS history](../ui/fps-history.md).

## Restoring live play

Entering playback pauses the player's run and cancels pending action feedback.
Leaving restores position, view, velocity, health, pause/timer state, live FPS
history, speed state and normal HUD layout. Checkpoint identity, run identity
and counters remain intact. Save requests are ignored during playback; load
requests ask playback to exit.

Normal demos, clip editing and clip-browser previews retain their own menu
overlay policies. Storage ownership is described in [recording](recording.md)
and [native memory](../native/memory.md). Use the
[test guide](../../development/testing.md) for the lifecycle and FPS fixtures;
their existence does not establish a pass for a new binary/script pair.
