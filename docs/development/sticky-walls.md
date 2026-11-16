# Sticky-wall regression suite

Run: python3 dev-tools/tests/run-sticky-walls-native.py

Requires the existing Docker Compose build environment and mp_galaxy assets.
The runner builds a separate instrumented binary and temporary isolated servers
with account/database callbacks disabled. It does not modify the live server.
Results are retained under local/sticky-wall-spike.

Production recovery is unconditional. A test-only wrapper selects the original
or corrected recovery. Production contains no switch or diagnostic hooks.

Coverage:
- 1,728 real-wall alternating-velocity cases varying frame time, speed, position and reversal period.
- 700 full Pmove WA/WD sequences per variant, with native acceleration and gravity
  at two heights including the original reported ledge.
- 40 controlled native collision cases compare every step's position and velocity:
  air, floor, ceiling, ramp, corner, corridor and ordinary walls.
- Focused helper checks: cod4x-server/tests/sticky_walls.c.

The command tests start airborne using upward velocity, not jump-button takeoff.
Synthetic fixtures exercise native slide movement, not the whole collision engine.
These tests do not validate bounce heights or client prediction. An unmodified
client may still show prediction corrections because its movement is unchanged.

Expected: original alternating cases include stalls; corrected cases do not.
Corrected full-command cases do not stall. Unrelated synthetic cases retain
identical position and velocity histories with recovery disabled/enabled.
