# Older save history

OpenCJ automatically prefetches older saves, with a hard limit of 100
recent saves per player. This includes restored history and new saves in the
current session. Persisted database saves remain available for future sessions;
the cap applies to loaded history, not to stored records.

## Player behavior

Resuming a run initially loads its newest 50 saved positions. With ten or fewer
loaded positions remaining behind the selected position, OpenCJ requests up to
50 more, limited by the remaining space under the 100-save cap. Existing load
controls and the safe-position command use this history.

New saves replace the oldest in-memory position once the cap is reached.
Reaching the cap prints "Only the 100 most recent saves are available."
Reaching a still-loading boundary prints "Loading older saves..." and leaves
the history cursor at the oldest available position. The player retries with
the existing controls; a late response never teleports the player.

## Memory and correctness

Positions remain native C++ nodes, not retained GSC row arrays. Each node is
56 bytes in the current 32-bit build: 100 positions for 32 players require
179,200 bytes (175 KiB) of save payload, plus allocator overhead and small
per-player metadata. At most two history page jobs may hold database results
at once, including initial restores. Each page has at most 50 rows and is
released before the next queued reader gets its slot.

The SQL cursor uses the real saveNumber, preserving gaps and chronology.
Queries check run ownership, map, current instance and archived status.
Replies are rejected after native history reset, run/instance/layout change,
account/map change, demo/CPC entry or replacement by a newer request.
Disconnected players cannot strand an occupied page slot. Eviction and reset
clear selected pointers, including another player's reference to a removed
save. Initial restoration blocks save/load actions until run metadata and
positions agree. Failed older-page reads preserve loaded history and allow a
retry after one second.

## Implementation

- server-ext/gsc_saveposition.cpp: native cap, eviction, older insertion,
  generation/count access and safe invalidation of selected positions.
- server-gsc/opencj/historysave.gsc: bounded asynchronous page loading.
- server-gsc/opencj/saveposition.gsc: existing control integration and notices.
- server-gsc/opencj/commands.gsc: safe-position history fallback.
- server-gsc/opencj/{demos,checkpointcreation}.gsc: cancel pending history on entry.
