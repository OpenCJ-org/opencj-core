# Spectator FPS history and halfbeat correction

Current behavior and implementation constraints. Earlier toolbar prototypes and
installation acceptance records are retained privately, not as setup requirements.

## Player behavior

Use `!specfps detailed` (default), `!specfps compact` or
`!specfps off`. `!fpshistory` is an alias. The existing settings framework stores
the viewer's choice and adds it to command help automatically.

Structured phases replace the earlier special-case `332` insertion. Opening
parastrafe appears as `32` in Compact and `WA 3 > WD 32` in Detailed once the
new phase is confirmed.

## Implementation

`server-gsc/opencj/huds/hudfpshistory.gsc` holds source actions and renderers.
Detailed uses one HUD string with inline color codes and ASCII separators.

CoD4x reports complete held forward/right input and ground state after processed
movement commands. `CodeCallback_MovementState` feeds the HUD. FPS values use the
existing detection pipeline. A pending candidate buffers FPS until its input is
held for 150 ms. A cancellable timer confirms live input even when no further
input-change callback arrives; replacement candidates start their own timer.
Landing rejects a shorter pending phase. Loads, seeks, resets and legacy setters
cancel pending state. Demo entry merges pending FPS before saving live history;
return restores the accepted input and never resumes an old pending timer.

Bounce/bhop markers split buffered FPS at the event while preserving the held
input's confirmation timer. This prevents either moving pre-bounce FPS after the
marker or losing a continuing native strafe when no further key event arrives.

Demo playback uses the same input gate, actions and renderers, with **recorded
50 ms sample time** instead of a wall-clock hold timer or nominal client FPS.
Pausing playback cannot confirm a pending strafe. Seeks, reversed/skipped frames
and recorded loads reset history; interpolation is ignored. A same-frame
input/FPS change uses incoming FPS. Bhop contact duration also uses sample time.
Input changes absent from the recording cannot be reconstructed.

The 150 ms gate affects HUD history only. Native halfbeat acceleration correction
continues processing every eligible movement command.

## Halfbeat correction

The former 100 ms GSC component-gain detector applied a 10% horizontal momentum
cut. Native handling now runs at PM_AirMove's original acceleration call, before
collision and bounce resolution.

A shared input classifier recognizes opposite-side diagonal -> A/D halfbeat,
including the S counterpart. Same-side landing adjustments are excluded.
Landings, fresh jumps, stale commands and load/run/demo transitions reset phase
tracking. Adding a diagonal input updates its anchor for mixed styles.

When halfbeat is disallowed in an active scored run:

1. Call the original CoD4 acceleration routine for actual A/D input.
2. Call the same routine with a copy of pre-acceleration state, adding the W/S
   counterpart, with the same view basis, wish speed, duration and settings.
3. Limit actual horizontal speed to the larger of pre-existing momentum and
   reference speed. Preserve actual steering direction and Z velocity.

The reference is corresponding fullbeat at the same view angle, not a claimed
maximum across all possible steering angles. No ET/RIK acceleration constants
are imported. There is no percentage penalty or subtraction of pre-existing
RPG/bounce momentum. Collision/bounce impulses occur after the hook.
Slopes/ground planes, non-normal movement and durations over 50 ms use the
unchanged engine path.

`!allowhalfbeat` and run/leaderboard eligibility retain their meaning.
Pause, stop, finish, spectating and demo entry disable correction immediately;
load/resume/start reset tracking. A 50 ms loop synchronizes remaining policy
changes and reports the first correction.

Native code: `server-ext/opencj_movement.cpp`, `opencj_movement.hpp` and
`opencj_strafe_logic.hpp`. CoD4x integration: `src/opencj_main.cpp` and the
air-acceleration adapter in `src/asmsource/_bg_pmove.asm`.

## Reproducing checks

From `dev-tools`:

`python3 tests/run-fps-history-smoke.py`

The runner builds an isolated test plugin and uses the current server executable
(or a supplied `--binary` candidate), starts two test clients without database
callbacks or exposed ports, runs GSC/native checks, then removes its test
container. It does not rebuild or replace the live executable. The plugin is never loaded into the runtime.

- `tests/fps-history.gsc`: real native-to-GSC input callback; modes, colors and
  fade state; phase labels and exclusions; history/command bounds; demo seeks,
  bhop timing and restoration.
- `tests/strafe-engine.cpp`: actual engine acceleration comparisons for left/right
  and forward/backward halfbeats, five world rotations, six command durations,
  positive excess gain, allowed-policy parity, direction/Z/momentum preservation,
  and state reset/exclusions.
- Logs/results: `local/fps-history-<id>/console.log` and `result.json`.
- Native build log/test plugin: `local/strafe-history-92/`.

## Playback and bounce boundaries

Reverse playback and seeks display history for the selected recorded frame.
Rendered Compact/Detailed snapshots are cached separately from the event builder.
Rebuilding is bounded to 512 samples; an airborne history beginning at that bound
shows truncation. Changing the demo, style or clip range invalidates the cache.
Rebuilding restores the native cursor before presentation.

Slow playback interpolates camera origin and the shortest angular arc at the
server tick rate. Loads, edited cuts and large recorded position jumps remain
discrete. Input and weapon events stay tied to recorded samples.

See [bounce boundaries](fps-bounce-boundaries.md) for exit grouping and
[demo viewing](demo-viewing-24.md) for current controls. The removed Live mode
must not be reintroduced by following an older proposal.
