# Route progress bar

A full-width gray track remains visible throughout a normal checkpoint run.
The green foreground shows completed progress using the existing checkpoint
counts. Before the first checkpoint, only the track is visible. Existing run
information above the bar, location, height, artwork and 250 ms width animation
are unchanged.

- Track: neutral gray (0.5, 0.5, 0.5), peak alpha 112/255 (about 44%).
- Completed fill: green (0.2, 0.8, 0.3), alpha 216/255 (about 85%).
- Checkpoint pass: a fast green flash across the entire bar, with a near-instant
  onset (1 ms), a 100 ms peak and a 100 ms fade-out. The remaining section flashes
  green (0.1, 1, 0.2) at 232/255 opacity, while the completed section brightens
  to (0.4, 1, 0.5) at the same opacity. The usual gray/green split then returns.
- Finish: the whole bar becomes green and pulses more strongly, peaking at
  248/255. Restoring an already finished run does not repeat the pulse.

The track sits behind the fill, so progress adds no changes to checkpoint
detection, route selection or run timing. One additional HUD element is kept
per connected player; checkpoint pulses reuse both existing elements.

The existing full-width red status for paused/invalid/stopped runs and cyan
checkpoint-editor status remain. Any%, death, spectating and demo playback
retain their existing hiding behavior. Both layers hide in menus. Run updates
and hiding cancel pending pulses, preventing an old flash from revealing a
hidden bar or overwriting a new state.
