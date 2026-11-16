# Run recording and storage

Run recording starts with a new eligible CoD4 run and stays in native memory
until completion. Pausing, watching a demo, checkpoint editing and AFK time add
no frames. Disconnecting discards unfinished capture; a run resumed from another
connection has no complete recording from that connection.

Loading a save marks the abandoned frames as failed-path history rather than
deleting them from the recording. Successful-path playback can skip those
frames; a fixed run-history view can include unsuccessful attempts. A failed
capture stops that recording without invalidating the player's run.

## Shared storage and retention

`demoRuns` holds recording metadata, `demoWinners` references retained category
winners, and `demoChunks` holds their shared compressed payload. Servers using
the same database can play these recordings without a shared filesystem.
Names and route selection use stable route IDs, not a copied route name.

Finishing captures the run's metadata and uploads chunks before the
[publication transaction](../database/demo-publication.md) makes the recording
playable. A failed upload does not remove the leaderboard finish. Unreferenced
superseded payloads are removed transactionally; unfinished uploads older than
seven days are cleaned up at map initialization. Retiring a route layout keeps
old recordings stored with `ready=2` but excludes them from selection.

Recordings, playback caches and fixed history copies share a 128 MiB native
allocation budget. The native demo table has 128 slots. Cache references
are released when viewers and outstanding requests stop using them; allocation
failure affects the recording or request, not the player's earned progress.
See [memory ownership](../native/memory.md).

## Wire formats

The current encoder writes **OCJ5**. The decoder also accepts OCJ1–OCJ4; missing
historical fields cannot be reconstructed from old recordings.

Each zlib-compressed chunk starts with the four-byte format marker and a
little-endian frame count. It contains at most 64 frames. The 27-byte base frame
stores float32 XYZ, three uint16 turn angles, movement flags, FPS, checkpoint ID
and event bits. Optional CoD4 presentation data adds 31 bytes, a weapon-name
length/name when needed, and two bytes for a landing event when present.
This means 27 bytes is not the current recording's total per-frame size.

| Format | Additional information available |
| --- | --- |
| OCJ1 | Base position, input and event fields |
| OCJ2 | Recorded weapon and movement presentation |
| OCJ3 | Landing events and impact strength |
| OCJ4 | Failed-path frame flags |
| OCJ5 | Whether elevation is known and used at each frame |

Weapon names appear on changes and at the first detailed frame of each chunk.
Chunks can therefore be decoded independently. Sampling uses the 20 Hz server
timeline. SQL stores compressed bytes; hex is only a compatibility transport,
not the persisted encoding. Current native upload/download paths use binary
SQL results.

## Recorded presentation

CoD4 recordings can retain weapon, stance/input flags, animation/timing, camera
height, ADS, velocity, ladder, sprint and mantle state. Recorded velocity drives
the playback speedometer; legacy frames without it hide that display.

Playback freezes live input and presents recorded state without running the
recorded fire inputs through weapon simulation. RPG viewmodel animation and
local fire sound do not spawn gameplay rockets. Landing events are presentation
only and are not repeated while paused, seeking or crossing a load boundary.
Load/teleport cuts do not interpolate across the discontinuity.

Playback exit restores the live run and presentation state; see
[lifecycle](lifecycle.md). Player commands and timeline controls are in
[viewing](viewing.md), and automatic matching is in [selection](selection.md).

## Implementation and verification

- [Recording lifecycle](../../../server-gsc/opencj/demorecording.gsc).
- [Playback and shared cache](../../../server-gsc/opencj/demos.gsc).
- [Native codec and allocation limits](../../../server-ext/opencj_demo.cpp).
- [Database publication](../database/demo-publication.md).

Use the [test guide](../../development/testing.md) for suite prerequisites.
Historical codec fixtures and current engine fixtures have different inputs;
a source inspection is not an in-game playback pass.
