# Getting started

Use an Ubuntu 24.04 x86_64 development host with Docker Engine, Compose v2,
Git and Python 3. The container build supplies the 32-bit compiler toolchain.
The optional host helper is `scripts/install-host.sh`; review it before use.

Obtain the complete core checkout and initialize only the needed engine:

```sh
git submodule update --init -- cod4x-server
```

Do not add `--recursive`: optional inherited engine gitlinks are not part of the
supported build. CoD2 developers can initialize `libcod` separately. The core commit pins compatible engine revisions; do not replace those pins
with a branch's latest revision as an initialization step.

## External assets

Provide a licensed CoD4 game installation with `main/`, `zone/`, the matching
CoD4x support IWDs and Steam bridge libraries. Provide matching compiled OpenCJ
`mod.ff` and IWD assets. Stock game files and Windows Mod Tools are separate
prerequisites; source checkout does not supply them.

## Empty development database

Run from `dev-tools`. Set `GAME_DIR` and `MOD_DIR` in your shell to your own
licensed game installation and compiled OpenCJ mod directory:

```sh
python3 dev.py init --game-dir "$GAME_DIR" --mod-dir "$MOD_DIR"
docker volume create opencj-dev_database
docker compose up -d --wait db
python3 scripts/bootstrap-db.py --confirm-empty
python3 dev.py build
python3 dev.py up
```

Initialization preserves existing configuration and engine work. It creates
private credentials in `.env` and `local/runtime/mods/opencj/opencj-dev.cfg`.
Keep both files. The default game bind address is loopback; choose a reachable
LAN/VPN address with `--bind-ip` and a suitable `--port` for remote play.

The database bootstrap refuses any existing tables, routines or events. It
imports the versioned baseline, applies every numbered migration with checksums,
and narrows gameplay permissions. A partial failure is not replayed blindly:
inspect the disposable database and its ledger before deliberate recovery.
It creates no player accounts, player runs or private moderation rules.

Compose's database healthcheck tests connectivity only. `dev.py up` also checks
that the full migration ledger matches the checkout before starting gameplay.
The named database volume is external: normal Compose teardown preserves it.
Backups are still necessary.

## Existing databases

Do not run bootstrap against an existing installation. Back up first, stop
writers and use `server-db/tools/migrate.py status` and the documented upgrade
procedure. `adopt-020` only recognizes the specifically supported post-020 legacy
schema; it is not a general upgrade shortcut. See [database safety](../operations/database.md).

## Verification limits

The automated fresh-database test requires no private backups or game files.
Game/client verification additionally requires the external assets and a player
connection. A successful container start is not proof that every map, client
build, or Windows Mod Tools installation works. Record those checks for your
installation instead of copying someone else's acceptance log.
