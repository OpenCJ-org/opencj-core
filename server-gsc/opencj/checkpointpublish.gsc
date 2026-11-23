// Publish a complete sequential route into the existing checkpoint graph.
// No waits inside the transaction: every statement uses the same sync connection.
publish()
{
    if (isDefined(self.cpc.insertAfter))
    {
        self.cpc.status = "Confirm or discard the insertion before finalizing";
        return false;
    }
    if (isDefined(self.cpc.network))
    {
        return self openCJ\checkpointNetwork::publish();
    }
    if (self.cpc.rows.size == 0)
    {
        self.cpc.status = "Confirm checkpoints before publishing";
        return false;
    }
    if (self.cpc.draft.points.size > 0 || self.cpc.draft.alternatives.size > 0)
    {
        self.cpc.status = "Confirm your current edit first (or Undo / New to discard it)";
        return false;
    }
    error = validationError(self.cpc.rows);
    if (error != "")
    {
        self.cpc.status = error;
        return false;
    }
    if (!openCJ\mapID::hasMapID())
    {
        self.cpc.status = "Map has no database ID";
        return false;
    }
    if (!isDefined(openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas LIMIT 0")))
    {
        self.cpc.status = "Install server-db/migrations/001-checkpoint-areas.sql first";
        return false;
    }
    if (!isDefined(openCJ\mySQL::mysqlSyncQuery("SELECT routeID FROM routes LIMIT 0")))
    {
        return self _fail("Install server-db/migrations/019-route-identity.sql first");
    }
    if (!isDefined(openCJ\mySQL::mysqlSyncQuery("START TRANSACTION")))
    {
        self.cpc.status = "Cannot start database transaction; draft retained";
        return false;
    }
    if (!self _writeRoute() ||
       !isDefined(openCJ\mySQL::mysqlSyncQuery("CALL rebuildCheckpointRoutes(" +
                                               openCJ\mapID::getMapID() + ")")))
    {
        openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
        self iprintln(self.cpc.status);
        return false;
    }
    if (!isDefined(openCJ\mySQL::mysqlSyncQuery("COMMIT")))
    {
        openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
        // A missing reply does not prove that COMMIT failed. A retry rechecks the saved layout.
        self.cpc.status = "Cannot confirm database commit; draft retained. Check the published route.";
        return false;
    }
    return true;
}

validationError(rows)
{
    if (rows.size == 0)
    {
        return "Confirm checkpoints before finalizing";
    }
    hasFinish = false;
    for (i = 0; i < rows.size; i++)
    {
        checkpoint = openCJ\checkpointCreation::_decode(rows[i]);
        // Empty polygons are valid unfinished drafts, but publication needs a stored center.
        if (!isDefined(checkpoint) || checkpoint.points.size == 0 ||
           openCJ\checkpointMoving::valid(checkpoint) != "")
        {
            return "Every checkpoint needs valid confirmed geometry";
        }
        if (hasFinish && !checkpoint.finish)
        {
            return "Finish checkpoints must come after all ordinary checkpoints";
        }
        if (checkpoint.finish)
        {
            hasFinish = true;
        }
    }
    if (!hasFinish)
    {
        return "Mark and confirm at least one Finish before !cp finalize";
    }
    return "";
}

// Refresh the graph without invalidating other players' checkpoint references.
activate()
{
    openCJ\checkpoints::onInit();
    level thread openCJ\mapRoutes::refresh();
    self openCJ\challenges::onRoutesPublished();
    players = getEntArray("player", "classname");
    for (i = 0; i < players.size; i++)
    {
        player = players[i];
        if (!isDefined(player.checkpoints_checkpoint))
        {
            continue;
        }
        currentCheckpoint = openCJ\checkpoints::getCheckpointByID(player.checkpoints_checkpoint.id);
        if (!isDefined(currentCheckpoint))
        {
            currentCheckpoint = level.checkpoints_startCheckpoint;
        }
        player.checkpoints_checkpoint = currentCheckpoint;
        player.route = openCJ\checkpoints::getRouteNameForCheckpoint(currentCheckpoint);
        player openCJ\elevate::_updateAllowEle();
        for (j = 0; j < player.checkpoints_passed.size; j++)
        {
            player.checkpoints_passed[j] =
                openCJ\checkpoints::getCheckpointByID(player.checkpoints_passed[j].id);
        }
        if (!player openCJ\checkpointCreation::isEditing())
        {
            player openCJ\checkpointPointers::onCheckpointsChanged();
        }
    }
}

_writeRoute()
{
    if (isDefined(self.cpc.sharedRoute))
    {
        return self openCJ\checkpointBranch::publish();
    }
    return self _writeSequentialRoute();
}

// The caller owns one synchronous transaction. Lock before inspecting the existing graph.
_writeSequentialRoute()
{
    entries = self _entries();
    mapID = openCJ\mapID::getMapID();
    routeNameSql = openCJ\util::dbStr(self.cpc.route);
    lockedMapRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT mapID FROM mapids WHERE mapID=" + mapID + " FOR UPDATE");
    if (!isDefined(lockedMapRows) || lockedMapRows.size != 1)
    {
        return self _fail("Cannot lock map for publishing");
    }
    existingAreas = readExistingAreas(mapID, routeNameSql);
    if (!isDefined(existingAreas))
    {
        return self _fail("Cannot read published checkpoint IDs");
    }
    migration = undefined;
    if (existingAreas.size > 0)
    {
        if (self unchangedPublished(entries, existingAreas))
        {
            // Geometry equality does not imply that the selected route color is unchanged.
            return self _writeRouteColor(existingAreas[0].id);
        }
        migration = self openCJ\checkpointMigration::prepare(entries, existingAreas);
        if (!isDefined(migration))
        {
            return false;
        }
        existingAreas = migration.existing;
    }
    else
    {
        collisionRows = openCJ\mySQL::mysqlSyncQuery(
            "SELECT c.cpID FROM checkpoints c " +
            "JOIN routes r ON r.routeID=c.finishRouteID " +
            "WHERE c.mapID=" + mapID + " AND r.routeName=" + routeNameSql + " LIMIT 1");
        if (!isDefined(collisionRows) || collisionRows.size > 0)
        {
            return self _fail(
                "An existing route already uses that name; it will not be overwritten");
        }
    }
    routeID = self ensureRouteIdentity(mapID, routeNameSql);
    if (!isDefined(routeID))
    {
        return false;
    }
    rebuildConnections = existingAreas.size == 0 || isDefined(migration);
    layout = self writeAreas(entries, existingAreas, routeID, mapID, rebuildConnections);
    if (!isDefined(layout))
    {
        return false;
    }
    if (rebuildConnections && !self connectGroups(layout.groups))
    {
        return false;
    }
    return self _writeRouteColor(layout.ids[0]);
}

// IDs and optional brother/finish references are decoded at the SQL boundary.
readExistingAreas(mapID, routeNameSql)
{
    rows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT cpID," +
        "(SELECT bigBrotherID FROM checkpointBrothers b WHERE b.cpID=checkpointAreas.cpID)," +
        "(SELECT finishRouteID FROM checkpoints c WHERE c.cpID=checkpointAreas.cpID) " +
        "FROM checkpointAreas " +
        "WHERE mapID=" + mapID + " AND draftName=" + routeNameSql + " ORDER BY ordinal");
    if (!isDefined(rows))
    {
        return undefined;
    }
    existingAreas = [];
    for (i = 0; i < rows.size; i++)
    {
        area = spawnStruct();
        area.id = int(rows[i][0]);
        area.bigBrotherId = rows[i][1];
        area.finishRouteId = rows[i][2];
        existingAreas[i] = area;
    }
    return existingAreas;
}

// Return the stable route ID after creating it if needed; undefined means publication failed.
ensureRouteIdentity(mapID, routeNameSql)
{
    inserted = openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO routes(mapID,routeName) VALUES (" + mapID + "," + routeNameSql + ") " +
        "ON DUPLICATE KEY UPDATE routeID=LAST_INSERT_ID(routeID)");
    if (!isDefined(inserted))
    {
        self _fail("Cannot create route identity");
        return undefined;
    }
    routeRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT routeID FROM routes WHERE mapID=" + mapID + " AND routeName=" + routeNameSql);
    if (!isDefined(routeRows) || routeRows.size != 1)
    {
        self _fail("Cannot read route identity");
        return undefined;
    }
    return int(routeRows[0][0]);
}

// Persist each area in ordinal order, so alternative leaders always have their IDs first.
writeAreas(entries, existingAreas, routeID, mapID, rebuildConnections)
{
    layout = spawnStruct();
    layout.ids = [];
    layout.groups = [];
    for (i = 0; i < self.cpc.rows.size; i++)
    {
        layout.groups[i] = [];
    }
    for (i = 0; i < entries.size; i++)
    {
        existingId = undefined;
        if (existingAreas.size > 0)
        {
            existingId = existingAreas[i].id;
        }
        checkpointId = self writeCheckpoint(entries[i].cp, entries[i].points, mapID,
                                             routeID, existingId);
        if (!isDefined(checkpointId))
        {
            return undefined;
        }
        layout.ids[i] = checkpointId;
        groupIndex = entries[i].group;
        layout.groups[groupIndex][layout.groups[groupIndex].size] = checkpointId;
        if (!self writeArea(entries[i], checkpointId, i, mapID))
        {
            return undefined;
        }
        if (rebuildConnections && entries[i].leader != i)
        {
            primaryId = layout.ids[entries[i].leader];
            linked = openCJ\mySQL::mysqlSyncQuery(
                "INSERT INTO checkpointBrothers (cpID,bigBrotherID) VALUES (" +
                checkpointId + "," + primaryId + ")");
            if (!isDefined(linked))
            {
                self _fail("Failed to link alternative area");
                return undefined;
            }
        }
    }
    return layout;
}

// Preserve an existing checkpoint ID when moving geometry; new areas receive a fresh ID.
writeCheckpoint(checkpoint, points, mapID, routeID, existingId)
{
    origin = (0, 0, 0);
    for (i = 0; i < points.size; i++)
    {
        origin += points[i];
    }
    origin = vectorScale(origin, 1.0 / points.size);
    finishRouteIdSql = "NULL";
    if (checkpoint.finish)
    {
        finishRouteIdSql = "" + routeID;
    }
    values = "x=" + int(origin[0]) + ",y=" + int(origin[1]) + ",z=" + int(origin[2]) +
             ",radius=NULL,elevate=" + int(checkpoint.allowEle) +
             ",allowSave=" + int(checkpoint.allowSave) + ",onGround=" + int(checkpoint.onGround) +
             ",finishRouteID=" + finishRouteIdSql;
    if (isDefined(existingId))
    {
        updated = openCJ\mySQL::mysqlSyncQuery(
            "UPDATE checkpoints SET " + values + " WHERE cpID=" + existingId);
        if (!isDefined(updated))
        {
            self _fail("Failed to update checkpoint");
            return undefined;
        }
        return existingId;
    }
    inserted = openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO checkpoints SET mapID=" + mapID + "," + values);
    if (!isDefined(inserted))
    {
        self _fail("Failed to insert checkpoint; transaction rolled back");
        return undefined;
    }
    idRows = openCJ\mySQL::mysqlSyncQuery("SELECT LAST_INSERT_ID()");
    if (!isDefined(idRows) || idRows.size != 1)
    {
        self _fail("Failed to obtain checkpoint ID");
        return undefined;
    }
    return int(idRows[0][0]);
}

writeArea(entry, checkpointId, ordinal, mapID)
{
    checkpoint = entry.cp;
    verticesSql = openCJ\util::dbStr(openCJ\checkpointArea::encode(entry.points));
    saved = openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO checkpointAreas (cpID,mapID,draftName,ordinal,vertices,allowDoubleRPG) " +
        "VALUES (" + checkpointId + "," + mapID + "," + openCJ\util::dbStr(self.cpc.route) + "," +
        ordinal + "," + verticesSql + "," + int(checkpoint.double) + ") " +
        "ON DUPLICATE KEY UPDATE vertices=VALUES(vertices),allowDoubleRPG=VALUES(allowDoubleRPG)");
    if (!isDefined(saved))
    {
        return self _fail("Failed to save checkpoint area");
    }
    platformRefSql = "NULL";
    if (openCJ\checkpointMoving::isMoving(checkpoint))
    {
        platformRefSql = openCJ\util::dbStr(checkpoint.platformRef);
    }
    updated = openCJ\mySQL::mysqlSyncQuery(
        "UPDATE checkpointAreas " +
        "SET heightAbove=" + floatToPreciseString(checkpoint.heightAbove) +
        ",platformRef=" + platformRefSql + " WHERE cpID=" + checkpointId);
    if (!isDefined(updated))
    {
        return self _fail("Cannot store checkpoint height/platform; install migrations 013 and 014");
    }
    return true;
}

// Finish groups all branch from the last ordinary group, rather than chaining finishes.
connectGroups(groups)
{
    parentGroupIndex = 0;
    firstCheckpoint = self openCJ\checkpointCreation::getConfirmed(0);
    for (i = 1; i < groups.size; i++)
    {
        previousCheckpoint = self openCJ\checkpointCreation::getConfirmed(i - 1);
        if (!previousCheckpoint.finish)
        {
            parentGroupIndex = i - 1;
        }
        else if (firstCheckpoint.finish)
        {
            continue;
        }
        if (!self connectGroupAreas(groups[parentGroupIndex], groups[i]))
        {
            return false;
        }
    }
    return true;
}

connectGroupAreas(parentIds, childIds)
{
    for (i = 0; i < parentIds.size; i++)
    {
        for (j = 0; j < childIds.size; j++)
        {
            connected = openCJ\mySQL::mysqlSyncQuery(
                "INSERT INTO checkpointConnections (cpID,childcpID) VALUES (" +
                parentIds[i] + "," + childIds[j] + ")");
            if (!isDefined(connected))
            {
                return self _fail("Failed to connect checkpoint groups");
            }
        }
    }
    return true;
}

// Save presentation metadata even when geometry did not require a migration.
_writeRouteColor(startCheckpointId)
{
    routeHex = self.cpc.routeHex;
    if (!isDefined(routeHex))
    {
        routeHex = openCJ\checkpointCreation::defaultRouteColor(self.cpc.route);
    }
    color = openCJ\checkpointCreation::routeRGB(routeHex);
    if (!isDefined(color))
    {
        return self _fail("Invalid route color; draft retained");
    }
    packedColor = packRouteColor(color);
    result = openCJ\mySQL::mysqlSyncQuery(
        "UPDATE routes " +
        "SET cpID=" + startCheckpointId + ",colorRGB=" + packedColor +
        " WHERE mapID=" + openCJ\mapID::getMapID() +
        " AND routeName=" + openCJ\util::dbStr(self.cpc.route));
    if (!isDefined(result))
    {
        return self _fail("Failed to store route color; transaction rolled back");
    }
    return true;
}

// Store normalized RGB channels as the existing 24-bit database color value.
packRouteColor(color)
{
    maximumColorChannel = 255;
    redByteMultiplier = 65536;
    greenByteMultiplier = 256;
    packedColor = int(color[0] * maximumColorChannel + 0.5) * redByteMultiplier +
                  int(color[1] * maximumColorChannel + 0.5) * greenByteMultiplier +
                  int(color[2] * maximumColorChannel + 0.5);
    return packedColor;
}

// Flatten logical checkpoints into areas. cp holds shared requirements; group and leader are indices.
_entries()
{
    entries = [];
    for (i = 0; i < self.cpc.rows.size; i++)
    {
        checkpoint = self openCJ\checkpointCreation::getConfirmed(i);
        primaryEntryIndex = entries.size;
        for (j = 0; j <= checkpoint.alternatives.size; j++)
        {
            entry = spawnStruct();
            entry.cp = checkpoint;
            entry.group = i;
            entry.leader = primaryEntryIndex;
            entry.points = checkpoint.points;
            if (j > 0)
            {
                entry.points = checkpoint.alternatives[j - 1];
            }
            entries[entries.size] = entry;
        }
    }
    return entries;
}

_fail(message)
{
    self.cpc.status = message;
    return false;
}

// Attach editable area metadata to the already-loaded checkpoint graph.
// Older installations may lack area/section tables; their ordinary checkpoints still work.
loadAreas()
{
    level.checkpointRoutes = [];
    if (getCodVersion() != 4)
    {
        return;
    }
    areaTables = openCJ\mySQL::mysqlSyncQuery("SHOW TABLES LIKE 'checkpointAreas'");
    if (!isDefined(areaTables) || areaTables.size == 0)
    {
        return;
    }
    loadRouteColors();
    areaRows = readAreaMetadata(openCJ\mapID::getMapID());
    if (!isDefined(areaRows))
    {
        return;
    }
    for (i = 0; i < areaRows.size; i++)
    {
        checkpointId = int(areaRows[i][0]);
        vertices = areaRows[i][1];
        allowDoubleRpg = int(areaRows[i][2]);
        draftName = areaRows[i][3];
        sectionColorHex = areaRows[i][4];
        platformRef = areaRows[i][5];
        heightAbove = float(areaRows[i][6]);
        checkpoint = openCJ\checkpoints::getCheckpointByID(checkpointId);
        points = openCJ\checkpointArea::decode(vertices);
        if (!isDefined(checkpoint) || !isDefined(points))
        {
            continue;
        }
        if (!isDefined(platformRef) && openCJ\checkpointArea::validate(points) != "")
        {
            continue;
        }
        checkpoint.area = points;
        checkpoint.heightAbove = heightAbove;
        if (isDefined(platformRef))
        {
            checkpoint.platformRef = platformRef;
        }
        checkpoint.allowDoubleRPG = allowDoubleRpg;
        checkpoint.routeInfo = level.checkpointRoutes[draftName];
        if (isDefined(sectionColorHex))
        {
            sectionInfo = spawnStruct();
            sectionInfo.name = draftName;
            sectionInfo.hex = toLower(sectionColorHex);
            sectionInfo.color = openCJ\checkpointCreation::routeRGB(sectionInfo.hex);
            checkpoint.routeInfo = sectionInfo;
        }
    }
}

loadRouteColors()
{
    colorColumns = openCJ\mySQL::mysqlSyncQuery("SHOW COLUMNS FROM routes LIKE 'colorRGB'");
    if (!isDefined(colorColumns) || colorColumns.size == 0)
    {
        return;
    }
    routeRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT r.cpID,r.routeName,CONCAT('#',LPAD(HEX(r.colorRGB),6,'0')) " +
        "FROM routes r JOIN checkpoints c ON c.cpID=r.cpID " +
        "WHERE c.mapID=" + openCJ\mapID::getMapID() + " AND r.colorRGB IS NOT NULL");
    if (!isDefined(routeRows))
    {
        return;
    }
    for (i = 0; i < routeRows.size; i++)
    {
        routeInfo = spawnStruct();
        routeInfo.startID = int(routeRows[i][0]);
        routeInfo.name = routeRows[i][1];
        routeInfo.hex = toLower(routeRows[i][2]);
        routeInfo.color = openCJ\checkpointCreation::routeRGB(routeInfo.hex);
        level.checkpointRoutes[routeInfo.name] = routeInfo;
    }
}

readAreaMetadata(mapID)
{
    sectionColumns = openCJ\mySQL::mysqlSyncQuery(
        "SHOW COLUMNS FROM checkpointAreas LIKE 'sectionName'");
    query =
        "SELECT cpID,vertices,allowDoubleRPG,draftName,NULL,platformRef,heightAbove " +
        "FROM checkpointAreas WHERE mapID=" + mapID;
    if (isDefined(sectionColumns) && sectionColumns.size)
    {
        query =
            "SELECT a.cpID,a.vertices,a.allowDoubleRPG,a.draftName," +
            "CONCAT('#',LPAD(HEX(s.colorRGB),6,'0')),a.platformRef,a.heightAbove " +
            "FROM checkpointAreas a " +
            "LEFT JOIN checkpointSectionColors s ON s.mapID=a.mapID AND s.sectionName=a.sectionName " +
            "WHERE a.mapID=" + mapID;
    }
    return openCJ\mySQL::mysqlSyncQuery(query);
}

// Compare persisted geometry and requirements before deciding whether a migration is needed.
// Route color is written separately even when every checkpoint is unchanged.
unchangedPublished(entries, existingAreas)
{
    if(entries.size != existingAreas.size)
    {
        return false;
    }
    areaRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT a.vertices,a.allowDoubleRPG,c.onGround,c.finishRouteID,c.allowSave," +
        "c.elevate,a.platformRef,a.heightAbove,r.routeName " +
        "FROM checkpointAreas a " +
        "JOIN checkpoints c ON c.cpID=a.cpID " +
        "LEFT JOIN routes r ON r.routeID=c.finishRouteID " +
        "WHERE a.mapID=" + openCJ\mapID::getMapID() +
        " AND a.draftName=" + openCJ\util::dbStr(self.cpc.route) + " ORDER BY a.ordinal");
    if(!isDefined(areaRows) || areaRows.size != entries.size)
    {
        return false;
    }
    for(i = 0; i < entries.size; i++)
    {
        storedPoints = openCJ\checkpointArea::decode(areaRows[i][0]);
        storedDoubleRpg = int(areaRows[i][1]);
        storedOnGround = int(areaRows[i][2]);
        storedFinishRouteId = areaRows[i][3];
        storedAllowSave = int(areaRows[i][4]);
        storedAllowEle = int(areaRows[i][5]);
        storedPlatformRef = areaRows[i][6];
        storedHeightAbove = float(areaRows[i][7]);
        storedRouteName = areaRows[i][8];
        checkpoint = entries[i].cp;
        if(!isDefined(storedPoints) || storedPoints.size != entries[i].points.size ||
           storedDoubleRpg != int(checkpoint.double) || storedOnGround != int(checkpoint.onGround))
        {
            return false;
        }
        if(storedAllowSave != int(checkpoint.allowSave) || storedAllowEle != int(checkpoint.allowEle))
        {
            return false;
        }
        if(isDefined(storedPlatformRef) != openCJ\checkpointMoving::isMoving(checkpoint))
        {
            return false;
        }
        if(isDefined(storedPlatformRef) && storedPlatformRef != checkpoint.platformRef)
        {
            return false;
        }
        if(storedHeightAbove != checkpoint.heightAbove ||
           checkpoint.finish != isDefined(storedFinishRouteId))
        {
            return false;
        }
        if(checkpoint.finish && storedRouteName != self.cpc.route)
        {
            return false;
        }
        maximumPointDifferenceSquared = 0.0001;
        for(j = 0; j < storedPoints.size; j++)
        {
            if(distanceSquared(storedPoints[j], entries[i].points[j]) > maximumPointDifferenceSquared)
            {
                return false;
            }
        }
        primaryEntryIndex = entries[i].leader;
        storedLeaderId = existingAreas[i].bigBrotherId;
        if(primaryEntryIndex == i && isDefined(storedLeaderId))
        {
            return false;
        }
        if(primaryEntryIndex != i && (!isDefined(storedLeaderId) ||
                                    int(storedLeaderId) != existingAreas[primaryEntryIndex].id))
        {
            return false;
        }
    }
    return true;
}
