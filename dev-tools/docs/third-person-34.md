# Third-person camera (#34)

The approved scope is **chat commands only**, available while playing,
spectating, and viewing demos/clips. No menus or client assets change.

| Command | Short alias | Values/default |
| --- | --- | --- |
| `!thirdperson [on/off]` | `!3p` | No argument toggles; off on every connection |
| `!thirdpersondistance <value>` | `!3pdist` | 40–300 units; default 120 |
| `!thirdpersonangle <value>` | `!3pangle` | 0–359 degrees; default 0 |

Angle 0 is behind the player; 180 looks from the front. Distance and angle remain
saved when third-person is off. These are personal viewing preferences, with no
changes to run progress, movement, checkpoints, or record classification. All
commands and aliases appear automatically in the existing help registry.

`server-gsc/opencj/camera.gsc` registers commands through the normal settings
module. Distance and angle are stored in `settings` / `playerSettings` via
`setPlayerSetting`. Enablement has `sessionOnly=true`: it is reset on connection,
excluded from setting writes, and older stored values are ignored without
deleting database records. Other settings retain their existing persistence.

At native initialization, `cg_thirdPerson=0` is published through initial
systeminfo before client map loading. This clears a camera left enabled on the
client without depending on account settings having loaded. The player stays
in first-person until explicitly enabling it through chat. The camera uses `cg_thirdPerson`, `cg_thirdPersonRange` and
`cg_thirdPersonAngle`. After connection initialization is acknowledged, current
values are reapplied; subsequent login preference callbacks apply loaded values.

During demo playback, the existing player body is shown to its owner using
`showToPlayer`. Native visibility gives it only to the owner and spectators
following that player, keeping it hidden from other players/free spectators.
Ending playback restores normal visibility. Existing recordings and their format
are unchanged.

Body motion uses the stock animation selector with the demo's recorded velocity,
keys, stance and weapon. This supports walking/running, sprinting, strafing,
crouching, prone crawling, climbing, jumping and landing. Short landing and
stance transitions use source-frame time; direct stand/prone transitions fall
back to the stock crouch/prone motion where the weapon's animation set omits
them. Event variants and animation restart bits remain stable across repeated
frames. These are reconstructed stock poses, not newly recorded exact animation
indices; existing OCJ1–4 recordings remain readable without migration.

Frozen, linked players normally receive an idle animation during movement
processing. The hook in `cod4x-server/src/g_active.cpp` reapplies the selected
demo body before copying player state into the outgoing entity. It only acts on
an active presentation with a selected pose. Ending presentation restores the
original animation state. No recorded input is sent through movement or weapon
simulation.
