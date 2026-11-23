// Pure matching only: one contiguous edit between unchanged endpoints.
plan(oldRows, newRows)
{
    // Drafts may predate precise float serialization. Compare canonical values,
    // not decimal spellings such as 2483.01 versus 2483.01001 (the same float).
    oldRows = canonicalRows(oldRows);
    newRows = canonicalRows(newRows);
    if(!isDefined(oldRows) || !isDefined(newRows))
    {
        return undefined;
    }
    if(oldRows.size < 2 || newRows.size < 2 || oldRows[0] != newRows[0] ||
       oldRows[oldRows.size - 1] != newRows[newRows.size - 1])
    {
        return undefined;
    }
    firstChangedIndex = 0;
    while(firstChangedIndex < oldRows.size && firstChangedIndex < newRows.size &&
          oldRows[firstChangedIndex] == newRows[firstChangedIndex])
    {
        firstChangedIndex++;
    }
    unchangedSuffixCount = 0;
    while(unchangedSuffixCount < oldRows.size - firstChangedIndex &&
          unchangedSuffixCount < newRows.size - firstChangedIndex &&
          oldRows[oldRows.size - 1 - unchangedSuffixCount] ==
              newRows[newRows.size - 1 - unchangedSuffixCount])
    {
        unchangedSuffixCount++;
    }
    maximumInsertedOrDeletedCheckpoints = 3;
    removedCount = oldRows.size - firstChangedIndex - unchangedSuffixCount;
    addedCount = newRows.size - firstChangedIndex - unchangedSuffixCount;
    if(removedCount > maximumInsertedOrDeletedCheckpoints ||
       addedCount > maximumInsertedOrDeletedCheckpoints ||
       (removedCount > 0 && addedCount > 0 && (removedCount != 1 || addedCount != 1)))
    {
        return undefined;
    }
    for(i = firstChangedIndex; i < firstChangedIndex + removedCount; i++)
    {
        checkpoint = openCJ\checkpointCreation::_decode(oldRows[i]);
        if(checkpoint.finish)
        {
            return undefined;
        }
        if(!addedCount && !hasDefaultRequirements(checkpoint))
        {
            return undefined;
        }
    }
    for(i = firstChangedIndex; i < firstChangedIndex + addedCount; i++)
    {
        checkpoint = openCJ\checkpointCreation::_decode(newRows[i]);
        if(checkpoint.finish)
        {
            return undefined;
        }
        for(j = 0; j < oldRows.size; j++)
        {
            if(oldRows[j] == newRows[i])
            {
                return undefined;
            }
        }
        if(removedCount == 1 && addedCount == 1)
        {
            previousCheckpoint = openCJ\checkpointCreation::_decode(oldRows[firstChangedIndex]);
            if(!sameRequirements(checkpoint, previousCheckpoint))
            {
                return undefined;
            }
        }
        else if(!hasDefaultRequirements(checkpoint))
        {
            return undefined;
        }
    }
    migrationPlan = spawnStruct();
    migrationPlan.mapping = [];
    for(i = 0; i < newRows.size; i++)
    {
        migrationPlan.mapping[i] = -1;
        if(i < firstChangedIndex)
        {
            migrationPlan.mapping[i] = i;
        }
        else if(i >= newRows.size - unchangedSuffixCount)
        {
            migrationPlan.mapping[i] = oldRows.size - (newRows.size - i);
        }
        else if(removedCount == 1 && addedCount == 1)
        {
            migrationPlan.mapping[i] = firstChangedIndex;
        }
    }
    return migrationPlan;
}

canonicalRows(rows)
{
    canonical = [];
    for(i = 0; i < rows.size; i++)
    {
        checkpoint = openCJ\checkpointCreation::_decode(rows[i]);
        if(!isDefined(checkpoint))
        {
            return undefined;
        }
        canonical[i] = openCJ\checkpointCreation::_encode(checkpoint);
    }
    return canonical;
}

// With no historical references, arbitrary edits need no run migration. Reuse
// IDs by position so the route's start/color identity remains stable.
unusedPlan(oldRows, newRows)
{
    migrationPlan = spawnStruct();
    migrationPlan.mapping = [];
    for(i = 0; i < newRows.size; i++)
    {
        migrationPlan.mapping[i] = -1;
        if(i < oldRows.size)
        {
            migrationPlan.mapping[i] = i;
        }
    }
    return migrationPlan;
}

// Called while publication holds the map row lock. The caller commits or rolls back.
// Keep the recovery file before replacing any layout; historical records retain their IDs.
prepare(entries, existing)
{
    if(isDefined(level.demoPersisting) && level.demoPersisting > 0)
    {
        return self fail("A demo is still saving; retry finalizing shortly");
    }
    mapId = openCJ\mapID::getMapID();
    routeName = self.cpc.route;
    published = self readPublishedDraft(mapId, routeName);
    if(!isDefined(published))
    {
        return undefined;
    }
    migrationPlan = self choosePlan(published, mapId, routeName);
    if(!isDefined(migrationPlan))
    {
        return undefined;
    }
    if(!self canReplaceRoute(published.checkpointIdsSql, routeName))
    {
        return undefined;
    }
    if(!self backUpPublishedDraft(routeName, published.rows))
    {
        return undefined;
    }
    retainedIdsSql = matchExistingAreas(entries, existing, published.groups, migrationPlan);
    if(!self replaceLayout(published.checkpointIdsSql, retainedIdsSql, mapId, routeName))
    {
        return undefined;
    }
    return migrationPlan;
}

// Decode SQL columns once, then combine contiguous alternative areas into logical rows.
readPublishedDraft(mapId, routeName)
{
    areaRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT a.cpID,b.bigBrotherID,c.finishRouteID,a.vertices,a.allowDoubleRPG," +
        "c.onGround,c.allowSave,c.elevate,a.platformRef,a.heightAbove " +
        "FROM checkpointAreas a " +
        "JOIN checkpoints c ON c.cpID=a.cpID " +
        "LEFT JOIN checkpointBrothers b ON b.cpID=a.cpID " +
        "WHERE a.mapID=" + mapId +
        " AND a.draftName=" + openCJ\util::dbStr(routeName) + " ORDER BY a.ordinal");
    if(!isDefined(areaRows) || !areaRows.size)
    {
        return self fail("Cannot read route for migration");
    }
    published = spawnStruct();
    published.rows = [];
    published.groups = [];
    published.checkpointIdsSql = "(";
    checkpointIds = [];
    for(i = 0; i < areaRows.size; i++)
    {
        checkpointId = int(areaRows[i][0]);
        leaderId = areaRows[i][1];
        finishRouteId = areaRows[i][2];
        vertices = areaRows[i][3];
        checkpoint = openCJ\checkpointCreation::_empty();
        checkpoint.points = openCJ\checkpointArea::decode(vertices);
        checkpoint.double = int(areaRows[i][4]);
        checkpoint.onGround = int(areaRows[i][5]);
        checkpoint.allowSave = int(areaRows[i][6]);
        checkpoint.allowEle = int(areaRows[i][7]);
        checkpoint.platformRef = areaRows[i][8];
        checkpoint.heightAbove = float(areaRows[i][9]);
        checkpoint.finish = isDefined(finishRouteId);
        checkpointIds[i] = checkpointId;
        if(i)
        {
            published.checkpointIdsSql += ",";
        }
        published.checkpointIdsSql += checkpointId;
        if(!isDefined(leaderId))
        {
            group = [];
            group[0] = i;
            published.groups[published.groups.size] = group;
            published.rows[published.rows.size] = openCJ\checkpointCreation::_encode(checkpoint);
            continue;
        }
        groupIndex = published.groups.size - 1;
        if(groupIndex < 0 || int(leaderId) != checkpointIds[published.groups[groupIndex][0]])
        {
            return self fail("Complex alternative grouping; draft retained");
        }
        primary = openCJ\checkpointCreation::_decode(published.rows[groupIndex]);
        primary.alternatives[primary.alternatives.size] = checkpoint.points;
        if(!sameRequirements(checkpoint, primary))
        {
            return self fail("Alternative requirements differ; draft retained");
        }
        published.rows[groupIndex] = openCJ\checkpointCreation::_encode(primary);
        published.groups[groupIndex][published.groups[groupIndex].size] = i;
    }
    published.checkpointIdsSql += ")";
    return published;
}

// Routes with history allow only the supported contiguous edit. Unused routes may be rebuilt.
choosePlan(published, mapId, routeName)
{
    migrationPlan = plan(published.rows, self.cpc.rows);
    if(isDefined(migrationPlan))
    {
        return migrationPlan;
    }
    checkpointIdsSql = published.checkpointIdsSql;
    historyRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT EXISTS(SELECT 1 FROM playerRuns WHERE finishcpID IN " + checkpointIdsSql + ")" +
        "+EXISTS(SELECT 1 FROM checkpointStatistics WHERE cpID IN " + checkpointIdsSql + ")" +
        "+EXISTS(SELECT 1 FROM playerSaves WHERE checkpointID IN " + checkpointIdsSql + ")" +
        "+EXISTS(SELECT 1 FROM demoRuns WHERE mapID=" + mapId +
        " AND routeID IN (SELECT routeID FROM routes WHERE mapID=" + mapId +
        " AND routeName=" + openCJ\util::dbStr(routeName) + "))");
    if(!isDefined(historyRows) || historyRows.size != 1)
    {
        return self fail("Cannot check route history; draft retained");
    }
    referenceCount = int(historyRows[0][0]);
    if(referenceCount != 0)
    {
        return self fail(
            "Route has run history: keep start/finish and requirements; change one checkpoint or insert/delete up to 3 together");
    }
    return unusedPlan(published.rows, self.cpc.rows);
}

// Do not detach shared graphs or replace a route while another player's run uses it.
canReplaceRoute(checkpointIdsSql, routeName)
{
    outsideConnections = openCJ\mySQL::mysqlSyncQuery(
        "SELECT cpID FROM checkpointConnections " +
        "WHERE (cpID IN " + checkpointIdsSql +
        " AND childcpID NOT IN " + checkpointIdsSql + ")" + " OR (childcpID IN " +
        checkpointIdsSql + " AND cpID NOT IN " + checkpointIdsSql + ")" +
        " UNION SELECT cpID FROM checkpointBrothers " +
        "WHERE bigBrotherID IN " +
        checkpointIdsSql + " AND cpID NOT IN " + checkpointIdsSql + " LIMIT 1");
    if(!isDefined(outsideConnections) || outsideConnections.size)
    {
        self fail("Shared route connections require manual migration; draft retained");
        return false;
    }
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        player = players[i];
        if(player != self && player openCJ\playerRuns::hasRunID() && isDefined(player.route) &&
           player.route == routeName)
        {
            self fail("Another player has this route open; ask them to reset before finalizing");
            return false;
        }
    }
    return true;
}

// _save writes through self.cpc; restore the active draft even when the backup fails.
backUpPublishedDraft(routeName, oldRows)
{
    activeDraft = self.cpc;
    backup = spawnStruct();
    backup.route = routeName;
    backup.rows = oldRows;
    backup.selected = oldRows.size;
    backup.draft = openCJ\checkpointCreation::_empty();
    backup.revision = 0;
    backup.routeHex = activeDraft.routeHex;
    basePath = activeDraft.path + ".before-migration-" + getTime();
    backup.path = basePath;
    // Match reset's collision budget; never overwrite an earlier recovery snapshot.
    maximumBackupNames = 10000;
    for(suffix = 0; suffix < maximumBackupNames && FS_TestFile(backup.path + ".b"); suffix++)
    {
        backup.path = basePath + "-" + suffix;
    }
    if(suffix == maximumBackupNames)
    {
        self fail("No free migration backup filename; draft and published route retained");
        return false;
    }
    self.cpc = backup;
    saved = self openCJ\checkpointCreation::_save();
    self.cpc = activeDraft;
    if(!saved)
    {
        self fail("Cannot back up finalized geometry; migration cancelled");
    }
    return saved;
}

// Each new area reuses its matching old group/area ID, or has an empty insertion slot.
matchExistingAreas(entries, existing, groups, migrationPlan)
{
    migrationPlan.existing = [];
    retainedIdsSql = "(";
    for(i = 0; i < entries.size; i++)
    {
        existingArea = [];
        oldGroupIndex = migrationPlan.mapping[entries[i].group];
        areaIndex = i - entries[i].leader;
        if(oldGroupIndex >= 0 && areaIndex < groups[oldGroupIndex].size)
        {
            existingArea = existing[groups[oldGroupIndex][areaIndex]];
            checkpointId = int(existingArea[0]);
            if(retainedIdsSql != "(")
            {
                retainedIdsSql += ",";
            }
            retainedIdsSql += checkpointId;
        }
        migrationPlan.existing[i] = existingArea;
    }
    retainedIdsSql += ")";
    return retainedIdsSql;
}

// Replace layout inside the owner's transaction, preserving all historical records.
replaceLayout(checkpointIdsSql, retainedIdsSql, mapId, routeName)
{
    queries = [];
    queries[queries.size] = "UPDATE checkpoints SET retired=1 " +
                            "WHERE cpID IN " +
                            checkpointIdsSql + " AND cpID NOT IN " + retainedIdsSql;
    queries[queries.size] = "DELETE FROM checkpointConnections " +
                            "WHERE cpID IN " +
                            checkpointIdsSql + " AND childcpID IN " + checkpointIdsSql;
    queries[queries.size] = "DELETE FROM checkpointBrothers WHERE cpID IN " + checkpointIdsSql;
    queries[queries.size] = "DELETE FROM checkpointAreas WHERE cpID IN " + checkpointIdsSql;
    queries[queries.size] =
        "UPDATE playerRuns r SET archived=1 " +
        "WHERE r.finishcpID IS NULL " +
        "AND (EXISTS(SELECT 1 FROM checkpointStatistics s WHERE s.runID=r.runID AND s.cpID IN " +
        checkpointIdsSql + ")" +
        " OR EXISTS(SELECT 1 FROM playerSaves s WHERE s.runID=r.runID AND s.checkpointID IN " +
        checkpointIdsSql + "))";
    // Keep old footage, but exclude it from playback and winner comparison.
    archivedDemoState = 2;
    queries[queries.size] = "UPDATE demoRuns SET ready=" + archivedDemoState +
                            " WHERE mapID=" + mapId +
                            " AND routeID IN (SELECT routeID FROM routes WHERE mapID=" + mapId +
                            " AND routeName=" + openCJ\util::dbStr(routeName) + ")";
    for(i = 0; i < queries.size; i++)
    {
        if(!isDefined(openCJ\mySQL::mysqlSyncQuery(queries[i])))
        {
            self fail("Migration failed; transaction rolled back and draft retained");
            return false;
        }
    }
    return true;
}

hasDefaultRequirements(checkpoint)
{
    return checkpoint.heightAbove <= 0 && !checkpoint.double && !checkpoint.allowEle &&
           checkpoint.allowSave && checkpoint.onGround;
}

sameRequirements(first, second)
{
    if(!openCJ\checkpointHeight::same(first, second) || first.double != second.double ||
       first.allowEle != second.allowEle)
    {
        return false;
    }
    return first.allowSave == second.allowSave && first.onGround == second.onGround &&
           first.finish == second.finish;
}

fail(message)
{
    self.cpc.status = message;
    return undefined;
}
