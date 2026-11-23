# Sticky-wall regression suite

Run:

    python3 -B dev-tools/tests/run-sticky-walls-native.py

Requires existing CoD4 build objects, the Docker Compose build environment and
mp_galaxy assets. Build the engine first using the normal development workflow.
The runner reuses the Makefile's link inputs, records their object hashes, and
replaces only the slide trace and recovery objects in a separate test binary.
Production source, objects and the installed engine stay unchanged.

Each invocation retains its binary, build log, native results and source hashes
under `dev-tools/local/sticky-walls-<id>/`. Build and server containers belong to
that invocation and are removed on success or failure. Account/database
callbacks are disabled in the isolated servers; no live restart is needed.

Production recovery is unconditional. A test-only wrapper selects the original
or corrected recovery. Production contains no switch or diagnostic hooks.

Coverage:

- 1,728 real-wall alternating-velocity cases varying frame time, speed, position
  and reversal period.
- 700 full Pmove WA/WD sequences per variant, with native acceleration and gravity
  at two heights including the original reported ledge.
- 40 controlled native collision cases compare every step's position and velocity:
  air, floor, ceiling, ramp, corner, corridor and ordinary walls.
- Focused helper checks: `cod4x-server/tests/sticky_walls.c`.

The command tests start airborne using upward velocity, not jump-button takeoff.
Synthetic fixtures exercise native slide movement, not the whole collision engine.
These tests do not validate bounce heights or client prediction. An unmodified
client may still show prediction corrections because its movement is unchanged.

Expected: original alternating cases include stalls; corrected cases do not.
Corrected full-command cases do not stall. Unrelated synthetic cases retain
identical position and velocity histories with recovery disabled/enabled.

For the GSC geometry probe alone, use `run-sticky-walls-server.py`. It defaults
to the installed engine and mp_galaxy. To inspect a prepared test binary, pass
`--binary /workspace/dev-tools/local/sticky-walls-<id>/cod4x18_sticky_live_test`,
`--recovery 0` or `1`, and optionally `--print-native`. Other maps can be supplied
as positional arguments, but the reported wall coordinates are specific to
mp_galaxy. Probe completion alone does not verify native recovery; the full
native runner checks all scenario results.
