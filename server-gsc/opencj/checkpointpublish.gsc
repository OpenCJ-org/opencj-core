// Publish a complete sequential route into the existing checkpoint graph.
// The caller holds the editor operation (checkpointOperation). Statements run in one
// asynchronous transaction, so this waits for the database over several server frames.
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
    if (!self openCJ\checkpointOperation::openTransaction())
    {
        self.cpc.status = "Database busy; cannot start publication. Draft retained";
        return false;
    }
    if (!self _writeRoute())
    {
        self openCJ\checkpointOperation::rollback();
        self iprintln(self.cpc.status);
        return false;
    }
    if (!isDefined(self openCJ\checkpointOperation::query(
            "CALL rebuildCheckpointRoutes(" + openCJ\mapID::getMapID() + ")")))
    {
        self openCJ\checkpointOperation::rollback();
        self.cpc.status = "Cannot rebuild route membership; draft retained";
        self iprintln(self.cpc.status);
        return false;
    }
    return self commitPublication(
        "Cannot confirm database commit; draft retained. Check the published route.");
}

// Commit the editor transaction after repeating the replacement checks that SQL waits
// could have invalidated. Returns true only when the database confirmed the commit;
// unconfirmedStatus is shown when the reply was lost and the commit may have happened.
commitPublication(unconfirmedStatus)
{
    blocker = self openCJ\checkpointMigration::replacementsBlocker();
    if (blocker != "")
    {
        self openCJ\checkpointOperation::rollback();
        return self _fail(blocker);
    }
    outcome = self openCJ\checkpointOperation::commit();
    if (outcome == level.sqlConstants.outcomeOK)
    {
        return true;
    }
    if (outcome == level.sqlConstants.outcomeUnknown)
    {
        // A missing reply does not prove that COMMIT failed. A retry rechecks the saved layout.
        return self _fail(unconfirmedStatus);
    }
    return self _fail("Database rolled back the publication; draft retained");
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
// The reload reads synchronously, like map start, so all players switch in one frame.
activate()
{
    if (!refreshGameplayRoutes())
    {
        return false;
    }
    self openCJ\challenges::onRoutesPublished();
    return true;
}

// Refresh gameplay after a COMMIT whose editor disconnected before its reply. Challenge
// links, which report to the editor, wait for the next publication or map start.
refreshAfterCommit(transaction)
{
    outcome = openCJ\mySQL::awaitCommit(transaction);
    if (outcome == level.sqlConstants.outcomeOK || outcome == level.sqlConstants.outcomeUnknown)
    {
        refreshGameplayRoutes();
    }
}

// Reload the published graph and move every player's references onto it.
refreshGameplayRoutes()
{
    if (!openCJ\checkpoints::onInit())
    {
        return false;
    }
    level thread openCJ\mapRoutes::refresh();
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
    return true;
}

_writeRoute()
{
    if (isDefined(self.cpc.sharedRoute))
    {
        return self openCJ\checkpointBranch::publish();
    }
    return self _writeSequentialRoute();
}

// The caller owns the editor transaction. Lock before inspecting the existing graph.
_writeSequentialRoute()
{
    entries = self _entries();
    mapID = openCJ\mapID::getMapID();
    routeNameSql = openCJ\util::dbStr(self.cpc.route);
    lockedMapRows = self openCJ\checkpointOperation::query(
        "SELECT mapID FROM mapids WHERE mapID=" + mapID + " FOR UPDATE");
    if (!isDefined(lockedMapRows) || lockedMapRows.size != 1)
    {
        return self _fail("Cannot lock map for publishing");
    }
    existingAreas = self readExistingAreas(mapID, routeNameSql);
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
        collisionRows = self openCJ\checkpointOperation::query(
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
    layout = self areaWrites(entries, existingAreas, routeID, mapID, rebuildConnections);
    statements = layout.statements;
    if (rebuildConnections)
    {
        statements = self addGroupConnections(statements, layout.groups);
    }
    colorStatement = self routeColorStatement(layout.areaIdsSql[0]);
    if (!isDefined(colorStatement))
    {
        return false;
    }
    statements[statements.size] = colorStatement;
    // All writes of the route go together: one database round trip, not one per statement.
    return isDefined(self openCJ\checkpointOperation::batch(statements));
}

// IDs and optional brother/finish references are decoded at the SQL boundary.
readExistingAreas(mapID, routeNameSql)
{
    rows = self openCJ\checkpointOperation::query(
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
    statements = [];
    statements[0] = openCJ\checkpointOperation::statement(
        "INSERT INTO routes(mapID,routeName) VALUES (" + mapID + "," + routeNameSql + ") " +
        "ON DUPLICATE KEY UPDATE routeID=LAST_INSERT_ID(routeID)",
        "Cannot create route identity");
    statements[1] = openCJ\checkpointOperation::statement(
        "SELECT routeID FROM routes WHERE mapID=" + mapID + " AND routeName=" + routeNameSql,
        "Cannot read route identity");
    rowsets = self openCJ\checkpointOperation::batch(statements);
    if (!isDefined(rowsets))
    {
        return undefined;
    }
    routeRows = rowsets[1];
    if (routeRows.size != 1)
    {
        self _fail("Cannot read route identity");
        return undefined;
    }
    return int(routeRows[0][0]);
}

// Connection variable holding the checkpoint ID that a new area's INSERT created.
// Variables live on the transaction's connection until later statements read them.
newAreaIdVariable(areaIndex)
{
    return "@cpcArea" + areaIndex;
}

// Build the statements that store every area, in ordinal order so alternative leaders
// get their IDs before their alternatives reference them. The returned layout holds
// the statements, each area's checkpoint ID as SQL (a kept ID or the variable set by
// its INSERT) and the areas of each logical checkpoint.
areaWrites(entries, existingAreas, routeID, mapID, rebuildConnections)
{
    layout = spawnStruct();
    layout.statements = [];
    layout.areaIdsSql = [];
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
        layout.statements = self addCheckpointStatements(layout.statements, entries[i], i,
                                                         existingId, mapID, routeID);
        areaIdSql = newAreaIdVariable(i);
        if (isDefined(existingId))
        {
            areaIdSql = "" + existingId;
        }
        layout.areaIdsSql[i] = areaIdSql;
        groupIndex = entries[i].group;
        layout.groups[groupIndex][layout.groups[groupIndex].size] = areaIdSql;
        layout.statements[layout.statements.size] = self areaStatement(entries[i], areaIdSql, i,
                                                                       mapID);
        if (rebuildConnections && entries[i].leader != i)
        {
            primaryIdSql = layout.areaIdsSql[entries[i].leader];
            layout.statements[layout.statements.size] = openCJ\checkpointOperation::statement(
                "INSERT INTO checkpointBrothers (cpID,bigBrotherID) " +
                "VALUES (" + areaIdSql + "," + primaryIdSql + ")",
                "Failed to link alternative area");
        }
    }
    return layout;
}

// Preserve an existing checkpoint ID when moving geometry. A new area's INSERT keeps its
// fresh ID in the area's connection variable instead of a separate ID query.
addCheckpointStatements(statements, entry, areaIndex, existingId, mapID, routeID)
{
    checkpoint = entry.cp;
    points = entry.points;
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
        statements[statements.size] = openCJ\checkpointOperation::statement(
            "UPDATE checkpoints SET " + values + " WHERE cpID=" + existingId,
            "Failed to update checkpoint");
        return statements;
    }
    statements[statements.size] = openCJ\checkpointOperation::statement(
        "INSERT INTO checkpoints SET mapID=" + mapID + "," + values,
        "Failed to insert checkpoint; transaction rolled back");
    statements[statements.size] = openCJ\checkpointOperation::statement(
        "SET " + newAreaIdVariable(areaIndex) + "=LAST_INSERT_ID()",
        "Failed to obtain checkpoint ID");
    return statements;
}

// Store an area's geometry, height and platform in one statement.
areaStatement(entry, areaIdSql, ordinal, mapID)
{
    checkpoint = entry.cp;
    verticesSql = openCJ\util::dbStr(openCJ\checkpointArea::encode(entry.points));
    platformRefSql = "NULL";
    if (openCJ\checkpointMoving::isMoving(checkpoint))
    {
        platformRefSql = openCJ\util::dbStr(checkpoint.platformRef);
    }
    return openCJ\checkpointOperation::statement(
        "INSERT INTO checkpointAreas " +
        "(cpID,mapID,draftName,ordinal,vertices,allowDoubleRPG,heightAbove,platformRef) " +
        "VALUES (" + areaIdSql + "," + mapID + "," + openCJ\util::dbStr(self.cpc.route) + "," +
        ordinal + "," + verticesSql + "," + int(checkpoint.double) + "," +
        floatToPreciseString(checkpoint.heightAbove) + "," + platformRefSql + ") " +
        "ON DUPLICATE KEY UPDATE vertices=VALUES(vertices),allowDoubleRPG=VALUES(allowDoubleRPG)," +
        "heightAbove=VALUES(heightAbove),platformRef=VALUES(platformRef)",
        "Failed to save checkpoint area");
}

// Finish groups all branch from the last ordinary group, rather than chaining finishes.
// groups holds each logical checkpoint's area IDs as SQL.
addGroupConnections(statements, groups)
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
        statements[statements.size] = groupConnectionStatement(groups[parentGroupIndex],
                                                               groups[i]);
    }
    return statements;
}

// One multi-row INSERT links every parent area to every child area.
groupConnectionStatement(parentIdsSql, childIdsSql)
{
    connectionRowsSql = "";
    for (i = 0; i < parentIdsSql.size; i++)
    {
        for (j = 0; j < childIdsSql.size; j++)
        {
            if (connectionRowsSql != "")
            {
                connectionRowsSql += ",";
            }
            connectionRowsSql += "(" + parentIdsSql[i] + "," + childIdsSql[j] + ")";
        }
    }
    return openCJ\checkpointOperation::statement(
        "INSERT INTO checkpointConnections (cpID,childcpID) VALUES " + connectionRowsSql,
        "Failed to connect checkpoint groups");
}

// Save presentation metadata even when geometry did not require a migration.
_writeRouteColor(startCheckpointId)
{
    colorStatement = self routeColorStatement("" + startCheckpointId);
    if (!isDefined(colorStatement))
    {
        return false;
    }
    statements = [];
    statements[0] = colorStatement;
    return isDefined(self openCJ\checkpointOperation::batch(statements));
}

// Build the route's start/color update, or return undefined for an invalid color.
routeColorStatement(startCheckpointIdSql)
{
    routeHex = self.cpc.routeHex;
    if (!isDefined(routeHex))
    {
        routeHex = openCJ\checkpointCreation::defaultRouteColor(self.cpc.route);
    }
    color = openCJ\checkpointCreation::routeRGB(routeHex);
    if (!isDefined(color))
    {
        self _fail("Invalid route color; draft retained");
        return undefined;
    }
    packedColor = packRouteColor(color);
    return openCJ\checkpointOperation::statement(
        "UPDATE routes " +
        "SET cpID=" + startCheckpointIdSql + ",colorRGB=" + packedColor +
        " WHERE mapID=" + openCJ\mapID::getMapID() +
        " AND routeName=" + openCJ\util::dbStr(self.cpc.route),
        "Failed to store route color; transaction rolled back");
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
    if (getCodVersion() != 4)
    {
        level.checkpointRoutes = [];
        return true;
    }
    areaTables = openCJ\mySQL::mysqlSyncQuery("SHOW TABLES LIKE 'checkpointAreas'");
    if (!isDefined(areaTables))
    {
        return false;
    }
    if (areaTables.size == 0)
    {
        level.checkpointRoutes = [];
        return true;
    }
    routeColors = loadRouteColors();
    if (!isDefined(routeColors))
    {
        return false;
    }
    areaRows = readAreaMetadata(openCJ\mapID::getMapID());
    if (!isDefined(areaRows))
    {
        return false;
    }
    level.checkpointRoutes = routeColors;
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
    return true;
}

loadRouteColors()
{
    colorColumns = openCJ\mySQL::mysqlSyncQuery("SHOW COLUMNS FROM routes LIKE 'colorRGB'");
    if (!isDefined(colorColumns))
    {
        return undefined;
    }
    routeColors = [];
    if (colorColumns.size == 0)
    {
        return routeColors;
    }
    routeRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT r.cpID,r.routeName,CONCAT('#',LPAD(HEX(r.colorRGB),6,'0')) " +
        "FROM routes r JOIN checkpoints c ON c.cpID=r.cpID " +
        "WHERE c.mapID=" + openCJ\mapID::getMapID() + " AND r.colorRGB IS NOT NULL");
    if (!isDefined(routeRows))
    {
        return undefined;
    }
    for (i = 0; i < routeRows.size; i++)
    {
        routeInfo = spawnStruct();
        routeInfo.startID = int(routeRows[i][0]);
        routeInfo.name = routeRows[i][1];
        routeInfo.hex = toLower(routeRows[i][2]);
        routeInfo.color = openCJ\checkpointCreation::routeRGB(routeInfo.hex);
        routeColors[routeInfo.name] = routeInfo;
    }
    return routeColors;
}

readAreaMetadata(mapID)
{
    sectionColumns = openCJ\mySQL::mysqlSyncQuery(
        "SHOW COLUMNS FROM checkpointAreas LIKE 'sectionName'");
    if (!isDefined(sectionColumns))
    {
        return undefined;
    }
    query =
        "SELECT cpID,vertices,allowDoubleRPG,draftName,NULL,platformRef,heightAbove " +
        "FROM checkpointAreas WHERE mapID=" + mapID;
    if (sectionColumns.size)
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
    areaRows = self openCJ\checkpointOperation::query(
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
