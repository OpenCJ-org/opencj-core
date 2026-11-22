# Tutorial mode

Tutorial mode is a separate run mode for new players. While a tutorial run is
played, the server sets the player's `com_maxfps` during jumps. Tutorial runs
never count for leaderboards, record notices, finish sounds or challenges, and
are never recorded as demos or clips.

Status: CoD4.

## First-connect introduction

A new account is asked "Are you familiar with the gameplay mechanics of CoD4
CodJumper?" on its first spawn (`opencj_tutorial_intro` menu). "No" leads to
the offer (`opencj_tutorial_offer`): the mechanics are complex and the learning
curve steep, so tutorial mode is strongly recommended. "Yes" there switches the
`tutorial` setting on, which makes the current and all new runs tutorial runs.
Pending state is the saved `tutorialintro` setting: new accounts get it on,
answering switches it off, and closing a popup with Escape asks again on the
next connection. `!tutorialintro` shows the introduction again on the next spawn.
Both popups dim the whole screen, also on widescreen displays.

Tutorial runs show a green graduation-cap "Tutorial" badge
(`opencj_icon_fps_tutorial`, built by `client-mod/source/build_mode_icons.py`)
in place of the FPS badge in the run HUD, the scoreboard and the runs board,
because the server picks their FPS. It needs a client build that includes the
material.

## Player behavior

`!tutorial [on/off]` is a saved account setting that chooses the mode of new
runs. A run's mode is fixed when the run is created:

- Before the run has started, switching changes the current run in place.
- Otherwise switching saves the current run (without a label), then starts a
  new run in the chosen mode. If the save fails, the run
  stays as it is and the setting applies to the next run. A run without any
  saves cannot be restored or listed, so it is archived like `!reset` instead.
- The runs menu shows the tutorial badge in the FPS column of tutorial runs and
  a cyan `[Tutorial]` prefix on their names. Only the Any FPS filter lists them;
  their FPS is chosen by the server, so Classic and Standard exclude them.
- Loading a save, including restoring a saved run, takes that run's mode from
  the save (save flag 512).

While a tutorial run is being played (started, playing, not in a demo or the
checkpoint editor), the server chooses the FPS. When that stops, the player's
own `com_maxfps` from before is given back. The mix/hax FPS settings never
load a tutorial run back, because the server changes the FPS on purpose.

## FPS rule

Implemented in `server-ext/opencj_autofps.cpp`:

- On the ground: 333.
- In the air: whichever of 333, 250 and 125 keeps the most horizontal speed
  over 48 ms with the current movement keys and strafe angle (the view
  turning with the velocity, as when strafing), decided again on
  every movement command. Strafe switches can therefore bring 333 back, as in
  333-250-333-250-125. 333 or 125 must beat 250 by at least 0.5 units/s;
  near-ties (around a 90 degree strafe angle, where no FPS gains speed) stay
  on 250. Without movement keys: 250.
- Height: scripts report the nearest point of the nearest next checkpoint
  (for a landing area, the nearest point of its edge) every server frame. When,
  flying the current way, the player would reach it horizontally below its
  height at 250/125 but at or above it at 333, the FPS is 333. When even 333
  falls short (for example before a bounce), the FPS cannot help and speed
  decides. Also 333 while climbing towards it when the peak at 250/125 would
  stay less than 48 units above it but the peak at 333 reaches it: the arrival
  time ignores that strafing adds speed, so right after a bounce it is too
  late and would wrongly give up (seen on a no-RPG mp_futile_fixed jump).
  The check uses the current position and speed, not the takeoff
  spot, so a low bounce towards a landing as high as the start gets no 333.
- Height stops deciding (for the rule above and the RPG rise below) once 250,
  with the speed it adds at the current keys and strafe angle, would still reach
  that point at least 32 units above it. On recorded RPG climbs this ended 333
  about 1 s before the peak, where holding it had kept speed flat.
- During a rise started by an RPG push (including an RPG on a bounce): 333
  until shortly before its peak. An RPG push
  and a bounce both raise the player's speed while the server processes a
  movement command, so speed
  alone cannot tell them apart. A push is an airborne upward gain of at least
  50 units/s over one command, with an RPG fired by the player within 500 ms
  before or after it. Map boosts are not treated as pushes. The switch away
  from 333 is made early by the client's ping (at most 300 ms), because a new
  `com_maxfps` takes effect only when the client receives it.

Why: the engine rounds velocity to whole units every client frame. At 333 FPS
a player loses 2 units/s of vertical speed per 3 ms frame (effective gravity
666); at 250 and 125 FPS the effective gravity is 750. 333 gives more height
and hang time; the best FPS for gaining speed depends on the angle between
view and velocity.

Delivery: a change is sent with an extra snapshot right away instead of with the
next server frame (at most one extra snapshot per player per server frame;
server setting `opencj_autofps_immediate`, default on). While auto-FPS is on,
`cl_maxpackets` is raised to 100 for clients that report their own value (the
client mod registers it as userinfo) and given back afterwards, so the server
sees strafe switches sooner. Recorded attempts on mp_futile_fixed measured
80-140 ms from a key change to the client running the new FPS before these.

Limits: the arrival estimate assumes a straight path at the current speed. A
server-chosen FPS still arrives at least one ping late, so very short changes
cannot be applied precisely.

## Route

Tutorial runs follow a route, because the height check aims at the next
checkpoint. Triggering a checkpoint that would start any% (a skipped
checkpoint or a route change) does not count: the player is loaded back to
their last save, or the run starts over when it has no saves. Saving is
refused (`Cannot save here: tutorial runs follow the route`) while such a load
is pending or while touching such a checkpoint.

The server sends `com_maxfps` like GSC `setClientDvar`, only when the value
changes, and waits while 32 or more reliable commands are unacknowledged.

## Storage

Before a tutorial finish is recorded, the run is marked with
`playerRuns.tutorial = 1` (migration 027). If that cannot be confirmed, the
finish is not recorded. Ranking queries require `tutorial = 0`.

Tutorial runs start no run recording, so they never become published demos or
appear in live history viewing. `!record` is refused during a tutorial run, and
a clip recording already running stops when a tutorial run is played.

## Tests

The `tutorial-mode` catalogue group checks the rule on synthetic player states
inside an engine, the save flag and the script API. Test clients do not send
movement commands, so no test observes a real client applying `com_maxfps`.
