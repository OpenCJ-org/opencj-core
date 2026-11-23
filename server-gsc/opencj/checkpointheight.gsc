#include openCJ\util;

above(checkpoint)
{
    if (isDefined(checkpoint.heightAbove))
    {
        return checkpoint.heightAbove;
    }
    return 0;
}

same(firstCheckpoint, secondCheckpoint)
{
    return above(firstCheckpoint) == above(secondCheckpoint);
}

valid(value)
{
    maximumHeightOffset = 16384;
    return value >= 0 && value <= maximumHeightOffset;
}

// A curved manual selection becomes a horizontal footprint at its lowest corner.
// Planar sloped selections retain their original plane.
flatten(checkpoint)
{
    if(checkpoint.points.size < 4 || openCJ\checkpointArea::validate(checkpoint.points) !=
                                         "All corners must lie on the same plane")
    {
        return false;
    }
    lowestCornerZ = checkpoint.points[0][2];
    highestCornerZ = lowestCornerZ;
    for(i = 1; i < checkpoint.points.size; i++)
    {
        lowestCornerZ = min(lowestCornerZ, checkpoint.points[i][2]);
        highestCornerZ = max(highestCornerZ, checkpoint.points[i][2]);
    }
    for(i = 0; i < checkpoint.points.size; i++)
    {
        checkpoint.points[i] = (checkpoint.points[i][0], checkpoint.points[i][1], lowestCornerZ);
    }
    checkpoint.heightAbove = max(above(checkpoint), highestCornerZ - lowestCornerZ);
    return true;
}

// The caller must validate a walkable plane before solving its height at XY.
planeZ(points, position)
{
    normal = openCJ\checkpointArea::planeNormal(points);
    return points[0][2] -
           (normal[0] * (position[0] - points[0][0]) + normal[1] * (position[1] - points[0][1])) /
               normal[2];
}

lower(points, position)
{
    lowerContactTolerance = 2;
    return planeZ(points, position) - lowerContactTolerance;
}

upper(points, checkpoint, position)
{
    upperContactTolerance = 4;
    return planeZ(points, position) + upperContactTolerance +
           openCJ\checkpointArea::supportOffset(points) + above(checkpoint);
}

// Clip an XY polygon against a linear inequality evaluated at its vertices.
clipValues(points, values)
{
    clippedPoints = [];
    for(i = 0; i < points.size; i++)
    {
        nextIndex = (i + 1) % points.size;
        currentValue = values[i];
        nextValue = values[nextIndex];
        if(currentValue >= 0)
        {
            clippedPoints[clippedPoints.size] = points[i];
        }
        if((currentValue < 0 && nextValue > 0) || (currentValue > 0 && nextValue < 0))
        {
            intersectionFraction = currentValue / (currentValue - nextValue);
            clippedPoints[clippedPoints.size] =
                points[i] + vectorScale(points[nextIndex] - points[i], intersectionFraction);
        }
    }
    return clippedPoints;
}

xyArea(points)
{
    signedDoubleArea = 0;
    for(i = 1; i < points.size - 1; i++)
    {
        signedDoubleArea += openCJ\checkpointArea::_cross(points[0], points[i], points[i + 1]);
    }
    return abs(signedDoubleArea) * 0.5;
}

// Intersection of two vertical prisms, including tilted upper/lower planes.
// Unlike centre sampling this also detects narrow crossing strips and containment.
overlap(firstCheckpoint, firstPoints, secondCheckpoint, secondPoints)
{
    minimumOverlapArea = 0.0001;
    if(firstPoints.size < 3 || secondPoints.size < 3)
    {
        return false;
    }
    if(!boundsOverlap(firstPoints, secondPoints))
    {
        return false;
    }
    if(openCJ\checkpointArea::validate(firstPoints) != "" ||
       openCJ\checkpointArea::validate(secondPoints) != "")
    {
        return false;
    }

    intersection = clipFootprints(firstPoints, secondPoints);
    intersection =
        clipHeights(intersection, firstCheckpoint, firstPoints, secondCheckpoint, secondPoints);
    return intersection.size >= 3 && xyArea(intersection) > minimumOverlapArea;
}

boundsOverlap(firstPoints, secondPoints)
{
    // Cheap bounds discard unrelated platforms before polygon clipping.
    for(axis = 0; axis < 2; axis++)
    {
        firstMin = firstPoints[0][axis];
        firstMax = firstMin;
        secondMin = secondPoints[0][axis];
        secondMax = secondMin;
        for(i = 1; i < firstPoints.size; i++)
        {
            firstMin = min(firstMin, firstPoints[i][axis]);
            firstMax = max(firstMax, firstPoints[i][axis]);
        }
        for(i = 1; i < secondPoints.size; i++)
        {
            secondMin = min(secondMin, secondPoints[i][axis]);
            secondMax = max(secondMax, secondPoints[i][axis]);
        }
        if(firstMax <= secondMin || secondMax <= firstMin)
        {
            return false;
        }
    }
    return true;
}

// Clip against every edge of the second convex footprint, in either winding.
clipFootprints(firstPoints, secondPoints)
{
    intersection = firstPoints;
    winding = 1;
    if(openCJ\checkpointArea::_cross(secondPoints[0], secondPoints[1], secondPoints[2]) < 0)
    {
        winding = -1;
    }
    for(edgeIndex = 0; edgeIndex < secondPoints.size && intersection.size >= 3; edgeIndex++)
    {
        values = [];
        for(i = 0; i < intersection.size; i++)
        {
            values[i] =
                winding * openCJ\checkpointArea::_cross(
                              secondPoints[edgeIndex],
                              secondPoints[(edgeIndex + 1) % secondPoints.size], intersection[i]);
        }
        intersection = clipValues(intersection, values);
    }
    return intersection;
}

// Keep only XY positions where both vertical ranges share positive height.
// Touching upper/lower faces alone must not block neighboring checkpoints.
clipHeights(intersection, firstCheckpoint, firstPoints, secondCheckpoint, secondPoints)
{
    heightOverlapTolerance = 0.001;
    for(side = 0; side < 2 && intersection.size >= 3; side++)
    {
        values = [];
        for(i = 0; i < intersection.size; i++)
        {
            if(side == 0)
            {
                values[i] = upper(firstPoints, firstCheckpoint, intersection[i]) -
                            lower(secondPoints, intersection[i]) - heightOverlapTolerance;
            }
            else
            {
                values[i] = upper(secondPoints, secondCheckpoint, intersection[i]) -
                            lower(firstPoints, intersection[i]) - heightOverlapTolerance;
            }
        }
        intersection = clipValues(intersection, values);
    }
    return intersection;
}

areas(checkpoint)
{
    result = [];
    if(isDefined(checkpoint.points))
    {
        result[0] = checkpoint.points;
    }
    else if(isDefined(checkpoint.area))
    {
        result[0] = checkpoint.area;
    }
    if(isDefined(checkpoint.alternatives))
    {
        for(i = 0; i < checkpoint.alternatives.size; i++)
        {
            result[result.size] = checkpoint.alternatives[i];
        }
    }
    return result;
}

groupsOverlap(firstCheckpoint, secondCheckpoint)
{
    firstAreas = areas(firstCheckpoint);
    secondAreas = areas(secondCheckpoint);
    for(i = 0; i < firstAreas.size; i++)
    {
        for(j = 0; j < secondAreas.size; j++)
        {
            if(overlap(firstCheckpoint, firstAreas[i], secondCheckpoint, secondAreas[j]))
            {
                return true;
            }
        }
    }
    return false;
}

sameArea(firstPoints, secondPoints)
{
    matchingCornerDistanceSquared = 0.0001;
    if(firstPoints.size != secondPoints.size)
    {
        return false;
    }
    for(i = 0; i < firstPoints.size; i++)
    {
        foundMatchingCorner = false;
        for(j = 0; j < secondPoints.size; j++)
        {
            if(distanceSquared(firstPoints[i], secondPoints[j]) < matchingCornerDistanceSquared)
            {
                foundMatchingCorner = true;
            }
        }
        if(!foundMatchingCorner)
        {
            return false;
        }
    }
    return true;
}

isSelectedCopy(checkpoint, selectedCheckpoint)
{
    if(!isDefined(selectedCheckpoint))
    {
        return false;
    }
    candidateAreas = areas(checkpoint);
    selectedAreas = areas(selectedCheckpoint);
    for(i = 0; i < candidateAreas.size; i++)
    {
        for(j = 0; j < selectedAreas.size; j++)
        {
            if(sameArea(candidateAreas[i], selectedAreas[j]))
            {
                return true;
            }
        }
    }
    return false;
}

// Report the first conflicting checkpoint while excluding the selected original.
conflict(candidate)
{
    selectedCheckpoint = undefined;
    if(self.cpc.selected < self.cpc.rows.size)
    {
        selectedCheckpoint = openCJ\checkpointCreation::_decode(self.cpc.rows[self.cpc.selected]);
    }
    for(i = 0; i < self.cpc.rows.size; i++)
    {
        if(i != self.cpc.selected)
        {
            otherCheckpoint = openCJ\checkpointCreation::_decode(self.cpc.rows[i]);
            if(groupsOverlap(candidate, otherCheckpoint))
            {
                return "checkpoint " + (i + 1) + " in " + self.cpc.route;
            }
        }
    }
    draftConflict = self otherDraftConflict(candidate, selectedCheckpoint);
    if(draftConflict != "")
    {
        return draftConflict;
    }
    return publishedConflict(candidate, selectedCheckpoint);
}

// Include pending selections in this account's other saved route drafts.
otherDraftConflict(candidate, selectedCheckpoint)
{
    draftPrefix = self openCJ\login::getPlayerID() + "_" + getCvar("mapname") + "_";
    draftFiles =
        opencjScanDir(getCvar("fs_homepath") + "/" + getCvar("fs_game") + "/checkpoints/drafts");
    routeNames = [];
    if(isDefined(draftFiles))
    {
        for(i = 0; i < draftFiles.size; i++)
        {
            routeName = openCJ\checkpointList::draftName(draftFiles[i], draftPrefix);
            if(isDefined(routeName) && routeName != self.cpc.route)
            {
                routeNames[routeName] = true;
            }
        }
    }
    routeNamesToCheck = getArrayKeys(routeNames);
    for(k = 0; k < routeNamesToCheck.size; k++)
    {
        section = self openCJ\checkpointNetwork::readSection(routeNamesToCheck[k]);
        if(!isDefined(section))
        {
            continue;
        }
        for(i = 0; i <= section.rows.size; i++)
        {
            if(i < section.rows.size)
            {
                otherCheckpoint = openCJ\checkpointCreation::_decode(section.rows[i]);
            }
            else
            {
                otherCheckpoint = section.draft;
            }
            if(!isDefined(otherCheckpoint) || isSelectedCopy(otherCheckpoint, selectedCheckpoint))
            {
                continue;
            }
            if(groupsOverlap(candidate, otherCheckpoint))
            {
                return "checkpoint " + (i + 1) + " in draft " + routeNamesToCheck[k];
            }
        }
    }
    return "";
}

// Published radius checkpoints predate polygons; protect their full bounding volume.
publishedConflict(candidate, selectedCheckpoint)
{
    if(isDefined(level.checkpoints_checkpoints))
    {
        for(i = 0; i < level.checkpoints_checkpoints.size; i++)
        {
            otherCheckpoint = level.checkpoints_checkpoints[i];
            if(!isDefined(otherCheckpoint) || isSelectedCopy(otherCheckpoint, selectedCheckpoint))
            {
                continue;
            }
            if(groupsOverlap(candidate, otherCheckpoint))
            {
                return "published checkpoint #" + otherCheckpoint.id;
            }
            // Old radius checkpoints have no polygon; conservatively protect their bounds.
            if(!isDefined(otherCheckpoint.area) && isDefined(otherCheckpoint.radius))
            {
                legacyBounds = openCJ\checkpointCreation::_empty();
                radius = otherCheckpoint.radius;
                origin = otherCheckpoint.origin;
                legacyBounds.points[0] = origin + (0 - radius, 0 - radius, 0);
                legacyBounds.points[1] = origin + (radius, 0 - radius, 0);
                legacyBounds.points[2] = origin + (radius, radius, 0);
                legacyBounds.points[3] = origin + (0 - radius, radius, 0);
                legacyBounds.heightAbove = 2 * radius;
                for(j = 0; j < legacyBounds.points.size; j++)
                {
                    legacyBounds.points[j] -= (0, 0, radius);
                }
                if(groupsOverlap(candidate, legacyBounds))
                {
                    return "legacy checkpoint #" + otherCheckpoint.id;
                }
            }
        }
    }
    return "";
}

// Check an independent proposal before replacing the editable checkpoint.
edit(action)
{
    heightStep = 4;
    if(action == "height" && isDefined(self.cpc.heightTarget))
    {
        self.cpc.heightTarget = undefined;
        return;
    }
    checkpoint = self.cpc.draft;
    if(openCJ\checkpointMoving::isMoving(checkpoint))
    {
        self.cpc.status = "Whole moving platforms do not use height offsets";
        return;
    }
    candidate = openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(checkpoint));
    if(flatten(candidate))
    {
        conflictingCheckpoint = self conflict(candidate);
        if(conflictingCheckpoint != "")
        {
            self.cpc.status = "Height unchanged: overlaps " + conflictingCheckpoint;
            self sendLocalChatMessage(self.cpc.status, true);
            return;
        }
        self.cpc.draft = candidate;
        checkpoint = candidate;
        self sendLocalChatMessage(
            "Using the lowest corner as the base; Upper covers the selected corner heights.");
    }
    if(openCJ\checkpointArea::validate(checkpoint.points) != "")
    {
        self.cpc.status = "Select at least three valid corners before editing height";
        return;
    }
    if(action == "height")
    {
        self.cpc.heightTarget = "upper";
        return;
    }
    requestedHeight = above(checkpoint);
    if(action == "heightup")
    {
        requestedHeight += heightStep;
    }
    else if(action == "heightdown")
    {
        requestedHeight = max(0, requestedHeight - heightStep);
    }
    else
    {
        requestedHeight = self.cpc.heightRequestValue;
    }
    if(!valid(requestedHeight))
    {
        self.cpc.status = "Height offset must be between 0 and 16384 units";
        return;
    }
    candidate = openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(checkpoint));
    candidate.heightAbove = requestedHeight;
    if(requestedHeight > above(checkpoint))
    {
        conflictingCheckpoint = self conflict(candidate);
        if(conflictingCheckpoint != "")
        {
            self.cpc.status = "Height unchanged: overlaps " + conflictingCheckpoint;
            self sendLocalChatMessage(self.cpc.status, true);
            return;
        }
    }
    self.cpc.draft = candidate;
    self.cpc.status = "";
}
