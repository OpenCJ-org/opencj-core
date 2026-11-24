# Running OpenCJ servers: administrator guide

This guide is for the person who looks after OpenCJ servers installed with
`opencj.sh install` ([installation guide](../setup/server.md)). It explains what runs by
itself, what you should check now and then, and how to change things. After the
first installation, every command is available as `sudo opencj <command>`.

## How it fits together

![OpenCJ server architecture: game host with main-eu, acceptance, map-test and the website behind a firewall; optional other host using the production database through an SSH tunnel; nightly backups to an off-site machine](server-architecture.svg)

- **Game servers** each run in their own containers, as their own Linux user, with
  their own database account. Players reach them through the firewall on their
  game port.
- **Databases.** main-eu owns the production database. acceptance has its own
  *copy*, refreshed on request; changes there never reach main. map-test has its own
  clean database. A server in another country *shares* main's database through an
  SSH tunnel that can reach nothing but the database port, with its own database
  account.
- **Shared assets.** One read-only copy of the game files and maps serves every
  server on the machine and the website.
- **Website.** The page generator reads only the tables the website needs, with a
  read-only account. Caddy serves the site over HTTPS (certificates from Let's
  Encrypt) and map downloads for pool maps over plain HTTP, which CoD4 needs.
  Private servers send their maps in game, only to players who joined with the
  password.
- **Discord.** The chat bridge connects one server to a public channel with a bot
  account. Alerts are separate: the scheduled jobs post them to a private channel
  through a webhook.
- **Backups** are made on the machine that owns each database and copied each night
  to the off-site machine, which can only receive new files.

## First-time setup

The [installation guide](../setup/server.md) explains every option in detail. In short:

**Before you start**

1. Rent a server with **Ubuntu 24.04 LTS (x86-64)**: at least 4 CPU cores, 8 GiB RAM
   and **120 GiB disk** (16 GiB game files and maps, Docker images, backups, and a
   temporary second copy of everything during a migration).
2. Log in with an **SSH key** as a normal user that can use `sudo` (not as root).
   Copy your key with `ssh-copy-id`; setup only disables password logins when it
   finds your key.
3. For the website, point your domain's DNS **A/AAAA record** at the server.
4. If your provider has its own firewall, allow SSH, the game ports (UDP and TCP,
   by default 28960-28962) and 80/443.
5. Optional: create the **Discord bot** for the chat bridge and a **webhook** in a
   private channel for alerts (see *Change settings* below).
6. To migrate from the old server: on the new server create a key
   (`sudo ssh-keygen -t ed25519 -f /root/migration-key`), add its `.pub` line to the
   old server account's `~/.ssh/authorized_keys` (an account with `sudo`), and save
   the old server's host key (`ssh-keyscan -p <port> <old host> | sudo tee
   /root/migration-known_hosts`; compare its fingerprint on the old server).

**Install**

```sh
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/OpenCJ-org/opencj-core.git
cd opencj-core
git checkout <release tag>
sudo bash opencj.sh install
```

The wizard asks which servers to create (suggested: `main-eu,acceptance,map-test`),
then per server: name, port, slots, public or private, where its database comes
from, map downloads, Discord, backups and pruning; then for the machine: website,
updates, firewall, SSH hardening and alerts. It shows a summary before it starts.
Building and copying can take an hour. If anything stops, run the same command
again: finished work is kept.

Start with a **rehearsal** migration (the old server keeps running) and look around
on the new servers. When you are ready to move for real, migrate again with
**cutover**, which keeps the old server stopped.

**Right after installing**

1. On the off-site machine, run the `backup-receiver` command that setup printed.
2. `sudo opencj alerts` and check that the test message arrives.
3. `sudo opencj status`: all servers `running healthy`.
4. Join each server in game (private servers: password in
   `/srv/opencj/<server>/join-password`) and open the website over HTTPS.
5. When main is ready for players: `sudo opencj configure main-eu` and answer
   **yes** to public access.

## What is where

| Path | Contents |
| --- | --- |
| `/srv/opencj/host-setup.json` | The plan for this machine: servers, firewall, SSH, updates, alert channel |
| `/srv/opencj/<server>/` | One folder per server: settings (`installation.json`), generated files, runtime files, backups |
| `/srv/opencj/<server>/join-password`, `rcon-password` | The server's join and administration passwords |
| `/srv/opencj/<server>/automatic-backups/` | Nightly database backups (the newest 7, within 2 GiB) |
| `/srv/opencj/<server>/upgrade-backups/` | Full backups taken before every upgrade and restore |
| `/srv/opencj/assets/` | Game files, maps (`game/usermaps/`) and compiled mod files, shared by all servers |
| `/srv/opencj-offsite/<server>/` | On the off-site machine: received copies of the backups |
| `/usr/local/sbin/opencj` | The `opencj` command: a link to `opencj.sh` in the checkout that installed or last upgraded |

Everything under `/srv/opencj` is readable only by root. Never share
`installation.json` or the `secrets/` folders: they contain passwords and keys.

## What happens automatically

| What | When | Where to see the result |
| --- | --- | --- |
| Crashed services start again | Immediately | `opencj status` (crash count), alert |
| Watchdog: restart a hung game server; report crashes, stopped services, low disk | Every 2 minutes | Alerts |
| Database backup, then copy to the off-site machine | Nightly 03:30 | `opencj status`, alert on failure |
| Delete unfinished runs not played for 6 months | Nightly 04:15 | `opencj status` (`last-prune.json`) |
| Ubuntu security updates | Daily 05:00 | `journalctl -u apt-daily-upgrade` |
| Reboot, only when an update needs it | 05:30 | Servers start by themselves |
| Housekeeping: old images, caches, old copies | Sundays 04:30 | `journalctl -u opencj-housekeeping` |
| Off-site retention (on the receiver) | Daily 06:00 | `journalctl -u opencj-offsite-retention` |
| IP-country data update (scoreboard flags) | Checked daily | `docker logs` of the `geoip` service |
| Website pages rebuilt, HTTPS certificate renewed | Every minute / by itself | The website |

All times are Europe/Amsterdam. Failed jobs and watchdog findings are sent to
the alert channel (see below) and always written to the system journal.

## Your routine

**Every day (a glance):** read the alert channel. No messages means nothing went
wrong. A crash alert includes the last log lines; repeated crashes of one server
need investigation (see *When something goes wrong*).

**Every week:**

```sh
sudo opencj status
```

Check that every server is `running healthy`, the last backup and off-site copy
are less than a day old, and there is enough free disk.

**Every month:**

- Test that a backup really restores, on the acceptance server (never on main):
  `sudo opencj restore acceptance /srv/opencj/main-eu/automatic-backups/<newest>.sql.gz`.
  If acceptance comes back `running healthy`, the backup works; acceptance then
  simply holds main's data from that night. A backup you have never restored is
  not proven.
- On the off-site machine, check that new files arrive:
  `ls -lt /srv/opencj-offsite/main-eu | head`.
- Look at `sudo fail2ban-client status sshd` and `sudo ufw status` once to know
  what normal looks like.

**For each new OpenCJ release:** read its release notes, then upgrade (below).

## Change settings

| You want to change | Command |
| --- | --- |
| Server name, public/private, join password, admin (rcon) password, player slots, game port, start map | `sudo opencj configure <server>` |
| Map downloads (website / in-game / off) | `sudo opencj configure <server>` |
| Discord chat bridge: bot account (token), Discord server, channel; on/off | `sudo opencj configure <server>` |
| Backups, off-site copies, run pruning, IP-country updates | `sudo opencj configure <server>` (database-owning servers) |
| Website domain, shown game address, Discord invite | `sudo opencj configure <server>` (the server with the website) |
| The Discord channel that receives alerts | `sudo opencj alerts` (sends a test message) |
| Add a server to this machine | `sudo opencj add-server` |
| Add or update a custom map | `sudo opencj maps add <folder, archive or https URL>` |
| Which maps are in a server's pool | In game, as before (the map pool lives in the database) |

`configure` shows each current value; press Enter to keep it. It restarts only
that server (players are disconnected briefly) and updates the firewall. Passwords
can be kept, generated (`new`) or typed (at least 8 characters).

**Alert channel.** Create a private Discord channel that only administrators can
read, then Channel settings > Integrations > Webhooks > New webhook > Copy URL, and
run `sudo opencj alerts`. A webhook always posts into the channel it was
created in. The chat bridge (players' chat) and alerts are separate: the bridge
uses a bot account and a public channel, alerts use the webhook and a private one.

**Discord bridge bot.** At <https://discord.com/developers/applications> create an
application, add a bot, enable *Message Content Intent*, copy its token, and invite
it to your Discord server with permission to read and send messages. For IDs,
enable Developer Mode in Discord, then right-click the server or channel > Copy ID.

## Look at a server

```sh
sudo opencj status                                              # all servers
sudo docker compose -f /srv/opencj/main-eu/compose.json ps             # one server's services
sudo docker compose -f /srv/opencj/main-eu/compose.json logs --tail 100 server
sudo journalctl -u 'opencj-*' --since today                            # jobs and alerts
sudo opencj install --instance-dir /srv/opencj/main-eu --check          # deep check
```

Use the game's own admin tools (rcon with the `rcon-password`) for in-game
administration. Do not `docker attach` to a server: Ctrl+C there stops it.

## Upgrade to a new release

```sh
cd ~/opencj-core && git fetch && git checkout <new release tag>
sudo bash opencj.sh upgrade
```

Each server is backed up first, the new release is built while the old one still
runs, then each server restarts on the new release (a short interruption). If a
server does not come back and the database was not changed, it returns to the old
release by itself. Otherwise the command stops and names the backup to restore.
Rerun the same command after fixing a problem; it continues where it stopped.
Upgrade the machine that owns a shared database before machines that use it.

## Restore a backup

```sh
sudo opencj restore main-eu /srv/opencj/main-eu/automatic-backups/<file>.sql.gz
```

Everything played after that backup is lost, so only restore after real data loss
or damage. The command first saves the current data in `upgrade-backups/`
(`before-restore-…`), so a restore can itself be undone. To restore from the
off-site machine, copy the file back first, for example
`scp offsite:/srv/opencj-offsite/main-eu/<file>.sql.gz /tmp/`.

## Refresh acceptance from main

```sh
sudo opencj refresh acceptance
```

Main pauses for about a minute (refused while players are connected). Acceptance's
database, saves and checkpoint drafts are replaced by main's current state.

## When something goes wrong

| Symptom | What to do |
| --- | --- |
| Crash alert, once | Nothing; the server restarted. Keep the log lines if you report a bug. |
| Crash alerts repeating | `logs --tail 200 server` (above); roll back with `restore`/`upgrade` only if a recent change caused it. |
| "keeps stopping: discord" | Wrong or reset bot token, or the bot was removed: `configure <server>` > Discord bridge. |
| "keeps stopping: geoip" | Usually a temporary download problem; it retries. Persisting for days: check `docker logs`. |
| Backup or off-site copy failed | `journalctl -u '<project>-backup' -n 50`. Off-site: is the receiver machine up, and did you run its `backup-receiver` command? |
| Off-site log says "Host key ... has changed" | Uploads stop when the receiver's SSH identity changes (reinstalled, or someone in between). Check the receiver's fingerprint on that machine (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`), then `configure <server>` > backups > off-site, and accept it only if both match. |
| Low disk space | `sudo du -sh /srv/opencj/*`; large culprits are maps and backups. Housekeeping runs on Sundays. |
| Website has no HTTPS | The domain's DNS must point at this server and ports 80/443 must be reachable; Caddy retries by itself. |
| Setup or a command stopped | Read `/srv/opencj/<server>/failure.txt`, fix the cause, run the same command again. |
| Cannot reach SSH | Use your hosting provider's web console. Check `ufw status`; if you moved the SSH port, use `ssh -p <port>`. Your address may be banned for an hour by fail2ban after repeated failed logins. |

## Security habits

- Log in with an SSH key; keep its passphrase. Setup disables passwords only when
  your key is installed.
- Give the join password only to people who should play on a private server; change
  it with `configure` when someone should lose access.
- Keep the alert channel private: logs are masked, but they still describe your
  servers.
- Upgrade when a release is published; Ubuntu security updates install themselves.
