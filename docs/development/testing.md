# Tests and prerequisites

Run commands from the core root unless stated otherwise. Test sources remain in
`dev-tools/tests/`; generated outputs belong in ignored `dev-tools/local/`.
Test requirements differ by suite. A setup-unit-test pass is not an engine,
database, asset or performance pass.

| Suite | Entry point | Requirements and effects |
| --- | --- | --- |
| Setup | `python3 -B -m unittest discover -s dev-tools/tests` | Standard library; temporary directories |
| Fresh database | `python3 -B dev-tools/tests/bootstrap-database.py` | Docker/MySQL; isolated synthetic database and backup restore |
| GSC fixtures | `python3 dev-tools/tests/run-demo-viewing-24.py --help` | Initialized Compose, engine, licensed game and compiled mod; isolated server |
| Native movement | `python3 dev-tools/tests/run-sticky-walls-native.py` | Compiler/build objects and map assets; [suite details](sticky-walls.md) |
| Native protocol | `python3 dev-tools/tests/run-snapshot-recovery.py` | Build container; native protocol fixtures; no network traffic |
| Player memory | `python3 dev-tools/tests/run-player-memory-audit.py` | Engine/assets; isolated synthetic player, no database |
| Capacity | `python3 dev-tools/tests/run-sql-capacity-190.py` | Initialized development schema, Docker, engine/assets and substantial CPU time |
| Query growth | `python3 dev-tools/tests/run-query-capacity.py` | Initialized development schema; disposable synthetic growth data |
| Client assets | `check-command-menu-assets.py`, `check-map-route-menu.py`, `check_client_init_menu.py`, `check_demo_menu.py` | Explicit compiled/unlinked asset inputs; runner arguments describe each input |
| GeoIP | `run-geoip-database.py`, `run-geoip-smoke.py` | Initialized development DB/updater image or explicit compiled assets |

Most GSC files are fixtures loaded through an engine runner; they are not
standalone commands. Native C/C++ sources similarly need their documented build
harness. Python files without the `test_*.py` name are not discovered by unittest.

## Select a test installation

Use a [separate test worktree and database](../setup/development.md#separate-test-installations).
Keep its `COMPOSE_PROJECT_NAME` and `DATABASE_VOLUME` set in the shell used
for tests. Database runners resolve the running `db` service from that worktree's
Compose project, including custom project names. They fail if the service is
missing or ambiguous; they do not fall back to a globally named container.
Runners that need a shared fixture network resolve it from that service.

Some suites create temporary schemas or users on the selected database; others
copy its schema or inspect its contents. Use synthetic data in the test
installation, never a live server's database. Each runner's prerequisites below
still apply.

The native protocol runner creates temporary Compose `build` containers. Build
that service first (`docker compose build build` from `dev-tools`); a running
game server is not required.

Engine runners start in their own fixture directory, where they prepare the
Steam bridge link. They must not depend on a previous normal-server launch to
create files in the shared runtime directory.

The query-capacity runner selects the first two CPU cores allowed to the
calling process. `--cpu-set` can select another pair of available cores,
including a range such as `0-1`. One-core hosts cannot reproduce this suite's
two-core comparison.

Build the GeoIP updater image before its database integration test:

```sh
docker build -t opencj-geoip-updater:latest server-db/tools/geoip
python3 dev-tools/tests/run-geoip-database.py --image opencj-geoip-updater:latest
```

The GeoIP test creates a synthetic schema, a temporary updater account and a
private password file, then removes them. It does not need a MaxMind account
or a downloaded database.

## Legacy and operator-assisted checks

Some runners depend on an initialized development database, generated
configuration, old schema or historical binary. Their presence does not make
them fresh-install tests.

- `database-cleanup.py`, `route-identity-174.py`, `database-safety.py` and
  `demo-viewing-db-24.py` rehearse migrations using existing schema/data or
  explicitly supplied historical backups. Inputs and outputs remain private.
- `challenge-route-link.py`, `shop-purchases.py` and `finish-sounds.py`
  currently expect a separately prepared legacy test schema.
- `run-sql-adapter.py --baseline-binary PATH` includes the historical queue
  comparison in `sql-adapter-benchmark.py`. Supply the matching pre-pool #192
  engine yourself; the runner does not assume an old investigation left one
  behind. The baseline must exist inside this checkout so Compose can mount it.
  The existing `OPENCJ_SKIP_POOL=1` diagnostic mode omits pool and benchmark
  checks and must not be reported as a full pass.
- `run-camera-smoke.py --binary PATH --plugin PATH` needs a matching camera test
  engine and `camera_engine.so`. Both paths must name files inside this checkout.
  This is an operator-assisted historical fixture, not a standard engine test.
- `run-finish-sounds-smoke.py` uses the compiled mod assets configured by
  `dev.py init --mod-dir`, mounted read-only at `/mod-assets`.
- `trace-fps-demo.py` reads an operator-selected recording or exported file.
  Stored run/clip IDs, recordings and traces are private diagnostic inputs.
- The former `run-clip-smoke.py` depended on a personal pre-existing container
  and has been retained privately. The reusable `clip-buffers.gsc` fixture
  remains public.

Do not run destructive tests against a live database. A runner must remove only
its own disposable resources. Native binaries and script snapshots must match;
see [native/script deployment](../operations/native-scripts.md).
