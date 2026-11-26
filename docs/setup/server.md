# Install an OpenCJ server

After installation, the [administrator guide](../operations/server-administration.md)
explains daily operation: status, alerts, changing settings, upgrades and restores.

The first release target is **beta-0.1.0**. `VERSION` identifies the source release;
each installation records its core revision, pinned engine revision, image ID and
migration state. A release name in source does not mean its Git tag or compiled
assets have already been published.

The supported host is **Ubuntu 24.04 LTS, x86-64**, with root access or an account
that can install prerequisites and use Docker. ARM and CoD2 are not supported by
this installer. The existing development helper remains available for source
work; this installer creates separate operational instances.

## One entry point

On a fresh **Ubuntu 24.04 LTS x86-64** host, configure your administrator's SSH
access and Git access, then clone the reviewed release and run its entry point:

```sh
git clone https://github.com/OpenCJ-org/opencj-core.git
cd opencj-core
# Select the reviewed release revision before running setup.
sudo bash opencj.sh install
```

Use your configured Git SSH URL instead when needed. Git is the only tool needed
to obtain the checkout (`sudo apt-get update && sudo apt-get install -y git` if
missing). Do not initialize submodules recursively: setup initializes the exact
engine pin it needs and builds inside Docker. It installs Python, rsync and Docker
Engine/Compose using the existing host prerequisite helper. Your administrator
uses sudo; runtime users never join the Docker group.

The standalone script from a **published** release clones its exact tag into
`/opt/opencj/releases/beta-0.1.0`. Until that tag exists, use a reviewed checkout.
The script never falls back to a moving branch. Do not pipe an unreviewed network
response into a root shell.

The default host wizard asks which servers to create, initially suggesting
`main-eu,acceptance,map-test`. It collects each instance's display name, distinct
ports, 32-player limit, private/public access, whether it runs only on demand and
database choice before creating services. Private is the default: unlisted/LAN mode plus a generated join password.
Per server it also asks for map downloads, the Discord bridge and, for each owned
database, backups (with an off-site copy), pruning of abandoned runs and IP-country
updates; production-like defaults apply to `main-*` servers. For the machine it asks
about the website (default no), security updates, the firewall, SSH hardening and an
alert channel. Invalid answers are asked again, and a summary must be confirmed
before anything is created.

The suggested topology is:

| Instance | Database choice | Result |
| --- | --- | --- |
| main-eu | migrate | Production database, maps, compiled assets and runtime drafts transferred from the old installation |
| acceptance | copy from main-eu | Independent database initialized from a consistent main snapshot |
| map-test | new; assets from main-eu | Empty player database with its own runtime, sharing only read-only asset files |
| later main region | owner (switched off, see below) | Shared production database through a restricted SSH tunnel, with separately revocable SQL credentials |

**On demand.** Every server except `main-*` is off until started by default
(`"on_demand": true` in a plan). Installation checks it while running and then stops
it; `sudo opencj start NAME` and `sudo opencj stop NAME` switch it on and off. Stop
stops the whole Compose project, its own database included, and keeps all data. The
watchdog, `opencj status` and the printed outside-check targets treat an on-demand
server that is off as normal, and its backup and pruning jobs skip it. `stop` on an
always-running server stops only its game server and Discord bridge, records the
current boot ID in `stopped-by-administrator.json`, and sends no alerts; after a reboot
the watchdog starts it again and removes the record. A server cannot
be on demand when it runs the website or when another server shares or copies its
database; setup and `configure` refuse that.

Acceptance copying briefly stops its selected source game to capture a consistent
snapshot. Use the migration player guard and maintenance window. Copying is a
one-time operation, not continuous replication. Subsequent acceptance writes do
not affect main. Refreshing it later is the explicit `opencj refresh acceptance`
(see below); rerunning setup never silently refreshes it.

The saved host plan is `/srv/opencj/host-setup.json`; each instance has its own
subdirectory. On failure, rerun **the same command without new answers**:

```sh
sudo bash opencj.sh install
# Or, if a different host directory was originally selected:
sudo opencj install --host-dir /srv/opencj
```

Completed instances are checked without restarting them. Unfinished instances
resume with their recorded credentials, Linux users and resource identities.
For unattended setup, pass `--plan /root/host-plan.json` only on the first run.
Its `instances` array contains the same per-instance settings as the single-instance
interface; dependencies use `copy_from`, `share_with` or `assets_from` naming an
earlier instance. `security_updates` holds `enabled`, `time`, `reboot` and optionally
`reboot_time`. Keep this file private.

The single-instance interface remains available:

```sh
sudo opencj install --instance-dir /srv/opencj/main-eu --config /root/main-answers.json
```

A fresh independent instance can use:

```json
{
  "name": "main-eu",
  "game_assets": "/srv/assets/cod4",
  "mod_assets": "/srv/assets/opencj-beta-0.1.0",
  "port": 28960,
  "bind_ip": "0.0.0.0",
  "public": false,
  "database": {"mode": "new", "name": "openCJ_cod4", "publish_port": 3306},
  "backups": {"enabled": true, "time": "03:30", "keep": 7, "max_gib": 2, "reserve_gib": 2}
}
```

The single-instance command configures its backup timer; host-wide update policy
is configured by the host wizard. Never supply a new plan/configuration to replace
an existing installation. Operator edits are preserved and reported for review.

## Supply game and compiled client files

For each asset set, supply an existing directory, a local ZIP/tar archive, or an
HTTPS archive URL. Downloads require the SHA-256 from a trusted source, entered
separately (`game_sha256` / `mod_sha256` in JSON). Archive roots must directly
contain the expected files, without an extra enclosing folder.

The game set needs `main/`, `zone/`, `steam_api.so` and `steamclient.so`, including
licensed base-game files, matching CoD4x support IWDs and the chosen map's assets.
The mod set needs the matching compiled `mod.ff` and OpenCJ IWD files. Preserve the
IWD's `licenses/` entries. `mp_killhouse` is the default initial stock map.
Custom maps also require their installed `usermaps/<mapname>` assets.

Directory inputs are mounted read-only and never copied over or modified. Their
contents must be readable by the runtime account. Archive inputs are extracted
into the machine's shared `/srv/opencj/assets/`, rejecting links, special files and
escaping paths. Downloads
and expanded assets are limited to 16 GiB per set, with at most 100,000 entries;
the download deadline is 30 minutes. Larger installations can use supplied
directories. Stock assets are not fetched from an invented redistribution URL.
See [licenses and asset sources](../reference/licensing.md).

The Linux installer builds the native engine from the core's exact submodule pin
inside the established Ubuntu builder. It does not initialize nested submodules,
replace local engine work or compile Windows client assets. The private runtime
mounts are separate from the source checkout; gameplay cannot write source files
or read database administration secrets.

## Database choices

### Independent local database

`mode: new` creates an independent MySQL 8.0 container and uniquely named external
volume. The image is pinned by digest. Main, acceptance and maptesting instances
therefore remain separate even on one machine. Names can differ, but a database
name must end in `4`: existing game scripts append the CoD version to `db_base`.

The existing bootstrap imports its baseline into the selected empty schema,
applies every checksummed migration and narrows the gameplay account's grants.
It does not create player/admin accounts or copy another installation's records.
A nonempty, untracked, incompatible or partially migrated schema is refused.
The same completed schema can be rechecked without replaying migrations.

`publish_port` exposes MySQL **only on host loopback**, for administration or SSH
forwarding from another machine. Use a distinct port for each local database;
zero disables host publication. No public MySQL port is opened automatically.
Docker publishing can bypass ordinary host firewall expectations; use the cloud
provider firewall as well. See the official
[Docker Ubuntu installation guidance](https://docs.docker.com/engine/install/ubuntu/).

### Share another instance on the same machine

Choose `mode: instance` and its `instance_dir`. Setup requires that instance to
be ready on the same release and to own its local database. It provisions a distinct, restricted gameplay account and joins that database's
Docker network; it never copies the root password or creates a second database volume.

Use independent databases for acceptance and maptesting when their changes must
not affect main. Sharing means sharing player progress, records and checkpoint
layouts, not just sharing an SQL process.

### Connect from another machine

> **Switched off until tested.** The wizard does not offer `owner` or `existing`, and a
> plan that uses them (or a published database port) is refused. The code is kept;
> to test it between two machines, set `REMOTE_DATABASE_ENABLED = True` in
> `dev-tools/setup/configuration.py`. The rest of this section describes it.

For an installation managed by this setup, choose `owner`. Supply the database
owner's checkout/instance paths and its administrator SSH connection, including a
**verified known_hosts file**. Source administration uses noninteractive sudo when
needed. The owner must expose MySQL on a loopback port.

Setup provisions distinct gameplay and optional website SQL accounts. It generates
a separate tunnel key and a locked, non-login Linux account on the owner. That
account has no SSH sessions, shell, PTY, agent forwarding or remote forwarding;
its key can forward only to the owner's selected `127.0.0.1` database port.
Installation administration uses the administrator connection, while the persistent
container receives only the new restricted key. Setup validates the effective SSH
policy before reloading SSH. Existing administrator access is not changed.

For a database managed elsewhere, choose `existing` and supply pre-provisioned
restricted SQL credentials plus either SSH or private-network transport. An
external SSH identity must already be dedicated and forwarding-restricted; do not
supply your administrator/root key for a persistent tunnel. The installer pins the
supplied host key and does not blindly trust `ssh-keyscan`. The tunnel has its own
Linux identity, reconnects after failure, and publishes no host port.

Use `private` only for an already-secured private network/VPN. The current native
SQL adapter does not configure verified TLS identity through installer settings;
do not present a public, opportunistically encrypted MySQL endpoint as equivalent
to the pinned SSH path. The setup connection uses the same transport as gameplay.

Joining checks the MySQL version, complete migration ledger and the complete
reviewed runtime grant policy. Use a dedicated gameplay account; broad grants,
roles, privileges on unrelated schemas and missing required permissions are refused.
Generic `existing` connections **never bootstrap, migrate or change grants** on
the shared database. Managed `owner`/local-sharing connections provision only
their new owned client accounts; they do not migrate the shared schema.
Use the owning installation for planned schema upgrades, coordinating all writers.
The supported database version for this beta is MySQL 8.0, matching the tested
runtime; MariaDB and other major versions are not claimed compatible.

## First administrator

A fresh database deliberately gives no privileges to the first player who joins.
After joining privately and identifying your account, use the database owner's
administration console to inspect `playerInformation` / `playerDisplayNames` and
give that verified player the uber permission (bit 0):
`UPDATE playerInformation SET permissions = permissions | 1 WHERE playerID = <id>;`
Reconnect to reload permissions. Do not grant it based merely on arrival order or
an assumed player ID. Grant other permissions in game with `!permissions grant`;
see the [permission table](../reference/permissions.md).

The owner can open the SQL console without putting its password in command arguments:

```sh
sudo docker compose -f /srv/opencj/main-eu/compose.json exec db sh -c \
  'MYSQL_PWD="$(cat "$MYSQL_ROOT_PASSWORD_FILE")" exec mysql -u root "$MYSQL_DATABASE"'
```

Checkpoint editing is disabled in the generated server configuration by default.
Enable it deliberately for an editing instance and retain the existing role checks.
A separate maptesting database avoids publishing experimental layouts into main.

## Migrate the old installation

Choose `migrate` and identify the old checkout and installation directory. The
current development installation is also supported by selecting its `dev-tools`
directory. Use SSH for another machine or a local path for the same host. Select
**rehearsal** to resume the source after snapshotting, or **cutover** to leave its
game and database stopped. Rehearsal targets must remain private.

Setup builds the candidate before maintenance and pre-copies game files, all
installed map binaries and compiled mod assets, and hashes that fixed asset copy
before the outage window. It then checks connected players,
stops only the selected game, refuses other database writers, freezes writes,
exports SQL plus per-table row counts and content digests, and copies persistent
runtime/editor files. The restore must reproduce every digest. FLOAT columns are
compared at the roughly six significant digits that SQL dumps (and scheduled
backups) keep; their last bits can change, which no gameplay value depends on.
Every transferred file is checked against a SHA-256 inventory. rsync resumes
interrupted transfers. Source configuration is retained privately for reference;
the new installation receives fresh credentials and generated configuration.

Rehearsals restore the source's previous read-only settings and active map. A cutover
keeps the source fenced. After restore/schema checks, the destination accepts write
ownership **before starting gameplay**. A later startup/website failure can be
resumed, but must not revive the old database alongside newer destination writes.
Before that ownership transfer, a failed cutover can be resumed or deliberately
cancelled from the source:

```sh
sudo bash opencj.sh resume-source --bundle /path/to/the/recorded/source-bundle
```

After acceptance, automatic rollback is refused because the destination may have
newer writes. Stop all writers and reconcile those writes before a planned rollback.
Never run old and new independent production copies concurrently for public play.

The source bundle path is recorded in the private installation record. Local or
uploaded complete bundles can also be selected with `restore`. An interrupted
**unaccepted candidate import** may be discarded and re-imported only after checking
its owned volume and absence of gameplay resources. Ready databases and operator
changes are never replaced. Pending schema migrations run after an exact restore
check. Source and target must use the supported matching MySQL version.

A migration bundle includes assets and SQL, so allow temporary space on both hosts.
File/transfer preflights reserve at least 2 GiB beyond the incoming copy; source SQL
uses a conservative size estimate. Other workloads can still consume disk, so
monitor free space throughout a large move.
The target's `migration/bundle/game` and `mod` directories are active read-only asset
roots: do not delete its bundle as a generic cleanup step. After acceptance and
independent backups, the old source export can be removed deliberately.

## Linux users and service isolation

Setup creates separate system identities per instance/service: game, database,
website generator, HTTP server and SSH tunnel when present. They have locked
passwords, `/usr/sbin/nologin`, no home directory, no sudo access and no Docker-group
membership. Their UID/GID and ownership marker are recorded and rechecked on retry.
Main, acceptance and map-test therefore do not share a writable runtime identity.

Containers use those non-root identities, drop Linux capabilities, disallow privilege
gain and use read-only root filesystems with limited writable mounts. Game services
see their own runtime, read-only assets and gameplay credentials; they cannot mount
the Docker socket, read administrative database credentials or modify the checkout.
Website SQL privileges are SELECT-only on its maintained table allowlist. Gameplay
uses the reviewed runtime policy; migrations and backup orchestration are separate
administrative operations. Docker administrators remain host administrators.

Use the provider firewall to expose only intended game ports, administrator SSH
and a public reverse proxy. MySQL binds only loopback when published; the website
binds loopback by default. Setup does not guess provider rules, replace your SSH
login policy or issue HTTPS certificates. Restricted service accounts and updates
are part of host security, not a guarantee against every application vulnerability.

## Optional website

Answer yes to use the actual [website project](../../web/README.md) shipped in
`web/`. Select its game instance, its main domain and any extra domains, local port,
public game address and Discord invite. Setup applies the complete migrations, including 028, then uses the
maintained website grant helper's table policy to provision a unique account.
The game runtime policy includes the `mapPlays` insert permission.

Each installation has private website configuration and a password file; the source
`web/.env` remains untouched. The generator and HTTP container run in a separate
Compose project with their own Linux identities. Only the generator receives the
read-only database credential and installed maps; the HTTP container serves generated
public files. Readiness requires a freshly generated page and a successful HTTP
check. `server-web` is not used.

**HTTPS.** With a domain name, a [Caddy](https://caddyserver.com/) container serves
the site on ports 80/443 and obtains and renews a free Let's Encrypt certificate by
itself. Extra domains (for example `opencj.net` next to `opencj.org`) get their own
certificates and redirect permanently to the main domain, so visitors and search
engines see one address. Plain HTTP redirects to HTTPS, except `/usermaps/`: CoD4
clients download maps over plain HTTP only. Change the domains later with
`sudo opencj configure <server>`. Caddy runs unprivileged (host ports 80/443 map to
container ports 8080/8443), read-only and without Linux capabilities; certificates
are kept in the installation's `website/caddy-data/`. Without a domain the site only
listens on `127.0.0.1:8090` (for an SSH tunnel or another proxy).

## Domain names and DNS

Each game server can have an address players connect to (for example
`eu.opencj.org`; blank means the IP address), asked after its game port. The website
has a main domain and optional extra domains. Setup reads this machine's public
addresses from its own network interfaces (behind a router it asks for the public
IPv4 address and you forward the ports), then prints the records to create at your
domain provider:

```text
  opencj.org                       A     203.0.113.10                            (website)
  opencj.net                       A     203.0.113.10                            (website, redirects to opencj.org)
  eu.opencj.org                    A     203.0.113.10                            (game server main-eu)
```

AAAA (IPv6) records are listed as optional when the machine has a public IPv6
address. Before the website starts, setup checks the website names and waits
(`check` / `continue`): certificates are issued only once every website name points
here, and a wrong AAAA record breaks them even when A is right. Choosing `continue`
is safe; Caddy fetches the certificate by itself once DNS is right. Game server
names are checked and reported only. `sudo opencj dns` prints the records and their
current state at any time; `configure` prints them after a name changes.

If your domain uses a DNS proxy such as Cloudflare, set these records to **DNS only**
(grey cloud): the proxy does not carry game traffic, and the check would see the
proxy's addresses instead of this machine.

## Maps and map downloads

All servers on a machine read one shared, read-only copy of the game files, maps and
compiled mod files in `/srv/opencj/assets/`. A migration moves its verified files
there; a copy such as acceptance uses the same folder instead of a second 16 GiB copy.

```sh
sudo opencj maps add /path/to/mp_newmap      # a folder, archive or https:// URL (+ --sha256)
sudo opencj maps list
```

`maps add` accepts only `<map>.ff`, `<map>_load.ff` and `.iwd` files, stages them next
to the live folder and swaps them in at once. Servers load a new map on the next map
change; offering it on a server is done through that server's map pool in the game.

Each server has a download mode, chosen in the wizard or with `configure`:

| Mode | Who can download | Typical server |
| --- | --- | --- |
| `website` | Anyone, over fast HTTP, for maps in the main database's pool | Public main servers |
| `in-game` | Only players who joined (on a private server: with the password), slowly through the game | map-test, acceptance |
| `off` | Nobody; players need the maps already | Special cases |

A map that is not in the main server's pool is never published on the website, even
though its files sit in the shared folder. A password-protected server reports its
map as `Hidden` to server browsers and query tools (`getstatus`, `getinfo` and the
Source-engine queries) unless the asking client joined with the password. Fast HTTP
downloads for private servers need the not-yet-built
[download grants](../proposals/map-download-authorization.md).

## Discord chat bridge

Per server, the wizard offers the Discord bridge from `discord-integration/` (default
yes for `main-*` servers) and lists these steps with links:

1. Create an application and its bot in the
   [developer portal](https://discord.com/developers/applications)
   ([step by step](https://docs.discord.com/developers/quick-start/getting-started)).
2. On the Bot page, switch on *Message Content Intent*: the bridge reads chat
   messages ([Discord docs](https://docs.discord.com/developers/events/gateway#message-content-intent)).
3. Invite the bot to your Discord server with permission to view the channel and send
   messages.
4. Switch on Developer Mode in Discord and copy the server and channel IDs
   ([how](https://support.discord.com/hc/en-us/articles/206346498)).
5. Bot page > Reset Token, and copy the token (shown once).

Then enter the server (guild) ID, the channel ID and the bot token
(entered hidden, stored only in the root-only installation record and the bridge's
private configuration). The bridge runs as its own Linux user; it and the game share
only a private socket folder.

Bridges stay apart by construction: a bridge reads only the event socket of its own
server (each server has its own socket folder), it reads no database, and it accepts
Discord messages only from its configured Discord server and channel. Setup refuses
two bridges with the same channel on one machine, so acceptance or map-test chat can
never appear in main's channel. One bot token may serve several servers, each in its
own channel. A wrong token makes only the bridge restart; the game is
not affected, and the watchdog reports it.

## Scheduled backups, pruning and security updates

For each owned database the wizard asks about nightly backups: **yes for main/main-*
instances, no for others**. Shared clients use the database owner's schedule.
Defaults are 03:30 Europe/Amsterdam, up to seven compressed SQL snapshots, a **2 GiB
combined storage limit** and **2 GiB minimum free space**. All are configurable.

**Off-site copies.** The wizard can also copy each night's backups to another machine
(default yes for `main-*`). It shows that machine's SSH host-key fingerprint for you to
confirm, creates a dedicated upload key and prints one command to run on the receiver,
from its own opencj-core checkout:

```sh
sudo bash opencj.sh backup-receiver --name main-eu --key 'ssh-ed25519 AAAA... opencj-main-eu-...-offsite'
```

The receiver gets a locked account without shell whose key may only *write* files
into `/srv/opencj-offsite/<name>/` (rsync's `rrsync -wo`). Every hour the receiver
moves finished uploads into `/srv/opencj-offsite/.kept/<name>/`, which only root can
open, so a compromised game server can neither read, change nor delete earlier copies.
Uploads dated in the future (which retention would otherwise keep as "newest") are
deleted, a second upload with an existing name is ignored, and both are reported to
the alert channel. Each night the game server sends only the backups it has not sent
before. The receiver keeps every backup for 14 days, one
per week for 8 weeks and one per month for a year, within **50 GiB for all senders
together** (`--max-gib`); over the limit the oldest go first, but each sender's newest
7 backups always stay. It needs no Docker.

**Pruning abandoned runs.** Saves accumulate quickly with many active players. Each
night (04:15) the database owner deletes **unfinished** runs nobody has played for the
chosen number of months (default 6; 0 disables), together with their saves, checkpoint
times, labels and unfinished demos. Finished runs are never touched, so leaderboards,
records, challenge completions and demos stay exactly as they are; runs with winning or
published demos are skipped too. Deletion happens in small batches, each rechecked
under a lock, so a player resuming a run at that moment keeps it. The result is in
`last-prune.json`.

The root-owned systemd backup service streams a transaction-consistent SQL dump,
including demo tables, routines, triggers and events. It has bounded time, memory
and disk use. Partial dumps never replace completed backups. Retention removes only
its own oldest backups and preserves the newest successful backup if a new one fails.
If one snapshot plus the last good snapshot cannot fit the configured budget, backup
fails visibly instead of consuming the disk; increase the budget or arrange remote
storage. Check the service journal and `last-backup.json` for successful completion.
Local copies alone do not protect against loss of the machine.

Scheduled SQL snapshots are in `automatic-backups/`. They exclude runtime files,
configuration and map assets; use the full migration export for relocation and the
manual verified backup below for SQL plus runtime/configuration recovery. Periodically
restore a backup into a disposable database. A successful dump is not a restore test.

The host wizard separately offers **Ubuntu security updates** (default yes), at
**05:00 Europe/Amsterdam**, with package metadata refreshed 15 minutes earlier.
Explicit timezone scheduling follows daylight saving without changing the host's
timezone. Missed timers do not unexpectedly run maintenance immediately at boot.
Updates can restart affected services. Automatic reboot (default **yes**) happens only
when an update requires it, at a 05:30 check that skips while APT jobs are active. All
OpenCJ services start again by themselves after a reboot.

Only Ubuntu security origins are enabled by this policy. Pinned Docker images,
OpenCJ releases and other third-party packages need their own reviewed upgrade
procedure; unattended host updates do not rebuild containers. This configuration
uses Ubuntu's [unattended-upgrades](https://ubuntu.com/server/docs/how-to/software/automatic-updates/)
and timezone-aware [systemd timers](https://www.freedesktop.org/software/systemd/man/latest/systemd.time.html).

## Firewall and SSH

The wizard configures `ufw` (default yes): all incoming connections are refused except
SSH, the game ports and, with a website domain, 80/443. SSH is rate-limited: an address
opening 6 or more connections within 30 seconds waits 30 seconds (scripts that open
many SSH sessions should reuse one connection). The SSH port is
read from the running SSH server and allowed before the firewall is switched on.
Docker publishes container ports with its own rules, which `ufw` does not filter;
setup therefore publishes only the game ports and 80/443 publicly and binds the
database and local website port to `127.0.0.1`.

**Personal administrator.** When setup runs as root, it offers (default yes) to
create a personal administrator account and switch root login off. It asks for the
name, runs `passwd` so you type the password yourself (hidden, typed twice, never seen
or stored by setup), adds the account to the `sudo` group and, if you agree, copies
root's SSH keys to it. It then waits for a key login by that account and for a
successful `sudo true` by it in the journal; only then is `PermitRootLogin no` written.
Running setup again checks the same proof before root stays locked. A plan file sets
this with `"admin_account": "NAME", "root_login": false` under `ssh_hardening`; the
account must already exist and have logged in with its key and used sudo.

SSH hardening always switches password logins off. When the administrator running
setup (the `sudo` user, or root) has no SSH key yet, setup prints how to create one
and copy it (`ssh-copy-id`, or a PowerShell one-liner on Windows), then waits until
the system journal shows a login **with that key**: a key file alone could be the
wrong key or have wrong permissions. An unattended (`--plan`) run without such a
login stops before changing anything. It also offers fail2ban (bans addresses that
keep failing, default yes) and an optional port change. Changing the port mostly
reduces log noise from scanners. It is done in two steps: SSH first listens on both
ports, you log in on the new port from a second terminal, and setup closes the old
port only after it sees that login. Otherwise both ports stay open. The port change is
interactive and is skipped in unattended (`--plan`) runs.

## Watchdog, crash alerts and housekeeping

Docker restarts a crashed service immediately (`unless-stopped`). Every 2 minutes a
watchdog also:

- restarts a game server that stopped answering (3 failed healthchecks in a row);
- reports a crash with its exit code and the last 40 log lines (player IP addresses
  and this server's passwords are masked);
- reports a stopped server, a Discord/GeoIP service that keeps stopping, and less than
  5 GiB free disk space (each at most every 6 hours).

A machine cannot report its own outage, so another machine (normally the external
backup server) can check it from outside: `sudo bash opencj.sh monitor --name NAME
--target game:HOST:PORT --target web:https://NAME/` installs a check every 2 minutes
(a game info query and an HTTPS request) that posts DOWN after 3 failures in a row,
repeats every 6 hours, and posts RECOVERED. `sudo opencj alerts` on the game host
prints this command with the right targets. It needs only Python, not Docker.

Any failing scheduled job (backup, off-site copy, pruning, housekeeping) is reported
too. Alerts go to a Discord webhook if you entered one (create it in a private channel
that only administrators can read:
[Discord: Intro to Webhooks](https://support.discord.com/hc/en-us/articles/228383668))
and always to the system journal
(`journalctl -u 'opencj-*'`).

Each Sunday, housekeeping removes old release images of this machine's servers once no
container uses them, Docker build cache older than a week, the APT package cache, the
migration copy 30 days after a successful migration and replaced runtime folders 30 days
after a `refresh`. It also moves the engine's game log (`games_mp.log`, with player
names, GUIDs and chat; OpenCJ never reads it) into a compressed copy in the root-only
`game-logs` folder of the installation, empties it in place, and deletes copies older
than 4 weeks.

## Change, upgrade and refresh

```sh
sudo opencj add-server         # add another server to this machine
sudo opencj configure map-test # name, public/private, slots, port, on demand, map, downloads, Discord
sudo opencj start map-test     # switch an on-demand server on; stop switches it off
sudo bash opencj.sh upgrade            # from the new release's checkout: all servers on this machine
sudo opencj refresh acceptance # replace acceptance's data with a fresh copy of main
```

`configure` refuses when generated files were edited by hand, shows each current value
as the default, restarts only that server, and updates the firewall. Making a server
private generates a new join password.

`upgrade` runs from the new release's checkout and upgrades each server in order
(database owners first). For each it takes a full database backup (in
`upgrade-backups/`), builds the new release while the old one keeps running, applies
the new database migrations, restarts and checks the server. If the new release does
not start and the database schema was not changed, it switches back to the previous
release automatically; otherwise it stops with instructions and the backup to restore.
Interrupted upgrades continue where they stopped. Servers on other machines that share
a database here must be upgraded too.

`refresh` works for servers created as a copy (for example acceptance from main). The
source pauses for about a minute for a consistent snapshot, and the refresh is refused
while players are connected to it. The copy's database, saves and checkpoint drafts
are replaced; its previous runtime folder is kept for 30 days.

## Verify, operate and recover

The installation directory contains private `installation.json`, `compose.json`,
`server.cfg`, `runtime.json`, `secrets/`, `join-password`, `rcon-password` and
persistent `runtime/`. Secret files are owner-only. Keep the join and administration
files private; setup prints their locations, not their values.

```sh
sudo opencj install --instance-dir /srv/opencj/main-eu --check
sudo opencj install --instance-dir /srv/opencj/main-eu --backup
```

`--check` verifies schema, grants, release image and the engine's actual UDP
`getstatus` healthcheck. A repeat setup on a ready instance performs these checks
without restarting it. Operator edits are preserved and reported instead of
being overwritten. Keep the installation record and generated Compose file
together; do not copy another instance's volume or project identifiers into them.

`--backup` reuses the existing backup tool, including an isolated restore check.
It saves the owning local database, configuration and checkpoint/runtime files
under `backups/`. Shared databases must be backed up from their owner. Runtime
files and the SQL snapshot are not one atomic transaction. External game/mod
assets and database user grants are not included. Manual verified backups under `backups/` are separate from the bounded scheduled
SQL backups and are not automatically pruned. Include an off-machine copy in your
recovery plan. Website configuration is included when enabled.

For explicit service operations, use the generated project:

```sh
sudo docker compose -f /srv/opencj/main-eu/compose.json ps
sudo docker compose -f /srv/opencj/main-eu/compose.json logs --tail 100 server
sudo docker compose -f /srv/opencj/main-eu/compose.json up -d --wait
```

Services restart after process/container exits and host reboots (`unless-stopped`);
the watchdog restarts hung game servers. Docker logs rotate at 10 MiB with three files
per service. Before deliberate restarts, check players and restore the previous map
according to the operator's maintenance policy.

Failed setup retains its owned data and private diagnostic files. A subsequent
run without `--config` resumes unfinished stages using the original identities.
It discards temporary failed extraction files and may reset only an owned,
unaccepted restore candidate as described above. Existing schema migration
ledger conflicts still require deliberate inspection. The external database volume survives
normal Compose teardown, including `down --volumes`.

Rerunning setup never upgrades a ready installation; use `opencj.sh upgrade` (from the new release checkout). Never
attach a newer schema to an older release just by editing the recorded version.

## Verification and remaining beta work

Run the maintained installation test with explicitly supplied licensed assets:

```sh
sudo python3 -B dev-tools/tests/run-server-setup.py --game-dir GAME_DIR --mod-dir MOD_DIR
```

It creates separate installations and synthetic databases, exercises repeated
setup, database isolation/sharing, SSH forwarding and the shipped website,
and removes its owned resources. See the [test guide](../development/testing.md).
This does not provision an actual rented VM, connect a human game client or prove
24/7 performance. Apply the [beta readiness review](../operations/beta-readiness.md)
before opening a public server.
