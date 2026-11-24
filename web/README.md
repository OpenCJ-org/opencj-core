# OpenCJ website

The public website for OpenCJ (CoD4). Status: beta, in development.

A generator container rebuilds a static site every minute from the database,
the game server's status reply and the release notes in
[docs/releases](../docs/releases/README.md). A separate web server container
serves the result. The site has no accounts, forms or uploads; it writes
nothing to the database.

## Pages

| Path | Content | Source |
| --- | --- | --- |
| `/` | Latest release notes, server status, Top 10 by challenge points, most played maps | Releases, game server, database |
| `/releases/` | Notes for every published version | `docs/releases/*.md` |
| `/maps/` and `/maps/<map>/` | Pool maps; per route the top 25 with in-game default filters; map download | Database |
| `/rankings/` | Challenge-point ranking (top 100) and all pool maps by plays | Database |
| `/players/<id>/` | Challenge points and personal bests | Database |
| `/downloads/` | Files of every pool map (`mapids.inRotation = 1`) | Map folders |
| `/guide/` | How to join, challenges and leaderboards | Templates |
| `/usermaps/<map>/<file>` | Map files, only for pool maps | Copied by the generator |

Map plays come from the `mapPlays` table (migration 028), filled by the game.

## Containers

| Service | Image | Networks | Purpose |
| --- | --- | --- | --- |
| `generator` | Built from `web/Dockerfile` | The game installation's Compose network | Reads the database (`db:3306`) and game status (`server:28960/udp`); writes the site and map copies to the `output` volume |
| `httpd` | `nginxinc/nginx-unprivileged:1.27.3-alpine` | Its own network only | Serves the `output` volume read-only on container port 8080 |

The web server cannot reach the database or the game server. Both containers
run without Linux capabilities and with read-only root filesystems.

## Port

| Host address | Default | Setting |
| --- | --- | --- |
| Bind address | `127.0.0.1` (this machine only) | `WEB_BIND_IP` |
| Port | `8090` | `WEB_PORT` |

Keep the loopback default. For public hosting, run a tunnel such as
Cloudflare Tunnel on the same host and point it at `http://127.0.0.1:8090`,
so no inbound port is opened. To look at a development site from another
computer, forward the port over SSH:

```sh
ssh -L 8090:127.0.0.1:8090 <user>@<host>
```

Then open `http://localhost:8090`.

## Configuration

Settings come from `web/.env` (private, ignored by Git). Copy
[.env.example](.env.example).

| Setting | Required | Default | Meaning |
| --- | --- | --- | --- |
| `WEB_DB_PASSWORD` | Yes | | Password of the read-only account; `tools/grant_web_access.py` creates it |
| `WEB_CONNECT_ADDRESS` | No | `eu.opencj.org:28960` | Game server address shown after `/connect` |
| `WEB_DISCORD_INVITE_URL` | No | `https://discord.gg/VDtbYExYWd` | Discord invite shown as a button on the homepage; set to an empty value to hide it |
| `WEB_USERMAPS_DIR` | Yes | | Host folder containing `<mapname>/` map folders |
| `WEB_USERMAPS_GID` | Yes | | Group ID that may read that folder |
| `WEB_GAME_NETWORK` | No | `opencj-dev_default` | Compose network of the game installation |
| `WEB_DB_HOST`, `WEB_DB_PORT`, `WEB_DB_NAME` | No | `db`, `3306`, `openCJ_cod4` | Database on that network |
| `WEB_DB_USER` | No | `opencj_web` | Read-only account name |
| `WEB_GAME_HOST`, `WEB_GAME_PORT` | No | `server`, `28960` | Game server on that network (UDP status query) |
| `WEB_BIND_IP`, `WEB_PORT` | No | `127.0.0.1`, `8090` | Host address of the site |
| `WEB_REBUILD_INTERVAL_SECONDS` | No | `60` | Time between rebuilds |
| `WEB_COMPOSE_PROJECT` | No | `opencj-web` | Compose project name |

## Database access

The site uses its own MySQL account that may only `SELECT` from these tables:
`challengeCompletions`, `challenges`, `checkpointStatistics`, `checkpoints`,
`mapids`, `mapMappers`, `mapPlays`, `mappers`, `playerDisplayNames` (a view of
player IDs and display names), `playerRuns` and `routes`. It cannot read
logins, IP addresses, settings or the player table itself.

Create or update the account after migrations are applied. From `web/`:

```sh
python3 tools/grant_web_access.py --container "$DB_CONTAINER" --confirm-database openCJ_cod4
```

`DB_CONTAINER` is the installation's running database container, as described
in [database operations](../docs/operations/database.md). The tool writes a
generated password to `web/.env` when none is set, and prints the final grants.

## Run

From `web/`, after the game installation is running:

```sh
docker compose up -d --build
docker compose logs generator
```

The generator logs `Site published` after each build. When a build fails, the
previous site stays online and the next cycle tries again.

## Disk use

The generator copies the `.ff` and `.iwd` files of pool maps into the `output`
volume, so downloads never expose other maps. Expect roughly the size of the
pool's map folders. Maps that leave the pool are removed on the next build.

## Tests

```sh
python3 -B dev-tools/scripts/test.py portable web-unit
```

Run from the core root. These cover status parsing, release notes, ranking
positions and download copying; they need no database or containers.

## Visual design

Direction "HUD": dark panels with cut corners, based on the in-game speed and
FPS huds. Headings use Chakra Petch, body text Barlow, times JetBrains Mono,
all loaded from Google Fonts.

| Role | Color |
| --- | --- |
| Page background | `#0c0f13` |
| Panel | `#141920` |
| Divider | `#263040` |
| Text | `#e8ecf2` |
| Muted text | `#8792a3` |
| Labels and bars (cyan) | `#5fd4e6` |
| Accent: numbers, positions, buttons (periwinkle) | `#93a2ec` |

The accent is a deeper version of the menu header color `PERIWINKLE_COLOR`.
The Discord button uses Discord's brand color `#5865f2`.

## Third-party material

- Discord logo: SVG path from [Simple Icons](https://simpleicons.org/) 13.21.0,
  released under CC0 1.0, inlined in `opencj_web/templates/macros.html`. The
  logo is a trademark of Discord Inc.; it is used only to link to the OpenCJ
  Discord server, as Discord's brand guidelines allow.
- Fonts (Chakra Petch, Barlow, JetBrains Mono) are loaded from Google Fonts
  under the SIL Open Font License and are not bundled.
- The logo's letters are outlines of Chakra Petch Bold (SIL Open Font License
  1.1); see [brand/README.md](brand/README.md) for the files and how to rebuild them.

## Integrated server setup

The [host setup wizard](../docs/setup/server.md) can configure this project for a
selected game instance, with separate Linux users, a unique read-only SQL account,
installed map paths and private per-instance Compose configuration. It does not
rewrite this checkout's `.env`. The generator accepts `WEB_DB_PASSWORD_FILE` as an
alternative to `WEB_DB_PASSWORD`; the installer mounts only that password file in
the generator. The HTTP container receives neither database credential. Standalone
Compose users can continue using the documented `.env` workflow.

With a domain name, setup adds a Caddy container that serves the site over HTTPS on
ports 80/443 with automatic Let's Encrypt certificates; `/usermaps/` also stays
reachable over plain HTTP for in-game map downloads.
