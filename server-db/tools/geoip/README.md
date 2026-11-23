# Country database updater

DB-IP Country Lite is the default. It requires no vendor account or download key.
Only public database files are downloaded; player IP addresses stay on the game
server. Data is supplied by [DB-IP](https://db-ip.com/db/lite.php), under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The scoreboard and
client archive retain attribution. Country lookup is an approximate IP-based
location, not proof of nationality or physical location.

Automatic updates are opt-in. Use the manual import procedure below unless
you deliberately enable the separate background updater.

## Install on a new host

Use `server-db/` and `dev-tools/` inside the same core checkout. Supply MySQL 8.0
and a Docker network reachable by the updater. It does not create the game DB.
Start with [database setup/upgrades](../../../docs/operations/database.md).

Run the commands below from `dev-tools` with the intended installation's Compose
variables selected. Resolve its database and choose a separate updater project:

```sh
DB_CONTAINER="$(docker compose ps --status running --quiet db)"
GEOIP_PROJECT=opencj-geoip
```

Check that `DB_CONTAINER` names exactly one intended container. Keep
`GEOIP_PROJECT` set for every updater command; choose a different name when
running another installation. The explicit `-p` below prevents an exported
core `COMPOSE_PROJECT_NAME` from merging updater and gameplay resources.

1. Stop gameplay writers, take and verify a private database backup, and apply
   all pending migrations with the tracked runner (025 introduces GeoIP):

       python3 ../server-db/tools/migrate.py apply --container "$DB_CONTAINER" --confirm-database openCJ_cod4

2. Provision a dedicated account and an ignored, mode-0600 secret file:

       python3 ../server-db/tools/geoip/provision.py --container "$DB_CONTAINER" --confirm-database openCJ_cod4 --secret-file ./local/geoip/password

   Run from dev-tools. For another DB/container use --container and --database,
   and match --confirm-database. Set --gameplay-account when its name differs.
   This administrative helper uses the existing database container's root
   authentication without printing it. It grants the updater only SELECT,
   INSERT, UPDATE and DELETE on geoIPReleases, geoIPRanges and geoIPState.
   It grants gameplay EXECUTE on the two country functions. No player-table
   access, schema DDL or database-wide updater grant is needed.

3. Configure non-secret deployment settings through environment variables:
   GEOIP_NETWORK, GEOIP_DB_HOST, GEOIP_DB_PORT, GEOIP_DB_NAME, GEOIP_DB_USER,
   GEOIP_PASSWORD_FILE and DEV_UID/DEV_GID. Defaults target the default OpenCJ development network. Set
   `GEOIP_NETWORK` explicitly for a custom Compose project; it must be the
   selected database's network. The container user must be able to read the
   mounted 0600 file. A remote MySQL service needs equivalent least-privilege
   account provisioning; never pass its password as a command argument.

4. Build the image and import once, without enabling automatic updates:

       docker compose -p "$GEOIP_PROJECT" -f compose.geoip.yaml build updater
       docker compose -p "$GEOIP_PROJECT" -f compose.geoip.yaml run --rm --no-deps updater --minimum-ranges 50000

   The explicit argument makes the import one-shot. It exits without leaving a
   background job running. This project never starts or restarts the game or
   database service.

## Optional: enable automatic updates

Only on the host where you deliberately want automatic updates, run from dev-tools:

    docker compose -p "$GEOIP_PROJECT" -f compose.geoip.yaml up -d --no-deps updater

This starts the background mode (--daemon) and enables restart after a reboot.
Inspect logs with docker compose -p "$GEOIP_PROJECT" -f compose.geoip.yaml logs --tail=20 updater.
To disable it again, use docker compose -p "$GEOIP_PROJECT" -f compose.geoip.yaml down. This removes
only the updater project; it keeps imported country data and the password file.
No recurring job is needed for manual imports.

## Updates and failure behavior

The daemon checks daily, retries failures after six hours, and tries the current
UTC month followed by the previous two months when a release returns HTTP 404.
Source and dependency versions are pinned in Dockerfile/requirements.txt.
Database releases themselves follow DB-IP's monthly publication.

Each download is parsed completely before publication. It validates addresses,
country codes, range ordering/non-overlap, minimum size, and bounded row/download
counts. IPv6 rows are validated then ignored: this game integration uses IPv4.
A release older than the active dataset or a drop exceeding 25% in ranges or
address coverage is rejected. An explicit --allow-older permits a planned older
import; it does not bypass the shrink check. A database-scoped advisory lock
prevents concurrent publishers.

A transaction inserts the validated dataset and switches its active pointer.
Readers see a complete old or new release. A failed transaction publishes no
partial ranges. The current and immediately previous releases are retained.
Identical provider/version/checksum imports are no-ops. Legacy geoIP and
longCountry tables are retained for compatibility; they are no longer the
active range source. An absent/gapped/unknown range never defaults to the UK.

Offline DB-IP imports use --input /data/country.csv.gz --month YYYY-MM, with the
public file bind-mounted read-only into the one-shot container. Existing
GeoLite CSV exports remain supported using --geolite-directory /data/geolite
--month YYYY-MM. Supply GeoLite2-Country-Locations-en.csv and
GeoLite2-Country-Blocks-IPv4.csv; retain MaxMind's applicable license/attribution
if you switch providers. No MaxMind downloading or credentials are configured.

## Secrets and publication

The development secret is dev-tools/local/geoip/password: ignored by Git,
mode 0600, mounted read-only through a Compose secret. Its value is absent from
Compose environment variables, image layers, source, client assets and reports.
Docker Compose secrets here are ordinary protected host files, not an encrypted
secret vault. Protect private backups and host access accordingly.

Do not add local/, .env, database dumps or secret files to Git or support bundles.
The Docker context whitelist contains only Dockerfile, requirements.txt and
update.py. provision.py checks Git exclusion and refuses to silently reset an
existing account whose local secret is missing. Existing updater accounts with table DDL
or transferable grants are refused; provisioning does not silently revoke them. To move hosts, provision a new
restricted account/secret there; do not put passwords in deployment manifests.

## Verification

Run the portable `database-client-unit` and `geoip-unit` groups from the
workspace root. They cover pipe cleanup, provider parsing, input validation and
private secret handling without a database.
The real MySQL fixture is python3 -B dev-tools/tests/run-geoip-database.py;
it creates and removes its own temporary schema/account/secret and checks exact
range boundaries, gaps, atomic failure, retention and restricted privileges.
It requires an updater image and the selected Compose test database.
See the [test guide](../../../docs/development/testing.md) for image construction,
`--image` and separate-installation requirements.
