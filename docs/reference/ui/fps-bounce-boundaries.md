# Spectator FPS at bounce boundaries

## Display rule

The first 150 ms after a bounce is buffered for presentation in both Compact
and Detailed. Raw actions and FPS changes remain untouched.

- If the initial post-bounce FPS repeats the approach FPS and changes within
  150 ms, the repeated leading value is omitted from the displayed exit phase.
  It is already represented immediately before the bounce marker.
- A new strafe that begins within that window is grouped with the exit once it
  passes the normal 150 ms held-input confirmation. The wait can therefore last
  until the candidate confirms. Short rejected taps create no extra strafe.
- Every subsequent FPS change in the window is retained. For example,
  carried `2` followed by `3 -> 2 -> 3` displays `323` after the marker.
- A strafe beginning later stays separate. Unchanged exit FPS is displayed
  after the window. A later FPS switch retains that established initial value.
- Demo timing uses recorded samples, including pause, slow/fast playback and
  reverse/seek reconstruction. Live presentation has a short refresh timer.
- Source events keep their original FPS strings; only the shared display
  projection is simplified. Existing parastrafe and halfbeat rules are retained.

Production changes are confined to
`server-gsc/opencj/huds/hudfpshistory.gsc`. No physics, recordings, database
records, client assets or native executable changed.

## Compact FPS-only sequence

Compact merges equal adjacent FPS values across all strafe phases, including
fullbeat and halfbeat. Strafe changes alone never append another digit.
Detailed retains each confirmed strafe and its own starting FPS.

For example, repeated adjacent `2` values collapse into one Compact entry, while Detailed retains each confirmed strafe and its FPS sequence. Bounce (`-`) and bhop (`/`) markers continue separating segments.

## Tests

The FPS history fixture covers held-input confirmation, rapid FPS changes, unchanged exits, late strafes, rejected taps, ground-only changes and airborne switches before landing. Recordings and trace outputs containing player data stay private; public regression cases use synthetic sequences.
