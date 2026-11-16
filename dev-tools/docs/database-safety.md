# Database safety and earned rewards

## Development scope and manual backup

This protects the development database. No scheduled backups, upload jobs or
retention timers are installed. Public-beta deployment/backup policy is deferred
to that server's setup.

The verified pre-change backup uses the established Amsterdam-time folder format:
the repository root-backups/2026-11-14_13h22m/

Its six files contain both OpenCJ databases (all data, demo payloads, routines,
triggers and events), runtime configuration, checkpoint drafts, an inventory,
checksums and an isolated restore report. Configuration and data are private.
Accounts/grants, map binaries, build trees and Git repositories are excluded.
Runtime files are copied online, not atomically with the SQL snapshot.

Run scripts/backup.py manually on the authoritative server for another backup.
It writes under backups, restores into an isolated MySQL
container, and checks every restored table/view. Copy the completed folder to the
requested destination and verify SHA256SUMS. No scheduler is involved.

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
reconstruct its original value. All existing development completions were active.

## Tracked migrations

server-db/tools/migrate.py maintains schemaMigrations: version, filename, SHA-256,
state, application time, and a schema fingerprint for explicit baseline adoption.
After stopping OpenCJ writers and making a backup, from server-db:

    python3 tools/migrate.py adopt-020 --confirm-database openCJ_cod4
    python3 tools/migrate.py apply --confirm-database openCJ_cod4
    python3 tools/migrate.py status

Adoption checks the known post-020 schema and records those earlier migrations as
adopted, not newly executed. It is not a fresh bootstrap or an automatic upgrade
from an arbitrary old database. The future beta bootstrap will be prepared separately.

Applied migrations are not rerun. Changed checksums, missing versions, concurrent
runners and interrupted migrations are refused. MySQL DDL commits implicitly;
failures remain marked applying. Inspect and restore/reconcile partial state
intentionally instead of bypassing that marker. Future changes use new migrations.

## Gameplay permissions and storage

From server-db:

    python3 tools/runtime_access.py --confirm-database openCJ_cod4 \
        --readonly-database opencj_test_cod4

Gameplay cannot create/alter/drop tables, rewrite migration history, update old
award amounts or directly delete accounts, runs, saves, statistics, checkpoints,
awards or purchases. Required data writes, temporary cleanup and reviewed stored
routines remain available. Administrative routine definers preserve account
creation rollback and atomic purchases. Passwords/accounts are not replaced.

The old persistent test database becomes read-only to gameplay. Destructive tests
use disposable containers and their own test/admin identity. Migration/recovery
admin access remains available. No other host service/database is changed.

Compose now treats the existing opencj-dev_database volume as external. Teardown,
including down --volumes, cannot remove it. Explicit administrator deletion is
still possible: this is protection against teardown mistakes, not a backup.
Fresh development setups must create that external volume before starting Compose.

## Applied development deployment

Applied 2026-11-14 at 13:57 Europe/Amsterdam. Only operator was connected before
the guarded restart; mp_futile_fixed was restored. No script or SQL startup errors.
The same database container/volume remains in use.

All pre-existing base-table projections and existing spending-point balances
matched their pre-migration values. Migrations 001–020 are explicitly recorded as
adopted; 021–023 are recorded as applied.

Validation: 55 database safety checks, 239 CPC checks, 34 history/layout checks,
36 exact-mode record comparisons, restricted-account engine startup, four setup
unit tests, and the disposable Docker-volume teardown test all passed.

The earlier cleanup (020) and this safety work are kept in separate commits.
Unrelated source changes were preserved.
