#include openCJ\util;

// A route is an ordered list of section drafts. Merges reference one shared
// section file; they never copy its edits into several competing drafts.
basePath()
{
    return "checkpoints/drafts/" + self openCJ\login::getPlayerID() + "_" + getCvar("mapname") +
           "_";
}

readSection(sectionName)
{
    sectionPath = self basePath() + sectionName;
    snapshotA = openCJ\checkpointCreation::_read(sectionPath + ".a", sectionName);
    snapshotB = openCJ\checkpointCreation::_read(sectionPath + ".b", sectionName);
    if (isDefined(snapshotB) && (!isDefined(snapshotA) || snapshotB.revision > snapshotA.revision))
    {
        snapshotA = snapshotB;
    }
    return snapshotA;
}

readNetworkFile(filePath)
{
    file = FS_FOpen(filePath, "read");
    if (!file)
    {
        return undefined;
    }
    line = FS_ReadLine(file);
    if (!isDefined(line))
    {
        FS_FClose(file);
        return undefined;
    }
    header = strTok(line, " ");
    if (header.size != 4 || header[0] != "CPN1" || !isValidInt(header[1]) ||
       !isValidInt(header[3]) || !openCJ\checkpointCreation::_validName(header[2]))
    {
        FS_FClose(file);
        return undefined;
    }
    network = spawnStruct();
    network.revision = int(header[1]);
    network.root = header[2];
    network.paths = [];
    minimumRouteCount = 2;
    maximumRouteCount = 16;
    routeCount = int(header[3]);
    if (routeCount < minimumRouteCount || routeCount > maximumRouteCount)
    {
        FS_FClose(file);
        return undefined;
    }
    for (i = 0; i < routeCount; i++)
    {
        line = FS_ReadLine(file);
        if (!isDefined(line))
        {
            FS_FClose(file);
            return undefined;
        }
        fields = strTok(line, " ");
        if (fields.size != 3 || !openCJ\checkpointCreation::_validName(fields[0]) ||
           !isDefined(openCJ\checkpointCreation::routeRGB(fields[1])))
        {
            FS_FClose(file);
            return undefined;
        }
        routePath = spawnStruct();
        routePath.hex = fields[1];
        routePath.sections = strTok(fields[2], ",");
        minimumSectionCount = 2;
        maximumSectionCount = 64;
        if (routePath.sections.size < minimumSectionCount ||
           routePath.sections.size > maximumSectionCount || routePath.sections[0] != network.root ||
           isDefined(network.paths[fields[0]]))
        {
            FS_FClose(file);
            return undefined;
        }
        for (j = 0; j < routePath.sections.size; j++)
        {
            if (!openCJ\checkpointCreation::_validName(routePath.sections[j]))
            {
                FS_FClose(file);
                return undefined;
            }
        }
        network.paths[fields[0]] = routePath;
    }
    line = FS_ReadLine(file);
    FS_FClose(file);
    if (!isDefined(line) || line != "END " + network.revision)
    {
        return undefined;
    }
    return network;
}

load()
{
    if (!isDefined(self.login_playerID))
    {
        return undefined;
    }
    manifestBasePath = self basePath() + "network";
    snapshotA = readNetworkFile(manifestBasePath + ".a");
    snapshotB = readNetworkFile(manifestBasePath + ".b");
    if (isDefined(snapshotB) && (!isDefined(snapshotA) || snapshotB.revision > snapshotA.revision))
    {
        return snapshotB;
    }
    return snapshotA;
}

save(network)
{
    minimumRouteCount = 2;
    maximumRouteCount = 16;
    minimumSectionCount = 2;
    maximumSectionCount = 64;
    routeNames = getArrayKeys(network.paths);
    if (routeNames.size < minimumRouteCount || routeNames.size > maximumRouteCount)
    {
        return false;
    }
    for (i = 0; i < routeNames.size; i++)
    {
        sections = network.paths[routeNames[i]].sections;
        if (sections.size < minimumSectionCount || sections.size > maximumSectionCount ||
           sections[0] != network.root)
        {
            return false;
        }
    }
    revision = network.revision + 1;
    suffix = ".a";
    if (revision % 2)
    {
        suffix = ".b";
    }
    file = FS_FOpen(self basePath() + "network" + suffix, "write");
    if (!file)
    {
        return false;
    }
    routeNames = getArrayKeys(network.paths);
    written = FS_WriteLine(file, "CPN1 " + revision + " " + network.root + " " + routeNames.size);
    for (i = 0; i < routeNames.size; i++)
    {
        routePath = network.paths[routeNames[i]];
        encodedSections = routePath.sections[0];
        for (j = 1; j < routePath.sections.size; j++)
        {
            encodedSections += "," + routePath.sections[j];
        }
        if (!FS_WriteLine(file, routeNames[i] + " " + routePath.hex + " " + encodedSections))
        {
            written = false;
        }
    }
    if (!FS_WriteLine(file, "END " + revision))
    {
        written = false;
    }
    FS_FClose(file);
    if (written)
    {
        network.revision = revision;
    }
    return written;
}

members(network, sectionName)
{
    routeNames = [];
    allRouteNames = getArrayKeys(network.paths);
    for (i = 0; i < allRouteNames.size; i++)
    {
        for (j = 0; j < network.paths[allRouteNames[i]].sections.size; j++)
        {
            if (network.paths[allRouteNames[i]].sections[j] == sectionName)
            {
                routeNames[routeNames.size] = allRouteNames[i];
                break;
            }
        }
    }
    return routeNames;
}

label(routeNames)
{
    routeLabel = "";
    for (i = 0; i < routeNames.size; i++)
    {
        if (i)
        {
            routeLabel += " + ";
        }
        routeLabel += routeNames[i];
    }
    return routeLabel;
}

// Called after the prior editor was saved/closed.
resolve(routeOrSectionName)
{
    network = self load();
    if (!isDefined(network))
    {
        manifestBasePath = self basePath() + "network";
        if (FS_TestFile(manifestBasePath + ".a") || FS_TestFile(manifestBasePath + ".b"))
        {
            return undefined;
        }
        return routeOrSectionName;
    }
    if (!isDefined(network.paths[routeOrSectionName]))
    {
        return routeOrSectionName;
    }
    sections = network.paths[routeOrSectionName].sections;
    return sections[sections.size - 1];
}

opened()
{
    network = self load();
    if (!isDefined(network))
    {
        return;
    }
    routeNames = members(network, self.cpc.route);
    if (!routeNames.size)
    {
        return;
    }
    if (routeNames.size == 1 && network.paths[routeNames[0]].hex != self.cpc.routeHex)
    {
        network.paths[routeNames[0]].hex = self.cpc.routeHex;
        if (!self save(network))
        {
            self.cpc.status = "Could not save route color to network";
        }
    }
    self.cpc.network = network;
    self.cpc.displayRoutes = label(routeNames);
    if (routeNames.size > 1)
    {
        self.cpc.displayRoutes += " (shared)";
    }
    if (!isDefined(self.cpc.restoreOrigin))
    {
        sections = network.paths[routeNames[0]].sections;
        for (i = 1; i < sections.size; i++)
        {
            if (sections[i] == self.cpc.route)
            {
                previousSection = self readSection(sections[i - 1]);
                if (isDefined(previousSection))
                {
                    self.cpc.restoreOrigin =
                        openCJ\checkpointCreation::restoreOrigin(previousSection);
                }
                break;
            }
        }
    }
}

fail(message)
{
    self.cpc.status = message;
    self sendLocalChatMessage(message, true);
    return false;
}

newSection(sectionName, routeColor, pendingCheckpoint)
{
    // An unreadable snapshot still belongs to an existing draft and may be recoverable.
    sectionPath = self basePath() + sectionName;
    if (FS_TestFile(sectionPath + ".a") || FS_TestFile(sectionPath + ".b"))
    {
        return false;
    }
    activeDraft = self.cpc;
    draft = spawnStruct();
    draft.route = sectionName;
    draft.routeHex = routeColor;
    draft.path = self basePath() + sectionName;
    draft.rows = [];
    draft.selected = 0;
    draft.revision = 0;
    draft.draft = openCJ\checkpointCreation::_empty();
    if (isDefined(pendingCheckpoint))
    {
        draft.draft = pendingCheckpoint;
    }
    self.cpc = draft;
    saved = self openCJ\checkpointCreation::_save();
    self.cpc = activeDraft;
    return saved;
}

namesValid(commandArguments)
{
    minimumRouteNames = 2;
    maximumRouteNames = 16;
    // The first token is the split/merge command; the remaining tokens are route names.
    if (commandArguments.size < minimumRouteNames + 1 ||
       commandArguments.size > maximumRouteNames + 1)
    {
        return false;
    }
    for (i = 1; i < commandArguments.size; i++)
    {
        if (!openCJ\checkpointCreation::_validName(commandArguments[i]))
        {
            return false;
        }
        for (j = 1; j < i; j++)
        {
            if (commandArguments[i] == commandArguments[j])
            {
                return false;
            }
        }
    }
    return true;
}

split(commandArguments)
{
    if (!namesValid(commandArguments))
    {
        return self fail("Use !cp split easy hard [more route names]");
    }
    network = self load();
    if (isDefined(network) && self.cpc.selected < self.cpc.rows.size)
    {
        return self splitExisting(commandArguments, network);
    }
    if (self.cpc.rows.size == 0 || self.cpc.draft.points.size || self.cpc.draft.alternatives.size)
    {
        return self fail("Confirm the last shared landing before splitting.");
    }
    lastCheckpoint = openCJ\checkpointCreation::_decode(self.cpc.rows[self.cpc.rows.size - 1]);
    if (lastCheckpoint.finish)
    {
        return self fail("A Finish cannot split. Unmark it first.");
    }
    if (!self openCJ\checkpointCreation::_save())
    {
        return false;
    }
    network = self load();
    isNewNetwork = !isDefined(network);
    if (isNewNetwork)
    {
        if (isDefined(self.cpc.sharedRoute))
        {
            return self fail(
                "Legacy branch draft: finish or migrate it before creating a network.");
        }
        network = spawnStruct();
        network.root = self.cpc.route;
        network.revision = 0;
        network.paths = [];
        for (i = 1; i < commandArguments.size; i++)
        {
            if (commandArguments[i] == network.root ||
               isDefined(self readSection(commandArguments[i])))
            {
                return self fail("A requested name already has a draft; nothing changed.");
            }
        }
    }
    else
    {
        routeOwners = members(network, self.cpc.route);
        if (routeOwners.size != commandArguments.size - 1)
        {
            return self fail("List all routes sharing this section when splitting.");
        }
        for (i = 1; i < commandArguments.size; i++)
        {
            if (!isDefined(network.paths[commandArguments[i]]))
            {
                return self fail("A later split must use the original route names.");
            }
            sections = network.paths[commandArguments[i]].sections;
            if (sections[sections.size - 1] != self.cpc.route)
            {
                return self fail("Only the current end of a shared section can split.");
            }
        }
    }
    for (i = 1; i < commandArguments.size; i++)
    {
        routeName = commandArguments[i];
        sectionName = "section_" + (network.revision + 1) + "_" + i;
        if (isNewNetwork)
        {
            sectionName = routeName;
        }
        routeColor = openCJ\checkpointCreation::defaultRouteColor(routeName);
        if (!isNewNetwork)
        {
            routeColor = network.paths[routeName].hex;
        }
        if (!self newSection(sectionName, routeColor))
        {
            return self fail("Could not create section; existing network retained.");
        }
        if (isNewNetwork)
        {
            routePath = spawnStruct();
            routePath.hex = routeColor;
            routePath.sections = [];
            routePath.sections[0] = network.root;
            network.paths[routeName] = routePath;
        }
        routePath = network.paths[routeName];
        routePath.sections[routePath.sections.size] = sectionName;
    }
    if (!self save(network))
    {
        return self fail("Network save failed; section drafts retained.");
    }
    self openCJ\checkpointCreation::_close();
    self openCJ\checkpointCreation::_start(commandArguments[1]);
    self sendLocalChatMessage(
        "Split saved. Editing " + commandArguments[1] + "; !cp start " + commandArguments[2] +
        " opens the other approach. Detect the common landing, then !cp merge " +
        labelCommand(commandArguments) + ".");
    return true;
}

labelCommand(commandArguments)
{
    routeArguments = commandArguments[1];
    for(i = 2; i < commandArguments.size; i++)
    {
        routeArguments += " " + commandArguments[i];
    }
    return routeArguments;
}

merge(commandArguments)
{
    if (!namesValid(commandArguments))
    {
        return self fail("Use !cp merge easy hard [more route names]");
    }
    network = self load();
    if (!isDefined(network))
    {
        return self fail("Split the shared opening into routes first.");
    }
    self checkOverlap(true);
    if (isDefined(self.cpc.overlapSection))
    {
        return self mergeExisting(commandArguments, network);
    }
    if (self.cpc.selected != self.cpc.rows.size ||
       openCJ\checkpointMoving::valid(self.cpc.draft) != "")
    {
        return self fail(
            "Detect the first common landing without confirming it, then !cp merge easy hard.");
    }
    includesActiveSection = false;
    for (i = 1; i < commandArguments.size; i++)
    {
        if (!isDefined(network.paths[commandArguments[i]]))
        {
            return self fail("Unknown route " + commandArguments[i]);
        }
        sectionNames = network.paths[commandArguments[i]].sections;
        lastSectionName = sectionNames[sectionNames.size - 1];
        routeOwners = members(network, lastSectionName);
        for (j = 0; j < routeOwners.size; j++)
        {
            includedOwner = false;
            for (k = 1; k < commandArguments.size; k++)
            {
                if (commandArguments[k] == routeOwners[j])
                {
                    includedOwner = true;
                }
            }
            if (!includedOwner)
            {
                return self fail("Include every route already sharing an incoming section.");
            }
        }
        sectionDraft = self readSection(lastSectionName);
        if (lastSectionName == self.cpc.route)
        {
            sectionDraft = self.cpc;
            includesActiveSection = true;
        }
        if (!isDefined(sectionDraft) || sectionDraft.rows.size == 0)
        {
            return self fail("Checkpoint " + commandArguments[i] +
                             " up to its last separate landing first.");
        }
        lastCheckpoint =
            openCJ\checkpointCreation::_decode(sectionDraft.rows[sectionDraft.rows.size - 1]);
        if (lastCheckpoint.finish)
        {
            return self fail(commandArguments[i] +
                             " ends in a Finish; remove that flag before merging.");
        }
        if (lastSectionName != self.cpc.route &&
           (sectionDraft.draft.points.size || sectionDraft.draft.alternatives.size))
        {
            return self fail("Confirm or discard the pending selection on " + commandArguments[i] +
                             " first.");
        }
    }
    if (!includesActiveSection)
    {
        return self fail("The route being edited must be included in the merge.");
    }
    sharedSectionName = "shared_" + (network.revision + 1);
    openingDraft = self readSection(network.root);
    if (!self newSection(sharedSectionName, openingDraft.routeHex, self.cpc.draft))
    {
        return self fail("Could not save the common landing; merge unchanged.");
    }
    self.cpc.draft = openCJ\checkpointCreation::_empty();
    if (!self openCJ\checkpointCreation::_save())
    {
        return false;
    }
    for (i = 1; i < commandArguments.size; i++)
    {
        routePath = network.paths[commandArguments[i]];
        routePath.sections[routePath.sections.size] = sharedSectionName;
    }
    if (!self save(network))
    {
        return self fail("Could not save merge; section draft retained.");
    }
    self openCJ\checkpointCreation::_close();
    self openCJ\checkpointCreation::_start(sharedSectionName);
    self sendLocalChatMessage(
        "Merged " + labelCommand(commandArguments) +
        ". Confirm this common landing and continue once for all routes. Use !cp split " +
        labelCommand(commandArguments) + " if they separate again.");
    return true;
}

publish()
{
    activeDraft = self.cpc;
    network = self load();
    if(!isDefined(network))
    {
        return self fail("Network draft cannot be read.");
    }
    routeNames = getArrayKeys(network.paths);
    routeDrafts = [];
    openingDraft = self readSection(network.root);
    if(!isDefined(openingDraft) || openingDraft.rows.size == 0)
    {
        return self fail("Complete the shared opening before finalizing the network.");
    }
    for(i = 0; i < routeNames.size; i++)
    {
        routeName = routeNames[i];
        routePath = network.paths[routeName];
        routeDraft = spawnStruct();
        routeDraft.route = routeName;
        routeDraft.routeHex = routePath.hex;
        routeDraft.sharedRoute = network.root;
        routeDraft.sharedHex = openingDraft.routeHex;
        routeDraft.sharedCount = openingDraft.rows.size;
        routeDraft.rows = [];
        routeDraft.sections = [];
        routeDraft.draft = openCJ\checkpointCreation::_empty();
        for(j = 0; j < routePath.sections.size; j++)
        {
            sectionName = routePath.sections[j];
            sectionDraft = self readSection(sectionName);
            if(!isDefined(sectionDraft) || sectionDraft.rows.size == 0)
            {
                return self fail("Complete section " + sectionName +
                                 " before finalizing the network.");
            }
            if(pendingEdit(sectionDraft))
            {
                return self fail("Confirm the pending area in " + sectionName + " first.");
            }
            for(k = 0; k < sectionDraft.rows.size; k++)
            {
                routeDraft.sections[routeDraft.rows.size] = sectionName;
                routeDraft.rows[routeDraft.rows.size] = sectionDraft.rows[k];
            }
        }
        validationMessage = openCJ\checkpointPublish::validationError(routeDraft.rows);
        if(validationMessage != "")
        {
            return self fail(routeName + ": " + validationMessage);
        }
        if(routeDraft.rows.size > 256)
        {
            return self fail(routeName + " exceeds 256 checkpoints.");
        }
        routeDrafts[i] = routeDraft;
    }
    if(!isDefined(
           openCJ\mySQL::mysqlSyncQuery("SELECT sectionName FROM checkpointSectionColors LIMIT 0")))
    {
        return self fail("Install migration 005-checkpoint-sections.sql first.");
    }
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery("START TRANSACTION")))
    {
        return self fail("Cannot begin network publication.");
    }
    published = true;
    errorMessage = "";
    for(i = 0; i < routeDrafts.size; i++)
    {
        self.cpc = routeDrafts[i];
        if(!self openCJ\checkpointPublish::_writeRoute())
        {
            published = false;
            errorMessage = self.cpc.status;
            break;
        }
        entries = self openCJ\checkpointPublish::_entries();
        // Logical checkpoints retain route-specific records through a merge.
        // Shared geometry is authored once in its section draft; the legacy
        // runtime receives one ordered continuation per route after the fork.
        areaIdRows = openCJ\mySQL::mysqlSyncQuery(
            "SELECT cpID FROM checkpointAreas WHERE mapID=" + openCJ\mapID::getMapID() +
            " AND draftName=" + dbStr(self.cpc.route) + " ORDER BY ordinal");
        sharedAreaCount = 0;
        for(j = 0; j < entries.size; j++)
        {
            if(entries[j].group < self.cpc.sharedCount)
            {
                sharedAreaCount++;
            }
        }
        if(!isDefined(areaIdRows) || areaIdRows.size != entries.size - sharedAreaCount)
        {
            published = false;
            errorMessage = "Cannot read published section IDs";
            break;
        }
        for(j = sharedAreaCount; j < entries.size; j++)
        {
            sectionName = self.cpc.sections[entries[j].group];
            if(!isDefined(openCJ\mySQL::mysqlSyncQuery(
                   "UPDATE checkpointAreas SET sectionName=" + dbStr(sectionName) +
                   " WHERE cpID=" + int(areaIdRows[j - sharedAreaCount][0]))))
            {
                published = false;
                errorMessage = "Cannot assign checkpoint section";
                break;
            }
        }
        if(!published)
        {
            break;
        }
    }
    self.cpc = activeDraft;
    if(published)
    {
        uniqueSections = [];
        for(i = 0; i < routeNames.size; i++)
        {
            for(j = 0; j < network.paths[routeNames[i]].sections.size; j++)
            {
                uniqueSections[network.paths[routeNames[i]].sections[j]] = true;
            }
        }
        sectionNames = getArrayKeys(uniqueSections);
        for(i = 0; i < sectionNames.size; i++)
        {
            sectionDraft = self readSection(sectionNames[i]);
            sectionColor = openCJ\checkpointCreation::routeRGB(sectionDraft.routeHex);
            packedColor = int(sectionColor[0] * 255 + 0.5) * 65536 +
                          int(sectionColor[1] * 255 + 0.5) * 256 + int(sectionColor[2] * 255 + 0.5);
            query = "INSERT INTO checkpointSectionColors(mapID,sectionName,colorRGB) VALUES (" +
                    openCJ\mapID::getMapID() + "," + dbStr(sectionNames[i]) + "," + packedColor +
                    ") ON DUPLICATE KEY UPDATE colorRGB=VALUES(colorRGB)";
            if(!isDefined(openCJ\mySQL::mysqlSyncQuery(query)))
            {
                published = false;
                errorMessage = "Cannot save section color";
                break;
            }
        }
    }
    if(published)
    {
        published = isDefined(openCJ\mySQL::mysqlSyncQuery("CALL rebuildCheckpointRoutes(" +
                                                           openCJ\mapID::getMapID() + ")"));
    }
    if(published)
    {
        published = isDefined(openCJ\mySQL::mysqlSyncQuery("COMMIT"));
    }
    if(!published)
    {
        openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
        return self fail("Network not published: " + errorMessage);
    }
    self.cpc.publishedLabel = label(routeNames);
    return true;
}

// Compare actual coplanar areas, not merely nearby centers. Also check edge
// midpoints so touching a common boundary alone does not report an overlap.
overlap(firstPoints, secondPoints)
{
    // The editor's label center is raised above the polygon; compare points on its plane.
    labelHeightOffset = 12;
    firstCenter = openCJ\checkpointCreation::_center(firstPoints) - (0, 0, labelHeightOffset);
    secondCenter = openCJ\checkpointCreation::_center(secondPoints) - (0, 0, labelHeightOffset);
    if(openCJ\checkpointArea::contains(firstPoints, secondCenter, true) ||
       openCJ\checkpointArea::contains(secondPoints, firstCenter, true))
    {
        return true;
    }
    for(i = 0; i < firstPoints.size; i++)
    {
        midpoint = vectorScale(firstPoints[i] + firstCenter, 0.5);
        if(openCJ\checkpointArea::contains(secondPoints, midpoint, true))
        {
            return true;
        }
    }
    for(i = 0; i < secondPoints.size; i++)
    {
        midpoint = vectorScale(secondPoints[i] + secondCenter, 0.5);
        if(openCJ\checkpointArea::contains(firstPoints, midpoint, true))
        {
            return true;
        }
    }
    return false;
}

checkOverlap(quiet)
{
    self.cpc.overlap = undefined;
    self.cpc.overlapSection = undefined;
    self.cpc.overlapIndex = undefined;
    if(openCJ\checkpointMoving::valid(self.cpc.draft) != "")
    {
        return;
    }
    network = self load();
    if(!isDefined(network))
    {
        return;
    }
    uniqueSections = [];
    routeNames = getArrayKeys(network.paths);
    for(i = 0; i < routeNames.size; i++)
    {
        for(j = 0; j < network.paths[routeNames[i]].sections.size; j++)
        {
            uniqueSections[network.paths[routeNames[i]].sections[j]] = true;
        }
    }
    sectionNames = getArrayKeys(uniqueSections);
    for(i = 0; i < sectionNames.size; i++)
    {
        if(sectionNames[i] == self.cpc.route)
        {
            continue;
        }
        sectionDraft = self readSection(sectionNames[i]);
        if(!isDefined(sectionDraft))
        {
            continue;
        }
        for(j = 0; j < sectionDraft.rows.size; j++)
        {
            candidateCheckpoint = openCJ\checkpointCreation::_decode(sectionDraft.rows[j]);
            areas = [];
            areas[0] = candidateCheckpoint.points;
            for(k = 0; k < candidateCheckpoint.alternatives.size; k++)
            {
                areas[areas.size] = candidateCheckpoint.alternatives[k];
            }
            for(k = 0; k < areas.size; k++)
            {
                if(areaOverlap(self.cpc.draft, candidateCheckpoint, areas[k]))
                {
                    self.cpc.overlap = candidateCheckpoint;
                    self.cpc.overlapSection = sectionNames[i];
                    self.cpc.overlapIndex = j;
                    self.cpc.status = "Overlaps " + label(members(network, sectionNames[i])) +
                                      " section " + sectionNames[i] + " #" + (j + 1);
                    if(!isDefined(quiet) || !quiet)
                    {
                        self sendLocalChatMessage(
                            self.cpc.status +
                                ". Use !cp merge <routes> at the first common landing; use !cp split <routes> where they separate again. Do not confirm duplicate platforms.",
                            true);
                    }
                    return;
                }
            }
        }
    }
}

// At a section boundary, show the separate incoming approaches in their colors.
drawConnections(checkpoint)
{
    if(!isDefined(self.cpc.network) || self.cpc.selected > 0 || checkpoint.points.size == 0)
    {
        return;
    }
    network = self.cpc.network;
    routeNames = members(network, self.cpc.route);
    drawnSections = [];
    for(i = 0; i < routeNames.size; i++)
    {
        sections = network.paths[routeNames[i]].sections;
        for(j = 1; j < sections.size; j++)
        {
            if(sections[j] == self.cpc.route)
            {
                previousSectionName = sections[j - 1];
                if(isDefined(drawnSections[previousSectionName]))
                {
                    break;
                }
                drawnSections[previousSectionName] = true;
                sectionDraft = self readSection(previousSectionName);
                if(!isDefined(sectionDraft) || sectionDraft.rows.size == 0)
                {
                    break;
                }
                previousCheckpoint = openCJ\checkpointCreation::_decode(
                    sectionDraft.rows[sectionDraft.rows.size - 1]);
                connectionColor = openCJ\checkpointCreation::_vec(
                                      openCJ\checkpointCreation::routeRGB(sectionDraft.routeHex)) +
                                  " 1";
                self openCJ\checkpointCreation::_outlineGroup(previousCheckpoint, connectionColor);
                self openCJ\checkpointCreation::_line(
                    openCJ\checkpointCreation::_center(
                        openCJ\checkpointMoving::points(previousCheckpoint)),
                    openCJ\checkpointCreation::_center(openCJ\checkpointMoving::points(checkpoint)),
                    connectionColor);
                break;
            }
        }
    }
}

hasName(commandArguments, routeName)
{
    for(i = 1; i < commandArguments.size; i++)
    {
        if(commandArguments[i] == routeName)
        {
            return true;
        }
    }
    return false;
}

sectionIndex(sectionNames, sectionName)
{
    for(i = 0; i < sectionNames.size; i++)
    {
        if(sectionNames[i] == sectionName)
        {
            return i;
        }
    }
    return -1;
}

uniqueSection(network)
{
    maximumSectionNameAttempts = 1024;
    for(i = 0; i < maximumSectionNameAttempts; i++)
    {
        sectionName = "part_" + (network.revision + 1) + "_" + i;
        if(!FS_TestFile(self basePath() + sectionName + ".a") &&
           !FS_TestFile(self basePath() + sectionName + ".b"))
        {
            return sectionName;
        }
    }
    return undefined;
}

writeSection(sectionName, sectionDraft)
{
    activeDraft = self.cpc;
    sectionDraft.route = sectionName;
    sectionDraft.path = self basePath() + sectionName;
    self.cpc = sectionDraft;
    saved = self openCJ\checkpointCreation::_save();
    self.cpc = activeDraft;
    return saved;
}

sliceSection(network, sourceSection, startRowIndex, endRowIndex, routeColor)
{
    sectionName = self uniqueSection(network);
    if(!isDefined(sectionName))
    {
        return undefined;
    }
    sectionDraft = spawnStruct();
    sectionDraft.rows = [];
    sectionDraft.routeHex = routeColor;
    sectionDraft.revision = 0;
    for(i = startRowIndex; i < endRowIndex; i++)
    {
        sectionDraft.rows[sectionDraft.rows.size] = sourceSection.rows[i];
    }
    sectionDraft.selected = sectionDraft.rows.size;
    sectionDraft.draft = openCJ\checkpointCreation::_empty();
    if(!self writeSection(sectionName, sectionDraft))
    {
        return undefined;
    }
    return sectionName;
}

replaceSection(network, previousName, firstName, secondName)
{
    routeNames = getArrayKeys(network.paths);
    for(i = 0; i < routeNames.size; i++)
    {
        previousSections = network.paths[routeNames[i]].sections;
        replacementSections = [];
        for(j = 0; j < previousSections.size; j++)
        {
            if(previousSections[j] != previousName)
            {
                replacementSections[replacementSections.size] = previousSections[j];
                continue;
            }
            if(isDefined(firstName))
            {
                replacementSections[replacementSections.size] = firstName;
            }
            if(isDefined(secondName))
            {
                replacementSections[replacementSections.size] = secondName;
            }
        }
        network.paths[routeNames[i]].sections = replacementSections;
    }
}

mergeExisting(commandArguments, network)
{
    sourceSectionName = self.cpc.route;
    targetSectionName = self.cpc.overlapSection;
    overlapIndex = self.cpc.overlapIndex;
    if(targetSectionName == network.root)
    {
        return self fail(
            "This is the shared opening, not a later merge. Select the actual joining landing.");
    }
    if(self.cpc.selected != self.cpc.rows.size || self.cpc.rows.size == 0)
    {
        return self fail("Merge from a new detected landing after your last separate checkpoint.");
    }
    sourceOwners = members(network, sourceSectionName);
    targetOwners = members(network, targetSectionName);
    for(i = 0; i < sourceOwners.size; i++)
    {
        sectionNames = network.paths[sourceOwners[i]].sections;
        if(sectionNames[sectionNames.size - 1] != sourceSectionName ||
           sectionIndex(sectionNames, targetSectionName) >= 0)
        {
            return self fail(
                "Split the existing continuation first; merge from the end of a new approach.");
        }
    }
    for(i = 0; i < sourceOwners.size; i++)
    {
        if(!hasName(commandArguments, sourceOwners[i]))
        {
            return self fail("Include every route on the incoming approach.");
        }
    }
    for(i = 0; i < targetOwners.size; i++)
    {
        if(!hasName(commandArguments, targetOwners[i]))
        {
            return self fail("Include every route already using the detected landing.");
        }
    }
    incomingNames = [];
    continuationRouteName = undefined;
    for(i = 1; i < commandArguments.size; i++)
    {
        if(!isDefined(network.paths[commandArguments[i]]))
        {
            return self fail("Unknown route " + commandArguments[i]);
        }
        sections = network.paths[commandArguments[i]].sections;
        if(sectionIndex(sections, targetSectionName) >= 0)
        {
            if(!isDefined(continuationRouteName))
            {
                continuationRouteName = commandArguments[i];
            }
            continue;
        }
        lastSectionName = sections[sections.size - 1];
        routeOwners = members(network, lastSectionName);
        for(j = 0; j < routeOwners.size; j++)
        {
            if(!hasName(commandArguments, routeOwners[j]))
            {
                return self fail("Include every route sharing an incoming approach.");
            }
        }
        sectionDraft = self readSection(lastSectionName);
        if(lastSectionName == sourceSectionName)
        {
            sectionDraft = self.cpc;
        }
        if(!isDefined(sectionDraft) || !sectionDraft.rows.size)
        {
            return self fail("Complete the separate approach for " + commandArguments[i] +
                             " first.");
        }
        lastCheckpoint =
            openCJ\checkpointCreation::_decode(sectionDraft.rows[sectionDraft.rows.size - 1]);
        if(lastCheckpoint.finish ||
           (lastSectionName != sourceSectionName && pendingEdit(sectionDraft)))
        {
            return self fail("Confirm the approach for " + commandArguments[i] +
                             " without a Finish before merging.");
        }
        incomingNames[incomingNames.size] = commandArguments[i];
    }
    if(!isDefined(continuationRouteName) || !incomingNames.size)
    {
        return self fail("Choose an incoming route and an existing continuation.");
    }
    // The first named existing route supplies the continuation for new arrivals.
    // Other existing routes keep their own later divergences untouched.
    continuation = network.paths[continuationRouteName].sections;
    continuationStartIndex = sectionIndex(continuation, targetSectionName);
    for(i = 0; i < incomingNames.size; i++)
    {
        incomingSections = network.paths[incomingNames[i]].sections;
        for(j = continuationStartIndex; j < continuation.size; j++)
        {
            if(sectionIndex(incomingSections, continuation[j]) >= 0)
            {
                return self fail("Merge would create a cycle; draft unchanged.");
            }
        }
    }
    targetSection = self readSection(targetSectionName);
    if(!isDefined(targetSection) || pendingEdit(targetSection))
    {
        return self fail("Confirm or discard the existing route's pending edit before merging.");
    }
    prefixSectionName = undefined;
    if(overlapIndex > 0)
    {
        prefixSectionName =
            self sliceSection(network, targetSection, 0, overlapIndex, targetSection.routeHex);
        if(!isDefined(prefixSectionName))
        {
            return self fail("Could not save existing approach; original retained.");
        }
    }
    openingDraft = self readSection(network.root);
    sharedSectionName = self sliceSection(network, targetSection, overlapIndex,
                                          targetSection.rows.size, openingDraft.routeHex);
    if(!isDefined(sharedSectionName))
    {
        return self fail("Could not save shared continuation; original retained.");
    }
    self replaceSection(network, targetSectionName, prefixSectionName, sharedSectionName);
    continuationSections = [];
    continuationSections[0] = sharedSectionName;
    for(j = continuationStartIndex + 1; j < continuation.size; j++)
    {
        continuationSections[continuationSections.size] = continuation[j];
    }
    for(i = 0; i < incomingNames.size; i++)
    {
        routePath = network.paths[incomingNames[i]];
        for(j = 0; j < continuationSections.size; j++)
        {
            routePath.sections[routePath.sections.size] = continuationSections[j];
        }
    }
    // Save the incoming approach without duplicating the joining checkpoint.
    pendingCheckpoint = self.cpc.draft;
    self.cpc.draft = openCJ\checkpointCreation::_empty();
    if(!self openCJ\checkpointCreation::_save())
    {
        self.cpc.draft = pendingCheckpoint;
        return false;
    }
    if(!self save(network))
    {
        self.cpc.draft = pendingCheckpoint;
        self openCJ\checkpointCreation::_save();
        return self fail("Could not save merge; original paths retained.");
    }
    self openCJ\checkpointCreation::_close();
    self openCJ\checkpointCreation::_start(sharedSectionName);
    self selectAndTeleport(0);
    self sendLocalChatMessage(
        "Merged " + labelCommand(commandArguments) +
        " here. Existing checkpoints and Finish are preserved. Select the last shared checkpoint and !cp split <keep existing route> <new branch route> if they separate later.");
    return true;
}

selectAndTeleport(checkpointIndex)
{
    self.cpc.selected = checkpointIndex;
    self.cpc.draft = openCJ\checkpointCreation::_decode(self.cpc.rows[checkpointIndex]);
    self.cpc.overlap = undefined;
    self.cpc.overlapSection = undefined;
    // Consume travel on the game update, replacing the draft-opening destination.
    self.cpc.restoreOrigin = openCJ\checkpointCreation::restoreOrigin(self.cpc);
    self openCJ\checkpointCreation::_save();
}

sameCheckpoint(firstCheckpoint, secondCheckpoint)
{
    if(!openCJ\checkpointHeight::same(firstCheckpoint, secondCheckpoint))
    {
        return false;
    }
    if(openCJ\checkpointMoving::isMoving(firstCheckpoint) !=
       openCJ\checkpointMoving::isMoving(secondCheckpoint))
    {
        return false;
    }
    if(openCJ\checkpointMoving::isMoving(firstCheckpoint))
    {
        return firstCheckpoint.platformRef == secondCheckpoint.platformRef &&
               firstCheckpoint.allowEle == secondCheckpoint.allowEle &&
               firstCheckpoint.allowSave == secondCheckpoint.allowSave &&
               firstCheckpoint.onGround == secondCheckpoint.onGround &&
               firstCheckpoint.finish == secondCheckpoint.finish &&
               firstCheckpoint.double == secondCheckpoint.double;
    }
    if(firstCheckpoint.allowEle != secondCheckpoint.allowEle ||
       firstCheckpoint.allowSave != secondCheckpoint.allowSave ||
       firstCheckpoint.onGround != secondCheckpoint.onGround ||
       firstCheckpoint.finish != secondCheckpoint.finish ||
       firstCheckpoint.double != secondCheckpoint.double ||
       firstCheckpoint.points.size != secondCheckpoint.points.size ||
       firstCheckpoint.alternatives.size != secondCheckpoint.alternatives.size)
    {
        return false;
    }
    for(i = 0; i < firstCheckpoint.points.size; i++)
    {
        if(distanceSquared(firstCheckpoint.points[i], secondCheckpoint.points[i]) > 0.0001)
        {
            return false;
        }
    }
    for(i = 0; i < firstCheckpoint.alternatives.size; i++)
    {
        if(firstCheckpoint.alternatives[i].size != secondCheckpoint.alternatives[i].size)
        {
            return false;
        }
        for(j = 0; j < firstCheckpoint.alternatives[i].size; j++)
        {
            if(distanceSquared(firstCheckpoint.alternatives[i][j],
                               secondCheckpoint.alternatives[i][j]) > 0.0001)
            {
                return false;
            }
        }
    }
    return true;
}

splitExisting(commandArguments, network)
{
    routeOwners = members(network, self.cpc.route);
    if(routeOwners.size != commandArguments.size - 1)
    {
        return self fail("List every route sharing the selected section.");
    }
    for(i = 0; i < routeOwners.size; i++)
    {
        if(!hasName(commandArguments, routeOwners[i]))
        {
            return self fail("List every route sharing the selected section.");
        }
    }
    checkpointIndex = self.cpc.selected;
    confirmedCheckpoint = openCJ\checkpointCreation::_decode(self.cpc.rows[checkpointIndex]);
    if(!sameCheckpoint(confirmedCheckpoint, self.cpc.draft))
    {
        return self fail("Confirm or undo changes to the selected checkpoint before splitting.");
    }
    if(confirmedCheckpoint.finish)
    {
        return self fail("Select the last shared landing before the Finish.");
    }
    if(self.cpc.route == network.root)
    {
        return self fail("The opening already has a split; select a later merged section.");
    }
    // First argument keeps the existing continuation; other routes receive a
    // new approach from this landing, without changing their earlier history.
    retainedRouteName = commandArguments[1];
    retainedSections = network.paths[retainedRouteName].sections;
    selectedSectionIndex = sectionIndex(retainedSections, self.cpc.route);
    if(selectedSectionIndex < 0)
    {
        return self fail("The retained route does not use this section.");
    }
    prefixSectionName =
        self sliceSection(network, self.cpc, 0, checkpointIndex + 1, self.cpc.routeHex);
    if(!isDefined(prefixSectionName))
    {
        return self fail("Could not save split boundary; original retained.");
    }
    suffixSectionName = undefined;
    if(checkpointIndex + 1 < self.cpc.rows.size)
    {
        suffixSectionName =
            self sliceSection(network, self.cpc, checkpointIndex + 1, self.cpc.rows.size,
                              network.paths[retainedRouteName].hex);
        if(!isDefined(suffixSectionName))
        {
            return self fail("Could not preserve existing continuation; original retained.");
        }
    }
    previousSectionName = self.cpc.route;
    self replaceSection(network, previousSectionName, prefixSectionName, suffixSectionName);
    if(!isDefined(suffixSectionName) && selectedSectionIndex == retainedSections.size - 1)
    {
        branchSectionName = self uniqueSection(network);
        if(!isDefined(branchSectionName) ||
           !self newSection(branchSectionName, network.paths[retainedRouteName].hex))
        {
            return self fail("Could not create retained route's new section.");
        }
        routePath = network.paths[retainedRouteName];
        routePath.sections[routePath.sections.size] = branchSectionName;
    }
    for(i = 2; i < commandArguments.size; i++)
    {
        routeName = commandArguments[i];
        previousSections = network.paths[routeName].sections;
        splitSectionIndex = sectionIndex(previousSections, prefixSectionName);
        branchSectionName = self uniqueSection(network);
        if(!isDefined(branchSectionName) ||
           !self newSection(branchSectionName, network.paths[routeName].hex))
        {
            return self fail("Could not create branch; original network retained.");
        }
        replacementSections = [];
        for(j = 0; j <= splitSectionIndex; j++)
        {
            replacementSections[replacementSections.size] = previousSections[j];
        }
        replacementSections[replacementSections.size] = branchSectionName;
        network.paths[routeName].sections = replacementSections;
    }
    if(!self save(network))
    {
        return self fail("Could not save split; original network retained.");
    }
    self openCJ\checkpointCreation::_close();
    self openCJ\checkpointCreation::_start(commandArguments[2]);
    self sendLocalChatMessage(
        "Split saved: " + retainedRouteName + " keeps its existing continuation. Editing " +
        commandArguments[2] +
        " from the selected landing; other branches can rejoin using !cp merge.");
    return true;
}

pendingEdit(sectionDraft)
{
    if(isDefined(sectionDraft.insertAfter))
    {
        return true;
    }
    if(sectionDraft.selected >= sectionDraft.rows.size)
    {
        return sectionDraft.draft.points.size > 0 || sectionDraft.draft.alternatives.size > 0;
    }
    // An empty replacement of an existing checkpoint is still an unapplied edit.
    return !sameCheckpoint(sectionDraft.draft, openCJ\checkpointCreation::_decode(
                                                   sectionDraft.rows[sectionDraft.selected]));
}

rename(previousName, newName)
{
    if(!openCJ\checkpointCreation::_validName(previousName) ||
       !openCJ\checkpointCreation::_validName(newName) || previousName == newName ||
       newName == "network")
    {
        return self fail("Use !cp rename <currentName> <newName> with distinct route names.");
    }
    if(!self openCJ\checkpointCreation::_save())
    {
        return false;
    }
    network = self load();
    previousNetwork = self load();
    previousSection = self readSection(previousName);
    targetSection = self readSection(newName);
    renamesRoute = isDefined(network) && isDefined(network.paths[previousName]);
    if(!isDefined(previousSection) && !renamesRoute)
    {
        return self fail("No route or section named " + previousName);
    }
    if(isDefined(targetSection) || (isDefined(network) && isDefined(network.paths[newName])))
    {
        return self fail("The new name is already used; nothing overwritten.");
    }
    if(isDefined(previousSection) && isDefined(previousSection.sharedRoute))
    {
        return self fail(
            "Rename legacy branches after converting their shared-opening references.");
    }
    mapID = openCJ\mapID::getMapID();
    collisionRows =
        openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE mapID=" + mapID +
                                     " AND draftName=" + dbStr(newName) +
                                     " UNION SELECT routeID FROM routes WHERE mapID=" + mapID +
                                     " AND routeName=" + dbStr(newName) + " LIMIT 1");
    if(!isDefined(collisionRows) || collisionRows.size)
    {
        return self fail("That name is already published; nothing overwritten.");
    }
    if(isDefined(previousSection))
    {
        if(!self writeSection(newName, previousSection))
        {
            return self fail("Could not save renamed draft; original retained.");
        }
        if(isDefined(network))
        {
            self replaceSection(network, previousName, newName, undefined);
            if(network.root == previousName)
            {
                network.root = newName;
            }
        }
    }
    if(renamesRoute)
    {
        network.paths[newName] = network.paths[previousName];
        network.paths[previousName] = undefined;
    }
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery("START TRANSACTION")))
    {
        return self fail("Cannot begin rename; original retained.");
    }
    queries = [];
    queries[0] = "SELECT mapID FROM mapids WHERE mapID=" + mapID + " FOR UPDATE";
    queries[1] = "UPDATE checkpointAreas SET draftName=" + dbStr(newName) +
                 " WHERE mapID=" + mapID + " AND draftName=" + dbStr(previousName);
    queries[2] = "UPDATE routes SET routeName=" + dbStr(newName) + " WHERE mapID=" + mapID +
                 " AND routeName=" + dbStr(previousName);
    queries[3] = "UPDATE checkpointAreas SET sectionName=" + dbStr(newName) +
                 " WHERE mapID=" + mapID + " AND sectionName=" + dbStr(previousName);
    queries[4] = "UPDATE checkpointSectionColors SET sectionName=" + dbStr(newName) +
                 " WHERE mapID=" + mapID + " AND sectionName=" + dbStr(previousName);
    for(i = 0; i < queries.size; i++)
    {
        if(!isDefined(openCJ\mySQL::mysqlSyncQuery(queries[i])))
        {
            openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
            return self fail(
                "Rename failed; existing database records unchanged. New draft copy retained.");
        }
    }
    if(isDefined(network) && !self save(network))
    {
        openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
        return self fail("Cannot save renamed network; original retained.");
    }
    if(!isDefined(openCJ\mySQL::mysqlSyncQuery("COMMIT")))
    {
        openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
        if(isDefined(previousNetwork))
        {
            previousNetwork.revision = network.revision;
            self save(previousNetwork);
        }
        return self fail("Rename commit failed; original names restored.");
    }
    // Keep an explicit recovery snapshot outside the active draft names.
    if(isDefined(previousSection))
    {
        activeDraft = self.cpc;
        previousSection.route = previousName;
        previousSection.path = self basePath() + previousName + ".renamed";
        self.cpc = previousSection;
        backupSaved = self openCJ\checkpointCreation::_save();
        self.cpc = activeDraft;
        if(backupSaved)
        {
            if(FS_TestFile(self basePath() + previousName + ".a"))
            {
                FS_Remove(self basePath() + previousName + ".a");
            }
            if(FS_TestFile(self basePath() + previousName + ".b"))
            {
                FS_Remove(self basePath() + previousName + ".b");
            }
        }
    }
    activeSectionName = self.cpc.route;
    if(activeSectionName == previousName)
    {
        activeSectionName = newName;
    }
    self openCJ\checkpointCreation::_close();
    self openCJ\checkpointPublish::activate();
    self openCJ\checkpointCreation::_start(activeSectionName);
    refreshRenamedRoute(previousName, newName);
    self sendLocalChatMessage(
        "Renamed " + previousName + " to " + newName +
        ". Colors, checkpoint IDs and records retained; separately named branches are unchanged.");
    return true;
}

followingShared()
{
    return isDefined(self.cpc.network) && members(self.cpc.network, self.cpc.route).size > 1 &&
           self.cpc.selected < self.cpc.rows.size;
}

selectDetectedShared()
{
    if(isDefined(self.cpc.insertAfter))
    {
        return false;
    }
    network = self load();
    if(!isDefined(network) || members(network, self.cpc.route).size < 2)
    {
        return false;
    }
    for(i = 0; i < self.cpc.rows.size; i++)
    {
        confirmedCheckpoint = openCJ\checkpointCreation::_decode(self.cpc.rows[i]);
        areas = [];
        areas[0] = confirmedCheckpoint.points;
        for(j = 0; j < confirmedCheckpoint.alternatives.size; j++)
        {
            areas[areas.size] = confirmedCheckpoint.alternatives[j];
        }
        for(j = 0; j < areas.size; j++)
        {
            if(areaOverlap(self.cpc.draft, confirmedCheckpoint, areas[j]))
            {
                self.cpc.selected = i;
                self.cpc.draft = confirmedCheckpoint;
                self.cpc.status = "Shared landing " + (i + 1) + " selected";
                return true;
            }
        }
    }
    if(self followingShared())
    {
        // Detection is navigation here, not permission to overwrite a shared landing.
        self.cpc.draft = openCJ\checkpointCreation::_decode(self.cpc.rows[self.cpc.selected]);
        self.cpc.status = "Outside shared path: split from the last shared landing first";
        self sendLocalChatMessage(
            "This landing is not in the shared section. Last shared checkpoint stays selected. Use !cp split <keep route> <new branch> (e.g. !cp split easy hard), then detect this landing again.",
            true);
    }
    return false;
}

// Observe all existing landings, not just the next one. Never replace pending edits.
trackSharedLanding(origin, grounded)
{
    if (self.cpc.testing || !isDefined(self.cpc.network) ||
       members(self.cpc.network, self.cpc.route).size < 2 || !grounded)
    {
        return;
    }
    checkpointIndex = -1;
    for (i = 0; i < self.cpc.rows.size; i++)
    {
        confirmedCheckpoint = openCJ\checkpointCreation::_decode(self.cpc.rows[i]);
        if (self openCJ\checkpointCreation::contains(confirmedCheckpoint, origin, true))
        {
            checkpointIndex = i;
            break;
        }
    }
    if (isDefined(self.cpc.sharedPresence) && self.cpc.sharedPresence == checkpointIndex)
    {
        return;
    }
    self.cpc.sharedPresence = checkpointIndex;
    if (checkpointIndex < 0 || pendingEdit(self.cpc))
    {
        return;
    }
    self.cpc.selected = checkpointIndex;
    self.cpc.draft = openCJ\checkpointCreation::_decode(self.cpc.rows[checkpointIndex]);
    self.cpc.overlap = undefined;
    self.cpc.overlapSection = undefined;
    self.cpc.status = "";
    self openCJ\checkpointCreation::_save();
}

// Moving objects may cross stationary floors without sharing a checkpoint.
areaOverlap(candidateCheckpoint, confirmedCheckpoint, confirmedPoints)
{
    candidateMoving = openCJ\checkpointMoving::isMoving(candidateCheckpoint);
    confirmedMoving = openCJ\checkpointMoving::isMoving(confirmedCheckpoint);
    if (candidateMoving || confirmedMoving)
    {
        return candidateMoving && confirmedMoving &&
               candidateCheckpoint.platformRef == confirmedCheckpoint.platformRef;
    }
    return openCJ\checkpointHeight::overlap(candidateCheckpoint, candidateCheckpoint.points,
                                            confirmedCheckpoint, confirmedPoints);
}

// Names cached by an already-open board are presentation data, never identity.
refreshRenamedRoute(previousName, newName)
{
    players = getEntArray("player", "classname");
    for(i = 0; i < players.size; i++)
    {
        player = players[i];
        if(isDefined(player.currentBoard) && isDefined(player.currentBoard["routes"]))
        {
            for(j = 0; j < player.currentBoard["routes"].size; j++)
            {
                if(player.currentBoard["routes"][j] == previousName)
                {
                    player.currentBoard["routes"][j] = newName;
                }
            }
            if(isDefined(player.currentMenu) && (player.currentMenu == "opencj_leaderboard" ||
                                                 player.currentMenu == "opencj_runsboard"))
            {
                player openCJ\menus\board_base::updateRoutes();
                player thread openCJ\menus\board_base::updateBoard();
            }
        }
        if(isDefined(player.currentMenu) && player.currentMenu == "opencj_challenges")
        {
            player thread openCJ\challenges::show();
        }
    }
}
