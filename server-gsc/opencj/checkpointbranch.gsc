#include openCJ\util;

// Publish saved CPC branch drafts inside the caller's transaction.
// Current split commands create section networks; this path preserves older saved drafts.
publish()
{
    branchDraft = self.cpc;
    sharedCount = branchDraft.sharedCount;
    if (!isDefined(sharedCount) || sharedCount < 1 || sharedCount >= branchDraft.rows.size)
    {
        return self openCJ\checkpointPublish::_fail(
            "Add this branch's checkpoints and Finish before finalizing");
    }
    sharedColor = branchDraft.sharedHex;
    if (!isDefined(sharedColor))
    {
        sharedColor = openCJ\checkpointCreation::defaultRouteColor(branchDraft.sharedRoute);
    }
    opening = publicationSection(branchDraft.sharedRoute, sharedColor, branchDraft.rows,
                                 0, sharedCount);
    self.cpc = opening;
    parentIds = self ensurePrefix();
    publicationStatus = self.cpc.status;
    self.cpc = branchDraft;
    if (!isDefined(parentIds))
    {
        return self openCJ\checkpointPublish::_fail(publicationStatus);
    }

    suffix = publicationSection(branchDraft.route, branchDraft.routeHex, branchDraft.rows,
                                sharedCount, branchDraft.rows.size);
    // The publisher reads self.cpc. Restore the player's complete draft on both outcomes.
    self.cpc = suffix;
    saved = self openCJ\checkpointPublish::_writeSequentialRoute();
    publicationStatus = self.cpc.status;
    self.cpc = branchDraft;
    if (!saved)
    {
        return self openCJ\checkpointPublish::_fail(publicationStatus);
    }
    firstCheckpoint = openCJ\checkpointCreation::_decode(suffix.rows[0]);
    return self connectBranch(parentIds, firstCheckpoint.alternatives.size + 1);
}

publicationSection(routeName, routeColor, rows, startIndex, endIndex)
{
    section = spawnStruct();
    section.route = routeName;
    section.routeHex = routeColor;
    section.rows = [];
    for (i = startIndex; i < endIndex; i++)
    {
        section.rows[section.rows.size] = rows[i];
    }
    return section;
}

// Connect every final shared area to every first branch area, including alternatives.
connectBranch(parentIds, firstGroupAreaCount)
{
    childRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT cpID FROM checkpointAreas " +
        "WHERE mapID=" + openCJ\mapID::getMapID() +
        " AND draftName=" + dbStr(self.cpc.route) +
        " ORDER BY ordinal LIMIT " + firstGroupAreaCount);
    if (!isDefined(childRows) || childRows.size != firstGroupAreaCount)
    {
        return self openCJ\checkpointPublish::_fail("Cannot read branch connection IDs");
    }
    for (i = 0; i < parentIds.size; i++)
    {
        parentId = parentIds[i];
        for (j = 0; j < childRows.size; j++)
        {
            childId = int(childRows[j][0]);
            // This legacy edge table has no unique key; explicitly avoid duplicates.
            query =
                "INSERT INTO checkpointConnections(cpID,childcpID) " +
                "SELECT " + parentId + "," + childId +
                " WHERE NOT EXISTS (SELECT 1 FROM checkpointConnections " +
                "WHERE cpID=" + parentId + " AND childcpID=" + childId + ")";
            if (!isDefined(openCJ\mySQL::mysqlSyncQuery(query)))
            {
                return self openCJ\checkpointPublish::_fail(
                    "Could not connect branch to shared opening");
            }
        }
    }
    return true;
}

// Create the shared opening once, or require an exact match under the map lock.
// Return the final group's checkpoint IDs; undefined leaves the caller to roll back.
ensurePrefix()
{
    mapID = openCJ\mapID::getMapID();
    lockedMapRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT mapID FROM mapids WHERE mapID=" + mapID + " FOR UPDATE");
    if (!isDefined(lockedMapRows) || lockedMapRows.size != 1)
    {
        self.cpc.status = "Cannot lock shared opening";
        return undefined;
    }
    entries = self openCJ\checkpointPublish::_entries();
    for (i = 0; i < entries.size; i++)
    {
        if (entries[i].cp.finish)
        {
            self.cpc.status = "Shared opening contains a Finish";
            return undefined;
        }
    }
    routeNameSql = dbStr(self.cpc.route);
    existingAreas = openCJ\checkpointPublish::readExistingAreas(mapID, routeNameSql);
    if (!isDefined(existingAreas))
    {
        self.cpc.status = "Cannot read shared opening";
        return undefined;
    }
    if (existingAreas.size == 0)
    {
        if (!self openCJ\checkpointPublish::_writeSequentialRoute())
        {
            return undefined;
        }
        // Re-read once; an unexpected empty result must not recursively retry publication.
        existingAreas = openCJ\checkpointPublish::readExistingAreas(mapID, routeNameSql);
        if (!isDefined(existingAreas))
        {
            self.cpc.status = "Cannot read shared opening";
            return undefined;
        }
    }
    if (existingAreas.size != entries.size)
    {
        self.cpc.status = "Shared opening differs from published checkpoints; draft retained";
        return undefined;
    }
    if (!self openCJ\checkpointPublish::unchangedPublished(entries, existingAreas))
    {
        self.cpc.status = "Shared geometry or requirements changed; existing checkpoints preserved";
        return undefined;
    }
    // Shared geometry can stay identical while its explicit opening color changes.
    if (!self openCJ\checkpointPublish::_writeRouteColor(existingAreas[0].id))
    {
        return undefined;
    }
    finalGroupIds = [];
    for (i = 0; i < entries.size; i++)
    {
        if (entries[i].group == self.cpc.rows.size - 1)
        {
            finalGroupIds[finalGroupIds.size] = existingAreas[i].id;
        }
    }
    return finalGroupIds;
}
