#include openCJ\util;

// Current map only: private draft filenames are restricted to the caller's ID.
show()
{
    // Stop here, not only in the read helper, when the player leaves during the read.
    self endon("disconnect");
    listCooldownMs = 2000;
    if(isDefined(self.cpcListTime) && getTime() - self.cpcListTime < listCooldownMs)
    {
        return;
    }
    self.cpcListTime = getTime();
    routeNameSet = self draftRouteNames();
    network = self openCJ\checkpointNetwork::load();
    sectionNames = [];
    if(isDefined(network))
    {
        routes = getArrayKeys(network.paths);
        for(i = 0; i < routes.size; i++)
        {
            routeNameSet[routes[i]] = true;
            for(j = 0; j < network.paths[routes[i]].sections.size; j++)
            {
                sectionNames[network.paths[routes[i]].sections[j]] = true;
            }
        }
    }
    publishedByRoute = self readPublishedRoutes();
    if(!isDefined(publishedByRoute))
    {
        self sendLocalChatMessage("Could not read published routes; please try again.", true);
        return;
    }
    if(isDefined(level.routeEnders))
    {
        routes = getArrayKeys(level.routeEnders);
        for(i = 0; i < routes.size; i++)
        {
            routeNameSet[routes[i]] = true;
        }
    }
    routeNames = getArrayKeys(routeNameSet);
    displayedCount = 0;
    self sendLocalChatMessage("Checkpoints on " + getCvar("mapname") +
                              ": ^1in progress ^7/ ^2completed^7.");
    for(i = 0; i < routeNames.size; i++)
    {
        displayedCount +=
            self printRouteStatus(routeNames[i], network, sectionNames, publishedByRoute);
    }
    if(!displayedCount)
    {
        self sendLocalChatMessage("No drafts of yours or completed routes on this map yet.");
    }
}

draftName(filename, accountMapPrefix)
{
    if(filename.size <= accountMapPrefix.size + 2 ||
       getSubStr(filename, 0, accountMapPrefix.size) != accountMapPrefix)
    {
        return undefined;
    }
    suffix = getSubStr(filename, filename.size - 2, filename.size);
    if(suffix != ".a" && suffix != ".b")
    {
        return undefined;
    }
    routeName = getSubStr(filename, accountMapPrefix.size, filename.size - 2);
    if(routeName == "network" || !openCJ\checkpointCreation::_validName(routeName))
    {
        return undefined;
    }
    return routeName;
}

part(sectionName)
{
    if(isDefined(self.cpc) && self.cpc.route == sectionName)
    {
        return self.cpc;
    }
    return self openCJ\checkpointNetwork::readSection(sectionName);
}

draft(routeName, network)
{
    if(!isDefined(network) || !isDefined(network.paths[routeName]))
    {
        return self part(routeName);
    }
    routeDraft = spawnStruct();
    routeDraft.rows = [];
    routeDraft.routeHex = network.paths[routeName].hex;
    routeDraft.pending = false;
    for(i = 0; i < network.paths[routeName].sections.size; i++)
    {
        section = self part(network.paths[routeName].sections[i]);
        if(!isDefined(section))
        {
            routeDraft.pending = true;
            continue;
        }
        if(openCJ\checkpointNetwork::pendingEdit(section))
        {
            routeDraft.pending = true;
        }
        for(j = 0; j < section.rows.size; j++)
        {
            routeDraft.rows[routeDraft.rows.size] = section.rows[j];
        }
    }
    return routeDraft;
}

matches(draftSection, publishedRows)
{
    if(!isDefined(publishedRows) || publishedRows.size != draftSection.rows.size)
    {
        return false;
    }
    if(isDefined(draftSection.pending))
    {
        if(draftSection.pending)
        {
            return false;
        }
    }
    else if(openCJ\checkpointNetwork::pendingEdit(draftSection))
    {
        return false;
    }
    for(i = 0; i < publishedRows.size; i++)
    {
        if(!openCJ\checkpointNetwork::sameCheckpoint(
               openCJ\checkpointCreation::_decode(draftSection.rows[i]),
               openCJ\checkpointCreation::_decode(publishedRows[i])))
        {
            return false;
        }
    }
    return true;
}

// Only this account's current-map drafts can become entries in its route list.
draftRouteNames()
{
    accountMapPrefix = self openCJ\login::getPlayerID() + "_" + getCvar("mapname") + "_";
    draftFiles =
        opencjScanDir(getCvar("fs_homepath") + "/" + getCvar("fs_game") + "/checkpoints/drafts");
    routeNameSet = [];
    if(isDefined(draftFiles))
    {
        for(i = 0; i < draftFiles.size; i++)
        {
            routeName = draftName(draftFiles[i], accountMapPrefix);
            if(isDefined(routeName))
            {
                routeNameSet[routeName] = true;
            }
        }
    }
    if(isDefined(self.cpc))
    {
        routeNameSet[self.cpc.route] = true;
    }
    return routeNameSet;
}

// Undefined means the query failed; an empty map means no editable routes were found.
readPublishedRoutes()
{
    publishedByRoute = [];
    if(openCJ\mapID::hasMapID())
    {
        rows = self openCJ\mySQL::mysqlAsyncRead("SELECT draftName, cpID " +
                                                 "FROM checkpointAreas " +
                                                 "WHERE mapID=" + openCJ\mapID::getMapID() +
                                                 " ORDER BY draftName, ordinal");
        if(!isDefined(rows))
        {
            return undefined;
        }
        for(i = 0; i < rows.size; i++)
        {
            routeName = rows[i][0];
            checkpointId = int(rows[i][1]);
            if(!isDefined(publishedByRoute[routeName]))
            {
                publishedByRoute[routeName] = [];
            }
            publishedByRoute[routeName][publishedByRoute[routeName].size] =
                openCJ\checkpoints::getCheckpointByID(checkpointId);
        }
    }
    return publishedByRoute;
}

// Print completed and pending states separately, returning the number of lines shown.
printRouteStatus(routeName, network, sectionNames, publishedByRoute)
{
    displayedCount = 0;
    // Network section files are implementation details, not extra routes.
    if(isDefined(sectionNames[routeName]) && !isDefined(network.paths[routeName]))
    {
        return 0;
    }
    draftSection = self draft(routeName, network);
    isPublished = isDefined(level.routeEnders) && isDefined(level.routeEnders[routeName]);
    if(!isDefined(draftSection) && !isPublished)
    {
        return 0;
    }
    matchesPublished = false;
    if(isPublished && isDefined(draftSection) && isDefined(publishedByRoute[routeName]))
    {
        publishedRows =
            openCJ\checkpointReset::rowsFromActive(publishedByRoute[routeName], routeName);
        matchesPublished = matches(draftSection, publishedRows);
        if(matchesPublished && isDefined(level.checkpointRoutes[routeName]) &&
           isDefined(draftSection.routeHex))
        {
            matchesPublished = draftSection.routeHex == level.checkpointRoutes[routeName].hex;
        }
    }
    if(isPublished)
    {
        self sendLocalChatMessage("^2" + routeName + " - Completed^7");
        displayedCount++;
    }
    if(isDefined(draftSection) && !matchesPublished)
    {
        suffix = " - In progress";
        if(isPublished)
        {
            suffix = " - Unpublished draft changes";
        }
        self sendLocalChatMessage("^1" + routeName + suffix + " (" + draftSection.rows.size +
                                  " checkpoints)^7 | !cpc " + routeName);
        displayedCount++;
    }
    return displayedCount;
}
