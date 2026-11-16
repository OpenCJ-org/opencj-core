# Spectator FPS history and halfbeat correction

Current behavior and implementation constraints. Earlier toolbar prototypes and
installation acceptance records are retained privately, not as setup requirements.

## Player behavior

Use `!specfps detailed` (default), `!specfps compact` or
`!specfps off`. `!fpshistory` is an alias. The existing settings framework stores
the viewer's choice and adds it to command help automatically.

- All modes share a **150 ms minimum held-input duration** before a new strafe
  enters history. Initial takeoff appears immediately. Rejected shorter taps
  contribute their FPS changes to the existing phase without another strafe
  entry. A confirmed phase retains the FPS sequence from its first sample.
- Detailed shows at most six recent phase/event entries, for example
  `... > WA 323 > WD 2 > BOUNCE > WA 32`. A-side labels are purple, D-side
  labels green, FPS digits white. Bounce is cyan and bhop gold in CoD's inline
  text palette. Explicit labels also identify actions without relying on color.
  Older entries have a visible `...` marker. An FPS run longer than eight
  characters shows `...` and its newest five digits.
- Compact shows FPS changes independently of strafe changes. An opening
  parastrafe is `32`; unchanged FPS at a confirmed strafe switch adds no digit.
  `-` still denotes bounce and `/` bhop.
- Live is no longer supported. Its HUD rows, fade updates and help
  option are gone. Existing saved `live` values safely resolve to Detailed.
- Detailed groups release/landing adjustments into their strafe phase:
  WA -> W -> WD -> D displays WA, then WD, preserving FPS changes throughout.
  Neutral input never becomes an entry. Straight W jumps keep W through S braking
  and A/D steering.
- Halfbeat requires a repeating confirmed pattern: WA -> D -> WA or
  WD -> A -> WD, including mirrored/backward variants. The first single-key
  phase is recovered retrospectively after that confirmation. Short taps do
  not establish the pattern. The first established fullbeat/halfbeat style
  persists for the airborne history; later braking cannot reclassify it.
- Off hides the FPS history HUD.
- Source histories retain up to 64 newest events; Compact stays within 512
  characters and each source FPS sequence within 480.
  Truncation is visible.

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
[demo viewing](../demos/viewing.md) for current controls. The removed Live mode
must not be reintroduced by following an older proposal.
