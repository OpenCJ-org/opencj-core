"""Portable country database updater. Download locally; never send player IPs upstream."""

from __future__ import annotations
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


def prepare(source: Path, scratch: Path, geolite=False, minimum=50000):
    """Validate completely before opening a database write transaction."""
    cache = sqlite3.connect(scratch)
    cache.execute("CREATE TABLE ranges(start INTEGER PRIMARY KEY,end INTEGER,country TEXT)")
    count = 0
    source_hash = hashlib.sha256()

    def digest(path):
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                source_hash.update(block)

    def add(start, end, country):
        nonlocal count
        a = ipaddress.ip_address(start)
        b = ipaddress.ip_address(end)
        if a.version != b.version or int(a) > int(b):
            raise ValueError("invalid IP range")
        country = country.strip().upper()
        if not re.fullmatch("[A-Z]{2}", country):
            raise ValueError("invalid country code")
        if a.version != 4:
            return
        cache.execute("INSERT INTO ranges VALUES(?,?,?)", (int(a), int(b), country))
        count += 1
        if count > 2000000:
            raise ValueError("IPv4 row budget exceeded")

    try:
        if geolite:
            locations = source / "GeoLite2-Country-Locations-en.csv"
            blocks = source / "GeoLite2-Country-Blocks-IPv4.csv"
            digest(locations)
            digest(blocks)
            with locations.open(encoding="utf-8-sig", newline="") as stream:
                by_id = {
                    row["geoname_id"]: row["country_iso_code"] for row in csv.DictReader(stream)
                }
            with blocks.open(encoding="utf-8-sig", newline="") as stream:
                for row in csv.DictReader(stream):
                    network = ipaddress.ip_network(row["network"])
                    if network.version != 4:
                        raise ValueError("IPv6 in IPv4 GeoLite input")
                    # Registered/represented country is not the visitor's location.
                    code = by_id.get(row["geoname_id"]) or "XX"
                    add(str(network.network_address), str(network.broadcast_address), code)
        else:
            digest(source)
            with gzip.open(source, "rt", encoding="utf-8-sig", newline="") as stream:
                for row_number, row in enumerate(csv.reader(stream), 1):
                    if row_number > 5000000:
                        raise ValueError("CSV row budget exceeded")
                    if len(row) != 3:
                        raise ValueError("expected DB-IP start,end,country columns")
                    add(*row)
        if count < minimum:
            raise ValueError("dataset has too few IPv4 ranges")
        previous = -1
        coverage = 0
        countries = set()
        for start, end, country in cache.execute("SELECT * FROM ranges ORDER BY start"):
            if start <= previous:
                raise ValueError("overlapping IPv4 ranges")
            previous = end
            coverage += end - start + 1
            countries.add(country)
        cache.commit()
        return cache, {
            "ranges": count,
            "addresses": coverage,
            "countries": sorted(countries),
            "sha256": source_hash.hexdigest(),
        }
    except BaseException:
        cache.close()
        raise


def download(target: Path, month: str):
    if not re.fullmatch(r"\d{4}-\d{2}", month):
        raise ValueError("invalid dataset month")
    dt.date.fromisoformat(month + "-01")
    url = f"https://download.db-ip.com/free/dbip-country-lite-{month}.csv.gz"
    request = urllib.request.Request(url, headers={"User-Agent": "OpenCJ-country-updater/1.0"})
    with urllib.request.urlopen(request, timeout=30) as response, target.open("wb") as out:
        if not response.url.startswith("https://"):
            raise ValueError("insecure download redirect")
        total = 0
        while block := response.read(1024 * 1024):
            total += len(block)
            if total > 64 * 1024 * 1024:
                raise ValueError("compressed download budget exceeded")
            out.write(block)
    return url


def connect():
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
        connect_timeout=15,
        read_timeout=120,
        write_timeout=120,
    )


def publish(db, cache, meta, provider, version, allow_older=False):
    """One transaction publishes complete ranges and pointer; retain previous release."""
    with db.cursor() as cur:
        cur.execute("SELECT GET_LOCK(CONCAT('opencj:geoip:',DATABASE()),0)")
        if cur.fetchone()[0] != 1:
            raise RuntimeError("another GeoIP updater holds the lock")
        try:
            cur.execute(
                "SELECT r.releaseID,r.provider,r.datasetVersion,r.sha256,r.rangeCount,r.addressCount FROM geoIPState s LEFT JOIN geoIPReleases r ON r.releaseID=s.activeReleaseID WHERE s.singleton=1"
            )
            old = cur.fetchone()
            if old is None:
                raise RuntimeError("GeoIP schema migration is missing")
            old_id = old[0]
            if old_id and (old[1], old[2], old[3]) == (provider, version, meta["sha256"]):
                db.rollback()
                return {"changed": False, "release": old_id}
            if old_id:
                if not allow_older and old[1] == provider and version < old[2]:
                    raise ValueError("refusing an older dataset")
                if meta["ranges"] < old[4] * 0.75 or meta["addresses"] < old[5] * 0.75:
                    raise ValueError("unexpected dataset shrink; active data retained")
            cur.execute(
                "SELECT releaseID,rangeCount,addressCount FROM geoIPReleases WHERE provider=%s AND datasetVersion=%s AND sha256=%s",
                (provider, version, meta["sha256"]),
            )
            existing = cur.fetchone()
            if existing:
                release = existing[0]
                if existing[1:] != (meta["ranges"], meta["addresses"]):
                    raise ValueError("retained dataset metadata mismatch")
            else:
                cur.execute(
                    "INSERT INTO geoIPReleases(provider,datasetVersion,sha256,rangeCount,addressCount) VALUES(%s,%s,%s,%s,%s)",
                    (provider, version, meta["sha256"], meta["ranges"], meta["addresses"]),
                )
                release = cur.lastrowid
                batch = []
                for start, end, country in cache.execute("SELECT * FROM ranges ORDER BY start"):
                    batch.append((release, start, end, country))
                    if len(batch) == 1000:
                        cur.executemany("INSERT INTO geoIPRanges VALUES(%s,%s,%s,%s)", batch)
                        batch = []
                if batch:
                    cur.executemany("INSERT INTO geoIPRanges VALUES(%s,%s,%s,%s)", batch)
            cur.execute("SELECT COUNT(*) FROM geoIPRanges WHERE releaseID=%s", (release,))
            if cur.fetchone()[0] != meta["ranges"]:
                raise ValueError("imported range count mismatch")
            cur.execute("UPDATE geoIPState SET activeReleaseID=%s WHERE singleton=1", (release,))
            cur.execute(
                "DELETE FROM geoIPReleases WHERE releaseID NOT IN (%s,%s)",
                (release, old_id or release),
            )
            db.commit()
            return {"changed": True, "release": release}
        except BaseException:
            db.rollback()
            raise
        finally:
            cur.execute("SELECT RELEASE_LOCK(CONCAT('opencj:geoip:',DATABASE()))")
            cur.fetchone()


def recent_months():
    date = dt.datetime.now(dt.timezone.utc).date().replace(day=1)
    for _ in range(3):
        yield date.strftime("%Y-%m")
        date = (date - dt.timedelta(days=1)).replace(day=1)


def run(args):
    with tempfile.TemporaryDirectory(prefix="opencj-geoip-") as temporary:
        work = Path(temporary)
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
        cache, meta = prepare(
            source, work / "validated.sqlite", bool(args.geolite_directory), args.minimum_ranges
        )
        try:
            if args.validate_only:
                result = {"validated": True}
            else:
                db = connect()
                try:
                    result = publish(db, cache, meta, provider, version, args.allow_older)
                finally:
                    db.close()
            LOG.info(
                json.dumps(
                    {
                        "provider": provider,
                        "version": version,
                        "ranges": meta["ranges"],
                        "addresses": meta["addresses"],
                        **result,
                    },
                    sort_keys=True,
                )
            )
        finally:
            cache.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    inputs = parser.add_mutually_exclusive_group()
    inputs.add_argument("--input", type=Path, help="Existing DB-IP CSV.gz")
    inputs.add_argument("--geolite-directory", type=Path)
    parser.add_argument("--month")
    parser.add_argument("--minimum-ranges", type=int, default=50000)
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
            delay = 86400
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
            delay = 21600
        if not args.daemon:
            return
        time.sleep(delay)


if __name__ == "__main__":
    main()
