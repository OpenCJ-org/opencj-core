// Stationary, planar, convex landing areas. Editor preview and gameplay share this test.
// Vertices must follow the perimeter, clockwise or counter-clockwise.
// Order selected corners without moving, dropping or inventing any points.
// XY ordering also works for walkable slopes; validate() still checks the plane
// and convexity, so interior/duplicate corners cannot silently expand the area.
orderCorners(points)
{
    orderedPoints = [];
    if(points.size < 3)
    {
        for(i = 0; i < points.size; i++)
        {
            orderedPoints[i] = points[i];
        }
        return orderedPoints;
    }
    centroid = (0, 0, 0);
    for(i = 0; i < points.size; i++)
    {
        centroid += points[i];
    }
    centroid = vectorScale(centroid, 1.0 / points.size);
    cornerAngles = [];
    for(i = 0; i < points.size; i++)
    {
        direction = points[i] - centroid;
        cornerAngle = vectorToAngles((direction[0], direction[1], 0))[1];
        insertionIndex = orderedPoints.size;
        while(insertionIndex > 0 && cornerAngles[insertionIndex - 1] > cornerAngle)
        {
            orderedPoints[insertionIndex] = orderedPoints[insertionIndex - 1];
            cornerAngles[insertionIndex] = cornerAngles[insertionIndex - 1];
            insertionIndex--;
        }
        orderedPoints[insertionIndex] = points[i];
        cornerAngles[insertionIndex] = cornerAngle;
    }
    return orderedPoints;
}

// Reject nonplanar or nonconvex outlines; the native detector uses the same limits.
validate(points)
{
    maximumCorners = 8;
    minimumWalkableNormalZ = 0.7;
    planarityTolerance = 0.25;
    minimumEdgeLengthSquared = 0.0001;
    if (points.size < 3 || points.size > maximumCorners)
    {
        return "Select 3 to 8 corners around the perimeter";
    }
    normal = planeNormal(points);
    if (normal[2] < minimumWalkableNormalZ)
    {
        return "Select a walkable landing plane";
    }
    winding = 0;
    for (i = 0; i < points.size; i++)
    {
        edgeStart = points[i];
        edgeEnd = points[(i + 1) % points.size];
        if (abs(vectorDot(edgeStart - points[0], normal)) > planarityTolerance)
        {
            return "All corners must lie on the same plane";
        }
        // Match native detection: reject numerical duplicates, not sub-unit ledges.
        if (distanceSquared(edgeStart, edgeEnd) < minimumEdgeLengthSquared)
        {
            return "Two corners are too close together";
        }
        // Every other corner must lie strictly on the same side of every edge.
        // This also rejects crossed polygons and redundant collinear corners.
        for (j = 0; j < points.size; j++)
        {
            if (j == i || j == (i + 1) % points.size)
            {
                continue;
            }
            signedCrossProduct = _cross(edgeStart, edgeEnd, points[j]);
            if (abs(signedCrossProduct) <= edgeTolerance(edgeStart, edgeEnd))
            {
                return "Corners must form a convex area without straight-line duplicates";
            }
            cornerSide = 1;
            if (signedCrossProduct < 0)
            {
                cornerSide = -1;
            }
            if (winding != 0 && winding != cornerSide)
            {
                return "Corners cross or form a concave area; select them around the perimeter";
            }
            winding = cornerSide;
        }
    }
    return "";
}

// Check the center against the polygon and its vertical contact allowance.
contains(points, origin, grounded, requireGround, heightAbove)
{
    minimumWalkableNormalZ = 0.7;
    lowerContactTolerance = 2;
    upperContactTolerance = 4;
    if (!isDefined(heightAbove))
    {
        heightAbove = 0;
    }
    if (!isDefined(requireGround))
    {
        requireGround = true;
    }
    if ((requireGround && !grounded) || points.size < 3)
    {
        return false;
    }
    normal = planeNormal(points);
    if (normal[2] < minimumWalkableNormalZ)
    {
        return false;
    }
    heightAbovePlane = vectorDot(origin - points[0], normal) / normal[2];
    if (heightAbovePlane < 0 - lowerContactTolerance ||
       heightAbovePlane > upperContactTolerance + supportOffset(points) + heightAbove)
    {
        return false;
    }
    polygonSide = 0;
    for (i = 0; i < points.size; i++)
    {
        signedCrossProduct = _cross(points[i], points[(i + 1) % points.size], origin);
        if (abs(signedCrossProduct) <= edgeTolerance(points[i], points[(i + 1) % points.size]))
        {
            continue;
        }
        edgeSide = 1;
        if (signedCrossProduct < 0)
        {
            edgeSide = -1;
        }
        if (polygonSide != 0 && polygonSide != edgeSide)
        {
            return false;
        }
        polygonSide = edgeSide;
    }
    return true;
}

// A grounded player can stand with their center outside the landing perimeter.
// Keep geometric contains() strict for editor overlap/merge detection; only
// player contact tests use the 15-unit collision footprint.
touchesPlayer(points, origin, grounded, requireGround, heightAbove)
{
    playerContactRadius = 15;
    minimumWalkableNormalZ = 0.7;
    minimumEdgeLengthSquared = 0.0001;
    lowerContactTolerance = 2;
    upperContactTolerance = 4;
    if (!isDefined(heightAbove))
    {
        heightAbove = 0;
    }
    if (!isDefined(requireGround))
    {
        requireGround = true;
    }
    if ((requireGround && !grounded) || points.size < 3)
    {
        return false;
    }
    if (contains(points, origin, grounded, requireGround, heightAbove))
    {
        return true;
    }
    normal = planeNormal(points);
    if (normal[2] < minimumWalkableNormalZ)
    {
        return false;
    }
    for (i = 0; i < points.size; i++)
    {
        edgeStart = points[i];
        edgeEnd = points[(i + 1) % points.size];
        edgeDeltaX = edgeEnd[0] - edgeStart[0];
        edgeDeltaY = edgeEnd[1] - edgeStart[1];
        edgeLengthSquared = edgeDeltaX * edgeDeltaX + edgeDeltaY * edgeDeltaY;
        if (edgeLengthSquared < minimumEdgeLengthSquared)
        {
            continue;
        }
        nearestPointFraction =
            ((origin[0] - edgeStart[0]) * edgeDeltaX + (origin[1] - edgeStart[1]) * edgeDeltaY) /
            edgeLengthSquared;
        if (nearestPointFraction < 0)
        {
            nearestPointFraction = 0;
        }
        if (nearestPointFraction > 1)
        {
            nearestPointFraction = 1;
        }
        nearestPoint = edgeStart + vectorScale(edgeEnd - edgeStart, nearestPointFraction);
        x = origin[0] - nearestPoint[0];
        y = origin[1] - nearestPoint[1];
        // Segment distance also rounds corners instead of extending each edge
        // independently, which would award checkpoints beyond the footprint.
        if (x * x + y * y > playerContactRadius * playerContactRadius)
        {
            continue;
        }
        heightAboveEdge = origin[2] - nearestPoint[2];
        if (heightAboveEdge >= 0 - lowerContactTolerance &&
           heightAboveEdge <= upperContactTolerance + supportOffset(points) + heightAbove)
        {
            return true;
        }
    }
    return false;
}

crossProduct(a, b)
{
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]);
}

planeNormal(points)
{
    // A tiny first bevel must not dominate the plane after coordinate rounding.
    normal = (0, 0, 0);
    for (i = 1; i < points.size - 1; i++)
    {
        normal += crossProduct(points[i] - points[0], points[i + 1] - points[0]);
    }
    normal = vectorNormalize(normal);
    if (normal[2] < 0)
    {
        normal = (0, 0, 0) - normal;
    }
    return normal;
}

// The player's capsule rests above the plane at its center on a slope.
// Callers must establish a walkable plane before dividing by its vertical normal.
supportOffset(points)
{
    playerContactRadius = 15;
    normal = planeNormal(points);
    return playerContactRadius * (1 / normal[2] - 1);
}

_cross(a, b, p)
{
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}

encode(points)
{
    text = "";
    for (i = 0; i < points.size; i++)
    {
        if (i > 0)
        {
            text += ";";
        }
        text += floatToPreciseString(points[i][0]) + "," + floatToPreciseString(points[i][1]) +
                "," + floatToPreciseString(points[i][2]);
    }
    return text;
}

decode(text)
{
    maximumCorners = 8;
    mapCoordinateLimit = 131072;
    points = [];
    pointStrings = strTok(text, ";");
    if (pointStrings.size > maximumCorners)
    {
        return undefined;
    }
    for (i = 0; i < pointStrings.size; i++)
    {
        coordinateStrings = strTok(pointStrings[i], ",");
        if (coordinateStrings.size != 3)
        {
            return undefined;
        }
        for (j = 0; j < 3; j++)
        {
            if (!isValidFloat(coordinateStrings[j]) ||
               abs(float(coordinateStrings[j])) > mapCoordinateLimit)
            {
                return undefined;
            }
        }
        points[i] =
            (float(coordinateStrings[0]), float(coordinateStrings[1]), float(coordinateStrings[2]));
    }
    return points;
}

// Cross products scale with edge length. Use a fixed world-space tolerance
// so tiny checkpoint edges do not acquire a larger containment allowance.
edgeTolerance(a, b)
{
    edgeDistanceTolerance = 0.0001;
    return edgeDistanceTolerance * distance((a[0], a[1], 0), (b[0], b[1], 0));
}
