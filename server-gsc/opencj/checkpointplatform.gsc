#include openCJ\util;

// Convex supported landings. Orientation comes from collision normals, never view yaw.
getRectangularPlatformOrgs()
{
    if (!self isOnGround())
    {
        self iprintln("Land on the platform before detecting it");
        return undefined;
    }
    points = detectLandingAt(self.origin);
    if (!isDefined(points))
    {
        self iprintln(
            "Could not identify a supported platform; use !cp corner for manual placement");
    }
    else
    {
        self iprintln("Detected platform edges from collision geometry");
    }
    return points;
}

// Combine connected coplanar brush, terrain and static-model collision faces
// only where their union supports the landing. Preserve gaps and wall boundaries.
// CoD2 retains its trace-based fallback.
detectLandingAt(origin)
{
    minimumWalkableNormalZ = 0.7;
    landingHeightTolerance = 0.5;
    top = traceGroundBelow(origin);
    hitWalkableSurface = top["fraction"] < 1 && top["normal"][2] >= minimumWalkableNormalZ;
    atLandingHeight = abs(top["position"][2] - origin[2]) <= landingHeightTolerance;
    if (hitWalkableSurface && atLandingHeight)
    {
        points = platformBrushFace(top["position"], top["normal"], false, true);
        if (isDefined(points) && openCJ\checkpointArea::validate(points) == "" &&
           openCJ\checkpointArea::contains(points, origin, true))
        {
            return points;
        }
    }
    // A grounded player's center may hang over an edge. Find a walkable face
    // within the same 15-unit circular edge contact and slope-height allowance
    // used by gameplay. The native broad-phase box is not itself support.
    supported = platformBrushFace(origin, (0, 0, 1), true, true);
    if (isDefined(supported) && openCJ\checkpointArea::validate(supported) == "")
    {
        return supported;
    }
    // CoD4's native path covers brushes, terrain and static-model collision.
    // A rejected/over-budget result must not fall through to a sampled rectangle.
    if (getCodVersion() == 4)
    {
        return undefined;
    }
    // Preserve CoD2's legacy trace detector until its native geometry is available.
    if (isDefined(platformBrushFace(origin, (0, 0, 1), true)))
    {
        return undefined;
    }
    if (top["fraction"] < 1 && abs(top["position"][2] - origin[2]) <= landingHeightTolerance)
    {
        return detectAt(origin);
    }
    return undefined;
}

// Recover a four-sided landing from short probes when native geometry is unavailable.
detectAt(origin)
{
    minimumWalkableNormalZ = 0.7;
    minimumEdgeAlignment = 0.95;
    maximumEdgeDistance = 4096;
    maximumTrimRetries = 4;
    probeInset = 0.5;
    top = traceGroundBelow(origin);
    if (top["fraction"] == 1 || top["normal"][2] < minimumWalkableNormalZ)
    {
        return undefined;
    }
    normal = top["normal"];
    start = top["position"] - normal;
    face = _side(start, vectorNormalize((normal[2], 0, 0 - normal[0])), normal);
    if (!isDefined(face))
    {
        face = _side(start, vectorNormalize((0, normal[2], 0 - normal[1])), normal);
    }
    if (!isDefined(face))
    {
        return undefined;
    }
    axis = face["normal"];
    side = openCJ\checkpointArea::crossProduct(normal, axis);
    // On a skewed slope, follow the adjacent edge instead of assuming a
    // right angle: a perpendicular scan can cross that same edge twice.
    // Allow up to about 18 degrees of skew; all corner/edge support checks remain.
    adjacent = _side(start, side, normal);
    if (!isDefined(adjacent) || vectorDot(adjacent["normal"], side) < minimumEdgeAlignment)
    {
        return undefined;
    }
    along = openCJ\checkpointArea::crossProduct(adjacent["normal"], normal);
    directions = [];
    directions[0] = along;
    directions[1] = side;
    directions[2] = vectorScale(along, -1);
    directions[3] = vectorScale(side, -1);
    distances = [];
    faces = [];
    for (i = 0; i < 4; i++)
    {
        hit = _side(start, directions[i], normal);
        if (!isDefined(hit) || vectorDot(hit["normal"], directions[i]) < minimumEdgeAlignment)
        {
            return undefined;
        }
        faces[i] = hit["normal"];
        distances[i] = vectorDot(hit["position"] - top["position"], faces[i]);
        if (distances[i] <= 0 || distances[i] >= maximumEdgeDistance)
        {
            return undefined;
        }
    }
    // A wall can overlap only part of an edge. Tighten to that wall's face,
    // then verify again; never accept a corner merely because it is obstructed.
    for (attempt = 0; attempt <= maximumTrimRetries; attempt++)
    {
        points = _corners(top["position"], axis, side, faces, distances);
        if (!isDefined(points))
        {
            return undefined;
        }
        center = vectorScale(points[0] + points[1] + points[2] + points[3], 0.25);
        trimmed = false;
        for (i = 0; i < 4 && !trimmed; i++)
        {
            along = vectorNormalize(points[(i + 1) % 4] - points[i]);
            across = vectorNormalize(points[(i + 3) % 4] - points[i]);
            probes = [];
            probes[0] = points[i] + vectorScale(along + across, probeInset);
            midpoint = vectorScale(points[i] + points[(i + 1) % 4], 0.5);
            probes[1] = midpoint + vectorScale(vectorNormalize(center - midpoint), probeInset);
            for (j = 0; j < probes.size; j++)
            {
                if (_sameTop(probes[j], normal))
                {
                    continue;
                }
                wall = obstructionAtProbe(probes[j], normal, top["position"], start);
                if (!isDefined(wall))
                {
                    return undefined;
                }
                boundaryTrim =
                    trimToWall(wall, top["position"], normal, directions, faces, distances);
                if (isDefined(boundaryTrim))
                {
                    faces[boundaryTrim.edgeIndex] = boundaryTrim.normal;
                    distances[boundaryTrim.edgeIndex] = boundaryTrim.distance;
                    trimmed = true;
                }
                // An oblique raised brush may cover a probe without being a
                // boundary of the landing. Keep the original checkpoint plane;
                // standing on top of the obstruction does not pass this area.
                if (!trimmed && _solidAt(probes[j], normal))
                {
                    continue;
                }
                if (!trimmed)
                {
                    return undefined;
                }
                break;
            }
        }
        if (!trimmed)
        {
            return points;
        }
    }
    return undefined;
}

// Find a supported edge or wall, then refine its position within a bounded scan.
_side(start, direction, normal)
{
    maximumSearchDistance = 4096;
    scanStep = 4;
    refinementPasses = 8;
    parallelNormalThreshold = 0.99;
    minimumRayPlaneAlignment = 0.001;
    wallProbeInset = 0.5;
    outsideMargin = 0.25;
    shallowProbeDepth = 0.125;
    zeroNormalToleranceSquared = 0.001;
    if (!isDefined(normal))
    {
        normal = (0, 0, 1);
    }
    // Walk outward on this top first. Tracing back from a distant wall can hit
    // a different brush behind the platform, even when its normal looks correct.
    top = start + normal;
    // Above the landing, a wall is a boundary too. Below it, the platform and
    // adjoining wall can be one continuous solid, so a reverse trace cannot exit.
    wallStart = top + normal;
    wall = bulletTrace(wallStart, wallStart + vectorScale(direction, maximumSearchDistance), false,
                       undefined);
    wallDistance = maximumSearchDistance + 1;
    if (wall["fraction"] < 1 && abs(vectorDot(wall["normal"], normal)) < parallelNormalThreshold)
    {
        // For an inclined wall, its intersection with the landing differs from
        // the hit one unit above it. Check support just inside the actual seam.
        denominator = vectorDot(wall["normal"], direction);
        if (abs(denominator) > minimumRayPlaneAlignment)
        {
            wallDistance = vectorDot(wall["position"] - top, wall["normal"]) / denominator;
        }
    }
    lastSupportedDistance = 0;
    probeDistance = scanStep;
    while (probeDistance <= maximumSearchDistance)
    {
        if (probeDistance >= wallDistance)
        {
            // The four-unit scan may step across a narrow gap before a wall.
            // Only use that wall if the landing actually reaches its near face.
            wallNear = wallDistance - wallProbeInset;
            if (wallNear > lastSupportedDistance && !_sameTop(top + vectorScale(direction, wallNear), normal))
            {
                probeDistance = wallNear;
                break;
            }
            // Use an outward normal consistently for walls and exposed edges.
            wall["normal"] = vectorScale(wall["normal"], -1);
            return _boundary(wall, top, direction, normal);
        }
        if (!_sameTop(top + vectorScale(direction, probeDistance), normal))
        {
            break;
        }
        lastSupportedDistance = probeDistance;
        probeDistance += scanStep;
    }
    if (probeDistance > maximumSearchDistance)
    {
        return undefined;
    }
    for (i = 0; i < refinementPasses; i++)
    {
        midpointDistance = (lastSupportedDistance + probeDistance) * 0.5;
        if (_sameTop(top + vectorScale(direction, midpointDistance), normal))
        {
            lastSupportedDistance = midpointDistance;
        }
        else
        {
            probeDistance = midpointDistance;
        }
    }
    outside = start + vectorScale(direction, probeDistance + outsideMargin);
    hit = bulletTrace(outside, start, false, undefined);
    // Near a steep end face, lowering the probe can move it back inside
    // the brush. Retry just below the landing plane to recover the edge normal.
    if (hit["fraction"] == 0 && vectorDot(hit["normal"], hit["normal"]) < zeroNormalToleranceSquared)
    {
        shallow = top - vectorScale(normal, shallowProbeDepth);
        hit = bulletTrace(shallow + vectorScale(direction, probeDistance + outsideMargin), shallow, false,
                          undefined);
    }
    if (hit["fraction"] == 1 || abs(vectorDot(hit["normal"], normal)) > parallelNormalThreshold)
    {
        return undefined;
    }
    boundary = _boundary(hit, top, direction, normal);
    if (!isDefined(boundary))
    {
        return undefined;
    }
    // At a thin tapered edge, collision padding on the underside is amplified
    // when intersected with the top plane. Never extrapolate past the measured
    // surface edge; retain the face orientation but use the last supported point.
    if (vectorDot(boundary["position"] - top, direction) > probeDistance + outsideMargin)
    {
        boundary["position"] = top + vectorScale(direction, lastSupportedDistance);
    }
    return boundary;
}

_sameTop(point, normal)
{
    probeDepth = 2;
    shallowProbeHeight = 0.25;
    minimumNormalAgreement = 0.999;
    positionToleranceSquared = 0.0625;
    if (!isDefined(normal))
    {
        normal = (0, 0, 1);
    }
    hit = bulletTrace(point + vectorScale(normal, probeDepth),
                      point - vectorScale(normal, probeDepth), false, undefined);
    // A tall probe can start inside an adjoining inclined wall even though the
    // landing itself is clear. Retry close to the surface before rejecting it.
    if (hit["fraction"] < 1 && vectorDot(hit["normal"], normal) < minimumNormalAgreement)
    {
        hit = bulletTrace(point + vectorScale(normal, shallowProbeHeight),
                          point - vectorScale(normal, probeDepth), false, undefined);
    }
    return hit["fraction"] < 1 && vectorDot(hit["normal"], normal) > minimumNormalAgreement &&
           distanceSquared(hit["position"], point) < positionToleranceSquared;
}

_tangent(vector, normal)
{
    return vectorNormalize(vector - vectorScale(normal, vectorDot(vector, normal)));
}

// Intersect the side face with the landing plane, removing the trace's height offset.
_boundary(hit, top, direction, normal)
{
    minimumRayPlaneAlignment = 0.001;
    denominator = vectorDot(hit["normal"], direction);
    if (abs(denominator) < minimumRayPlaneAlignment)
    {
        return undefined;
    }
    distance = vectorDot(hit["position"] - top, hit["normal"]) / denominator;
    hit["position"] = top + vectorScale(direction, distance);
    hit["normal"] = _tangent(hit["normal"], normal);
    return hit;
}

// Brush compilation can leave nominally rectangular sides slightly nonparallel.
// Intersect their measured planes rather than extending a small angular error
// across a long platform and placing a corner outside the actual landing.
_corners(origin, axis, side, faces, distances)
{
    points = [];
    for (i = 0; i < 4; i++)
    {
        j = (i + 1) % 4;
        a = vectorDot(faces[i], axis);
        b = vectorDot(faces[i], side);
        c = vectorDot(faces[j], axis);
        d = vectorDot(faces[j], side);
        determinant = a * d - b * c;
        // Parallel edge planes have no unique intersection; reject this landing.
        if (determinant == 0)
        {
            return undefined;
        }
        x = (distances[i] * d - b * distances[j]) / determinant;
        y = (a * distances[j] - distances[i] * c) / determinant;
        points[i] = origin + vectorScale(axis, x) + vectorScale(side, y);
    }
    return points;
}

// A zero-length normal at fraction zero means the short trace starts in solid.
// Do not treat a missing surface (fraction one) as an obstruction.
_solidAt(point, normal)
{
    probeHalfHeight = 0.125;
    zeroNormalToleranceSquared = 0.001;
    hit = bulletTrace(point + vectorScale(normal, probeHalfHeight),
                      point - vectorScale(normal, probeHalfHeight), false, undefined);
    return hit["fraction"] == 0 &&
           vectorDot(hit["normal"], hit["normal"]) < zeroNormalToleranceSquared;
}

// Use the same short vertical probe for native detection and the CoD2 fallback.
traceGroundBelow(origin)
{
    probeStartHeight = 2;
    probeDepth = 24;
    return bulletTrace(origin + (0, 0, probeStartHeight), origin - (0, 0, probeDepth), false,
                       undefined);
}

// A failed surface probe can be a wall or an exposed edge. Trace both cases.
obstructionAtProbe(probe, normal, top, start)
{
    parallelNormalThreshold = 0.99;
    above = top + normal;
    wall = bulletTrace(above, probe + normal, false, undefined);
    if (wall["fraction"] == 1)
    {
        wall = bulletTrace(probe - normal, start, false, undefined);
        wall["normal"] = vectorScale(wall["normal"], -1);
    }
    if (wall["fraction"] == 1 || abs(vectorDot(wall["normal"], normal)) > parallelNormalThreshold)
    {
        return undefined;
    }
    return wall;
}

// Find the first side this obstruction can tighten without extending the landing.
trimToWall(wall, top, normal, directions, faces, distances)
{
    minimumRayPlaneAlignment = 0.001;
    minimumOpposingAlignment = 0.95;
    edgeDistanceTolerance = 0.01;
    for (edgeIndex = 0; edgeIndex < directions.size; edgeIndex++)
    {
        faceNormal = _tangent(wall["normal"], normal);
        denominator = vectorDot(wall["normal"], directions[edgeIndex]);
        if (abs(denominator) < minimumRayPlaneAlignment)
        {
            continue;
        }
        wallDistance = vectorDot(wall["position"] - top, wall["normal"]) / denominator;
        if (vectorDot(faceNormal, faces[edgeIndex]) < 0 - minimumOpposingAlignment &&
           wallDistance > 0 && wallDistance < distances[edgeIndex] - edgeDistanceTolerance)
        {
            boundary = _boundary(wall, top, directions[edgeIndex], normal);
            trim = spawnStruct();
            trim.edgeIndex = edgeIndex;
            trim.normal = vectorScale(boundary["normal"], -1);
            trim.distance = vectorDot(boundary["position"] - top, trim.normal);
            return trim;
        }
    }
    return undefined;
}
