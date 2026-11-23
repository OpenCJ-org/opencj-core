// The map browser reads the same published normal routes as gameplay.
onInit()
{
    level.mapRoutes = [];
    level.mapRoutesReady = false;
    level.mapRoutesRequest = 0;
    level thread refresh();
}

// Named difficulty routes precede custom names; row order resolves duplicate labels.
query()
{
    return "SELECT m.mapname, r.routeName, COALESCE(r.colorRGB, 16777215) " +
        "FROM routes r " +
        "JOIN mapids m ON m.mapID = r.mapID " +
        "WHERE r.routeType = 'normal' " +
        "AND r.routeName IS NOT NULL AND r.routeName <> '' " +
        "AND EXISTS (" +
            "SELECT 1 FROM checkpoints e " +
            "WHERE e.mapID = r.mapID AND e.retired = 0 AND e.finishRouteID = r.routeID" +
        ") " +
        "ORDER BY m.mapname, " +
            "CASE LOWER(r.routeName) " +
                "WHEN 'normal' THEN 0 " +
                "WHEN 'basic' THEN 1 " +
                "WHEN 'easy' THEN 2 " +
                "WHEN 'inter' THEN 3 " +
                "WHEN 'inter+' THEN 4 " +
                "WHEN 'hard' THEN 5 " +
                "WHEN 'hard+' THEN 6 " +
                "WHEN 'adv' THEN 7 " +
                "WHEN 'advanced' THEN 7 " +
                "WHEN 'adv+' THEN 8 " +
                "WHEN 'advanced+' THEN 8 " +
                "ELSE 9 " +
            "END, " +
            "LOWER(r.routeName), r.colorRGB IS NULL, r.routeID";
}

// A later refresh owns publication even if an older database reply arrives last.
refresh()
{
    if(!isDefined(level.mapRoutesRequest))
    {
        level.mapRoutesRequest = 0;
    }
    level.mapRoutesRequest++;
    requestVersion = level.mapRoutesRequest;
    rows = openCJ\mySQL::mysqlAsyncRead(query());
    if(requestVersion != level.mapRoutesRequest)
    {
        return;
    }
    applyRows(rows);
}

applyRows(rows)
{
    if(!loadRows(rows))
    {
        return false;
    }
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        if(isDefined(players[i].currentMenu) && players[i].currentMenu == "opencj_maplist")
        {
            players[i] openCJ\menus\mapList::_updateMapList(false);
        }
    }
    return true;
}

// Keep the last complete snapshot when a read fails; a successful empty read replaces it.
loadRows(rows)
{
    if(!isDefined(rows))
    {
        return false;
    }

    routesByMap = [];
    seenRoutes = [];
    for(i = 0; i < rows.size; i++)
    {
        mapName = toLower(rows[i][0]);
        routeName = rows[i][1];
        packedColor = rows[i][2];
        routeKey = mapName + ":" + toLower(routeName);
        if(routeName == "" || isDefined(seenRoutes[routeKey]))
        {
            continue;
        }
        seenRoutes[routeKey] = true;
        if(!isDefined(routesByMap[mapName]))
        {
            routesByMap[mapName] = [];
        }

        route = spawnStruct();
        route.name = routeName;
        route.label = label(routeName);
        route.color = unpackColor(packedColor);
        route.palette = paletteIndex(route.color);
        routesByMap[mapName][routesByMap[mapName].size] = route;
    }

    level.mapRoutes = routesByMap;
    level.mapRoutesReady = true;
    return true;
}

// Decode the database's packed 24-bit RGB into the engine's normalized channels.
unpackColor(packedColor)
{
    maximumPackedRgb = 16777215;
    if(!isDefined(packedColor))
    {
        return (1, 1, 1);
    }
    packedColor = int(packedColor);
    if(packedColor < 0 || packedColor > maximumPackedRgb)
    {
        return (1, 1, 1);
    }

    byteRadix = 256;
    maximumChannelValue = 255.0;
    red = int(packedColor / (byteRadix * byteRadix)) / maximumChannelValue;
    green = (int(packedColor / byteRadix) % byteRadix) / maximumChannelValue;
    blue = (packedColor % byteRadix) / maximumChannelValue;
    return (red, green, blue);
}

// Route labels must fit the menu row and cannot inject game color codes.
label(routeName)
{
    plainText = "";
    firstPrintableAscii = 32;
    lastPrintableAscii = 126;
    maximumLabelCharacters = 18;
    ellipsis = "...";

    for(i = 0; i < routeName.size; i++)
    {
        character = routeName[i];
        if(character == "^")
        {
            i++;
            continue;
        }
        asciiCode = getAscii(character);
        if(asciiCode < firstPrintableAscii || asciiCode > lastPrintableAscii)
        {
            continue;
        }
        plainText += character;
    }
    if(plainText.size > maximumLabelCharacters)
    {
        plainText = getSubStr(plainText, 0, maximumLabelCharacters - ellipsis.size) + ellipsis;
    }
    return plainText;
}

overview(mapName)
{
    view = spawnStruct();
    view.rows = [];
    view.total = 0;
    view.title = "";
    view.message = "";
    if(!isDefined(mapName))
    {
        return view;
    }
    view.title = "Routes";
    if(!isDefined(level.mapRoutesReady) || !level.mapRoutesReady)
    {
        view.message = "Routes unavailable";
        return view;
    }

    routes = level.mapRoutes[toLower(mapName)];
    if(!isDefined(routes) || !routes.size)
    {
        view.message = "No routes available";
        return view;
    }

    maximumVisibleRoutes = 10;
    view.total = routes.size;
    view.title = "Routes (" + view.total + ")";
    if(view.total > maximumVisibleRoutes)
    {
        view.title = "Routes (first " + maximumVisibleRoutes + " of " + view.total + ")";
    }
    for(i = 0; i < min(maximumVisibleRoutes, routes.size); i++)
    {
        view.rows[view.rows.size] = routes[i];
    }
    return view;
}

// CoD4 menus support dynamic alpha, not RGB. Palette slots match ROUTE_ROW in
// opencj_maplist.menu; custom colors select the nearest normalized RGB value.
paletteIndex(color)
{
    packedColors = [];
    packedColors[0] = 16777215;
    packedColors[1] = 255;
    packedColors[2] = 65535;
    packedColors[3] = 65280;
    packedColors[4] = 16776960;
    packedColors[5] = 16746496;
    packedColors[6] = 16742263;
    packedColors[7] = 11163135;
    packedColors[8] = 52479;
    packedColors[9] = 16711680;
    packedColors[10] = 11141120;
    packedColors[11] = 16744652;

    nearestPaletteIndex = 0;
    // The initial value exceeds any squared distance between normalized RGB colors (at most 3).
    nearestDistanceSquared = 999;
    for(i = 0; i < packedColors.size; i++)
    {
        paletteColor = unpackColor(packedColors[i]);
        candidateDistanceSquared = distanceSquared(color, paletteColor);
        if(candidateDistanceSquared < nearestDistanceSquared)
        {
            nearestDistanceSquared = candidateDistanceSquared;
            nearestPaletteIndex = i;
        }
    }
    return nearestPaletteIndex;
}
