# Tests and prerequisites

Run commands from the core root on Linux. Start with the portable checks:

```sh
python3 -B dev-tools/scripts/test.py portable
```

This validates the test catalogue, then runs the explicitly reviewed setup,
discovery, GeoIP and Discord unit tests plus source/asset checks. It requires
Python 3 and Git, but no Docker, initialized installation, database credentials,
game assets or network access. Discord uses a temporary Unix socket. Failures,
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
| Fresh schema, permissions or backup | `database-bootstrap`, `database-volume` |
| Challenge routes, shop or finish ranking | `feature-sql`, `notification-sql` |
| Save ownership or SQL pool | `sql-adapter` |
| Native demo upload/download or cancellation | `sql-adapter`, `demo-storage` |
| Demo view receipts | `demo-view-sql` |
| Demo playback or camera | `demo-engine`, `camera-engine`, `native-unit`, `demo-storage` |
| Checkpoint editor/contact/HUD | `checkpoint-engine`, `checkpoint-matching`, `focused-gsc` |
| Player visibility or ping sampling | `native-unit`, `focused-gsc` |
| Platform or movement code | `platform-engine`, `movement-engine`, `sticky-walls`, `native-unit` |
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

The SQL adapter fixture also uploads and downloads a small synthetic clip. It
checks destroyed/reused native IDs, map teardown, malformed payloads and missing
chunks without running the capacity benchmark.

The platform support runner accepts the same `--engine PATH` option. Choose one
fixture variant per run; conflicting variant flags are rejected before creating
a fixture server.

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
focused fixtures. The save-history native fixture checks invalid inputs, non-player
calls and stale selections without a database. HUD observation wrappers are
installed only in the fixture copy.

Build the GeoIP updater image before its database integration test:

```sh
docker build -t opencj-geoip-updater:latest server-db/tools/geoip
python3 -B dev-tools/tests/run-geoip-database.py --image opencj-geoip-updater:latest
```

This uses synthetic input; no MaxMind account or download is needed.
Capacity testing needs two available CPU cores and substantial runtime.
`run-query-capacity.py --cpu-set` can select a different available pair.

Compiled menu checks require actual Unlinker output from the build being reviewed.
The source-only demo-menu check does not establish that a fastfile or game client
works. The recording trace tool accepts an explicit export or a synthetic
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
