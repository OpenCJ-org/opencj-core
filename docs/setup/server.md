# Install an OpenCJ server

The first release target is **beta-0.1.0**. `VERSION` identifies the source release;
each installation records its core revision, pinned engine revision, image ID and
migration state. A release name in source does not mean its Git tag or compiled
assets have already been published.

The supported host is **Ubuntu 24.04 LTS, x86-64**, with root access or an account
that can install prerequisites and use Docker. ARM and CoD2 are not supported by
this installer. The existing development helper remains available for source
work; this installer creates separate operational instances.

## One entry point

Run as root on a fresh host (or use `sudo bash setup.sh`). From a reviewed
checkout of the intended release:

```sh
bash setup.sh
```

The same `setup.sh` can be downloaded from a published release and run standalone.
It then clones the exact `beta-0.1.0` tag into `/opt/opencj/releases/beta-0.1.0`;
it refuses to overwrite an existing source directory or fall back to `main`.
Until that tag exists, use the reviewed checkout. Do not pipe an unreviewed
network response directly into a root shell.

The entry point uses the existing host prerequisite helper. On an empty supported
host it installs Git, Python and Docker Engine/Compose from the official Docker
Ubuntu repository. Existing Docker installations are preserved; if their Compose
plugin or account access is missing, setup stops with an explicit instruction.
No firewall, SSH daemon or unrelated host service is reconfigured.

Setup asks for:

- An installation directory and instance name, such as `main`, `acceptance` or
  `maptesting`. Choose a different directory for every instance.
- Display name, game port, bind address, starting map and slots (default **32**).
- Public access (default **no**). Private instances use LAN/unlisted mode and a
  generated join password; public instances allow password-free access and listing.
- Licensed game assets and matching compiled OpenCJ assets.
- A new independent database, another local instance's database, or an existing
  database reached through SSH or an already-secured private network.
- Whether to run the OpenCJ website (default **no**).

For unattended setup, supply the same answers in a private JSON file:

```sh
bash setup.sh --instance-dir /srv/opencj/main --config /root/main-answers.json
```

The minimal structure is:

```json
{
  "name": "main",
  "game_assets": "/srv/assets/cod4",
  "mod_assets": "/srv/assets/opencj-beta-0.1.0",
  "port": 28960,
  "bind_ip": "0.0.0.0",
  "public": false,
  "database": {"mode": "new", "name": "openCJ_cod4", "publish_port": 3306}
}
```

Optional `slots`, `map` and `hostname` use the interactive defaults. Treat answer
files as secrets when they contain existing database access, and keep them outside
Git. A repeat invocation takes only `--instance-dir`; new answers cannot silently
replace an installation.

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
into the instance, rejecting links, special files and escaping paths. Downloads
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
be ready on the same release and to own its local database. It copies only the
restricted gameplay connection and joins that database's Docker network; it
never copies its root password or creates a second database volume.

Use independent databases for acceptance and maptesting when their changes must
not affect main. Sharing means sharing player progress, records and checkpoint
layouts, not just sharing an SQL process.

### Connect from another machine

Choose `mode: existing`, enter the database name and restricted gameplay account,
and select `ssh` or `private` transport.

With `ssh`, also supply an SSH endpoint/user, private-key file and **verified
known_hosts file**. Setup pins that host key and runs a separate SSH forwarding
container. The database host/port is interpreted from the SSH server, commonly
`127.0.0.1` and the owning instance's published loopback port. The key must permit
unattended forwarding, with no interactive passphrase prompt. Verify the host key
through a trusted channel; the installer does not automatically trust `ssh-keyscan`.
It reconnects the tunnel after failure without exposing its local forwarding
port on the host.

Use `private` only for an already-secured private network/VPN. The current native
SQL adapter does not configure verified TLS identity through installer settings;
do not present a public, opportunistically encrypted MySQL endpoint as equivalent
to the pinned SSH path. The setup connection uses the same transport as gameplay.

Joining checks the MySQL version, complete migration ledger and the complete
reviewed runtime grant policy. Use a dedicated gameplay account; broad grants,
roles, privileges on unrelated schemas and missing required permissions are refused.
It **never bootstraps, migrates or changes grants** on that shared database.
Use the owning installation for planned schema upgrades, coordinating all writers.
The supported database version for this beta is MySQL 8.0, matching the tested
runtime; MariaDB and other major versions are not claimed compatible.

## First administrator

A fresh database deliberately gives no privileges to the first player who joins.
After joining privately and identifying your account, use the database owner's
administration console to inspect `playerInformation` / `playerDisplayNames` and
set that verified player's `adminLevel` to 100. Reconnect to reload permissions.
Do not grant a role based merely on arrival order or an assumed player ID.
The existing role levels are editor 20, moderator 40, admin 60 and uber-admin 100.

The owner can open the SQL console without putting its password in command arguments:

```sh
docker compose -f /srv/opencj/main/compose.json exec db sh -c \
  'MYSQL_PWD="$(cat "$MYSQL_ROOT_PASSWORD_FILE")" exec mysql -u root "$MYSQL_DATABASE"'
```

Checkpoint editing is disabled in the generated server configuration by default.
Enable it deliberately for an editing instance and retain the existing role checks.
A separate maptesting database avoids publishing experimental layouts into main.

## Optional website

Supply Claude's self-contained website Compose file with `website_compose`, or
answer yes and give its path. Follow that project's README first to supply its
own environment, access tool, ports, domains and certificates. The installer
neither uses `server-web` nor invents an application-specific environment contract.

The website runs as a separate `<instance-project>-web` Compose project. Its
services must use project-scoped names, and volumes must be managed by that
project. Fixed `container_name` and external volumes are refused. The website
project owns application migrations and permissions; OpenCJ setup does not hand
it the gameplay database root account. Include healthchecks so Compose can
verify application readiness. Website containers with no healthcheck are only
verified to have started.

The installer can validate a supplied project's startup. Actual website behavior
must be checked against Claude's delivered project; a synthetic integration
fixture is not acceptance of that application. If the project is not available,
choose no. A future website deployment should use its README and a separate
project rather than rewriting an existing game installation's configuration.

## Verify, operate and recover

The installation directory contains private `installation.json`, `compose.json`,
`server.cfg`, `runtime.json`, `secrets/`, `join-password`, `rcon-password` and
persistent `runtime/`. Secret files are owner-only. Keep the join and administration
files private; setup prints their locations, not their values.

```sh
bash setup.sh --instance-dir /srv/opencj/main --check
bash setup.sh --instance-dir /srv/opencj/main --backup
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
assets and database user grants are not included. Keep an off-machine copy and
choose a backup schedule/retention policy for the deployment; setup does not
install a host cron job or delete old backups automatically.

For explicit service operations, use the generated project:

```sh
docker compose -f /srv/opencj/main/compose.json ps
docker compose -f /srv/opencj/main/compose.json logs --tail 100 server
docker compose -f /srv/opencj/main/compose.json up -d --wait
```

Services restart after process/container exits and host reboots (`unless-stopped`).
An unhealthy status alone does not restart a hung process; monitor and alert on
it. Docker logs rotate at 10 MiB with three files per service. Monitor persistent
runtime files and database/backups disk usage separately. Before deliberate
restarts, check players and restore the previous map according to the operator's
maintenance policy.

Failed setup retains its owned data and private diagnostic files. A subsequent
run without `--config` resumes unfinished stages using the original identities.
It discards temporary failed extraction files, not database contents. An interrupted
migration remains blocked for deliberate inspection/restore; never erase it or
replay it merely to make setup proceed. The external database volume survives
normal Compose teardown, including `down --volumes`.

This command does not upgrade a ready installation to a different release.
Back up, stop all writers, follow the [migration procedure](../operations/database.md),
and deploy matching source/native/client versions deliberately. Never attach a
newer schema to an older release just by editing the recorded version.

## Verification and remaining beta work

Run the maintained installation test with explicitly supplied licensed assets:

```sh
python3 -B dev-tools/tests/run-server-setup.py --game-dir GAME_DIR --mod-dir MOD_DIR
```

It creates separate installations and synthetic databases, exercises repeated
setup, database isolation/sharing, SSH forwarding and an optional fixture website,
and removes its owned resources. See the [test guide](../development/testing.md).
This does not provision an actual rented VM, connect a human game client or prove
24/7 performance. Apply the [beta readiness review](../operations/beta-readiness.md)
before opening a public server.
