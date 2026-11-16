# OpenCJ development tools

Develop on an Ubuntu 24.04 x86_64 server using VS Code Remote SSH. Source stays
on that server; Compose mounts the same files into the build and game containers.
The Ubuntu 24.04 image contains the 32-bit GCC/G++ and MySQL client toolchain.
MySQL 8.0 runs separately with its own persistent volume and no published port.

This is a development setup, not a production deployment. It does not replace
your existing CoD4 installation or executable. Game files are mounted read-only;
OpenCJ writes under `dev-tools/local/runtime`. The host port defaults to 28961.

## First setup

Place this repository at `~/opencj/dev-tools` (or another parent directory).
The setup clones missing sibling repositories from **OpenCJ-org**. Existing
checkouts are preserved, including their current branches and uncommitted work.
Defaults are `master`, except `cod4x-server` and `libcod` use `opencj`;
Discord uses its remote default branch. The separate libcod checkout is for CoD2;
CoD4 compiles its native helpers directly from `server-ext`.

1. Install Docker Engine with Compose v2, Git, and Python 3 on Ubuntu. An optional
   helper is `bash scripts/install-host.sh`. It uses Docker's official repository
   when Docker is absent; it leaves existing Docker installations in place.
   Run development commands as your normal SSH user with Docker access.
2. Locate your existing CoD4 game root, containing `main/` and `zone/`.
   Custom maps belong in its `usermaps/` directory.
   Include the CoD4x support IWDS, including `jcod4x_00.iwd`, alongside the stock
   game IWDS. A Steam-only installation may be missing this client support archive.
   Use the matching archive from your CoD4x installation; on Windows it can live
   in `%LOCALAPPDATA%\CallofDuty4MW\main`. Alternatively, put it in
   `dev-tools/local/runtime/main/` to keep the existing game root unchanged.
   Without it, pure validation can reject clients specifically after map reloads.
3. Put matching OpenCJ `mod.ff` and IWD assets in the game root's `mods/opencj/`
   directory. This is the default asset location; it is required to play but may
   be absent during initialization/build. `--mod-dir` overrides it if needed.
4. From `dev-tools` on Ubuntu:

   ```bash
   python3 dev.py init --game-dir $GAME_DIR \
     --bind-ip 192.168.1.20 --port 28961 --map mp_killhouse
   python3 dev.py build
   python3 dev.py up
   python3 dev.py logs
   ```

Replace the example paths and IP. Use a reachable LAN/VPN IP, or `0.0.0.0` to
publish on all host interfaces. The default `127.0.0.1` is host-local; Remote SSH
does not automatically forward the game's UDP traffic. Allow the chosen UDP/TCP
port through your network firewall. Docker-published ports need Docker-aware
firewall rules; see Docker's installation documentation below.

Initialization creates random database passwords in ignored, owner-readable
`.env` and `local/runtime/mods/opencj/opencj-dev.cfg`. Keep these files together.
Repeated `init` refuses to overwrite them. Database initialization imports the
checked-in schema only when the named volume is empty. Restarting or running
`down` preserves it. An existing volume is never automatically reimported.
If initialization fails, inspect `docker compose logs db`; do not treat a
partially initialized volume as a successful schema import.

## VS Code and everyday changes

Install Microsoft's **Remote - SSH** extension on Windows. Connect to Ubuntu,
then open `dev-tools/opencj.code-workspace` in that SSH window. All repositories
appear as separate folders. Use **Terminal → Run Task** for build/start/restart/
logs/stop, or run `python3 dev.py <command>` in a remote terminal.

  ```powershell
  cd '$MOD_TOOLS'
  python makeMod.py
  ```

  This builds that source directory, including local changes, and writes the
  `.ff` and IWD to its parent. Deploy both into the server's `mods/opencj/`.
  Back up existing outputs first: the script deletes them before building.
  The unchanged script succeeded on the existing Mod Tools installation.
  Its linker-failure handler now reports `cpe.stderr`, preserving the original
  error. The existing `mod.csv` destination (`zone`) remains unchanged.
  The successful run already had a matching `zone_source/mod.csv` from an earlier
  build; a clean-install test remains necessary. Source trees are not automatically reconciled.

GSC/GSX associations provide basic C-style highlighting, not a GSC compiler.
C++ IntelliSense uses the CoD4 definitions, but full system-header resolution and
container debugging are not configured in this first version.

## Optional Discord bridge

Create `local/config_cod4` following `discord-integration/README.md`, with your
bot token, channel ID and guild ID; run `chmod 600 local/config_cod4`. Then:

```bash
docker compose --profile discord up -d --build discord
docker compose logs -f discord
```

The bridge and server share only their Unix socket directory. The server keeps
internal port 28960, which the native Discord integration currently requires;
the independently chosen published host port does not affect it. The Python
dependency is constrained to discord.py 2.x; this bridge still needs a live test.
`docker compose --profile discord down` stops all services while preserving data.

## Map screenshots and preview assets

## Database safety

The database uses the existing external Docker volume opencj-dev_database.
On a fresh development host, run docker volume create opencj-dev_database before
starting Compose. Never replace an existing deployment's volume with an empty one.

Use server-db/tools/migrate.py and tools/runtime_access.py for migrations and
permissions. scripts/backup.py creates and restore-tests an on-demand backup.
See docs/database-safety.md; no backup schedule is installed.
