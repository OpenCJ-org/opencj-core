"""Portable country database updater. Download locally; never send player IPs upstream."""

from __future__ import annotations
from contextlib import closing
import argparse
import csv
import datetime as dt
import gzip
import hashlib
import ipaddress
import json
import logging
import os
import re
import sqlite3
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

LOG = logging.getLogger("opencj.geoip")

DEFAULT_MINIMUM_IPV4_RANGES = 50_000
MAX_IPV4_RANGES = 2_000_000
MAX_CSV_ROWS = 5_000_000
IO_CHUNK_BYTES = 1024 * 1024
MAX_DOWNLOAD_BYTES = 64 * 1024 * 1024
DOWNLOAD_TIMEOUT_SECONDS = 30
CONNECT_TIMEOUT_SECONDS = 15
DATABASE_TIMEOUT_SECONDS = 120
INSERT_BATCH_SIZE = 1000
MIN_RETAINED_DATA_FRACTION = 0.75
RECENT_MONTH_ATTEMPTS = 3
SUCCESS_INTERVAL_SECONDS = 86_400
FAILURE_RETRY_SECONDS = 21_600


def _hash_files(paths):
    """Hash provider inputs in their defined order, without loading them into memory."""
    source_hash = hashlib.sha256()
    for path in paths:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(IO_CHUNK_BYTES), b""):
                source_hash.update(block)
    return source_hash.hexdigest()


def _geolite_ranges(source_directory):
    """Read located IPv4 blocks; registered countries do not describe visitor location."""
    locations_path = source_directory / "GeoLite2-Country-Locations-en.csv"
    blocks_path = source_directory / "GeoLite2-Country-Blocks-IPv4.csv"
    with locations_path.open(encoding="utf-8-sig", newline="") as stream:
        country_by_geoname = {
            row["geoname_id"]: row["country_iso_code"] for row in csv.DictReader(stream)
        }
    with blocks_path.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            network = ipaddress.ip_network(row["network"])
            if network.version != 4:
                raise ValueError("IPv6 in IPv4 GeoLite input")
            country_code = country_by_geoname.get(row["geoname_id"]) or "XX"
            yield str(network.network_address), str(network.broadcast_address), country_code


def _dbip_ranges(source_path):
    """Stream the three provider columns while enforcing the input row budget."""
    with gzip.open(source_path, "rt", encoding="utf-8-sig", newline="") as stream:
        for row_number, row in enumerate(csv.reader(stream), 1):
            if row_number > MAX_CSV_ROWS:
                raise ValueError("CSV row budget exceeded")
            if len(row) != 3:
                raise ValueError("expected DB-IP start,end,country columns")
            yield row


def _store_ipv4_range(validated_ranges, start, end, country):
    """Validate every row, including IPv6 rows that are excluded from this IPv4 cache."""
    start_address = ipaddress.ip_address(start)
    end_address = ipaddress.ip_address(end)
    if start_address.version != end_address.version or int(start_address) > int(end_address):
        raise ValueError("invalid IP range")
    country_code = country.strip().upper()
    if not re.fullmatch("[A-Z]{2}", country_code):
        raise ValueError("invalid country code")
    if start_address.version != 4:
        return False
    validated_ranges.execute(
        "INSERT INTO ranges VALUES(?,?,?)",
        (int(start_address), int(end_address), country_code),
    )
    return True


def _summarize_ranges(validated_ranges):
    """Reject overlaps before calculating the complete dataset's coverage."""
    previous_end = -1
    address_count = 0
    country_codes = set()
    for start, end, country_code in validated_ranges.execute(
        "SELECT start, end, country FROM ranges ORDER BY start"
    ):
        if start <= previous_end:
            raise ValueError("overlapping IPv4 ranges")
        previous_end = end
        address_count += end - start + 1
        country_codes.add(country_code)
    return address_count, sorted(country_codes)


def prepare(source: Path, scratch: Path, geolite=False, minimum=DEFAULT_MINIMUM_IPV4_RANGES):
    """Validate into SQLite before any publication; the caller closes the returned cache."""
    validated_ranges = sqlite3.connect(scratch)
    try:
        validated_ranges.execute(
            "CREATE TABLE ranges(start INTEGER PRIMARY KEY,end INTEGER,country TEXT)"
        )
        if geolite:
            source_files = [
                source / "GeoLite2-Country-Locations-en.csv",
                source / "GeoLite2-Country-Blocks-IPv4.csv",
            ]
            provider_rows = _geolite_ranges(source)
        else:
            source_files = [source]
            provider_rows = _dbip_ranges(source)
        source_sha256 = _hash_files(source_files)
        range_count = 0
        with closing(provider_rows) as rows:
            for start, end, country_code in rows:
                if _store_ipv4_range(validated_ranges, start, end, country_code):
                    range_count += 1
                    if range_count > MAX_IPV4_RANGES:
                        raise ValueError("IPv4 row budget exceeded")
        if range_count < minimum:
            raise ValueError("dataset has too few IPv4 ranges")
        address_count, country_codes = _summarize_ranges(validated_ranges)
        validated_ranges.commit()
        return validated_ranges, {
            "ranges": range_count,
            "addresses": address_count,
            "countries": country_codes,
            "sha256": source_sha256,
        }
    except BaseException:
        validated_ranges.close()
        raise


def download(target: Path, month: str):
    """Stream one monthly archive with bounded size and network waits."""
    if not re.fullmatch(r"\d{4}-\d{2}", month):
        raise ValueError("invalid dataset month")
    dt.date.fromisoformat(month + "-01")
    url = f"https://download.db-ip.com/free/dbip-country-lite-{month}.csv.gz"
    request = urllib.request.Request(url, headers={"User-Agent": "OpenCJ-country-updater/1.0"})
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT_SECONDS) as response, target.open(
        "wb"
    ) as output_file:
        if not response.url.startswith("https://"):
            raise ValueError("insecure download redirect")
        downloaded_bytes = 0
        while block := response.read(IO_CHUNK_BYTES):
            downloaded_bytes += len(block)
            if downloaded_bytes > MAX_DOWNLOAD_BYTES:
                raise ValueError("compressed download budget exceeded")
            output_file.write(block)
    return url


def connect():
    """Open the updater account with the installation's private credential file."""
    import pymysql

    password = Path(os.environ["GEOIP_DB_PASSWORD_FILE"]).read_text().strip()
    return pymysql.connect(
        host=os.environ.get("GEOIP_DB_HOST", "db"),
        port=int(os.environ.get("GEOIP_DB_PORT", "3306")),
        user=os.environ.get("GEOIP_DB_USER", "geoip_updater"),
        password=password,
        database=os.environ.get("GEOIP_DB_NAME", "openCJ_cod4"),
        charset="ascii",
        autocommit=False,
        connect_timeout=CONNECT_TIMEOUT_SECONDS,
        read_timeout=DATABASE_TIMEOUT_SECONDS,
        write_timeout=DATABASE_TIMEOUT_SECONDS,
    )


def _import_release(cursor, validated_ranges, metadata, provider, version):
    """Reuse a retained release or insert its ranges into the caller's transaction."""
    cursor.execute(
        "SELECT releaseID, rangeCount, addressCount"
        " FROM geoIPReleases"
        " WHERE provider=%s AND datasetVersion=%s AND sha256=%s",
        (provider, version, metadata["sha256"]),
    )
    retained_release = cursor.fetchone()
    if retained_release:
        release_id, range_count, address_count = retained_release
        if (range_count, address_count) != (metadata["ranges"], metadata["addresses"]):
            raise ValueError("retained dataset metadata mismatch")
        return release_id

    cursor.execute(
        "INSERT INTO geoIPReleases(provider,datasetVersion,sha256,rangeCount,addressCount)"
        " VALUES(%s,%s,%s,%s,%s)",
        (provider, version, metadata["sha256"], metadata["ranges"], metadata["addresses"]),
    )
    release_id = cursor.lastrowid
    batch = []
    for start, end, country_code in validated_ranges.execute(
        "SELECT start, end, country FROM ranges ORDER BY start"
    ):
        batch.append((release_id, start, end, country_code))
        if len(batch) == INSERT_BATCH_SIZE:
            cursor.executemany("INSERT INTO geoIPRanges VALUES(%s,%s,%s,%s)", batch)
            batch = []
    if batch:
        cursor.executemany("INSERT INTO geoIPRanges VALUES(%s,%s,%s,%s)", batch)
    return release_id


def publish(database_connection, validated_ranges, metadata, provider, version, allow_older=False):
    """Publish ranges and their active pointer atomically, retaining the previous release."""
    with database_connection.cursor() as cursor:
        cursor.execute("SELECT GET_LOCK(CONCAT('opencj:geoip:',DATABASE()),0)")
        if cursor.fetchone()[0] != 1:
            raise RuntimeError("another GeoIP updater holds the lock")
        try:
            # Read the active release only after taking the publication lock.
            cursor.execute(
                "SELECT r.releaseID, r.provider, r.datasetVersion, r.sha256,"
                " r.rangeCount, r.addressCount"
                " FROM geoIPState s"
                " LEFT JOIN geoIPReleases r ON r.releaseID=s.activeReleaseID"
                " WHERE s.singleton=1"
            )
            active_release = cursor.fetchone()
            if active_release is None:
                raise RuntimeError("GeoIP schema migration is missing")
            (
                active_release_id,
                active_provider,
                active_version,
                active_sha256,
                active_range_count,
                active_address_count,
            ) = active_release
            active_identity = (active_provider, active_version, active_sha256)
            if active_release_id and active_identity == (provider, version, metadata["sha256"]):
                database_connection.rollback()
                return {"changed": False, "release": active_release_id}
            if active_release_id:
                if not allow_older and active_provider == provider and version < active_version:
                    raise ValueError("refusing an older dataset")
                ranges_shrank = metadata["ranges"] < active_range_count * MIN_RETAINED_DATA_FRACTION
                coverage_shrank = (
                    metadata["addresses"] < active_address_count * MIN_RETAINED_DATA_FRACTION
                )
                if ranges_shrank or coverage_shrank:
                    raise ValueError("unexpected dataset shrink; active data retained")

            release_id = _import_release(cursor, validated_ranges, metadata, provider, version)
            cursor.execute("SELECT COUNT(*) FROM geoIPRanges WHERE releaseID=%s", (release_id,))
            imported_range_count = cursor.fetchone()[0]
            if imported_range_count != metadata["ranges"]:
                raise ValueError("imported range count mismatch")
            cursor.execute(
                "UPDATE geoIPState SET activeReleaseID=%s WHERE singleton=1", (release_id,)
            )
            cursor.execute(
                "DELETE FROM geoIPReleases WHERE releaseID NOT IN (%s,%s)",
                (release_id, active_release_id or release_id),
            )
            database_connection.commit()
            return {"changed": True, "release": release_id}
        except BaseException:
            database_connection.rollback()
            raise
        finally:
            cursor.execute("SELECT RELEASE_LOCK(CONCAT('opencj:geoip:',DATABASE()))")
            cursor.fetchone()


def recent_months():
    date = dt.datetime.now(dt.timezone.utc).date().replace(day=1)
    for _ in range(RECENT_MONTH_ATTEMPTS):
        yield date.strftime("%Y-%m")
        date = (date - dt.timedelta(days=1)).replace(day=1)


def _select_source(args, work):
    """Choose local input or the newest available monthly download."""
    if args.geolite_directory:
        if not args.month:
            raise ValueError("--month required for GeoLite import")
        source = args.geolite_directory
        version = args.month
        provider = "maxmind-geolite"
    elif args.input:
        if not args.month:
            raise ValueError("--month required for a local DB-IP file")
        source = args.input
        version = args.month
        provider = "dbip-lite"
    else:
        source = work / "country.csv.gz"
        provider = "dbip-lite"
        for version in ([args.month] if args.month else recent_months()):
            try:
                download(source, version)
                break
            except urllib.error.HTTPError as error:
                if error.code != 404:
                    raise
        else:
            raise RuntimeError("no recent DB-IP country download is available")
    if not re.fullmatch(r"\d{4}-\d{2}", version):
        raise ValueError("invalid dataset month")
    return source, provider, version


def run(args):
    """Own temporary input and connections through validation, publication and reporting."""
    with tempfile.TemporaryDirectory(prefix="opencj-geoip-") as temporary:
        work = Path(temporary)
        source, provider, version = _select_source(args, work)
        validated_ranges, metadata = prepare(
            source,
            work / "validated.sqlite",
            geolite=bool(args.geolite_directory),
            minimum=args.minimum_ranges,
        )
        try:
            if args.validate_only:
                result = {"validated": True}
            else:
                database_connection = connect()
                try:
                    result = publish(
                        database_connection,
                        validated_ranges,
                        metadata,
                        provider,
                        version,
                        args.allow_older,
                    )
                finally:
                    database_connection.close()
            LOG.info(
                json.dumps(
                    {
                        "provider": provider,
                        "version": version,
                        "ranges": metadata["ranges"],
                        "addresses": metadata["addresses"],
                        **result,
                    },
                    sort_keys=True,
                )
            )
        finally:
            validated_ranges.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--input", type=Path, help="Existing DB-IP CSV.gz")
    inputs.add_argument("--geolite-directory", type=Path)
    parser.add_argument("--month")
    parser.add_argument("--minimum-ranges", type=int, default=DEFAULT_MINIMUM_IPV4_RANGES)
    parser.add_argument("--validate-only", action="store_true")
    parser.add_argument("--allow-older", action="store_true")
    parser.add_argument("--daemon", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
    if args.daemon and (
        args.input or args.geolite_directory or args.month or args.validate_only or args.allow_older
    ):
        parser.error("daemon mode follows the current DB-IP monthly release only")
    while True:
        try:
            run(args)
            delay_seconds = SUCCESS_INTERVAL_SECONDS
        except Exception as error:
            detail = type(error).__name__
            if isinstance(error, (ValueError, RuntimeError)):
                detail += " / " + str(error)
            elif isinstance(error, urllib.error.HTTPError):
                detail += " / HTTP " + str(error.code)
            elif error.args and isinstance(error.args[0], int):
                detail += " / code " + str(error.args[0])
            LOG.error("Update failed (%s); no partial dataset is published", detail)
            if not args.daemon:
                raise SystemExit(1)
            delay_seconds = FAILURE_RETRY_SECONDS
        if not args.daemon:
            return
        time.sleep(delay_seconds)


if __name__ == "__main__":
    main()
