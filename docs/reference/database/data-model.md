# Database identity and historical values

## Player labels are not identity

runID identifies a run permanently. The player may give it an optional runLabel.
The label is kept in runLabels and can be changed without changing the ID,
statistics, saves or recording. Two different runs may have the same label.
Only the unused second label column in playerRuns was removed.

playerRuns.tutorial marks [tutorial-mode](../gameplay/tutorial-mode.md) runs.
Ranking queries require it to be 0; it is set before a tutorial finish is recorded.

## Relationships

- Challenges bind `mapID` and `routeID`, with permanent `challengeKey` ownership.
  A map can exist in the catalogue while `inRotation=0`; identity alone does not
  publish a route or approve a map for voting.
- Checkpoint areas must belong to their checkpoint's map. A challenge route must
  belong to its map, and a demo winner's category must match its recording.
- Equipment has one item per player/slot. Its slot must agree with the catalogue;
  display category comes from the catalogue rather than a separate equipment copy.
- Route and section colors use RGB metadata; route identity is described in
  [stable route IDs](route-identity.md).
- Historical runs, checkpoint statistics, saves and earned rewards have
  [reference and deletion protections](../../operations/database.md#historical-data-protection-021).

Migration 020 defines the cleanup and matching-reference constraints;
later migrations strengthen data safety. The [migration procedure](../../operations/database.md)
is the authority for installation and upgrades, not a list of old feature notes.

## Why some repeated values stay

A checkpoint time records when the player passed that checkpoint. A save
records the state when it was made. The run later changes, so replacing those
values with the run's current values would lose historical information.

Demo summaries keep the recording's FPS, modes, time and RPG count available to
the selection/publication queries. They are small summaries, not extra copies
of the recording. A demo winner's repeated route/FPS/modes describe the category
it won; the database now rejects a winner pointing at a different category.

checkpointAreas.mapID participates in its unique (map, draft, ordinal) index.
It is retained to enforce editor ordering, with a constraint making it agree
with checkpoints.mapID. Checkpoint centers also remain because existing runtime
code uses those coordinates in addition to the polygon's shape.

shopEquipped.slot makes the one-item-per-slot rule enforceable. Category can
come from the catalogue, but removing slot would require redesigning the
equipment key. The catalogue slot and equipped slot now move together.

A recorded purchase price is what the player actually paid. It must not change
when today's catalogue price changes. Earned challenge ownership likewise
remains independent of whether an old supporting run is eventually removed.
