"""Verify route-refresh cancellation and stale replies using real isolated SQL jobs."""

from pathlib import Path
import re

import gsc_fixture
from isolated_database import IsolatedDatabase

ROOT = Path(__file__).resolve().parents[2]


def install_route_observers(mod):
    """Control query timing and hold completed replies only in the fixture copy."""
    routes = mod / "opencj/maproutes.gsc"
    source, count = re.subn(
        r"(?m)^query\s*\(", "_fixtureProductionQuery(", routes.read_text()
    )
    if count != 1:
        raise RuntimeError("Expected one route query builder")
    source += r"""
query()
{
    return openCJ\platformTest::refreshQuery();
}
"""
    routes.write_text(source)

    mysql = mod / "opencj/mysql.gsc"
    source, count = re.subn(
        r"(?m)^_request\s*\(", "_fixtureOriginalRequest(", mysql.read_text()
    )
    if count != 1:
        raise RuntimeError("Expected one SQL request boundary")
    source += r"""
_request(query, policy, key, scope, queueWaitMs, retainRows)
{
    isRouteQuery = isSubStr(query, "/* map-route-fixture */");
    requestVersion = level.mapRoutesRequest;
    result = self _fixtureOriginalRequest(query, policy, key, scope, queueWaitMs, retainRows);
    if(isRouteQuery)
    {
        level.routeTestOutcomes[requestVersion] = result.status;
        printf("MAP ROUTES REQUEST " + requestVersion + " outcome=" + result.status +
               " waitMs=" + result.waitMs + " executionMs=" + result.executionMs + "\n");
        if(isDefined(level.routeTestHoldVersion) && requestVersion == level.routeTestHoldVersion)
        {
            level.routeTestHeldReplyReady = true;
            replyDeadlineMs = getTime() + 5000;
            while(!level.routeTestReleaseReply && getTime() < replyDeadlineMs)
            {
                wait 0.05;
            }
        }
        level.routeTestRepliesReturned[requestVersion] = true;
    }
    return result;
}
"""
    mysql.write_text(source)


def main():
    options = gsc_fixture.parse_options(
        default_fixture=ROOT / "dev-tools/tests/map-routes.gsc",
        completion_marker="MAP ROUTES COMPLETE",
    )
    if options.maps != ["mp_killhouse"]:
        raise ValueError("Route-refresh scenarios use mp_killhouse")

    database = IsolatedDatabase("map-routes")
    database.home.mkdir(mode=0o700)
    try:
        database.prepare_database()
        source_hashes, _ = gsc_fixture.prepare_fixture(
            options, database.home, retained_callbacks=()
        )
        install_route_observers(database.home / "mods/opencj")
        database.write_engine_config()
        gsc_fixture.run_prepared_fixture(
            options,
            database.home,
            "mp_killhouse",
            source_hashes,
            config_files=(database.config.name,),
            extra_settings={"opencj_route_fixture": database.home.name},
        )
    finally:
        database.cleanup()
        print("Evidence: " + str(database.home), flush=True)


if __name__ == "__main__":
    main()
