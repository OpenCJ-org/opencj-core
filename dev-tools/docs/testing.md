# Tests and prerequisites

Commands below run from the core root unless stated otherwise. Keep results in
`dev-tools/local/`; never use a live database as a destructive test fixture.

| Suite | Command or entry point | Requirements and effects |
| --- | --- | --- |
| Setup unit tests | `python3 -B -m unittest discover -s dev-tools/tests` | Standard library; temporary directories; no Docker/game access |
| Fresh database | `python3 -B dev-tools/tests/bootstrap-database.py` | Docker and MySQL 8.0; disposable network-isolated database; no existing data |
| GeoIP database | `python3 -B dev-tools/tests/run-geoip-database.py` | Disposable database; synthetic country ranges |
| Native sticky walls | `python3 -B dev-tools/tests/run-sticky-walls-native.py` | Native compiler/toolchain; see the sticky-wall guide |
| GSC engine fixtures | `dev-tools/tests/run-demo-viewing-24.py --help` | Initialized Compose, engine, stock game and compiled mod; disposable server |
| SQL concurrency/capacity | `dev-tools/tests/run-sql-capacity-190.py` | Docker, engine/assets and disposable database; substantial CPU/time |
| Database recovery rehearsal | `dev-tools/tests/database-safety.py` | An explicitly supplied private pre-021 backup; not a public fixture |
| Client asset checks | `dev-tools/tests/check-command-menu-assets.py` and related `check-*` files | Matching compiled client artifacts and their documented external tooling |

`unittest discover` runs the setup tests only. It does not cover the GSC,
standalone native, database, performance or visual suites. Read each runner's
header and arguments before use: older fixture runners can require an explicitly
prepared local environment. They are not a universal fresh-install test command.

Most `.gsc` files are engine fixtures, `.c`/`.cpp` files are native harnesses,
and `run-*.py` files prepare/execute them. The fixtures remain beside the runners
to preserve their existing paths. Use the [reference index](index.md) to find
feature-specific commands and expected behavior.

Test cleanup must target only the disposable resources it created. Running
engines use matching native binaries and script snapshots; do not overlay live
source on an unrelated deployed binary. See the native/script runbook.

## Publication checks

Review the exact proposed branch, including its history. Run `gitleaks git . --log-opts=main --redact=100` from the core root and
review installation-specific paths and operational notes separately. A clean
scanner result is not proof that every kind of private information is absent. Check licenses/asset notices, documentation links and
ignored fixture/config paths. Never publish `refs/local-only/*`, stashes, private
operator files or backups. Public CI must not require personal game files or
credentials.
