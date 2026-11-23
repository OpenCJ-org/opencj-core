#include openCJ\util;

// Record a timed checkpoint; the offset interpolates contact within the previous server frame.
_checkpointPassed(checkpoint, timeOffsetMs)
{
    elapsedMs = self openCJ\playTime::getTimePlayed();
    checkpointId = getCheckpointID(checkpoint);
    if (!isDefined(checkpointId))
    {
        return;
    }

    // Paused runs keep their visible checkpoint state without recording a new split.
    if (!self openCJ\playerRuns::hasRunID())
    {
        return;
    }
    if (self openCJ\playerRuns::isRunPaused())
    {
        self iprintln("^5You passed a checkpoint, but your run is paused.");
        return;
    }
    if (!isDefined(self.route))
    {
        self.route = getRouteNameForCheckpoint(checkpoint);
    }
    passedAtMs = elapsedMs + timeOffsetMs;
    self openCJ\showRecords::onCheckpointPassed(checkpoint, passedAtMs);
    runID = self openCJ\playerRuns::getRunID();
    self thread storeCheckpointPassed(runID, checkpointId, passedAtMs);
    self thread openCJ\recordNotices::checkpoint(runID, checkpointId, passedAtMs);
}

storeCheckpointPassed(runID, checkpointId, elapsedMs)
{
    if (self openCJ\playerRuns::isRunFinished() || !self openCJ\playerRuns::hasRunID() ||
       self openCJ\cheating::isCheating())
    {
        return false;
    }

    saveCount = self openCJ\statistics::getSaveCount();
    loadCount = self openCJ\statistics::getLoadCount();
    explosiveJumps = self openCJ\statistics::getExplosiveJumps();       // RPG/nade jump
    explosiveLaunches = self openCJ\statistics::getExplosiveLaunches(); // RPG launch / nade throw
    doubleExplosives = self openCJ\statistics::getDoubleExplosives();   // Double RPGs

    // Snapshot run statistics before the asynchronous write can yield.
    explosiveArguments = explosiveJumps + ", " + explosiveLaunches + ", " + doubleExplosives;
    modeArguments = "";
    if (getCodVersion() == 4)
    {
        modeArguments = ", '" + self openCJ\fps::getCurrentFPSMode() + "', " +
                        int(self openCJ\elevate::hasUsedEle()) + ", " +
                        int(self openCJ\anyPct::hasAnyPct()) + ", " + int(self openCJ\tas::hasHardTAS());
    }
    instanceNumber = self openCJ\playerRuns::getRunInstanceNumber();
    query = "SELECT checkpointPassed(" + runID + ", " + checkpointId + ", " + elapsedMs + ", " +
            saveCount + ", " + loadCount + ", " + explosiveArguments + modeArguments + ", " +
            instanceNumber + ")";
    printf("Executing checkpointPassed query:\n" + query + "\n"); // Debug

    resultRows = self openCJ\mySQL::mysqlAsyncWrite(query, "run:" + runID);
    if (!isDefined(resultRows) || !isDefined(resultRows[0]) || !isDefined(resultRows[0][0]))
    {
        message = self openCJ\runStorage::resultMessage(
            runID, instanceNumber, resultRows, "checkpoint progress");
        if (message != "")
        {
            self iPrintLnBold(message);
        }
        return false;
    }
    return true;
}


onRunStarted()
{
    self.route = undefined;
}

// Load a complete graph before advancing the layout epoch used by player caches.
onInit()
{
    previousGraph = captureCheckpointGraph();
    level.checkpoints_startCheckpoint = spawnStruct();
    level.checkpoints_startCheckpoint.isEleAllowed = false;
    level.checkpoints_startCheckpoint.childs = [];
    level.checkpoints_checkpoints = [];

    if(openCJ\mapid::hasMapID())
    {
        checkpointRows = readCheckpointRows();
        if(!isDefined(checkpointRows))
        {
            restoreCheckpointGraph(previousGraph);
            return false;
        }
        checkpoints = [];
        for(i = 0; i < checkpointRows.size; i++)
        {
            checkpoints[i] = decodeCheckpointRow(checkpointRows[i]);
        }
        linkCheckpointChildren(checkpoints);
        resolveCheckpointBrothers(checkpoints);
        startCheckpoint = level.checkpoints_startCheckpoint;
        for(i = 0; i < checkpoints.size; i++)
        {
            if(!checkpoints[i].hasParent)
            {
                startCheckpoint.childs[startCheckpoint.childs.size] = checkpoints[i];
            }
        }
        level.checkpoints_startCheckpoint.checkpointsFromStart = 0;
        level.checkpoints_checkpoints = checkpoints;
        if(!openCJ\checkpointPublish::loadAreas())
        {
            restoreCheckpointGraph(previousGraph);
            return false;
        }
        linkContactAreas(checkpoints);
        annotateRouteEndpoints();
        annotateDistanceFromStart();
        _parseRoutesAndFixUnnamedRoutes();
    }
    if(!isDefined(level.checkpointLayoutEpoch))
    {
        level.checkpointLayoutEpoch = 0;
    }
    level.checkpointLayoutEpoch++;
    return true;
}

// CoD2 retains its older finish columns; both queries return the same row shape.
readCheckpointRows()
{
    if(getCodVersion() == 4)
    {
        query = "SELECT a.cpID, a.x, a.y, a.z, a.radius, a.onGround, " +
                "GROUP_CONCAT(b.childCpID), r.routeName, a.elevate, NULL, " +
                "c.bigBrotherID, a.allowSave, a.finishRouteID " +
                "FROM checkpoints a " +
                "LEFT JOIN routes r ON r.routeID=a.finishRouteID " +
                "LEFT JOIN checkpointConnections b ON a.cpID = b.cpID " +
                "LEFT JOIN checkpointBrothers c ON a.cpID = c.cpID ";
    }
    else
    {
        query = "SELECT a.cpID, a.x, a.y, a.z, a.radius, a.onGround, " +
                "GROUP_CONCAT(b.childCpID), a.ender, a.elevate, a.endShaderColor, " +
                "c.bigBrotherID, a.allowSave, NULL " +
                "FROM checkpoints a " +
                "LEFT JOIN checkpointConnections b ON a.cpID = b.cpID " +
                "LEFT JOIN checkpointBrothers c ON a.cpID = c.cpID ";
    }
    return openCJ\mySQL::mysqlSyncQuery(
        query + "WHERE a.retired=0 AND a.mapID = " + openCJ\mapid::getMapID() + " GROUP BY a.cpID");
}

// Decode the positional SQL result once; graph traversal uses named checkpoint fields.
decodeCheckpointRow(row)
{
    checkpoint = spawnStruct();
    checkpoint.id = int(row[0]);
    checkpoint.origin = (int(row[1]), int(row[2]), int(row[3]));
    checkpoint.radius = intOrUndefined(row[4]);
    checkpoint.onGround = int(row[5]) != 0;
    childIdsCsv = row[6];
    checkpoint.ender = row[7];
    checkpoint.isEleAllowed = int(row[8]);
    checkpoint.endShaderColor = row[9];
    checkpoint.bigBrother = intOrUndefined(row[10]);
    checkpoint.allowSave = int(row[11]) != 0;
    checkpoint.finishRouteID = intOrUndefined(row[12]);
    checkpoint.hasParent = false;
    checkpoint.childIDs = [];
    if(isDefined(childIdsCsv))
    {
        checkpoint.childIDs = strTok(childIdsCsv, ",");
    }
    return checkpoint;
}

// Replace stored child IDs with graph references and identify roots and finish candidates.
linkCheckpointChildren(checkpoints)
{
    for(i = 0; i < checkpoints.size; i++)
    {
        checkpoint = checkpoints[i];
        checkpoint.childs = [];
        for(j = 0; j < checkpoint.childIDs.size; j++)
        {
            childId = int(checkpoint.childIDs[j]);
            found = false;
            for(k = 0; k < checkpoints.size; k++)
            {
                if(k == i || checkpoints[k].id != childId)
                {
                    continue;
                }
                child = checkpoints[k];
                checkpoint.childs[checkpoint.childs.size] = child;
                // Only leaf checkpoints may finish a route.
                checkpoint.ender = undefined;
                child.hasParent = true;
                found = true;
                break;
            }
            if(!found)
            {
                printf("WARNING: Could not find child " + checkpoint.childIDs[j] +
                       " for checkpoint " + checkpoint.id + "\n");
            }
        }
        checkpoint.childIDs = undefined;
        checkpoint.hasChildren = checkpoint.childs.size > 0;
        checkpoint.endCheckpoints = [];
    }
}

resolveCheckpointBrothers(checkpoints)
{
    for(i = 0; i < checkpoints.size; i++)
    {
        checkpoint = checkpoints[i];
        if(!isDefined(checkpoint.bigBrother))
        {
            continue;
        }
        for(j = 0; j < checkpoints.size; j++)
        {
            if(i != j && checkpoint.bigBrother == checkpoints[j].id)
            {
                checkpoint.bigBrother = checkpoints[j];
                break;
            }
        }
    }
}

// Walk back from each finish to record reachable routes and distances to a finish.
annotateRouteEndpoints()
{
    finishCheckpoints = getAllEndCheckpoints();
    level.checkpoints_startCheckpoint.endCheckpoints = finishCheckpoints;
    level.checkpoints_startCheckpoint.enderName = _determineEnderName(finishCheckpoints);
    if(finishCheckpoints.size == 0)
    {
        level.checkpoints_startCheckpoint.checkpointsTillEnd = 0;
    }
    for(i = 0; i < finishCheckpoints.size; i++)
    {
        finish = finishCheckpoints[i];
        frontier = [];
        frontier[0] = finish;
        finish.endCheckpoints[finish.endCheckpoints.size] = finish;
        finish.checkpointsTillEnd = 0;
        visited = finishCheckpoints;
        distanceFromFinish = 0;
        while(frontier.size)
        {
            nextFrontier = [];
            for(j = 0; j < frontier.size; j++)
            {
                checkpoint = frontier[j];
                if(!isDefined(checkpoint.checkpointsTillEnd))
                {
                    checkpoint.checkpointsTillEnd = distanceFromFinish;
                }
                parents = getCheckpointParents(checkpoint);
                if(!parents.size &&
                   !isDefined(level.checkpoints_startCheckpoint.checkpointsTillEnd))
                {
                    level.checkpoints_startCheckpoint.checkpointsTillEnd = distanceFromFinish + 1;
                }
                for(k = 0; k < parents.size; k++)
                {
                    parent = parents[k];
                    if(isInArray(parent, visited) || isInArray(parent, frontier) ||
                       isInArray(parent, nextFrontier))
                    {
                        continue;
                    }
                    nextFrontier[nextFrontier.size] = parent;
                    parent.endCheckpoints[parent.endCheckpoints.size] = finish;
                }
                visited[visited.size] = checkpoint;
            }
            frontier = nextFrontier;
            distanceFromFinish++;
        }
    }
}

// Breadth-first traversal assigns the shortest number of steps from any opening.
annotateDistanceFromStart()
{
    frontier = level.checkpoints_startCheckpoint.childs;
    visited = [];
    distanceFromStart = 1;
    while(frontier.size)
    {
        nextFrontier = [];
        for(i = 0; i < frontier.size; i++)
        {
            checkpoint = frontier[i];
            if(!isDefined(checkpoint.checkpointsFromStart))
            {
                checkpoint.checkpointsFromStart = distanceFromStart;
            }
            for(j = 0; j < checkpoint.childs.size; j++)
            {
                child = checkpoint.childs[j];
                if(isInArray(child, visited) || isInArray(child, frontier) ||
                   isInArray(child, nextFrontier))
                {
                    continue;
                }
                nextFrontier[nextFrontier.size] = child;
            }
            visited[visited.size] = checkpoint;
        }
        frontier = nextFrontier;
        distanceFromStart++;
    }
}

// Keep graph objects alive until all synchronous data reads have succeeded.
// No waits occur while onInit replaces them, so a rejected refresh can restore them together.
captureCheckpointGraph()
{
    previousGraph = spawnStruct();
    previousGraph.start = level.checkpoints_startCheckpoint;
    previousGraph.checkpoints = level.checkpoints_checkpoints;
    previousGraph.routes = level.checkpointRoutes;
    previousGraph.routeEnders = level.routeEnders;
    return previousGraph;
}

restoreCheckpointGraph(previousGraph)
{
    if(isDefined(previousGraph.start))
    {
        level.checkpoints_startCheckpoint = previousGraph.start;
        level.checkpoints_checkpoints = previousGraph.checkpoints;
        level.checkpointRoutes = previousGraph.routes;
        level.routeEnders = previousGraph.routeEnders;
        return;
    }

    // Startup has no earlier graph to recover; leave an explicit empty graph.
    level.checkpoints_startCheckpoint = spawnStruct();
    level.checkpoints_startCheckpoint.isEleAllowed = false;
    level.checkpoints_startCheckpoint.childs = [];
    level.checkpoints_startCheckpoint.checkpointsFromStart = 0;
    level.checkpoints_startCheckpoint.checkpointsTillEnd = 0;
    level.checkpoints_startCheckpoint.endCheckpoints = [];
    level.checkpoints_checkpoints = [];
    level.checkpointRoutes = [];
    level.routeEnders = [];
}

_parseRoutesAndFixUnnamedRoutes()
{
    // Goal: fill in names for unnamed routes, and store all (not only unnamed) routes into level.routeEnders for later leaderboard use

    nextRouteNr = 1;
    level.routeEnders = []; // Will have all 'finish' checkpoint IDs for each route
    for (i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        checkpoint = level.checkpoints_checkpoints[i];
        if (checkpoint.hasChildren)
        {
            // Not an end checkpoint
            continue;
        }

        // Even if the checkpoint has an ender, bigBrother takes precedence and we'll encounter (or have encountered) that checkpoint.
        if (isDefined(checkpoint.bigBrother))
        {
            // All 'little brother' checkpoints link to the same big brother, but we do a quick check for corruption
            bigBro = checkpoint.bigBrother;
            if (isDefined(bigBro.bigBrother))
            {
                printf("WARNING: big brother is not as big as he thought..\n"); // We'd want to dump the ID, but since it has a big brother we shouldn't..
            }

            continue;
        }

        // Found an end checkpoint. Check if its ender has a name.
        if (isDefined(checkpoint.ender) && (checkpoint.ender.size > 0))
        {
            // Route is named, store this route name if it wasn't already known
            _storeRouteAndEndCheckpoint(checkpoint);
            continue;
        }

        // No route was found. Generate a name.
        name = "normal";
        if (nextRouteNr > 1)
        {
            name += nextRouteNr;
        }
        checkpoint.ender = name;
        nextRouteNr++;

        // Store the (newly filled in) route name
        _storeRouteAndEndCheckpoint(checkpoint);
    }
}

_storeRouteAndEndCheckpoint(checkpoint)
{
    enderName = checkpoint.ender;
    if (!isDefined(level.routeEnders[enderName]))
    {
        level.routeEnders[enderName] = [];
    }

    // And add the end checkpoint for the route.
    level.routeEnders[enderName][level.routeEnders[enderName].size] = checkpoint;
}

getRouteNameForCheckpoint(checkpoint)
{
    if (!isDefined(checkpoint))
    {
        return undefined;
    }

    if (isDefined(checkpoint.bigBrother))
    {
        checkpoint = checkpoint.bigBrother;
    }

    if (!isDefined(checkpoint.id))
    {
        return undefined;
    }

    return _determineEnderName(getEndCheckpoints(checkpoint));
}

_determineEnderName(endCheckpoints) // Argument is the end checkpoint(s) for a specific checkpoint
{
    if (!isDefined(endCheckpoints))
    {
        return undefined;
    }

    // Goal: determine what route a checkpoint is part of
    // This is used for displaying the route on screen, so if the player has not yet selected a route, we want to show nothing (undefined)
    enderName = undefined;
    for(i = 0; i < endCheckpoints.size; i++)
    {
        if(!isDefined(endCheckpoints[i].ender))
        {
            if (!isDefined(endCheckpoints[i].bigBrother))
            {
                return undefined; // There is (at least) an unnamed ender in here. So we don't know the name of the route for sure.
            }
            continue; // Checkpoint has a big brother so we don't care if this one doesn't have an ender name
        }

        // We already had an enderName from one of the other end checkpoints, and now another one
        if (isDefined(enderName) && enderName != endCheckpoints[i].ender)
        {
            return undefined; // Multiple ender names, can't know for sure which route
        }

        enderName = endCheckpoints[i].ender;
    }

    return enderName;
}

getCheckpointShaderColor(checkpoint)
{
    if(!isDefined(checkpoint))
    {
        return undefined;
    }
    ends = getEndCheckpoints(checkpoint);
    endShaderColors = [];
    undefined_endShaderColor = false;
    for(i = 0; i < ends.size; i++)
    {
        if(!isDefined(ends[i].endShaderColor))
        {
            undefined_endShaderColor = true;
        }
        else if(!isInArray(ends[i].endShaderColor, endShaderColors))
        {
            endShaderColors[endShaderColors.size] = ends[i].endShaderColor;
        }
    }
    if(endShaderColors.size != 1 || undefined_endShaderColor)
    {
        return undefined;
    }
    return endShaderColors[0];
}

isEleAllowed(checkpoint)
{
    return checkpoint.isEleAllowed;
}

getPassedCheckpointCount(checkpoint)
{
    return checkpoint.checkpointsFromStart;
}

getRemainingCheckpointCount(checkpoint)
{
    remainingCount = checkpoint.checkpointsTillEnd;
    // Before choosing a route, show the longest possible total in the HUD.
    if (!isDefined(getRouteNameForCheckpoint(checkpoint)))
    {
        finishCheckpoints = getEndCheckpoints(checkpoint);
        for (i = 0; i < finishCheckpoints.size; i++)
        {
            routeRemainingCount = finishCheckpoints[i].checkpointsFromStart -
                                  checkpoint.checkpointsFromStart;
            if (isDefined(routeRemainingCount) &&
                (!isDefined(remainingCount) || routeRemainingCount > remainingCount))
            {
                remainingCount = routeRemainingCount;
            }
        }
    }
    return remainingCount;
}

getEndCheckpoints(checkpoint)
{
    if (!isDefined(checkpoint))
    {
        return undefined;
    }

    endCheckpoints = [];
    if (!isDefined(checkpoint.hasChildren) || !checkpoint.hasChildren)
    {
        endCheckpoints[0] = checkpoint;
        return endCheckpoints;
    }
    return checkpoint.endCheckpoints;
}

getAllEndCheckpoints()
{
    enders = [];
    for(i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        if(level.checkpoints_checkpoints[i].childs.size == 0)
        {
            enders[enders.size] = level.checkpoints_checkpoints[i];
        }
    }
    return enders;
}

getAllCheckpoints()
{
    return level.checkpoints_checkpoints;
}

getCheckpointsForRoute(routeName)
{
    if (!isDefined(level.routeEnders[routeName]))
    {
        return undefined;
    }

    endCheckpointForRoute = undefined;
    for (i = 0; i < level.routeEnders[routeName]; i++)
    {
        if (!isDefined(level.routeEnders[routeName][i].bigBrother))
        {
            // Should only be one final checkpoint
            endCheckpointForRoute = level.routeEnders[routeName][i];
            break;
        }
    }

    if (!isDefined(endCheckpointForRoute))
    {
        printf("ERROR: all ender checkpoints have big brothers or none exist\n");
        return undefined;
    }

    // Get all checkpoint ids in the route from the end checkpoint id
    checkpointIdsInRoute = [];
    currentCheckpoint = endCheckpointForRoute;
    nextIdx = 0;
    for (i = 0; i < level.checkpoints_checkpoints.size; i++) // Using a for loop to prevent infinite loop
    {
        if (isDefined(currentCheckpoint.bigBrother))
        {
            currentCheckpoint = currentCheckpoint.bigBrother;
        }

        // Add this checkpoint as part of the route
        checkpointIdsInRoute[nextIdx] = currentCheckpoint.id;
        nextIdx++;

        // Continue with the parent of the checkpoint. If there is none, we are finished.
        parents = getCheckpointParents(currentCheckpoint);
        if (!isDefined(parents))
        {
            break; // No parents
        }

        if (parents.size > 0) // We're at the point where routes are splitting
        {
            break; // Multiple parents
        }

        currentCheckpoint = parents[0];
    }
}

getCheckpointParents(checkpoint)
{
    parents = [];
    for(i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        for(j = 0; j < level.checkpoints_checkpoints[i].childs.size; j++)
        {
            if(level.checkpoints_checkpoints[i].childs[j] == checkpoint)
            {
                parents[parents.size] = level.checkpoints_checkpoints[i];
            }
        }
    }
    return parents;
}

checkpointHasID(cp)
{
    return (isDefined(cp) && isDefined(cp.id));
}

getCheckpointByID(id)
{
    if (!isDefined(id))
    {
        return undefined;
    }

    for(i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        if(level.checkpoints_checkpoints[i].id == id)
        {
            return level.checkpoints_checkpoints[i];
        }
    }

    return undefined;
}

getCheckpointID(cp)
{
    id = undefined;

    // Checkpoint may not have an ID
    if (!isDefined(cp))
    {
        return; // That's a shame
    }

    if (!isDefined(cp.id))
    {
        if (!isDefined(cp.bigBrother))
        {
            return; // Nothing we can do
        }

        brotherCheckpoint = cp.bigBrother;
        for (i = 0; i < level.checkpoints.size; i++)
        {
            if (isDefined(brotherCheckpoint.id))
            {
                id = brotherCheckpoint.id;
                break; // Found it!
            }

            if (!isDefined(brotherCheckpoint.bigBrother))
            {
                break; // No luck
            }

            // Try the next one
            brotherCheckpoint = brotherCheckpoint.bigBrother;
        }
    }
    else
    {
        id = cp.id;
    }

    return id;
}

// Rebuild the passed-checkpoint cache after loading a save. The save already carries
// any% state, so all ancestors count as passed even when the original run skipped one.
updateCheckpointsForPlayer(newCheckpointID)
{
    self.checkpoints_passed = [];
    self _setCurrentCheckpoint(getCheckpointByID(newCheckpointID));
    currentCheckpoint = self.checkpoints_checkpoint;
    if (!isDefined(currentCheckpoint) || currentCheckpoint == level.checkpoints_startCheckpoint)
    {
        return;
    }

    pendingCheckpoints = [];
    pendingCheckpoints[0] = currentCheckpoint;
    self.checkpoints_passed[0] = currentCheckpoint;
    currentGroup = currentCheckpoint;
    if (isDefined(currentGroup.bigBrother))
    {
        currentGroup = currentGroup.bigBrother;
    }
    visitedGroups = [];
    visitedGroups["" + currentGroup.id] = true;

    // Mark a group when queuing it. Rejoins and alternative areas must not add it
    // twice; the same bound also stops a malformed cycle from stalling the server.
    while (pendingCheckpoints.size > 0)
    {
        lastIndex = pendingCheckpoints.size - 1;
        parents = getCheckpointParents(pendingCheckpoints[lastIndex]);
        pendingCheckpoints[lastIndex] = undefined;
        for (i = 0; i < parents.size; i++)
        {
            parent = parents[i];
            if (isDefined(parent.bigBrother))
            {
                parent = parent.bigBrother;
            }
            groupKey = "" + parent.id;
            if (isDefined(visitedGroups[groupKey]))
            {
                continue;
            }
            visitedGroups[groupKey] = true;
            pendingCheckpoints[pendingCheckpoints.size] = parent;
            self.checkpoints_passed[self.checkpoints_passed.size] = parent;
        }
    }
}

getCurrentCheckpointID()
{
    return self.checkpoints_checkpoint.id;
}

_setCurrentCheckpoint(checkpoint)
{
    if(!self isPlayerReady(true) || self openCJ\playerRuns::isRunFinished())
    {
        return;
    }

    oldcheckpoint = self.checkpoints_checkpoint;
    if(!isDefined(checkpoint))
    {
        self.checkpoints_checkpoint = level.checkpoints_startCheckpoint;
    }
    else
    {
        self.checkpoints_checkpoint = checkpoint;
    }

    // Update player's route
    self.route = getRouteNameForCheckpoint(checkpoint);

    // Checkpoints may have changed for this player
    if(self.checkpoints_checkpoint != oldcheckpoint)
    {
        self openCJ\events\checkpointsChanged::main();
    }
}

getCurrentChildCheckpoints()
{
    if (isDefined(self.checkpoints_checkpoint))
    {
        return self.checkpoints_checkpoint.childs;
    }
    return undefined;
}

nextAllowsDoubleRPG()
{
    if (self openCJ\checkpointCreation::isEditing())
    {
        if (self.cpc.testing && self.cpc.testNext < self.cpc.rows.size)
        {
            nextCheckpoint = self openCJ\checkpointCreation::getConfirmed(self.cpc.testNext);
            return nextCheckpoint.double;
        }
        return false;
    }
    nextCheckpoints = self getCurrentChildCheckpoints();
    if (!isDefined(nextCheckpoints) || nextCheckpoints.size == 0)
    {
        return false;
    }
    // Equivalent landing areas share one requirement. Distinct route splits
    // remain ambiguous, even if one of their branches grants double RPG.
    nextCheckpoints = filterOutBrothers(nextCheckpoints);
    if (nextCheckpoints.size != 1)
    {
        return false;
    }
    return isDefined(nextCheckpoints[0].allowDoubleRPG) && nextCheckpoints[0].allowDoubleRPG;
}

// Same ambiguity rule as Double RPG: alternative areas share one requirement;
// a split into different checkpoints does not grant a branch's exemption globally.
nextAllowsEle()
{
    nextCheckpoints = self getCurrentChildCheckpoints();
    if (!isDefined(nextCheckpoints) || nextCheckpoints.size == 0)
    {
        return false;
    }
    nextCheckpoints = filterOutBrothers(nextCheckpoints);
    return nextCheckpoints.size == 1 && isDefined(nextCheckpoints[0].isEleAllowed) &&
           nextCheckpoints[0].isEleAllowed;
}

hasPassedCheckpoint(checkpoint)
{
    if (isDefined(checkpoint.bigBrother))
    {
        checkpoint = checkpoint.bigBrother;
    }
    for (i = 0; i < self.checkpoints_passed.size; i++)
    {
        passedCheckpoint = self.checkpoints_passed[i];
        if (isDefined(passedCheckpoint.bigBrother))
        {
            passedCheckpoint = passedCheckpoint.bigBrother;
        }
        if (passedCheckpoint.id == checkpoint.id)
        {
            return true;
        }
    }
    return false;
}

getCurrentCheckpoint()
{
    return self.checkpoints_checkpoint;
}

onRunCreated()
{
    resetPlayerCheckpointsToStart();
}

resetPlayerCheckpointsToStart()
{
    self.checkpointContact = undefined;
    self.route = undefined;
    self.checkpoints_checkpoint = level.checkpoints_startCheckpoint;
    self.checkpoints_passed = [];
}

onLoadPosition()
{
    self.checkpointContact = undefined;
    self.previousOrigin = self.origin;
    self.previousOnground = true;
}

onSpawnPlayer()
{
    self.checkpointContact = undefined;
    self.previousOrigin = self.origin;
    self.previousOnground = true;
}

filterOutBrothers(checkpoints)
{
    newcheckpoints = [];
    brothers = [];
    for(i = 0; i < checkpoints.size; i++)
    {
        if(isDefined(checkpoints[i].bigBrother))
        {
            brothers[brothers.size] = checkpoints[i];
        }
        else
        {
            newcheckpoints[newcheckpoints.size] = checkpoints[i];
        }
    }
    for(i = 0; i < brothers.size; i++)
    {
        if(!isInArray(brothers[i].bigBrother, newcheckpoints))
        {
            newcheckpoints[newcheckpoints.size] = brothers[i].bigBrother;
        }
    }
    return newcheckpoints;
}

getSubSVFPsPassedTiming(prevOrg, newOrg, prevOnGround, cp)
{
    // If there is no previous origin, can't calculate how much distance the player has moved, so no accurate timing
    if (!isDefined(prevOrg))
    {
        return 0;
    }

    tOffset = 0;
    if ((prevOrg != newOrg) && // Did player move?
        distanceSquared(prevOrg, newOrg) < (250 * 250) && // Basic teleport check. TODO: not accurate, player could have teleported a shorter distance
        (!cp.onGround || prevOnGround)) // TODO: onGround callback doesn't have origin yet, so not sure when exactly player landed
    {
        checkpointDist = distance(newOrg, cp.origin);
        previousCheckpointDist = distance(prevOrg, cp.origin);
        radius = cp.radius;
        if (checkpointDist < previousCheckpointDist)
        {
            tOffset = int(((radius - checkpointDist) / (previousCheckpointDist - checkpointDist)) * -50);
            if (tOffset > 0)
            {
                tOffset = 0;
            }
            else if(tOffset < -50)
            {
                tOffset = -50;
            }
        }
    }

    return tOffset;
}

_checkAnyPctTriggered(checkpoint, nextCheckpoints)
{
    routeName = getRouteNameForCheckpoint(checkpoint);
    if (isDefined(self.route) && isDefined(routeName) && routeName != self.route)
    {
        return true;
    }
    // Expected successors do not skip any required steps.
    for (i = 0; i < nextCheckpoints.size; i++)
    {
        // One of the next allowed checkpoints?
        if (checkpoint == nextCheckpoints[i])
        {
            return false;
        }
    }

    // Another checkpoint on the same route skips a required step.
    if (isDefined(self.route))
    {
        if (isDefined(routeName) && (routeName == self.route))
        {
            return true;
        }
    }
    else
    {
        // A shared opening has no single route name. A non-child checkpoint
        // with parents still skips required steps, including the first branch.
        if (checkpoint.hasParent)
        {
            return true;
        }
    }

    return false;
}

// Prefer the expected landing, reserve it while contact settles, then score it once.
whileAlive()
{
    if (!self openCJ\playerRuns::modeDetectionActive() ||
        (isDefined(self.playerRuns_runFinishing) && self.playerRuns_runFinishing))
    {
        return;
    }
    nextCheckpoints = self getCurrentChildCheckpoints();
    if (!isDefined(nextCheckpoints))
    {
        return;
    }

    foundContact = false;
    grounded = self isOnGround();
    groundEntity = self getGroundEntity();
    onCurrentCheckpoint = self touchesCheckpointGroup(
        self.checkpoints_checkpoint, grounded, groundEntity);
    for (i = 0; i < nextCheckpoints.size + level.checkpoints_checkpoints.size; i++)
    {
        if (i < nextCheckpoints.size)
        {
            checkpoint = nextCheckpoints[i];
        }
        else
        {
            // Expected successors win over coincident areas on another route.
            // Standing on the current area must not trigger that other route next frame.
            if (onCurrentCheckpoint)
            {
                break;
            }
            checkpoint = level.checkpoints_checkpoints[i - nextCheckpoints.size];
        }
        if (!isDefined(checkpoint.radius) && !isDefined(checkpoint.area))
        {
            continue;
        }
        if (self hasPassedCheckpoint(checkpoint) || self.checkpoints_checkpoint == checkpoint)
        {
            continue;
        }
        if (!self touchesArea(checkpoint, grounded, groundEntity) ||
            (checkpoint.onGround && !grounded))
        {
            continue;
        }

        foundContact = true;
        // Keep this landing reserved while it settles instead of trying another route's area.
        if (!self contactReady(checkpoint, grounded, getTime(), self getVelocity()))
        {
            break;
        }
        self.checkpointContact = undefined;
        if (!self acceptCheckpointRoute(checkpoint, nextCheckpoints))
        {
            break;
        }
        self recordCheckpointContact(checkpoint);
        break;
    }

    // Leaving the area breaks continuous contact even without leaving the ground.
    if (!foundContact)
    {
        self.checkpointContact = undefined;
    }
    self.previousOrigin = self.origin;
    self.previousOnground = self isOnGround();
}

// Tutorials reject skipped steps; ordinary runs may continue with any% marked.
acceptCheckpointRoute(checkpoint, nextCheckpoints)
{
    if (self openCJ\anyPct::hasAnyPct() ||
        !self _checkAnyPctTriggered(checkpoint, nextCheckpoints))
    {
        return true;
    }
    if (self openCJ\tutorial::isTutorialRun())
    {
        self openCJ\tutorial::onCheckpointSkipped();
        return false;
    }
    routeName = getRouteNameForCheckpoint(checkpoint);
    printf("DEBUG ANYPCT: Player " + self.name + " triggered any pct on cpID: " + checkpoint.id + "\n");
    if (isDefined(self.route) && isDefined(routeName) && routeName != self.route)
    {
        self iprintlnbold("Route changed from " + self.route + " to " + routeName +
                         ": any'/. mode enabled");
    }
    else
    {
        self iprintlnbold("Checkpoint skipped, any'/. mode enabled");
    }
    self openCJ\anyPct::setAnyPct(true);
    return true;
}

// Keep the touched area's position for gameplay, but persist its canonical group's identity.
recordCheckpointContact(checkpoint)
{
    routeName = getRouteNameForCheckpoint(checkpoint);
    if (checkpoint.childs.size == 0 || self openCJ\anyPct::hasAnyPct())
    {
        self.route = routeName;
    }
    self.checkpoints_checkpoint = checkpoint;
    self.checkpoints_passed[self.checkpoints_passed.size] = checkpoint;

    // Landing areas use observed contact time; radius interpolation does not apply.
    timeOffsetMs = 0;
    if (!isDefined(checkpoint.area))
    {
        timeOffsetMs = getSubSVFPSPassedTiming(
            self.previousOrigin, self.origin, self.previousOnground, checkpoint);
    }
    if (isDefined(checkpoint.bigBrother))
    {
        checkpoint = checkpoint.bigBrother;
    }
    if (checkpoint.childs.size == 0)
    {
        self openCJ\events\runFinished::main(checkpoint, timeOffsetMs, routeName);
    }
    else
    {
        self _checkpointPassed(checkpoint, timeOffsetMs);
        self openCJ\events\checkpointsChanged::main(true);
    }
}

// True when the player touches a checkpoint that would skip part of their route
// (any%). Tutorial runs may not save there, so loading back leaves that spot.
touchesRouteSkippingCheckpoint()
{
    nextCheckpoints = self getCurrentChildCheckpoints();
    if (!isDefined(nextCheckpoints))
    {
        return false;
    }
    groundEntity = self getGroundEntity();
    // Like whileAlive: standing on the current checkpoint never triggers a
    // coincident checkpoint of another route.
    if (self touchesCheckpointGroup(self.checkpoints_checkpoint, self isOnGround(), groundEntity))
    {
        return false;
    }
    for (i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        checkpoint = level.checkpoints_checkpoints[i];
        if (!isDefined(checkpoint.radius) && !isDefined(checkpoint.area))
        {
            continue;
        }
        if (self hasPassedCheckpoint(checkpoint) || (self.checkpoints_checkpoint == checkpoint))
        {
            continue;
        }
        if (!self touchesArea(checkpoint, self isOnGround(), groundEntity))
        {
            continue;
        }
        if (self _checkAnyPctTriggered(checkpoint, nextCheckpoints))
        {
            return true;
        }
    }
    return false;
}

// Match the actual landing area, including alternatives loaded as separate areas.
canSaveHere()
{
    if (isDefined(self.cpc) || self openCJ\anyPct::hasAnyPct())
    {
        return true;
    }
    for (i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        checkpoint = level.checkpoints_checkpoints[i];
        if (!isDefined(checkpoint.allowSave) || checkpoint.allowSave)
        {
            continue;
        }
        if (openCJ\checkpointMoving::isMoving(checkpoint))
        {
            platform = openCJ\checkpointMoving::resolve(checkpoint.platformRef);
            if (isDefined(platform) &&
               ((isDefined(self getGroundEntity()) && self getGroundEntity() == platform) ||
                self isTouching(platform)))
            {
                return false;
            }
        }
        else if (isDefined(checkpoint.area))
        {
            if (openCJ\checkpointArea::touchesPlayer(
                    checkpoint.area, self.origin, self isOnGround(), false,
                    openCJ\checkpointHeight::above(checkpoint)))
            {
                return false;
            }
        }
        else if (isDefined(checkpoint.radius) &&
                distanceSquared(self.origin, checkpoint.origin) <= checkpoint.radius * checkpoint.radius)
        {
            return false;
        }
    }
    return true;
}

// Ordinary-speed landings count immediately; excess carried speed still needs
// 150 ms of continuous contact. Geometry, CPC and no-save checks stay separate.
// 350 u/s is a conservative strafe-jump allowance, not a reachability proof.
contactReady(checkpoint, grounded, nowMs, velocity)
{
    if (!checkpoint.onGround)
    {
        self.checkpointContact = undefined;
        return true;
    }
    if (!grounded)
    {
        self.checkpointContact = undefined;
        return false;
    }
    ordinaryLandingSpeed = 350;
    contactGapLimitMs = 100;
    requiredContactMs = 150;
    // Only horizontal momentum carries into the next jump. Unknown velocity keeps
    // the settled-contact rule, including callers that do not supply a sample.
    if (isDefined(velocity))
    {
        horizontalSpeedSquared = velocity[0] * velocity[0] + velocity[1] * velocity[1];
        if (horizontalSpeedSquared <= ordinaryLandingSpeed * ordinaryLandingSpeed)
        {
            self.checkpointContact = undefined;
            return true;
        }
    }
    contact = self.checkpointContact;
    if (!isDefined(contact) || contact.checkpoint != checkpoint ||
        nowMs - contact.lastSeenMs > contactGapLimitMs)
    {
        contact = spawnStruct();
        contact.checkpoint = checkpoint;
        contact.startedMs = nowMs;
    }
    contact.lastSeenMs = nowMs;
    self.checkpointContact = contact;
    return nowMs - contact.startedMs >= requiredContactMs;
}

// Cache alternative groups once when loading the graph, not every player tick.
linkContactAreas(checkpoints)
{
    for (i = 0; i < checkpoints.size; i++)
    {
        checkpoints[i].contactAreas = [];
    }
    for (i = 0; i < checkpoints.size; i++)
    {
        checkpoint = checkpoints[i];
        groupLeader = checkpoint;
        if (isDefined(checkpoint.bigBrother))
        {
            groupLeader = checkpoint.bigBrother;
        }
        groupLeader.contactAreas[groupLeader.contactAreas.size] = checkpoint;
    }
}

touchesArea(checkpoint, grounded, groundEntity)
{
    if (!isDefined(checkpoint))
    {
        return false;
    }
    if (openCJ\checkpointMoving::isMoving(checkpoint))
    {
        return self openCJ\checkpointMoving::touches(checkpoint, grounded, groundEntity);
    }
    if (isDefined(checkpoint.area))
    {
        return openCJ\checkpointArea::touchesPlayer(
            checkpoint.area, self.origin, grounded, checkpoint.onGround,
            openCJ\checkpointHeight::above(checkpoint));
    }
    if (!isDefined(checkpoint.radius) || (checkpoint.onGround && !grounded))
    {
        return false;
    }
    return self getEyePos()[2] >= checkpoint.origin[2] &&
           distanceSquared(self.origin, checkpoint.origin) < checkpoint.radius * checkpoint.radius;
}

touchesCheckpointGroup(checkpoint, grounded, groundEntity)
{
    if (!isDefined(checkpoint))
    {
        return false;
    }
    groupLeader = checkpoint;
    if (isDefined(checkpoint.bigBrother))
    {
        groupLeader = checkpoint.bigBrother;
    }
    if (!isDefined(groupLeader.contactAreas))
    {
        return self touchesArea(checkpoint, grounded, groundEntity);
    }
    for (i = 0; i < groupLeader.contactAreas.size; i++)
    {
        if (self touchesArea(groupLeader.contactAreas[i], grounded, groundEntity))
        {
            return true;
        }
    }
    return false;
}
