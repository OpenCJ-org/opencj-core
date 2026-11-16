# Hold scoreboard implementation history

Historical investigation notes: the stages below describe successive prototypes,
not current setup instructions. The production Tab implementation supersedes the
F10 spike configs, which have been removed. Keep this record for the client input
and parser findings; consult current source for layout and configuration.

The initial experiment required no server changes, fastfile replacement, or
executable patches. It temporarily used F10 while leaving Tab unchanged.

## Evidence
Read-only disassembly of the installed iw3mp.exe, plus CoD4x_Client_pub:
- CL_KeyEvent 0x467eb0: normal gameplay repeat presses are suppressed at 0x467f79.
- Key-up at 0x468246 reads the CURRENT binding and, if it begins with +,
  queues its minus counterpart (0x468255 onward).
- CG_ScoresUp_f 0x42a9d0 only starts native fading if scores were already visible.
- Ordinary +vstr/-vstr is not registered in the examined client sources/binary.

## Client test result

operator reports that the corrected dvar diagnostics appear to alternate between 1
on press and 0 on release, with the stock scoreboard staying hidden. This supports
the basic rebinding approach on the installed client. Rapid taps, Escape/console,
focus loss, and recovery remain unverified; no production binding was changed.

## First actual scoreboard prototype

The hold/release and quick/interrupted-hold checks were reported as working by
operator. This is encouraging, not exhaustive proof against input-buffer races.

Server: opencj/scoreboard.gsc, initialized on player connection. A private userinfo
flag requests changed, batched data once per second while held. No DB queries.
Client: ui_mp/opencj_scoreboard.menu is a noninteractive HUD, gated by the local
hold dvar and hidden in other menus. It does not call +scores or capture the mouse.
Compact layout: up to 32 one-line player rows, grouped as Jumpers and Spectators,
without pagination. Panel height follows the connected player count. Modes use
existing FPS/any-percent/elevator/halfbeat/TAS icons; rank and XP are placeholders.
Country uses existing country code data. Hostname appears at the bottom right.
F10 remains opt-in via exec ui_mp/opencj_scoreboard_keys.cfg; reset via
exec ui_mp/opencj_scoreboard_reset.cfg. Tab is unchanged.

The compact menu builds with the existing Windows makeMod.py. The isolated engine
test passes (SCOREBOARD COMPLETE failures=0). Actual visual alignment and readability
at 32 players still require in-game verification.

## Readability revision
Activity removed; panel narrowed symmetrically from 570 to 500 virtual units.
Player text is .23 scale and icons are 16 units, with row height reduced only above
24 players so all 32 fit. Progress retains its full heading. Ping colors are muted:
under 100 white, 100 through 150 amber, above 150 red. No packet-loss estimate is
presented; no existing per-player percentage was found in server script bindings.
Server display name is top-right; public connection address requires a reliable
source and must not be confused with sv_hostname (the display name).

## Icons and connection identity
Any% is text in Progress, not a mode icon. Checkpoint world HUD elements use
foreground=false to allow menus to cover them. Rank is a row-height placeholder.
Country flags are 32px textures from flag-icons v7.5.0 (MIT); license retained in
client-mod/licenses and the deployed IWD. UK maps to GB; unknown codes retain text.
opencj_public_hostname defaults to eu.opencj.org and is read on scoreboard updates;
net_port is appended. No external-IP lookup or client executable modification.
Packet loss is not implemented: incoming sequence gaps could estimate upload loss
over a short rolling window, but cannot represent client-side snapshot loss.

## Quiet initialization and update budget
Dedicated opencj_scoreboard_setup menu initializes the hold aliases on connection,
without the shared openCJ_clientcmd transport. Press/release use vstr and no file
execution; manual setup cfg remains available. Menu parsing supplies the quoted
release binding without nesting quotes through the console tokenizer.
A single level-wide row snapshot is calculated per second while requested. Viewers
receive only changed dvars; self highlighting remains private. Updates are deferred
when the viewer has over 16 queued reliable messages. This leaves startup headroom.
Synthetic serialization of 32 changing timers/pings/variation values is 2,954 bytes
and four commands per viewer per second, or 94,528 bytes for 32 viewers. Protocol
overhead, retransmissions and first-open/static-field bursts are additional. This
is a payload estimate, not a live 32-client load test.

## Silent-alias regression and recovery
The setup menu compiled adjacent quoted name/value tokens into one string; aliases
were absent on the client. Restored proven config-based hold/release, retaining the
dedicated connection setup and shared/throttled network updates. Exec messages
remain until a silent replacement is verified on the client. Inspecting decompressed
fastfile menu scripts is required in addition to a successful linker build.

## Verified silent alias encoding
Use unquoted dvar identifiers and preserve escaped quotes through both parsers.
The installed client's String_Parse (0x54b510) calls the general parser; its quoted
string handling at 0x571128 recognizes escaped quote and backslash. The linker
consumes one escape layer, so the source binding quotes need another layer.
Decompressed fastfile checks now assert separate setDvar name/value tokens and the
exact escaped binding. Hold/release continues to use the previously tested rebinding
mechanism, with vstr replacing exec. No stock +scores call on key-down.
