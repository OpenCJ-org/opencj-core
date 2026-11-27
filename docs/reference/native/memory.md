# Script and native memory ownership

## Limits are different resources

The engine has 65,534 child-variable slots and 32,768 parent/object slots.
Each internal variable record is 16 bytes. Its separate script memory-tree
arena is 65,536 nodes of 16 bytes (1 MiB), used for strings, vectors and thread
stacks. Native demo frames live outside these pools.

Thus ordinary free system RAM does not prevent script-variable or script-string
exhaustion. The main findings concern dynamic growth and temporary duplication,
not a large fixed reservation made for each player at login.

## Script references at map load

While a script compiles, the engine reserves one entry for every
`file::function` call site and `#include` in it. Scripts load depth-first, and
each script keeps its reservation until every file it references has loaded.
The limit therefore applies to the sum along the deepest chain of nested script
loads, not to one file. Exceeding it stops the map load with
`MAX_PRECACHE_ENTRIES exceeded`; this is unrelated to asset precaching.

Stock CoD4 allows 1,024 entries. OpenCJ's production scripts reached about 990
in a 31-file chain, so OpenCJ's engine allows 4,096 (`MAX_PRECACHE_ENTRIES` in
`cod4x-server/src/scr_vm.h`). Files that call many other files, or that sit
early in a long dependency chain, use most of this budget.

## Implemented optimizations

- Demo viewers retain text only for their selected mode. A native change list
  records a new string only when the text changes. It retains the existing
  source-sample rewind window without consuming GSC child slots per frame.
- Changing mode hides the current jump and starts the selected display on the
  next takeoff. Off clears demo display history. Once started, normal rewind
  and seeking remain available. Detailed still shows six actions; Compact,
  halfbeat, parastrafe and bounce rules remain covered by regression tests.
- Seek reconstruction visits native frames in order with a single temporary
  GSC sample. It no longer constructs the 512-frame script array.
- Downloads for both runs and clips use binary SQL results and the same native
  decoder. Decode work is spread across server frames. Ordinary SQL completions
  continue to be collected while native decoding is pending.
- Run and clip uploads encode/submit chunks natively. Clip publication pins its
  native source through asynchronous SQL, even if its editor closes. It releases
  that ownership on completion/error/disconnect; a completed upload must not
  close subsequently opened playback.
- Native load completions verify demo generation, reject corrupt payloads and
  drain abandoned map-transition reads. Existing recording formats remain valid.
- Duplicate speedometer initialization is removed and made idempotent.
  Position HUDs are created when enabled and destroyed when disabled.
- Finished recordings release their save-number index. Native save lists are
  freed on disconnect and map initialization, preserving the database and
  unfinished run recordings.
- Full playback no longer builds an identity frame-index vector. Edited
  playback vectors are freed on presentation exit/replacement/map change.

The underlying event builder still supports different spectators choosing
different modes. There are no separate saved Compact/Detailed versions for
each demo frame.

## Upload ownership

A finishing upload must not close newly opened playback or overwrite another pending submission's ownership. Closing the editor does not discard an upload's pinned native source. Completion, failure and cancellation release the corresponding pending state.

Use the allocation and capacity fixtures described in the [test guide](../../development/testing.md). Their synthetic workload measurements are not guarantees for other hosts or complete client sessions.
