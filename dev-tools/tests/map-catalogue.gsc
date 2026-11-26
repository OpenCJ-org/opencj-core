main()
{
    level.failures = 0;
    level.checks = 0;
    verifyRouteLabels();
    verifyRouteSnapshot();
    verifyRouteOverview();
    verifyMapPool();
    printf("MAP CATALOGUE COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}

verifyRouteLabels()
{
    check(openCJ\mapRoutes::label("^1Easy") == "Easy", "route labels remove color codes");
    check(openCJ\mapRoutes::label("A\nB") == "AB", "route labels remove control characters");
    check(openCJ\mapRoutes::label("abcdefghijklmnopqr") == "abcdefghijklmnopqr",
          "18-character label fits");
    check(openCJ\mapRoutes::label("abcdefghijklmnopqrs") == "abcdefghijklmno...",
          "long label keeps room for ellipsis");
}

routeRow(mapName, routeName, packedColor)
{
    row = [];
    row[0] = mapName;
    row[1] = routeName;
    row[2] = packedColor;
    return row;
}

// Database row order selects the first case-insensitive duplicate.
verifyRouteSnapshot()
{
    rows = [];
    rows[0] = routeRow("MP_KILLHOUSE", "Easy", 16711680);
    rows[1] = routeRow("mp_killhouse", "easy", 255);
    rows[2] = routeRow("mp_killhouse", "", 0);
    rows[3] = routeRow("mp_killhouse", "Hard", undefined);
    rows[4] = routeRow("mp_killhouse", "Invalid", -1);
    rows[5] = routeRow("mp_killhouse", "Overflow", 16777216);
    rows[6] = routeRow("mp_crossfire", "Blue", 255);

    check(openCJ\mapRoutes::loadRows(rows), "route snapshot accepted");
    check(level.mapRoutesReady, "successful snapshot is ready");
    routes = level.mapRoutes["mp_killhouse"];
    check(routes.size == 4, "duplicate and empty route names omitted");
    check(routes[0].name == "Easy" && routes[0].color == (1, 0, 0),
          "first duplicate retains name and RGB color");
    check(routes[0].palette == 9, "red uses matching menu palette slot");
    check(routes[1].color == (1, 1, 1), "missing color defaults to white");
    check(routes[2].color == (1, 1, 1), "negative color defaults to white");
    check(routes[3].color == (1, 1, 1), "overflowing color defaults to white");
    check(level.mapRoutes["mp_crossfire"][0].color == (0, 0, 1),
          "routes remain grouped by map");

    check(!openCJ\mapRoutes::loadRows(undefined), "failed read remains a failure");
    check(level.mapRoutes["mp_killhouse"].size == 4, "failed read retains last snapshot");
    check(openCJ\mapRoutes::paletteIndex((0.99, 0.01, 0)) == 9,
          "custom color uses nearest menu palette slot");
}

verifyRouteOverview()
{
    rows = [];
    for(i = 0; i < 12; i++)
    {
        rows[i] = routeRow("mp_killhouse", "Route " + i, 16777215);
    }
    openCJ\mapRoutes::loadRows(rows);
    overview = openCJ\mapRoutes::overview("MP_KILLHOUSE");
    check(overview.total == 12 && overview.rows.size == 10,
          "overview bounds rows while retaining total");
    check(overview.title == "Routes (first 10 of 12)", "truncated overview explains count");
    check(overview.rows[9].name == "Route 9", "overview preserves database ordering");

    overview = openCJ\mapRoutes::overview("mp_no_such_map");
    check(overview.message == "No routes available", "missing map has an empty-state message");
    level.mapRoutesReady = false;
    overview = openCJ\mapRoutes::overview("mp_killhouse");
    check(overview.message == "Routes unavailable", "unavailable routes differ from empty routes");

    check(openCJ\mapRoutes::loadRows([]), "successful empty snapshot accepted");
    overview = openCJ\mapRoutes::overview("mp_killhouse");
    check(overview.message == "No routes available", "empty snapshot replaces old routes");
}

mapRow(mapName, releaseDate, inRotation, author)
{
    row = [];
    row[0] = mapName;
    row[1] = releaseDate;
    row[2] = inRotation;
    row[3] = author;
    return row;
}

// Real installed-map checks enforce pool access independently of database metadata.
verifyMapPool()
{
    rows = [];
    rows[0] = mapRow("MP_KILLHOUSE", "2020-01-01", 1, "Fixture Author");
    rows[1] = mapRow("mp_crossfire", "Unknown", 0, "");
    rows[2] = mapRow("mp_missing_catalogue_fixture", "Unknown", 1, "Fixture Author");
    openCJ\maps::loadMapRows(rows);

    check(openCJ\maps::canVoteMap("MP_KILLHOUSE", 0), "ordinary player can vote installed pool map");
    check(!openCJ\maps::canVoteMap("mp_crossfire", 0), "ordinary player cannot vote outside pool");
    uberPermissions = openCJ\permissions::permissionNamed("uber").flag;
    check(openCJ\maps::canVoteMap("mp_crossfire", uberPermissions),
          "uber-admin can vote installed map outside pool");
    check(!isDefined(level.mapNames["mp_missing_catalogue_fixture"]),
          "missing map cannot enter catalogue through database row");
    check(openCJ\maps::previewImage("mp_killhouse") == "loadscreen_mp_killhouse",
          "pool map uses its preview");
    check(openCJ\maps::previewImage("mp_crossfire") == "opencj_missing_image",
          "map outside pool uses missing preview");

    poolMaps = openCJ\maps::voteMaps(0);
    check(poolMaps.size == 1 && poolMaps[0]["name"] == "mp_killhouse",
          "ordinary vote list contains only installed pool maps");
    check(poolMaps[0]["date"] == "2020-01-01" && poolMaps[0]["author"] == "Fixture Author",
          "database metadata survives local map discovery");

    openCJ\maps::loadMapRows(undefined);
    check(openCJ\maps::voteMaps(0).size == 0, "failed metadata read grants no pool access");
    check(isDefined(level.mapNames["mp_killhouse"]), "failed metadata read still discovers installed maps");
}

check(condition, message)
{
    level.checks++;
    if(!condition)
    {
        level.failures++;
        printf("MAP CATALOGUE FAIL " + message + "\n");
    }
}
