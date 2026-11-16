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

## Verification

From dev-tools, run `python3 -B tests/run-geoip-database.py` for synthetic database
checks. The engine fixture needs matching compiled assets and scripts:

```sh
python3 -B tests/run-geoip-smoke.py --asset-dir /path/to/assets --scripts /path/to/release mp_killhouse
```

Asset-pool and renderer limits depend on the installed map and client assets.
Recheck those limits when adding maps. Keep deployment records and inventories
under ignored local storage. Follow the native/script and client-asset runbooks.
