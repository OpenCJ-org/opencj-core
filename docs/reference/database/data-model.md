# Database identity and historical values

## Player labels are not identity

runID identifies a run permanently. The player may give it an optional runLabel.
The label is kept in runLabels and can be changed without changing the ID,
statistics, saves or recording. Two different runs may have the same label.
Only the unused second label column in playerRuns was removed.

## Changes

- Challenges reference mapID instead of copying mapName. Eleven map names already
  present in challenge definitions receive catalogue IDs, with inRotation=0.
  Map identity alone does not publish a route or approve a map for voting.
- Removed three empty obsolete tables: playerSaves_test, playerRecordings,
  demoEvents. Removed their unused createEvent, prepareAllDemos, prepareDemo,
  savePosition_test and storeDemoFrame functions. Current GSC/native code had
  no references to them.
- Removed unused routeShaderColor/endShaderColor palette fields. Existing RGB
  colors are unchanged; CoD2's legacy read path remains untouched.
- Removed the unused shopEquipped.category copy. Kept slot because one player
  can equip only one item per slot, and enforced its agreement with shopCatalog.
- Added matching-reference constraints for checkpoint-area maps,
  challenge-route maps and demo-winner categories.

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
