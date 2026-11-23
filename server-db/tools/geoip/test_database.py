"""Run synthetic GeoIP publication scenarios inside the isolated updater fixture."""

from contextlib import closing, contextmanager
import ipaddress
import json
import re
import sqlite3

import pymysql
import update as updater


def read_value(database, sql):
    try:
        with database.cursor() as cursor:
            cursor.execute(sql)
            row = cursor.fetchone()
        return row[0]
    finally:
        # End each read transaction so the next assertion sees the latest publication.
        database.rollback()


def lookup(database, ip_address):
    return read_value(database, "SELECT geoIPLookupCode(INET_ATON('" + ip_address + "'))")


@contextmanager
def release_fixture(release_number):
    """Keep each tiny range cache alive for its publication and rollback checks."""
    with closing(sqlite3.connect(":memory:")) as cache:
        cache.execute("CREATE TABLE ranges(start INTEGER PRIMARY KEY,end INTEGER,country TEXT)")
        for start, end, country_code in (
            ("8.8.8.0", "8.8.8.7", "US"),
            ("8.8.8.16", "8.8.8.31", "GB"),
        ):
            cache.execute(
                "INSERT INTO ranges VALUES(?,?,?)",
                (int(ipaddress.ip_address(start)), int(ipaddress.ip_address(end)), country_code),
            )
        metadata = {"ranges": 2, "addresses": 24, "sha256": str(release_number) * 64}
        yield cache, metadata


def verify_lookup_boundaries(database):
    expected_countries = (
        ("8.8.8.0", "US"),
        ("8.8.8.7", "US"),
        ("8.8.8.8", "range_not_found"),
        ("8.8.8.15", "range_not_found"),
        ("8.8.8.16", "GB"),
        ("8.8.8.31", "GB"),
        ("8.8.8.32", "range_not_found"),
        ("1.0.0.1", "range_not_found"),
    )
    for ip_address, expected in expected_countries:
        actual = lookup(database, ip_address)
        assert actual == expected, (ip_address, expected, actual)
    for ip_address in (
        "0.1.2.3",
        "10.2.3.4",
        "100.64.0.1",
        "127.0.0.1",
        "169.254.2.3",
        "172.16.1.2",
        "192.0.0.1",
        "192.0.2.3",
        "192.168.0.1",
        "198.18.0.1",
        "198.51.100.3",
        "203.0.113.7",
        "224.0.0.1",
        "255.255.255.255",
    ):
        assert lookup(database, ip_address) == "non_public_ip", ip_address
    assert lookup(database, "192.0.0.9") == "range_not_found"
    assert read_value(database, "SELECT geoIPLookupCode(NULL)") == "invalid_ip"
    assert read_value(database, "SELECT getCountry(INET_ATON('8.8.8.8'))") is None
    assert read_value(database, "SELECT getCountry(INET_ATON('8.8.8.16'))") == "GBUnited Kingdom"


class PublicationFailureCursor:
    """Fail at the active-release switch after real range inserts have run."""

    def __init__(self, cursor):
        self.cursor = cursor

    def __enter__(self):
        self.cursor.__enter__()
        return self

    def __exit__(self, *args):
        return self.cursor.__exit__(*args)

    def execute(self, sql, *args):
        if re.match(r"\s*UPDATE\s+geoIPState\b", sql, re.I):
            raise RuntimeError("injected publication failure")
        return self.cursor.execute(sql, *args)

    def __getattr__(self, name):
        return getattr(self.cursor, name)


class PublicationFailureConnection:
    def __init__(self, database):
        self.database = database

    def cursor(self):
        return PublicationFailureCursor(self.database.cursor())

    def rollback(self):
        return self.database.rollback()

    def commit(self):
        return self.database.commit()


def verify_failed_publication(database, cache, metadata, active_release):
    try:
        updater.publish(
            PublicationFailureConnection(database), cache, metadata, "fixture", "2026-02"
        )
    except RuntimeError as error:
        assert str(error) == "injected publication failure", str(error)
    else:
        raise AssertionError("injected publication failure did not fail")
    assert read_value(database, "SELECT activeReleaseID FROM geoIPState") == active_release
    assert read_value(database, "SELECT COUNT(*) FROM geoIPReleases") == 1
    assert lookup(database, "8.8.8.16") == "GB"


def verify_rejected_releases(database, first_cache, first_metadata):
    try:
        updater.publish(database, first_cache, first_metadata, "fixture", "2026-01")
    except ValueError:
        pass
    else:
        raise AssertionError("older release accepted")
    try:
        updater.publish(
            database, first_cache, {**first_metadata, "ranges": 0}, "fixture", "2026-04"
        )
    except ValueError:
        pass
    else:
        raise AssertionError("truncated release accepted")


def verify_restricted_access(database):
    permission_denied_codes = (1044, 1142)
    for sql in (
        "SELECT 1 FROM openCJ_cod4.playerInformation LIMIT 0",
        "CREATE TABLE must_not_exist(id INT)",
    ):
        try:
            with database.cursor() as cursor:
                cursor.execute(sql)
        except pymysql.MySQLError as error:
            assert error.args[0] in permission_denied_codes, error.args[0]
        else:
            raise AssertionError("updater identity has excessive privileges")


def main():
    with (
        closing(updater.connect()) as database,
        release_fixture(1) as (first_cache, first_metadata),
        release_fixture(2) as (second_cache, second_metadata),
        release_fixture(3) as (third_cache, third_metadata),
    ):
        assert lookup(database, "8.8.8.0") == "database_unavailable"
        assert lookup(database, "127.0.0.1") == "non_public_ip"
        first = updater.publish(database, first_cache, first_metadata, "fixture", "2026-01")
        assert first["changed"], "first dataset was not published"
        verify_lookup_boundaries(database)
        repeated = updater.publish(database, first_cache, first_metadata, "fixture", "2026-01")
        assert not repeated["changed"], "identical publication created another release"
        verify_failed_publication(database, second_cache, second_metadata, first["release"])

        second = updater.publish(database, second_cache, second_metadata, "fixture", "2026-02")
        assert second["changed"], "newer dataset was not published"
        assert read_value(database, "SELECT COUNT(*) FROM geoIPReleases") == 2
        updater.publish(database, third_cache, third_metadata, "fixture", "2026-03")
        assert read_value(database, "SELECT COUNT(*) FROM geoIPReleases") == 2
        verify_rejected_releases(database, first_cache, first_metadata)
        verify_restricted_access(database)

    print(
        json.dumps(
            {
                "sql_boundaries": "pass",
                "non_public_ranges": "pass",
                "atomic_failure_rollback": "pass",
                "idempotent_publication": "pass",
                "last_two_releases": "pass",
                "downgrade_and_shrink_rejection": "pass",
                "least_privilege": "pass",
            }
        )
    )


if __name__ == "__main__":
    main()
