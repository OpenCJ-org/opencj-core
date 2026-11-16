# Integrated country flags

Country lookup runs once after successful login. Downloading/unauthenticated
clients produce no connection announcement or lookup. Login announces exactly
Player <name> connected, without a country in chat. Repeated login events on the
same connection do not repeat it. A new connection resets this state.

server-gsc/opencj/country.gsc calls the indexed geoIPLookupCode SQL function.
The scoreboard resolves country codes through generated flagatlas.gsc, sending
one of eight atlas materials plus a cell selector. Unknown/unmapped countries
use the existing default material (the approved question-mark artwork), including
connecting rows. There is no invented GB/UK fallback.

Failures produce one OpenCJ GeoIP log entry containing entity slot, player ID
and a reason, without raw IP or SQL. Reasons include missing_address,
unsupported_ip_family, query_unavailable, query_failed (status and numeric MySQL
code), empty_query_result, invalid_ip, non_public_ip, database_unavailable,
range_not_found, country_not_reported and unsupported_country_code. Login is
not blocked by a failed lookup. The DB query has a five-second deadline.

Setup and maintenance: [updater](../../server-db/tools/geoip/README.md) and
[flag pipeline](../../client-mod/assets/flags/README.md).

## Resource validation, 14 November 2026

The deployed baseline contained 257 separate flag material/image pairs. The
new catalogue uses eight pairs, saving 249 slots in each pool. Total mod
inventory changes from 368 materials / 364 images to 119 / 115. Existing default
is already present and costs no additional slot.

The static survey parsed all 868 installed usermap fastfiles across 458 map
folders, with no parser failures. It conservatively included five stock global
zones, including ui_mp, and summed all nested assets without deduplicating names.
Against the researched pools (2048 materials, 2400 images), the highest totals
were on mp_ultimate: 1772 materials and 2177 images, leaving 276 and 223 slots.
mp_marketcenter followed at 1701 / 2067. mp_sierra was not installed and is not
covered by this result. New maps/assets or a different client build require a
fresh check. These inventories do not measure renderer VRAM or guarantee every
future map; total texture payload is 42.67 MiB plus runtime overhead.

Focused checks:

    python3 -B tests/run-geoip-smoke.py --asset-dir /path/to/assets --scripts /path/to/release mp_blue2
    python3 -B tests/run-geoip-database.py

Follow the existing native-script and client-asset deployment runbooks: capture
players/map, restart only if empty or operator alone, apply migration after a
verified private backup, install matching Windows/server assets, fully restart
the game server, restore its map and verify the advertised mod fastfile size.
