isPoolMap(name)
{
    return isDefined(level.poolMapNames) && isDefined(level.poolMapNames[toLower(name)]);
}

previewImage(name)
{
    if (isPoolMap(name))
    {
        return "loadscreen_" + toLower(name);
    }
    return "opencj_missing_image";
}

canVoteMap(name, adminLevel)
{
    name = toLower(name);
    if (!openCJ\commands_base::isUberAdminLevel(adminLevel) && !isPoolMap(name))
    {
        return false;
    }
    return opencjMapExists(name);
}

onInit()
{
    level.maps = [];
    level.mapNames = [];
    level.poolMapNames = [];
    level thread fetchAllMaps();
    openCJ\mapRoutes::onInit();
}

fetchAllMaps()
{
    // One shared pool for voting and the future download catalogue (#203).
    // Keep metadata for installed maps outside the pool for uber-admin menus.
    rows = openCJ\mysql::mysqlAsyncRead(
        "SELECT m.mapname, COALESCE(m.releaseDate, 'Unknown'), m.inRotation, COALESCE(GROUP_CONCAT(a.name ORDER BY a.name SEPARATOR ', '), 'Unknown') FROM mapids m LEFT JOIN mapMappers mm ON mm.mapID = m.mapID LEFT JOIN mappers a ON a.mapperID = mm.mapperID GROUP BY m.mapID, m.mapname, m.releaseDate, m.inRotation ORDER BY m.mapname ASC");
    loadMapRows(rows);
    printf("[OpenCJ] Map catalogue: " + level.maps.size + " installed, " + voteMaps(0).size +
           " in pool\n");
    thread openCJ\menus\endMapVote::fillRandomMaps();
}

loadMapRows(rows)
{
    // Build a complete snapshot before publishing it: discovery yields.
    catalogue = spawnStruct();
    catalogue.maps = [];
    catalogue.names = [];
    catalogue.pool = [];
    if (isDefined(rows))
    {
        for (i = 0; i < rows.size; i++)
        {
            _addMap(catalogue, toLower(rows[i][0]), rows[i][1], rows[i][2], rows[i][3]);
            if (i % 100 == 99)
            {
                wait 0.05;
            }
        }
    }
    _addUsermaps(catalogue, getCvar("fs_basepath") + "/usermaps");
    _addUsermaps(catalogue, getCvar("fs_homepath") + "/usermaps");
    _addStockMaps(catalogue, getCvar("fs_basepath") + "/zone");
    _addStockMaps(catalogue, getCvar("fs_homepath") + "/zone");
    // No hard-coded fallback: unavailable/empty DB rows grant no pool access.
    level.maps = catalogue.maps;
    level.mapNames = catalogue.names;
    level.poolMapNames = catalogue.pool;
}

_addUsermaps(catalogue, path)
{
    entries = opencjScanDir(path);
    if (!isDefined(entries))
    {
        return;
    }
    for (i = 0; i < entries.size; i++)
    {
        _addMap(catalogue, toLower(entries[i]), undefined, undefined, undefined);
        if (i % 100 == 99)
        {
            wait 0.05;
        }
    }
}

_addStockMaps(catalogue, path)
{
    directories = opencjScanDir(path);
    if (!isDefined(directories))
    {
        return;
    }
    for (i = 0; i < directories.size; i++)
    {
        // Scan language folders; the native existence check below decides
        // whether the engine can actually load a candidate in this setup.
        entries = opencjScanDir(path + "/" + directories[i]);
        if (!isDefined(entries))
        {
            continue;
        }
        for (j = 0; j < entries.size; j++)
        {
            filename = toLower(entries[j]);
            if (filename.size <= 6 || getSubStr(filename, 0, 3) != "mp_" ||
                getSubStr(filename, filename.size - 3) != ".ff")
            {
                continue;
            }
            _addMap(catalogue, getSubStr(filename, 0, filename.size - 3), undefined, undefined,
                    undefined);
            if (j % 100 == 99)
            {
                wait 0.05;
            }
        }
    }
}

_addMap(catalogue, name, date, inRotation, author)
{
    if (isDefined(catalogue.names[name]) || !opencjMapExists(name))
    {
        return;
    }
    entry = [];
    entry["name"] = name;
    entry["date"] = "Unknown";
    if (isDefined(date))
    {
        entry["date"] = date;
    }
    entry["desc"] = "";
    entry["author"] = "Unknown";
    if (isDefined(author) && author != "")
    {
        entry["author"] = author;
    }
    catalogue.maps[catalogue.maps.size] = entry;
    catalogue.names[name] = true;
    if (isDefined(inRotation) && int(inRotation) == 1)
    {
        catalogue.pool[name] = true;
    }
}

voteMaps(adminLevel)
{
    maps = [];
    if (!isDefined(level.maps))
    {
        return maps;
    }
    for (i = 0; i < level.maps.size; i++)
    {
        if (canVoteMap(level.maps[i]["name"], adminLevel))
        {
            maps[maps.size] = level.maps[i];
        }
    }
    return maps;
}
