# Shared checkpoint sections

Use the [editor guide](editor.md) for setup, selection, properties and shortcuts.
Shared sections let several routes reuse the same authored landing geometry.
Draft edits do not change published data until finalization.

## Split and merge routes

Resume the opening with `!cp start normal`. Confirm its last shared landing,
then use `!cp split easy hard`. Up to 16 route names are supported. The editor
opens Easy; `!cp start hard` resumes Hard at its latest section. An empty section
places the editor at its incoming shared landing.

Easy may be complete before Hard joins it. While building Hard, Detect on an
existing Easy landing highlights that checkpoint and explains
`!cp merge easy hard`. Merge before confirming a duplicate. Hard's approach
joins that checkpoint and reuses Easy's saved continuation and finish. The editor
opens at the join, not the route's end.

For several existing continuations, the first named existing route supplies the
path for new arrivals; existing routes retain their later divergences. When no
continuation exists yet, merge at the first common landing and author the shared
section once. Include every route already using an incoming or shared section.

To split again, stand on the last shared checkpoint and use Detect, or select
its section index with `!cp edit N`. Then `!cp split easy hard` keeps Easy's
existing continuation and opens a new Hard branch. The first argument keeps the
existing path; the remaining arguments receive new branches. They can merge
back into another section or finish later.

Overlapping areas are highlighted, and confirming duplicate sections is blocked.
The editor asks for a merge at the join and a split at the later divergence.
Original section files remain as recovery snapshots; the network manifest
selects the active versions.

## Follow a saved continuation

After merging into a completed route, landing on an existing checkpoint in that
shared section selects and highlights it, including alternative areas. The panel
identifies the selected checkpoint. The next checkpoint has a numbered boundary
and center-to-center connection; a finish is labeled FINISH.

Existing checkpoints do not need to be recreated. Confirm saves an edit without
jumping to the end, and automatic selection preserves pending edits. Landing
outside the saved checkpoints retains the last shared checkpoint as the split
point. Detect warns instead of overwriting shared geometry.

The HUD names every route using the section. Shared sections keep the opening's
explicit color; exclusive sections use their route colors. Runtime marker
behavior is described in [playing published routes](editor.md#playing-published-routes).

## Rename and publish

`!cp rename normal combined` renames a shared opening without renaming its
descendant routes. `!cp rename easy newname` renames that route. Names cannot
collide with another draft or published route. Renaming requires editor mode and
does not finalize an unfinished draft.

Draft files and the network manifest move together, retaining `.renamed` recovery
snapshots. Published routes keep their numeric IDs, checkpoint IDs, recordings
and earned history; consumers resolve the current catalogue name. See
[stable route identity](../database/route-identity.md).

If the commit reply is lost, the editor checks a published route's stable ID
before restoring any names. If the database is unavailable or the change only
renames an internal section, the outcome may remain unknown: both draft copies
and the alternating manifests are retained. Check the published names before
retrying; an error reply alone does not prove that the database rename failed.

Complete every branch, mark its finish, then use `!cp finalize` to publish the
network in one database transaction. A shared finish is supported. Finalization
may reuse an identical recorded route but rejects unsupported changes to
recorded geometry, grouping or requirements.

Shared sections are saved once as ordinary section drafts. Alternating CPN1
manifests record each route's ordered section references. Retain **both manifests
and every referenced section draft** for recovery; finalization deletes neither.
Bring the database to the complete migration set through the
[setup or upgrade procedure](../../setup/development.md).

At runtime, the opening is shared and later sections expand into route-specific
logical chains. Expected-next-checkpoint handling prevents coincident copies
from counting on successive frames. Taking another route's later branch enables
any% with a route-change message.

## Legacy draft compatibility

Standalone drafts use CPC4. Legacy branches use CPC6 to preserve their shared
opening color. CPC2–CPC5 remain readable. Legacy branch drafts use their guarded
publisher; loading them does not silently convert them into section networks.

Implementation: [network editing](../../../server-gsc/opencj/checkpointnetwork.gsc),
[legacy branches](../../../server-gsc/opencj/checkpointbranch.gsc),
[draft encoding](../../../server-gsc/opencj/checkpointcreation.gsc) and
[publication](../../../server-gsc/opencj/checkpointpublish.gsc).
