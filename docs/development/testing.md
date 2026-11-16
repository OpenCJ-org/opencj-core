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

## Legacy and operator-assisted checks

Some runners still depend on an existing development database, generated
configuration, old schema or historical binary. The portability audit is
separate work; the file's presence does not make it a fresh-install test.

- `database-cleanup.py`, `route-identity-174.py`, `database-safety.py` and
  `demo-viewing-db-24.py` rehearse migrations using existing schema/data or
  explicitly supplied historical backups. Inputs and outputs remain private.
- `challenge-route-link.py`, `shop-purchases.py` and `finish-sounds.py`
  currently expect a separately prepared legacy test schema.
- `sql-adapter-benchmark.py` compares against an explicitly prepared historical
  executable. Ordinary regression checks must not be reported as that comparison.
- `trace-fps-demo.py` reads an operator-selected recording or exported file.
  Stored run/clip IDs, recordings and traces are private diagnostic inputs.
- The former `run-clip-smoke.py` depended on a personal pre-existing container
  and has been retained privately. The reusable `clip-buffers.gsc` fixture
  remains public.

Do not run destructive tests against a live database. A runner must remove only
its own disposable resources. Native binaries and script snapshots must match;
see [native/script deployment](../operations/native-scripts.md).
