isPoolMap(mapName)
{
    return isDefined(level.poolMapNames) && isDefined(level.poolMapNames[toLower(mapName)]);
}

previewImage(mapName)
{
    if (isPoolMap(mapName))
    {
        return "loadscreen_" + toLower(mapName);
    }
    return "opencj_missing_image";
}

// Uber-admins may vote for any installed map; everyone else only for pool maps.
canVoteMap(mapName, permissionMask)
{
    mapName = toLower(mapName);
    if (!openCJ\permissions::isUberMask(permissionMask) && !isPoolMap(mapName))
    {
        return false;
    }
    return opencjMapExists(mapName);
}

onInit()
{
    level.maps = [];
    level.mapNames = [];
    level.poolMapNames = [];
    level thread fetchAllMaps();
    openCJ\mapRoutes::onInit();
}

// One catalogue supplies map voting and browser metadata, including admin-only maps.
fetchAllMaps()
{
    query = "SELECT m.mapname, COALESCE(m.releaseDate, 'Unknown'), m.inRotation, " +
        "COALESCE(GROUP_CONCAT(a.name ORDER BY a.name SEPARATOR ', '), 'Unknown') " +
        "FROM mapids m " +
        "LEFT JOIN mapMappers mm ON mm.mapID = m.mapID " +
        "LEFT JOIN mappers a ON a.mapperID = mm.mapperID " +
        "GROUP BY m.mapID, m.mapname, m.releaseDate, m.inRotation " +
        "ORDER BY m.mapname ASC";
    rows = openCJ\mysql::mysqlAsyncRead(query);
    loadMapRows(rows);

    printf("[OpenCJ] Map catalogue: " + level.maps.size + " installed, " +
           voteMaps(0).size + " in pool\n");
    thread openCJ\menus\endMapVote::fillRandomMaps();
}

// Discovery yields, so publish all three indexes only after the snapshot is complete.
loadMapRows(rows)
{
    catalogue = spawnStruct();
    catalogue.maps = [];
    catalogue.mapNames = [];
    catalogue.poolMapNames = [];
    rowBatchSize = 100;
    scanPauseSeconds = 0.05;

    if (isDefined(rows))
    {
        for (i = 0; i < rows.size; i++)
        {
            mapName = toLower(rows[i][0]);
            releaseDate = rows[i][1];
            inRotation = rows[i][2];
            author = rows[i][3];
            _addMap(catalogue, mapName, releaseDate, inRotation, author);
            if (i % rowBatchSize == rowBatchSize - 1)
            {
                wait scanPauseSeconds;
            }
        }
    }

    _addUsermaps(catalogue, getCvar("fs_basepath") + "/usermaps");
    _addUsermaps(catalogue, getCvar("fs_homepath") + "/usermaps");
    _addStockMaps(catalogue, getCvar("fs_basepath") + "/zone");
    _addStockMaps(catalogue, getCvar("fs_homepath") + "/zone");

    // Installed files alone grant no pool access when database metadata is unavailable.
    level.maps = catalogue.maps;
    level.mapNames = catalogue.mapNames;
    level.poolMapNames = catalogue.poolMapNames;
}

_addUsermaps(catalogue, directoryPath)
{
    entries = opencjScanDir(directoryPath);
    if (!isDefined(entries))
    {
        return;
    }

    entryBatchSize = 100;
    scanPauseSeconds = 0.05;
    for (i = 0; i < entries.size; i++)
    {
        _addMap(catalogue, toLower(entries[i]), undefined, undefined, undefined);
        if (i % entryBatchSize == entryBatchSize - 1)
        {
            wait scanPauseSeconds;
        }
    }
}

// Language folders can differ; the native check decides which candidates are loadable.
_addStockMaps(catalogue, directoryPath)
{
    languageDirectories = opencjScanDir(directoryPath);
    if (!isDefined(languageDirectories))
    {
        return;
    }

    mapPrefix = "mp_";
    fastfileExtension = ".ff";
    minimumFilenameLength = mapPrefix.size + 1 + fastfileExtension.size;
    entryBatchSize = 100;
    scanPauseSeconds = 0.05;

    for (i = 0; i < languageDirectories.size; i++)
    {
        entries = opencjScanDir(directoryPath + "/" + languageDirectories[i]);
        if (!isDefined(entries))
        {
            continue;
        }
        for (j = 0; j < entries.size; j++)
        {
            filename = toLower(entries[j]);
            if (filename.size < minimumFilenameLength ||
                getSubStr(filename, 0, mapPrefix.size) != mapPrefix ||
                getSubStr(filename, filename.size - fastfileExtension.size) != fastfileExtension)
            {
                continue;
            }

            mapName = getSubStr(filename, 0, filename.size - fastfileExtension.size);
            _addMap(catalogue, mapName, undefined, undefined, undefined);
            if (j % entryBatchSize == entryBatchSize - 1)
            {
                wait scanPauseSeconds;
            }
        }
    }
}

// Database rows are added first, so file discovery cannot overwrite their metadata.
_addMap(catalogue, mapName, releaseDate, inRotation, author)
{
    if (isDefined(catalogue.mapNames[mapName]) || !opencjMapExists(mapName))
    {
        return;
    }

    entry = [];
    entry["name"] = mapName;
    entry["date"] = "Unknown";
    if (isDefined(releaseDate))
    {
        entry["date"] = releaseDate;
    }
    entry["desc"] = "";
    entry["author"] = "Unknown";
    if (isDefined(author) && author != "")
    {
        entry["author"] = author;
    }
    catalogue.maps[catalogue.maps.size] = entry;
    catalogue.mapNames[mapName] = true;
    if (isDefined(inRotation) && int(inRotation) == 1)
    {
        catalogue.poolMapNames[mapName] = true;
    }
}

voteMaps(permissionMask)
{
    eligibleMaps = [];
    if (!isDefined(level.maps))
    {
        return eligibleMaps;
    }
    for (i = 0; i < level.maps.size; i++)
    {
        if (canVoteMap(level.maps[i]["name"], permissionMask))
        {
            eligibleMaps[eligibleMaps.size] = level.maps[i];
        }
    }
    return eligibleMaps;
}
