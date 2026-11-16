# Database safety and earned rewards

## Manual backups

Backups contain private gameplay data and credentials. Keep them outside Git
and copy verified backups to independent storage. The manual helper accepts
explicit database names, container, source paths and output location; see
[the backup helper](../../dev-tools/scripts/backup.py) with `--help`.

It restore-checks the SQL snapshot in an isolated MySQL container. Runtime files
are copied online and are not atomic with that SQL snapshot. Accounts/grants,
map binaries and source repositories require their own recovery plan.
No backup scheduler or retention policy is installed by development setup.

## Historical data protection (021)

Deleting maps, players or finish checkpoints no longer cascades into deleting runs.
Deleting a run/checkpoint with saved progress or statistics is rejected. Normal
checkpoint retirement, run archiving, geometry editing and route renaming remain
supported. Existing historical rows are not rewritten.

Save checkpoints, award ownership, shop accounts and purchase references are
enforced. If an administrator deliberately deletes an otherwise deletable supporting
run, an award's runID becomes NULL but the award/player ownership survives.
Awarded challenge definitions and purchased catalogue items must be disabled,
not deleted.

Checkpoint connection pairs are unique. Triggers reject self links and cross-map
connections, alternatives, memberships, statistics, saves, finishes, route starts
and demos. Map ownership cannot change after row creation. This prevents parent
moves bypassing child checks without duplicating mapID into every link table.
The normal map/route display-name rename paths remain available.

The default run start time is now CURRENT_TIMESTAMP; old dates are unchanged.
Temporary clip/session cleanup and obsolete published-demo payload cleanup retain
their existing behavior. Removing recording chunks does not remove player runs.

## Checkpoint statistics (022)

checkpointPassed previously assigned timePlayed first, so the following comparisons
retained old RPG/count/mode fields. It now compares all fields against the original
time and assigns timePlayed last, with run ownership locked throughout.
Older, equal-time and stale-owner writes leave accepted statistics unchanged.

Historical counts cannot safely be reconstructed from current run totals, which
represent another point in time. The migration does not guess or rewrite them.

## Earned currency (023)

challengeCompletions.pointsAwarded records the reward at first completion.
Shop balance sums these amounts minus actual purchase prices. Later challenge
repricing/deactivation neither removes earned spending points nor grants a second
reward. Competitive ranking retains current active challenge values.

Past amounts were not recorded. Migration preserves each existing award's current
contribution (current reward when active, otherwise zero), without pretending to
reconstruct its original value.

## Tracked migrations

server-db/tools/migrate.py maintains schemaMigrations: version, filename, SHA-256,
state, application time, and a schema fingerprint for explicit baseline adoption.
Select the intended installation before invoking an administrative tool.
From its `dev-tools` directory, with that installation's Compose variables set:

```sh
DB_CONTAINER="$(docker compose ps --status running --quiet db)"
```

Check that this resolves exactly one intended database container. For a standalone
database, set `DB_CONTAINER` explicitly instead. The migration and permission
tools have a default container name, so pass `--container` rather than relying
on that default. The commands below run from `server-db` in the same shell.

For a database already managed by the migration ledger, first inspect status.
After stopping gameplay writers and making a verified backup, apply pending
migrations:

```sh
python3 tools/migrate.py status --container "$DB_CONTAINER"
python3 tools/migrate.py apply --container "$DB_CONTAINER" --confirm-database openCJ_cod4
```

Only a verified **post-020 legacy database without a migration ledger** uses the
one-time adoption action:

```sh
python3 tools/migrate.py adopt-020 --container "$DB_CONTAINER" --confirm-database openCJ_cod4
```

Adoption validates that specific legacy schema and records its earlier migrations
as adopted, not newly executed. It is neither a fresh bootstrap nor an automatic
upgrade from an arbitrary older database. Then use the normal apply/status path.
For an empty development database, use the [bootstrap procedure](../setup/development.md).

Applied migrations are not rerun. Changed checksums, missing versions, concurrent
runners and interrupted migrations are refused. MySQL DDL commits implicitly;
failures remain marked applying. Inspect and restore/reconcile partial state
intentionally instead of bypassing that marker. Future changes use new migrations.

## Gameplay permissions and storage

From server-db:

    python3 tools/runtime_access.py --container "$DB_CONTAINER" --confirm-database openCJ_cod4

Gameplay cannot create/alter/drop tables, rewrite migration history, update old
award amounts or directly delete accounts, runs, saves, statistics, checkpoints,
awards or purchases. Required data writes, temporary cleanup and reviewed stored
routines remain available. Administrative routine definers preserve account
creation rollback and atomic purchases. Passwords/accounts are not replaced.

An optional legacy test database can be made read-only to gameplay with the
`--readonly-database` option. Destructive tests use disposable containers and their own test/admin identity. Migration/recovery
admin access remains available. No other host service/database is changed.

Compose treats the configured `DATABASE_VOLUME` as external (default:
`opencj-dev_database`). Normal teardown, including `down --volumes`, preserves it. Explicit administrator deletion is
still possible: this is protection against teardown mistakes, not a backup.
Fresh development setups must create that external volume before starting Compose.

## Verification and recovery

Use the current [test guide](../development/testing.md) and catalogue.
From the core root, the fresh bootstrap regression creates its own network-isolated
database and verifies migrations, repeat-run preservation, runtime DDL denial and
a synthetic backup/restore:

```sh
python3 -B dev-tools/tests/bootstrap-database.py
```

From a separately selected disposable Compose installation, use `database-volume`
for external-volume preservation, `feature-sql` for current route/shop behavior,
and `sql-adapter` for save ownership and pool failures. These are regression tests
on synthetic data, not a substitute for rehearsing an installation's actual backup
and version-specific upgrade.

Recovery requires matching database and source versions. Keep the server stopped
while restoring the pre-migration dump and previous GSC files. Re-provision the
matching permissions through the administrator connection. Do not restore over
newer player activity without reviewing which data would be replaced.
