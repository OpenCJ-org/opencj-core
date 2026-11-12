# Spectator FPS modes and halfbeat correction (#92)

## Player behavior

Use `!specfps detailed` (default), `!specfps compact` or
`!specfps off`. `!fpshistory` is an alias. The existing settings framework stores
the viewer's choice and adds it to command help automatically.

Structured phases replace the earlier special-case `332` insertion. Opening
parastrafe appears as `332` or `WA 3 > WD 32` once the new phase is confirmed.

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

The runner builds the debug server and an isolated test plugin, starts two test
clients without database callbacks or exposed ports, runs GSC/native checks,
then removes its test container. The plugin is never loaded into the runtime.

- `tests/fps-history.gsc`: real native-to-GSC input callback; modes, colors and
  fade state; phase labels and exclusions; history/command bounds; demo seeks,
  bhop timing and restoration.
- `tests/strafe-engine.cpp`: actual engine acceleration comparisons for left/right
  and forward/backward halfbeats, five world rotations, six command durations,
  positive excess gain, allowed-policy parity, direction/Z/momentum preservation,
  and state reset/exclusions.
- Logs/results: `local/fps-history-<id>/console.log` and `result.json`.
- Native build log/test plugin: `local/strafe-history-92/`.

## Real-demo noise evidence

`python3 tests/trace-fps-demo.py 3667 review`

A numeric ID performs only a SELECT export. An existing JSON export can instead
be passed as the first argument. Input JSON contains `runID` and `chunks` pairs
of chunk number/hex payload. A deterministic 50 ms playback clock drives the
fixture. It logs input samples, accepted source actions, Detailed strings (older traces also include the retired Live renderer); it does not touch a human client or write to the DB.

| Revision | Source actions | Marked switches | Live text changes | Live label changes | Unwanted A/S/D/None outputs |
| --- | ---: | ---: | ---: | ---: | ---: |
| Confirmed style, before duration gate | 342 | 73 | 200 | 131 | 0 |
| 150 ms gate and short Detailed | 214 | 50 | 182 | 113 | 0 |

The earlier four-action Detailed revision never exceeded 37 visible characters
or 61 encoded characters in that replay. Regression tests also cover longer FPS sequences and
truncation. The counts describe this recording, not a universal reduction target.

Previously noisy windows remain covered:
- Frames 182-201: WA -> W -> WD -> D -> WD -> neutral -> A -> landing.
- Frames 664-673: W -> neutral -> S braking.
- Frames 6212-6287: fullbeat followed by D/neutral/A/D landing taps.

The independent earlier style-confirmation fix removed the unwanted single-key
rows. The latest duration gate additionally rejects short alternations before
they reach any view; it does not change the native physics classifier.

## Final view simplification and demo toolbar (2026-11-12)

The demo toolbar keeps transport, direction and speed in one compact row:
- Checkpoint previous/next, pause/play, elapsed/duration, a current-state
  Forward/Reverse toggle, and Exit.
- Five speed buttons: Slowest (0.25x), Slow (0.5x), Normal (1x / default), Fast (2x),
  Fastest (4x). The selected speed remains highlighted.
- Direction changes preserve speed; speed changes preserve direction. Neither
  implicitly resumes a paused demo. New demos start Forward / Normal.
- Left/right shortcuts select the next slower/faster magnitude in the current
  direction. Chat also supports `!demo forward`, `!demo reverse` and
  `!demo speed 0.25|0.5|1|2|4`. Pause/resume remain separate.
- Fractional speeds accumulate recorded frame steps on the normal 50 ms ticks.
  Fractional ticks interpolate camera position and view angles between adjacent
  samples; they do not re-fire events or clear FPS history. Explicit seeks and direction/speed changes reset the
  remainder. Reverse playback pauses at the beginning while retaining the
  selected direction/speed.

Source: `client-mod/cod4/ui_mp/scriptmenus/opencj_demo.menu` and
`server-gsc/opencj/demos.gsc`. The clip editor's existing controls are separate.

Verification adds every speed in both directions, actual in-memory native
frame selection, menu responses, pause preservation, quarter-speed parastrafe
history, six-entry boundaries and fallback from stored Live preferences.
`tests/check_demo_menu.py` checks menu registration and control contracts.
The Windows Mod Tools build preserved all unrelated inputs; compiled menus
were unlinked and checked for the new controls with no warnings or errors.


### Toolbar layout correction (2026-11-12)

The correction restores the original y=443, height=37 bar. Every control uses
the original source y=449.5 (the stock linker's origin parser truncates this to
449), height=24. Transport, time, Forward/Reverse, five named speed buttons and
Exit occupy separate horizontal regions. Each speed button owns its text;
selected/unselected variants use identical rectangles. Checkpoint icons remain
visible but gray when navigation is unavailable. Multipliers and Normal's
default meaning are hover hints above the bar, hidden otherwise.
No playback or halfbeat logic changed.


### Playback consistency and toolbar refinements (2026-11-12)

Current speed labels are **Slowest, Slow, Normal, Fast, Fastest** (.25/.5/1/2/4).
The bar remains a single row, 37 units high. Transport uses centered geometric
pause bars and existing arrow materials, independent of font alignment.
Forward has a subdued green background; Reverse a subdued red background.
Speed buttons are 46 units wide. The established red X replaces Exit, at
x=606 with its right edge at 632. Time has an explicit baseline 16 units into
its 24-unit rectangle. Direct fractional rectangles preserve y=449.5 through
the linker, unlike the previous integer-parsed origin offsets.

Fast playback previously skipped source frames before updating FPS history,
causing discontinuity resets. The production pipeline now processes crossed
recorded samples in chronology, preserving the same 150 ms held-input filter,
FPS sequences and six-action Detailed view at every supported speed.
Landing expiry uses recorded time, so slow motion and pauses do not expire
history according to unrelated wall time. Leftover Live-only phase timing was
removed; Live itself remains unavailable.

Reverse and seeks display history as it stood at the selected recorded frame.
Rendered Compact/Detailed snapshots are cached separately from the mutable
event builder. Rebuilding looks back at most 512 samples (about 25.6 seconds);
an airborne history beginning at that bound visibly marks truncation. Cache
eviction is bounded; changes to demo, style or clip range invalidate it.
Peeking/rebuilding restores the native playback cursor before presentation.

Slow modes now interpolate camera origin and the shortest angular arc every
50 ms tick, instead of holding the entire picture for 100/200 ms.
Loads, edited-timeline cuts and large legacy position jumps (>256 units per
sample) remain discrete in either direction. Recorded input, events and native
weapon/stance presentation stay anchored to actual recorded samples; no
recorded movement or firing is re-simulated. This smooths camera movement
within the server tick rate, not arbitrary client frame-rate animation.


### Screenshot-based alignment correction (2026-11-12)

Adjusted bordered labels by (-1, -1.5) menu units, the time baseline from 16 to
17.5, and the X's horizontal bearing by -0.5. Repositioned the arrow artwork,
tightened the skip-symbol gaps and reduced stop/pause bars to a comparable
visible height. The toolbar, button rectangles, responses, playback code and
textures are unchanged. Both active/disabled checkpoint symbols use the same
placement.

Measurements and compiled validation: `local/demo-controls-92-alignment-r4/`.
Only opencj_demo changed among 275 compiled menus; all 323 runtime IWD entries
are unchanged. The deployed GSC/native files still exactly match the prior
158/740-check evidence, so gameplay tests were not repeated. Server restart
passed the player guard (operator only), restored mp_to_the_moon and produced no
script errors. Matching client menu installed with a backup and no game control
or process restart. User visual recheck remains pending; no commit authorized.
