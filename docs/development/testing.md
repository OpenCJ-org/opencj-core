# Tests and prerequisites

Run commands from the core root on Linux. Start with the portable checks:

```sh
python3 -B dev-tools/scripts/test.py portable
```

This validates the test catalogue, then runs the explicitly reviewed setup,
discovery, SQL-client, name-policy, client-build, console transport, GeoIP and Discord unit tests plus source/asset checks. It requires
Python 3 and Git, but no Docker, initialized installation, database credentials,
game assets or network access. SQL-client tests use short-lived Python child processes;
Discord uses a temporary Unix socket. Failures,
empty unit suites and skipped unit tests produce a nonzero exit status.

CI uses this same command. A portable pass is not an engine, database,
compiled-client or performance pass.

## Find the right tests

```sh
python3 -B dev-tools/scripts/test.py list
python3 -B dev-tools/scripts/test.py list focused-gsc
python3 -B dev-tools/scripts/test.py check
```

The maintained [catalogue](../../dev-tools/tests/catalogue.json) groups every
test source, fixture and helper by purpose. Each group records its command,
prerequisites and effects. `list GROUP` shows those details and its files.
Commands containing uppercase placeholders require your own reviewed inputs.

The launcher executes only `portable` groups. You can select a subset, such as
`portable setup-unit geoip-unit`; an unknown or nonportable group is rejected
before any test starts. Run integration and diagnostic commands explicitly
after preparing their prerequisites. There is no automatic “run everything”
command that starts databases, imports player data or launches game servers.

Do not recursively import every Python file or assume `--help` is harmless on
old scripts. Several integration files execute work at import time or use
positional arguments without an argument parser. GSC and C/C++ files are inputs
to their listed harnesses, not standalone commands.

| Change | Catalogue group |
| --- | --- |
| Setup/configuration/target selection | `setup-unit` |
| Test registration or launcher | `discovery-unit` |
| GeoIP parsing and import | `geoip-unit`, `geoip-database`, `geoip-engine` |
| Private name-policy maintenance | `name-policy-unit` |
| Persistent SQL-client transport and cleanup | `database-client-unit` |
| Fresh schema, permissions or backup | `database-bootstrap`, `database-volume` |
| Challenge routes, shop or finish ranking | `feature-sql`, `notification-sql` |
| Challenge catalogue keys, ranks and progress | `focused-gsc` |
| Notification and finish-sound lifetimes | `notifications-engine` |
| Save ownership or SQL pool | `sql-adapter` |
| Native demo upload/download or cancellation | `sql-adapter`, `demo-storage` |
| Demo view receipts | `demo-view-sql` |
| Demo playback or camera | `demo-engine`, `camera-engine`, `native-unit`, `demo-storage` |
| Checkpoint editor/contact/HUD | `checkpoint-engine`, `checkpoint-matching`, `focused-gsc` |
| Player visibility or ping sampling | `native-unit`, `focused-gsc` |
| Platform or movement code | `platform-engine`, `movement-engine`, `sticky-walls`, `native-unit` |
| Client build scripts and private Windows helper | `client-build-unit`, `client-build-windows` and an actual asset build |
| Menus or notification artwork | `compiled-menus`, `demo-menu-source`, `notification-assets` |
| Query growth or capacity | `capacity` |
| Tutorial mode, automatic FPS or landing targets | `tutorial-mode` |
| Discord listener | `discord-socket` |

## Integration prerequisites and isolation

Use a [separate test worktree and database](../setup/development.md#separate-test-installations).
Keep its `COMPOSE_PROJECT_NAME` and `DATABASE_VOLUME` set in the shell used for
tests. A separate project name does not isolate an explicitly named external
volume. Database runners resolve the selected project's `db` service and refuse
a missing or ambiguous target. Never select a live gameplay database.

Use synthetic data. Route/shop checks need administrative access for fixture
setup; they roll back or remove their own rows. Other runners create temporary
schemas, accounts or containers. Keep output in ignored `dev-tools/local/`;
raw logs, recordings and database exports remain private.

Build the Compose services needed by the selected runner. Native protocol tests
need the `build` image, but no game server. Engine fixtures need a matching CoD4
binary, licensed game/maps and compiled mod assets. They launch their own server
and do not require a live server restart. Test scripts and native interfaces must
match; see [native/script deployment](../operations/native-scripts.md).

The `sql-adapter` and `run-history-175.py` runners accept `--engine PATH` to test
a separate candidate without replacing the deployed executable. The candidate must be inside the
core checkout so the Compose container can read it. A missing or external path
is rejected before any fixture resources are created.

The history-save runner also tests latest-run lookup ownership with real SQL.
It delays completed replies to verify run changes and overlapping requests, and
occupies native workers to prove obsolete queued lookups are cancelled before
execution. Mode-change and disconnect scenarios call their production cancellation
boundaries; the final restore handoff is observed in the fixture copy. These cases
do not verify client rendering or a physical network disconnect.

The SQL adapter fixture also uploads and downloads a small synthetic clip. It
checks destroyed/reused native IDs, map teardown, malformed payloads and missing
chunks without running the capacity benchmark.

The platform support runner uses the shared isolated GSC runner and accepts
`--binary PATH` (also `--engine PATH`) and `--scripts PATH`. Choose one fixture
variant per run; conflicting flags and invalid prerequisites are rejected before
creating a fixture server. Each run records source and engine hashes privately;
gameplay database callbacks remain disabled.

The aim-teleport runner uses the measured `mp_dark` fixture. Its optional
`--engine PATH` selects an existing candidate inside the checkout; another map
is rejected because the fixture's platform and wall coordinates would be invalid.

The player-name runner accepts `--binary PATH` and `--scripts PATH` and requires
`mp_killhouse`. It creates a separate schema and account, uses synthetic names,
and removes its private configuration afterward. It does not read deployment
credentials or replay old migrations over the current schema. Its record-panel scenarios
hold real SQL replies in the fixture copy and verify obsolete run/instance replies,
superseded checkpoint results, queued cancellation and result cleanup.

The FPS-registration runner uses the stock `mp_killhouse` map by default and
accepts `--binary PATH` and `--scripts PATH`. It runs the actual handshake
with synthetic client IO and reports each assertion; it does not verify a
human client's menu rendering.

The moon movement runner accepts `--binary PATH` and `--scripts PATH` through
the shared GSC harness. It requires `mp_to_the_moon` because its scenarios use
that map's ramps. The report records engine and script hashes, and the fixture
compares native trajectories while isolating account, UI, and database services.

The tutorial auto-FPS runner accepts a candidate engine path inside the checkout,
either as a host path or its `/workspace/...` container path. It checks movement
choices and shot timing through a native plugin. The paired GSC fixture checks
mode flags, the native script API and checkpoint landing targets; neither proves
that a real client applies the requested `com_maxfps` value.

The `camera-engine` runner builds its probe from tracked source by default.
The `native-unit` command requires g++ with C++17 and 32-bit development libraries,
but no game assets. The `demo-storage` command uses the Compose build image to
check native storage and script return values without a game server or database.
Focused GSC commands name their fixture and completion marker;
checkpoint contact uses `mp_futile_fixed`, not the stock map used by the other
focused fixtures. Its synthetic graph cases also exercise the real saved-position
ancestor traversal across rejoined branches, alternative areas and a malformed
cycle, without database writes. Real-player landing cases check expected-successor
priority, fast-contact reservation, coincident-current-area suppression and paused
runs. Only the scoring handoff is observed; these cases do not persist progress.
The save-history native fixture checks invalid inputs, non-player
calls and stale selections without a database. HUD observation wrappers are
installed only in the fixture copy.

The focused `challenge-state.gsc` fixture executes catalogue definitions,
rank boundaries, progress labels and mode-icon selection without a database.
Permanent challenge keys are checked through the produced definitions, so source
formatting and helper layout do not affect that contract.

The scoreboard connection runner exercises the production connection hook in
an otherwise isolated engine callback, then verifies the connecting, joined
and disconnected snapshots. Its shared harness accepts `--binary` and
`--scripts`. The focused `scoreboard-points.gsc` fixture separately checks
stable point ordering and every team split across the supported scroll range.
These VM tests do not verify human-client rendering.

The notification engine group uses the shared GSC runner's `--binary` and
`--scripts` inputs and requires `mp_killhouse`. It copies only schema and routines
from the selected Compose database into a separate disposable MySQL container.
Its synthetic runs exercise exact record categories, preference persistence,
late replies, completion-sound delivery and HUD cleanup for 32 players. Set `OPENCJ_TEST_ASSET_DIR` to a
directory inside the checkout to select an explicit `mod.ff` and `z_opencj.iwd`;
otherwise it uses the installation's compiled assets. Temporary credentials and
containers are removed after success or failure. This engine check does not
establish how the effect looks or sounds in a human game client.

The GeoIP engine fixture exercises atlas selectors, login announcements and
country fallback behavior without a database. It defaults to the complete
working script tree; `--scripts` can select a complete prepared release
containing `opencj/` and `maps/`. Supply matching compiled assets explicitly:

```sh
python3 -B dev-tools/tests/run-geoip-smoke.py --asset-dir COMPILED_MOD_DIR mp_killhouse
```

It snapshots the selected binary and assets, records their hashes with script
hashes, and uses the shared isolated-server cleanup path. This fixture does not
test database GeoIP queries or client rendering.

Build the GeoIP updater image before its database integration test:

```sh
docker build -t opencj-geoip-updater:latest server-db/tools/geoip
python3 -B dev-tools/tests/run-geoip-database.py --image opencj-geoip-updater:latest
```

This uses synthetic input; no MaxMind account or download is needed.
Capacity testing needs two available CPU cores and substantial runtime.
`run-query-capacity.py --cpu-set` can select a different available pair.

Checkpoint editor, migration and command-menu launchers use the shared isolated GSC runner.
They accept `--binary` and `--scripts` to select the artifacts under review,
validate prerequisites before launch, and retain their actual hashes in private
evidence. Gameplay database callbacks remain disabled in these fixtures.
The route-list fixture records chat messages only in its source copy; it checks
pending/completed labels, throttling and an unavailable database without connecting
to a gameplay database.

Compiled menu checks require actual Unlinker output from the build being reviewed.
They inspect command controls and route geometry, and replay startup commands with
controlled FPS/max-packets values to check registration and repeated startup.
The replay models immediate/deferred commands; it does not run the game client.
The source-only demo-menu check verifies asset registration, response actions and
toolbar geometry. Menu startup, initial overlay output and closing/restoring the
normal menu are exercised by the demo engine fixture through forwarding native
IO observers in its private script copy. Neither check establishes that a human
client renders the fastfile correctly. The recording trace tool accepts an explicit export or a synthetic
database run/clip; it is a diagnostic, not a standard regression suite.

## Maintaining the test set

Register new or moved tests in the catalogue in the same change. The checker
compares it with Git's tracked and nonignored test inventory, including component
`test_*.py` files, without importing integration code. Ignored experiments are
not discovered. Keep fixtures with their owning group and shared helpers in
`support`; each executable group needs a maintained command.

Repair still-relevant tests when their setup, schema or interfaces change.
Remove completed one-off comparisons and obsolete acceptance snapshots instead
of retaining broken scripts with an “old” label. Preserve useful compatibility
and regression checks; age or an issue number alone is not a reason to delete
them. Recover historical investigation material through Git or private recovery
records, not through the current test entry point.

Report exactly which groups ran, which inputs/builds they used, and what remains
unverified. Passing a listed command once does not establish that other groups
pass or that future changes preserve the result.

### HUD settings and checkpoint indicators

The catalogue's HUD-settings fixture runs real menu-response handling and native
HUD creation on a synthetic client. It covers marker modes, moving-platform
translation, cancellation of further platform lookups, the 16-marker capacity
and cleanup after the visible set shrinks. Observation hooks forward material,
waypoint and platform-center calls to the real engine methods. This checks
server behavior and selected materials; it does not inspect client rendering.

### Checkpoint publication

Run `python3 -B dev-tools/tests/run-checkpoint-publication.py` to exercise real GSC
publication against a temporary schema-only copy of the selected database. All
route and player rows are synthetic. The test checks repeated publication,
alternative connections, checkpoint ID and historical-statistics preservation,
rejected requirement/color edits, bounded recovery-name lookup, retirement, and
rollback after a partial write.
Graph loading uses the real database, with fixture-only hooks rejecting each of
its checkpoint and metadata queries in turn. Checks cover retaining the previous
graph and layout epoch, an empty first-load result, and recovery after reads resume.
Known synthetic routes verify their connections, alternative groups, reachable
finishes and step counts independently of the loader traversal. Returned-row
corruption checks reject missing, self-linked and cyclic alternative leaders
without replacing the playable graph or changing stored data.
Finalization checks keep publication, editor closure and run-creation SQL real.
They verify that rejected publication retains the editor, a failed refresh after
commit retains the published rows and allows retry, and successful finalization
creates a fresh run. Normal graph-refresh and gameplay presentation callbacks
are observed; the failed-refresh case enters the real loader. These checks do not
exercise the player's actual spawn or HUD rendering.
The engine account is restricted to that fixture schema. The runner deletes its
schema, account and temporary credential file on exit; logs and draft snapshots
remain under ignored `dev-tools/local/`. Both publication fixtures simulate a lost
reply after a real commit and verify
that retries retain one set of route/checkpoint IDs. This does not exercise a live
player's editor UI, actual network transport failures or concurrent publishers.

The same runner accepts the section-network fixture:

```sh
python3 -B dev-tools/tests/run-checkpoint-publication.py --fixture dev-tools/tests/checkpoint-network.gsc --completion-marker "NETWORK SELFTEST COMPLETE"
```

This exercises shared-section publication, repeated publication, pending-edit
rejection, alternating-manifest recovery, damaged snapshot preservation and a
missing opening. It also drives split, merge, rejoin and rename through real
section files and SQL. Fixture-only hooks observe editor reopening, navigation
and graph-refresh calls; they do not replace the persistence or command logic.
The file-open hook simulates failed approach/manifest writes and checks that the
pending edit remains recoverable. Rename checks distinguish a committed change,
a rollback and an unresolved reply while retaining recovery drafts. A rejected
graph-refresh callback verifies that a committed rename stays saved without
relabeling the still-active graph. These are
simulated failures at those boundaries, not operating-system disk faults.
It uses the same owned schema/account and isolated file tree.

### Finish audio conversion

The portable `audio-converter-unit` group checks channel-preserving resampling,
quiet PCM bytes, silent input, invalid metadata and decoder-handle cleanup using
a synthetic decoder boundary. It does not require libsndfile or source audio.
For an actual MP3 conversion, run the converter with libsndfile and an explicit
`--output-dir` as described in the [audio source guide](../../client-mod/audio-source/README.md).
Compare both resulting WAVs and retain their Pixabay notice when packaging them.

### Bouncer artwork builder

Install `dev-tools/requirements-art.txt` on the Linux build host, then run the
catalogue's `bouncer-art-unit` command. Synthetic DXT1 images and ZIP archives
exercise header/length preservation, selected-entry replacement, failed-build
preservation and source/output aliases. This group does not load game assets or
replace deployed map files. A real rebuild additionally requires the original
IWD and the [artwork procedure](../../client-mod/assets/map-previews/README.md).

### Command browser

The command-menu runner exercises registration, alias ranking, live permissions,
list/detail pages and real menu/search notifications with a synthetic client.
It initializes SQL cancellation constants without connecting to a database.
Its empty-chat check covers dispatch before command-token indexing. Debug teleport
cases exercise real handlers: malformed and overflowing coordinates and invalid
entity indices preserve state, while valid movement marks the run assisted.
These commands require ordinary signed decimal integers, without leading zeros
or a plus sign; this rejects numeric prefixes and overflow before conversion is
used for movement. The fixture
uses the shared runner's engine/source selection, bounded wait and owned-container
cleanup; it does not inspect the client's rendered menu.
