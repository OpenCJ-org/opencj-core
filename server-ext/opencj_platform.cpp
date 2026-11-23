#include "gsc_custom_utils.hpp"
#ifdef COD4
extern "C" {
#include "../cod4x-server/src/cm_local.h"
#include "../cod4x-server/src/xassets/xmodel.h"
}
#include <cmath>
#include <algorithm>
#include <vector>

namespace {

// Geometry and work budgets are separate: a large simple floor may be cheap,
// while a small fragmented floor can exhaust the clipping/search budgets.
constexpr int maxPolygonVertices = 64;
constexpr int maxCheckpointVertices = 8;
constexpr int maxTraversalDepth = 64;
constexpr int maxRegionSearchVisits = 4096;
constexpr int maxBrushSidePlanes = 128;
constexpr int maxWallPolygons = 2048;
constexpr int maxLandingSurfaces = 4096;
constexpr int maxUncoveredPieces = 512;
constexpr int maxCollisionTriangles = 16384;
constexpr int maxModelSurfaces = 4096;
constexpr unsigned maxModelTriangles = 65536;
constexpr int maxSupportQueryLeaves = 1024;
constexpr unsigned axialBrushPlaneCount = 6;
constexpr int supportContentsMask = 0x11; // Solid brushes and player-solid glass.

// Match the checkpoint contact rules and keep wall slices just above the floor.
constexpr double minimumSupportNormalZ = 0.7;
constexpr double parallelPlaneDotThreshold = 0.99999;
constexpr double coplanarHeightTolerance = 0.01;
constexpr double wallSliceHeight = 0.5;
constexpr double wallConnectionMargin = 0.25;
constexpr double checkpointWallClearance = 0.125;
constexpr double playerContactRadius = 15;
constexpr double playerQueryHalfHeight = 11;
constexpr double pointQueryReach = 0.5;
constexpr double regionAreaTolerance = 0.001;
constexpr double mapCoordinateLimit = 131072;

// Double precision avoids losing the landing plane on distant, thin slopes.
// Use one tolerance for joining floor faces and verifying their coverage.
// Otherwise a seam accepted during collection becomes a false gap afterward.
constexpr double surfaceSeamTolerance = 0.01;
struct Point {
    double x[3];
};
struct Plane {
    Point normal;
    double distance;
};
double dot(const Point &a, const Point &b) {
    return a.x[0] * b.x[0] + a.x[1] * b.x[1] + a.x[2] * b.x[2];
}

Point add(const Point &a, const Point &b, double scale) {
    return {{a.x[0] + b.x[0] * scale, a.x[1] + b.x[1] * scale, a.x[2] + b.x[2] * scale}};
}

Point cross(const Point &a, const Point &b) {
    return {{a.x[1] * b.x[2] - a.x[2] * b.x[1], a.x[2] * b.x[0] - a.x[0] * b.x[2],
             a.x[0] * b.x[1] - a.x[1] * b.x[0]}};
}

Plane plane(const cbrush_t &brush, unsigned planeIndex) {
    Plane result = {};
    if (planeIndex < axialBrushPlaneCount) {
        const unsigned axis = planeIndex / 2;
        const bool upper = planeIndex % 2;
        result.normal.x[axis] = upper ? 1 : -1;
        result.distance = upper ? brush.maxs[axis] : -brush.mins[axis];
    } else {
        const cplane_t &side = *brush.sides[planeIndex - axialBrushPlaneCount].plane;
        for (int j = 0; j < 3; j++) {
            result.normal.x[j] = side.normal[j];
        }
        result.distance = side.dist;
    }
    return result;
}

// Clip against one brush half-space. Return the remaining vertex count;
// zero means empty geometry or an exhausted vertex buffer.
int clip(Point *points, int count, const Plane &boundary) {
    Point clippedVertices[maxPolygonVertices];
    int clippedCount = 0;
    for (int i = 0; i < count; i++) {
        const Point a = points[i];
        const Point b = points[(i + 1) % count];
        const double startDistance = dot(a, boundary.normal) - boundary.distance;
        const double endDistance = dot(b, boundary.normal) - boundary.distance;
        if (startDistance <= 0) {
            if (clippedCount == maxPolygonVertices) {
                return 0;
            }
            clippedVertices[clippedCount++] = a;
        }
        if ((startDistance < 0 && endDistance > 0) || (startDistance > 0 && endDistance < 0)) {
            if (clippedCount == maxPolygonVertices) {
                return 0;
            }
            clippedVertices[clippedCount++] =
                add(a, add(b, a, -1), startDistance / (startDistance - endDistance));
        }
    }
    std::copy(clippedVertices, clippedVertices + clippedCount, points);
    return clippedCount;
}

// Geometry utilities shared by brush tops and wall footprints.
int simplify(Point *points, int vertexCount, double minimumEdgeLengthSquared = 0.0001) {
    bool changed = true;
    while (changed && vertexCount >= 3) {
        changed = false;
        for (int i = 0; i < vertexCount; i++) {
            const Point a = add(points[i], points[(i + vertexCount - 1) % vertexCount], -1);
            const Point b = add(points[(i + 1) % vertexCount], points[i], -1);
            const Point c = cross(a, b);
            if (dot(a, a) < minimumEdgeLengthSquared ||
                dot(c, c) < 0.000001 * dot(a, a) * dot(b, b)) {
                for (int j = i; j < vertexCount - 1; j++) {
                    points[j] = points[j + 1];
                }
                --vertexCount;
                changed = true;
                break;
            }
        }
    }
    return vertexCount;
}

// Start with the brush bounds projected onto the face plane, so the temporary
// polygon always encloses the complete face regardless of player position.
int brushFace(const cbrush_t &brush, unsigned face, const Point &center, const Point &normal,
              Point *points) {
    Point u = {{normal.x[2], 0, -normal.x[0]}};
    u = add(Point{}, u, 1 / std::sqrt(dot(u, u)));
    const Point v = cross(normal, u);
    double loU = 1e30;
    double hiU = -1e30;
    double loV = 1e30;
    double hiV = -1e30;
    for (int corner = 0; corner < 8; corner++) {
        Point p;
        for (int axis = 0; axis < 3; axis++) {
            p.x[axis] = (corner & (1 << axis)) ? brush.maxs[axis] : brush.mins[axis];
        }
        p = add(p, center, -1);
        const double du = dot(p, u);
        const double dv = dot(p, v);
        loU = std::min(loU, du);
        hiU = std::max(hiU, du);
        loV = std::min(loV, dv);
        hiV = std::max(hiV, dv);
    }
    points[0] = add(add(center, u, loU - 1), v, loV - 1);
    points[1] = add(add(center, u, hiU + 1), v, loV - 1);
    points[2] = add(add(center, u, hiU + 1), v, hiV + 1);
    points[3] = add(add(center, u, loU - 1), v, hiV + 1);
    int count = 4;
    for (unsigned i = 0; i < brush.numsides + axialBrushPlaneCount && count >= 3; i++) {
        if (i != face) {
            count = clip(points, count, plane(brush, i));
        }
    }
    return simplify(points, count);
}

double area(const Point *points, int vertexCount, const Point &normal) {
    double sum = 0;
    for (int i = 1; i < vertexCount - 1; i++) {
        sum += dot(cross(add(points[i], points[0], -1), add(points[i + 1], points[0], -1)), normal);
    }
    return std::abs(sum) * 0.5;
}

// Use the whole polygon: a tiny first bevel is a poor basis after float rounding.
Point polygonNormal(const Point *points, int count) {
    Point sum = {};
    for (int i = 1; i < count - 1; i++) {
        sum = add(sum, cross(add(points[i], points[0], -1), add(points[i + 1], points[0], -1)), 1);
    }
    const double length = std::sqrt(dot(sum, sum));
    return length > 1e-12 ? add(Point{}, sum, 1 / length) : Point{};
}

Plane edgePlane(const Point &a, const Point &b, const Point &normal) {
    Point n = cross(add(b, a, -1), normal);
    n = add(Point{}, n, 1 / std::sqrt(dot(n, n)));
    return {n, dot(n, a)};
}

struct Obstacle {
    Point points[maxPolygonVertices];
    int count;
    bool wall;
    double clearance = 0;
};
int intersection(Point *points, int count, const Obstacle &obstacle, const Point &normal) {
    for (int i = 0; i < obstacle.count && count >= 3; i++) {
        count =
            clip(points, count,
                 edgePlane(obstacle.points[i], obstacle.points[(i + 1) % obstacle.count], normal));
    }
    return count;
}

void worldBrushes(int nodeIndex, std::vector<unsigned> &brushIndices, int depth = 0) {
    if (nodeIndex <= 0 || unsigned(nodeIndex) >= cm.leafbrushNodesCount ||
        depth > maxTraversalDepth) {
        return;
    }
    const cLeafBrushNode_t &node = cm.leafbrushNodes[nodeIndex];
    if (node.leafBrushCount > 0) {
        for (int i = 0; i < node.leafBrushCount; i++) {
            brushIndices.push_back(node.data.leaf.brushes[i]);
        }
        return;
    }
    if (node.leafBrushCount < 0) {
        worldBrushes(nodeIndex + 1, brushIndices, depth + 1);
    }
    worldBrushes(nodeIndex + node.data.children.childOffset[0], brushIndices, depth + 1);
    worldBrushes(nodeIndex + node.data.children.childOffset[1], brushIndices, depth + 1);
}

// Canonical geometry ordering gives equal-area solutions and budget handling a
// stable result regardless of BSP brush order or triangle winding/start vertex.
void canonicalize(Obstacle &polygon) {
    int first = 0;
    for (int i = 1; i < polygon.count; i++) {
        for (int axis = 0; axis < 3; axis++) {
            if (polygon.points[i].x[axis] < polygon.points[first].x[axis]) {
                first = i;
                break;
            }
            if (polygon.points[i].x[axis] > polygon.points[first].x[axis]) {
                break;
            }
        }
    }
    std::rotate(polygon.points, polygon.points + first, polygon.points + polygon.count);
}

bool polygonLess(const Obstacle &a, const Obstacle &b) {
    if (a.count != b.count) {
        return a.count < b.count;
    }
    for (int i = 0; i < a.count; i++) {
        for (int axis = 0; axis < 3; axis++) {
            if (a.points[i].x[axis] != b.points[i].x[axis]) {
                return a.points[i].x[axis] < b.points[i].x[axis];
            }
        }
    }
    return false;
}

// Search all useful separating edges instead of greedily clipping each gap.
// Bounds keep pathological map geometry from monopolizing a server frame.
struct SupportedRegion {
    const std::vector<Obstacle> &gaps;
    Point normal;
    Point seed;
    Obstacle best = {};
    double bestArea = 0;
    int visits = 0;
    double margin = 0.01;
    bool exhausted = false;
    // The gap vector outlives this search, so the returned pointer stays valid.
    const Obstacle *largestObstruction(const Obstacle &region) const {
        const Obstacle *obstruction = nullptr;
        double largest = 0;
        for (const auto &gap : gaps) {
            Point overlap[maxPolygonVertices];
            std::copy(region.points, region.points + region.count, overlap);
            const int overlapCount = intersection(overlap, region.count, gap, normal);
            const double overlapArea = overlapCount >= 3 ? area(overlap, overlapCount, normal) : 0;
            if (overlapArea > largest + regionAreaTolerance) {
                largest = overlapArea;
                obstruction = &gap;
            }
        }
        return obstruction;
    }

    // Keep candidates on the seed's side and visit the largest promising areas first.
    std::vector<Obstacle> separatingRegions(const Obstacle &region, const Obstacle &obstruction) {
        std::vector<Obstacle> choices;
        for (int i = 0; i < obstruction.count; i++) {
            const Plane edge = edgePlane(obstruction.points[i],
                                         obstruction.points[(i + 1) % obstruction.count], normal);
            if (dot(seed, edge.normal) < edge.distance + std::max(margin, obstruction.clearance)) {
                continue;
            }
            const double clearance = std::max(margin, obstruction.clearance);
            const Plane keep = {add(Point{}, edge.normal, -1), -edge.distance - clearance};
            Obstacle candidate = region;
            candidate.count = clip(candidate.points, candidate.count, keep);
            candidate.count = simplify(candidate.points, candidate.count);
            if (candidate.count >= 3 &&
                area(candidate.points, candidate.count, normal) > bestArea + regionAreaTolerance) {
                canonicalize(candidate);
                choices.push_back(candidate);
            }
        }
        std::sort(choices.begin(), choices.end(), [this](const Obstacle &a, const Obstacle &b) {
            const double areaA = area(a.points, a.count, normal);
            const double areaB = area(b.points, b.count, normal);
            if (areaA != areaB) {
                return areaA > areaB;
            }
            return polygonLess(a, b);
        });
        return choices;
    }

    // Stop at the shared visit/depth budgets; callers reject an exhausted search.
    void search(Obstacle region, int depth = 0) {
        if (++visits > maxRegionSearchVisits || depth > maxTraversalDepth) {
            exhausted = true;
            return;
        }
        if (region.count < 3) {
            return;
        }
        const double size = area(region.points, region.count, normal);
        if (size <= bestArea + regionAreaTolerance) {
            return;
        }
        const Obstacle *obstruction = largestObstruction(region);
        if (!obstruction) {
            // Small supported ledges are valid; discard only numerical duplicates.
            region.count = simplify(region.points, region.count);
            if (region.count >= 3 && region.count <= maxCheckpointVertices) {
                best = region;
                bestArea = area(region.points, region.count, normal);
            }
            return;
        }
        const std::vector<Obstacle> choices = separatingRegions(region, *obstruction);
        for (const auto &candidate : choices) {
            search(candidate, depth + 1);
            if (exhausted) {
                return;
            }
        }
    }
};

// Propagate boundary connectivity across complete footprints and touching seams.
void connectWalls(std::vector<Obstacle> &obstacles, const Point &normal) {
    bool changed = true;
    while (changed) {
        changed = false;
        for (auto &candidate : obstacles) {
            if (candidate.wall) {
                continue;
            }
            for (const auto &wall : obstacles) {
                if (!wall.wall) {
                    continue;
                }
                Point section[maxPolygonVertices];
                std::copy(candidate.points, candidate.points + candidate.count, section);
                int sectionCount = candidate.count;
                for (int i = 0; i < wall.count && sectionCount >= 3; i++) {
                    Plane boundary =
                        edgePlane(wall.points[i], wall.points[(i + 1) % wall.count], normal);
                    boundary.distance += wallConnectionMargin;
                    sectionCount = clip(section, sectionCount, boundary);
                }
                if (sectionCount >= 3 &&
                    area(section, sectionCount, normal) > regionAreaTolerance) {
                    candidate.wall = true;
                    changed = true;
                    break;
                }
            }
        }
    }
}

// Collision patches are triangle soups, not brushes. Intersect their surfaces
// with the same floor-height slice and feed their connected edges to the joint selection.
bool triangleSection(const Point *triangle, const Plane &slice, const Point &normal,
                     Obstacle &out) {
    Point hits[3];
    int n = 0;
    for (int i = 0; i < 3; i++) {
        const Point a = triangle[i];
        const Point b = triangle[(i + 1) % 3];
        const double da = dot(a, slice.normal) - slice.distance;
        const double db = dot(b, slice.normal) - slice.distance;
        if ((da <= 0 && db > 0) || (db <= 0 && da > 0)) {
            hits[n++] = add(a, add(b, a, -1), da / (da - db));
        }
    }
    if (n != 2) {
        return false; // Coplanar floors and triangles outside the slice.
    }
    // Project the slice back down onto the landing plane.
    hits[0].x[2] -= wallSliceHeight;
    hits[1].x[2] -= wallSliceHeight;
    const Point edge = add(hits[1], hits[0], -1);
    const double length = std::sqrt(dot(edge, edge));
    if (length < 0.001) {
        return false;
    }
    const Point offset = add(Point{}, cross(edge, normal), 0.01 / length);
    out = {};
    out.count = 4;
    out.points[0] = add(hits[0], offset, 1);
    out.points[1] = add(hits[1], offset, 1);
    out.points[2] = add(hits[1], offset, -1);
    out.points[3] = add(hits[0], offset, -1);
    return true;
}

bool terrainTriangles(unsigned treeIndex, const vec3_t mins, const vec3_t maxs,
                      std::vector<int> &triangleIndices, int depth = 0) {
    if (treeIndex >= unsigned(cm.aabbTreeCount) || depth > maxTraversalDepth) {
        return false;
    }
    const auto &tree = cm.aabbTrees[treeIndex];
    for (int axis = 0; axis < 3; axis++) {
        if (tree.origin[axis] + tree.halfSize[axis] < mins[axis] ||
            tree.origin[axis] - tree.halfSize[axis] > maxs[axis]) {
            return true;
        }
    }
    if (tree.materialIndex >= cm.numMaterials) {
        return false;
    }
    if (!(cm.materials[tree.materialIndex].contentFlags & supportContentsMask)) {
        return true;
    }
    if (tree.childCount) {
        for (unsigned i = 0; i < tree.childCount; i++) {
            if (!terrainTriangles(tree.u.firstChildIndex + i, mins, maxs, triangleIndices,
                                  depth + 1)) {
                return false;
            }
        }
    } else {
        if (tree.u.partitionIndex < 0 || tree.u.partitionIndex >= cm.partitionCount) {
            return false;
        }
        const auto &partition = cm.partitions[tree.u.partitionIndex];
        for (unsigned i = 0; i < unsigned(static_cast<unsigned char>(partition.triCount)); i++) {
            const int triangleIndex = partition.firstTri + i;
            if (triangleIndex < 0 || triangleIndex >= cm.triCount ||
                triangleIndices.size() >= maxCollisionTriangles) {
                return false;
            }
            triangleIndices.push_back(triangleIndex);
        }
    }
    return true;
}

// The runtime XModelTraceLine layout includes the triangle pointer/count omitted
// by the public XModelCollSurf header. Keep this engine view local to detection.
struct ModelCollisionSurface {
    const float (*triangles)[3][4];
    int triangleCount;
    float mins[3];
    float maxs[3];
    int boneIndex;
    int contents;
    int surfaceFlags;
};
static_assert(sizeof(ModelCollisionSurface) == 44, "CoD4 model collision surface ABI");
static_assert(offsetof(XModel, collSurfs) == 0x98 && offsetof(XModel, collLod) == 0xc6,
              "CoD4 model collision ABI");
bool planeIntersection(const Plane *p, Point &result) {
    const Point a = cross(p[1].normal, p[2].normal);
    const Point b = cross(p[2].normal, p[0].normal);
    const Point c = cross(p[0].normal, p[1].normal);
    const double determinant = dot(p[0].normal, a);
    if (std::abs(determinant) < 1e-15) {
        return false;
    }
    result = add(add(add(Point{}, a, p[0].distance), b, p[1].distance), c, p[2].distance);
    result = add(Point{}, result, 1 / determinant);
    for (double v : result.x) {
        if (!std::isfinite(v)) {
            return false;
        }
    }
    return true;
}

bool modelTriangle(const float encoded[3][4], const cStaticModel_t &model, Obstacle &triangle) {
    Plane local[3];
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) {
            local[i].normal.x[j] = encoded[i][j];
        }
        local[i].distance = encoded[i][3];
    }
    triangle = {};
    triangle.count = 3;
    for (int i = 0; i < 3; i++) {
        Plane planes[3] = {local[0], local[1], local[2]};
        if (i) {
            planes[i].distance += 1; // Barycentric coordinates (0,0), (1,0), (0,1).
        }
        Point vertex;
        if (!planeIntersection(planes, vertex)) {
            return false;
        }
        Plane transform[3];
        for (int j = 0; j < 3; j++) {
            for (int k = 0; k < 3; k++) {
                transform[j].normal.x[k] = model.invScaledAxis[k][j];
            }
            transform[j].distance = vertex.x[j];
        }
        if (!planeIntersection(transform, triangle.points[i])) {
            return false;
        }
        for (int j = 0; j < 3; j++) {
            triangle.points[i].x[j] += model.origin[j];
        }
    }
    return true;
}

bool boundsOverlap(const float *low, const float *high, const vec3_t mins, const vec3_t maxs) {
    for (int axis = 0; axis < 3; axis++) {
        if (high[axis] < mins[axis] || low[axis] > maxs[axis]) {
            return false;
        }
    }
    return true;
}

bool appendTriangle(const Obstacle &triangle, const vec3_t mins, const vec3_t maxs,
                    std::vector<Obstacle> &out) {
    for (int axis = 0; axis < 3; axis++) {
        double low = triangle.points[0].x[axis];
        double high = low;
        for (int i = 1; i < 3; i++) {
            low = std::min(low, triangle.points[i].x[axis]);
            high = std::max(high, triangle.points[i].x[axis]);
        }
        if (high < mins[axis] || low > maxs[axis]) {
            return true;
        }
    }
    if (out.size() >= maxCollisionTriangles) {
        return false;
    }
    out.push_back(triangle);
    return true;
}

// One bounded source of exact triangles for both wall slices and landing unions.
// Static models use collision surfaces, never their render geometry or bounds as floors.
// Decode terrain collision triangles touching the query; reject invalid indices or budget overflow.
bool collectTerrainCollisionTriangles(const vec3_t mins, const vec3_t maxs,
                                      std::vector<Obstacle> &outputTriangles) {
    std::vector<uint16_t> leaves(cm.numLeafs);
    int lastLeaf;
    const int leafCount = CM_BoxLeafnums(mins, maxs, leaves.data(), leaves.size(), &lastLeaf);
    std::vector<int> triangleIndices;
    for (int i = 0; i < leafCount; i++) {
        const auto &leaf = cm.leafs[leaves[i]];
        for (unsigned j = 0; j < leaf.collAabbCount; j++) {
            if (!terrainTriangles(leaf.firstCollAabbIndex + j, mins, maxs, triangleIndices)) {
                return false;
            }
        }
    }
    std::sort(triangleIndices.begin(), triangleIndices.end());
    triangleIndices.erase(std::unique(triangleIndices.begin(), triangleIndices.end()),
                          triangleIndices.end());
    for (int triangleIndex : triangleIndices) {
        Obstacle triangle = {};
        triangle.count = 3;
        for (int i = 0; i < 3; i++) {
            const unsigned vertexIndex = cm.triIndices[triangleIndex * 3 + i];
            if (vertexIndex >= cm.vertCount) {
                return false;
            }
            for (int axis = 0; axis < 3; axis++) {
                triangle.points[i].x[axis] = cm.verts[vertexIndex][axis];
            }
        }
        if (!appendTriangle(triangle, mins, maxs, outputTriangles)) {
            return false;
        }
    }
    return true;
}

// Read the collision mesh of each overlapping static model, including its scale and rotation.
bool collectModelCollisionTriangles(const vec3_t mins, const vec3_t maxs,
                                    std::vector<Obstacle> &outputTriangles) {
    for (unsigned i = 0; i < cm.numStaticModels; i++) {
        const auto &model = cm.staticModelList[i];
        if (!boundsOverlap(model.absmin, model.absmax, mins, maxs) || !model.xmodel ||
            model.xmodel->collLod < 0) {
            continue;
        }
        const auto *surfaces =
            reinterpret_cast<const ModelCollisionSurface *>(model.xmodel->collSurfs);
        if (!surfaces) {
            continue;
        }
        if (model.xmodel->numCollSurfs < 0 || model.xmodel->numCollSurfs > maxModelSurfaces) {
            return false;
        }
        unsigned visitedTriangles = 0;
        for (int j = 0; j < model.xmodel->numCollSurfs; j++) {
            const auto &surface = surfaces[j];
            if (!(surface.contents & supportContentsMask)) {
                continue;
            }
            if (surface.triangleCount < 0 || unsigned(surface.triangleCount) > maxModelTriangles ||
                (surface.triangleCount && !surface.triangles)) {
                return false;
            }
            for (int k = 0; k < surface.triangleCount; k++) {
                if (++visitedTriangles > maxModelTriangles) {
                    return false;
                }
                Obstacle triangle;
                if (!modelTriangle(surface.triangles[k], model, triangle)) {
                    return false;
                }
                if (!appendTriangle(triangle, mins, maxs, outputTriangles)) {
                    return false;
                }
            }
        }
    }
    return true;
}

// Append terrain first, then model triangles. A false result means the caller
// must discard the partial output; it must never publish incomplete support.
bool collisionTriangles(const vec3_t mins, const vec3_t maxs, std::vector<Obstacle> &out) {
    if (!collectTerrainCollisionTriangles(mins, maxs, out)) {
        return false;
    }
    return collectModelCollisionTriangles(mins, maxs, out);
}

// Work from player-solid brush intersections, never sampled rays. Freestanding objects
// remain ignored; solids connected to the landing boundary are walls.
bool collectWalls(const Point *points, int count, std::vector<Obstacle> &obstacles) {
    Point normal = polygonNormal(points, count);
    normal = add(Point{}, normal, 1 / std::sqrt(dot(normal, normal)));
    vec3_t mins;
    vec3_t maxs;
    for (int axis = 0; axis < 3; axis++) {
        mins[axis] = maxs[axis] = points[0].x[axis];
        for (int i = 1; i < count; i++) {
            mins[axis] = std::min(double(mins[axis]), points[i].x[axis]);
            maxs[axis] = std::max(double(maxs[axis]), points[i].x[axis]);
        }
    }
    maxs[2] += wallSliceHeight;
    std::vector<uint16_t> leaves(cm.numLeafs);
    int last;
    const int leafCount = CM_BoxLeafnums(mins, maxs, leaves.data(), leaves.size(), &last);
    std::vector<unsigned> indices;
    for (int i = 0; i < leafCount; i++) {
        worldBrushes(cm.leafs[leaves[i]].leafBrushNode, indices);
    }
    std::sort(indices.begin(), indices.end());
    indices.erase(std::unique(indices.begin(), indices.end()), indices.end());
    for (unsigned index : indices) {
        if (index >= cm.numBrushes) {
            continue;
        }
        const cbrush_t &brush = cm.brushes[index];
        if (!(brush.contents & supportContentsMask) || brush.numsides > maxBrushSidePlanes) {
            continue; // Solid and player-solid glass walls.
        }
        bool overlaps = true;
        for (int axis = 0; axis < 3; axis++) {
            if (brush.maxs[axis] < mins[axis] || brush.mins[axis] > maxs[axis]) {
                overlaps = false;
            }
        }
        if (!overlaps) {
            continue;
        }
        Obstacle obstacle = {};
        obstacle.count = count;
        std::copy(points, points + count, obstacle.points);
        // Intersect just above the landing plane. Connectivity, not arbitrary
        // wall height, distinguishes an enclosing obstruction from a loose prop.
        for (unsigned i = 0; i < brush.numsides + axialBrushPlaneCount && obstacle.count >= 3;
             i++) {
            Plane p = plane(brush, i);
            p.distance -= p.normal.x[2] * wallSliceHeight;
            obstacle.count = clip(obstacle.points, obstacle.count, p);
        }
        obstacle.count = simplify(obstacle.points, obstacle.count);
        if (obstacle.count < 3 || area(obstacle.points, obstacle.count, normal) < 0.01) {
            continue;
        }
        obstacles.push_back(obstacle);
        if (obstacles.size() > maxWallPolygons) {
            return false;
        }
    }
    std::vector<Obstacle> triangles;
    if (!collisionTriangles(mins, maxs, triangles)) {
        return false;
    }
    const Plane slice = {normal, dot(points[0], normal) + normal.x[2] * wallSliceHeight};
    for (const auto &triangle : triangles) {
        Obstacle obstacle;
        if (!triangleSection(triangle.points, slice, normal, obstacle)) {
            continue;
        }
        for (int i = 0; i < count && obstacle.count >= 3; i++) {
            obstacle.count = clip(obstacle.points, obstacle.count,
                                  edgePlane(points[i], points[(i + 1) % count], normal));
        }
        obstacle.count = simplify(obstacle.points, obstacle.count);
        if (obstacle.count < 3 || area(obstacle.points, obstacle.count, normal) < 0.001) {
            continue;
        }
        obstacles.push_back(obstacle);
        if (obstacles.size() > maxWallPolygons) {
            return false;
        }
    }
    return true;
}

// A landing can be built from several coplanar brushes (e.g. a solid rim
// around player-solid glass). Merge only when their union covers the hull.
// Convex hull alone would incorrectly fill holes and concave cutouts.
// With an empty gaps output, false plus nonempty gaps means uncovered floor;
// false plus empty gaps means the fragmentation budget was exhausted.
bool coveredHull(const Obstacle &hull, const std::vector<Obstacle> &surfaces, const Point &normal,
                 std::vector<Obstacle> *gaps = nullptr) {
    std::vector<Obstacle> remaining(1, hull);
    for (const auto &surface : surfaces) {
        std::vector<Obstacle> next;
        for (const auto &piece : remaining) {
            Obstacle inside = piece;
            for (int e = 0; e < surface.count && inside.count >= 3; e++) {
                Plane boundary =
                    edgePlane(surface.points[e], surface.points[(e + 1) % surface.count], normal);
                boundary.distance +=
                    surfaceSeamTolerance; // Same BSP seam tolerance as face connectivity.
                Obstacle outside = inside;
                Plane reverse = {add(Point{}, boundary.normal, -1), -boundary.distance};
                outside.count = clip(outside.points, outside.count, reverse);
                if (outside.count >= 3 && area(outside.points, outside.count, normal) > 0.0001) {
                    next.push_back(outside);
                }
                inside.count = clip(inside.points, inside.count, boundary);
                if (next.size() > maxUncoveredPieces) {
                    return false;
                }
            }
        }
        remaining.swap(next);
        if (remaining.empty()) {
            return true;
        }
    }
    double uncovered = 0;
    for (const auto &p : remaining) {
        uncovered += area(p.points, p.count, normal);
    }
    if (gaps) {
        *gaps = remaining;
    }
    return uncovered < 0.001;
}

bool convexHull(const std::vector<Obstacle> &surfaces, Obstacle &hull) {
    std::vector<Point> points;
    for (const auto &s : surfaces) {
        points.insert(points.end(), s.points, s.points + s.count);
    }
    std::sort(points.begin(), points.end(), [](const Point &a, const Point &b) {
        return a.x[0] < b.x[0] || (a.x[0] == b.x[0] && a.x[1] < b.x[1]);
    });
    points.erase(std::unique(points.begin(), points.end(),
                             [](const Point &a, const Point &b) {
                                 return std::abs(a.x[0] - b.x[0]) < 0.00001 &&
                                        std::abs(a.x[1] - b.x[1]) < 0.00001;
                             }),
                 points.end());
    if (points.size() < 3) {
        return false;
    }
    std::vector<Point> out(points.size() * 2);
    int k = 0;
    for (const auto &p : points) {
        while (k >= 2 &&
               cross(add(out[k - 1], out[k - 2], -1), add(p, out[k - 1], -1)).x[2] <= 0.00001) {
            --k;
        }
        out[k++] = p;
    }
    const int lower = k + 1;
    for (int i = int(points.size()) - 2; i >= 0; i--) {
        while (k >= lower &&
               cross(add(out[k - 1], out[k - 2], -1), add(points[i], out[k - 1], -1)).x[2] <=
                   0.00001) {
            --k;
        }
        out[k++] = points[i];
    }
    if (--k < 3 || k > maxPolygonVertices) {
        return false;
    }
    std::copy(out.begin(), out.begin() + k, hull.points);
    hull.count = simplify(hull.points, k);
    return hull.count >= 3;
}

bool triangleFace(Obstacle &face, const Point &normal, double height) {
    Point n =
        cross(add(face.points[1], face.points[0], -1), add(face.points[2], face.points[0], -1));
    const double length = std::sqrt(dot(n, n));
    if (length < 0.000001) {
        return false;
    }
    n = add(Point{}, n, 1 / length);
    if (std::abs(dot(n, normal)) < parallelPlaneDotThreshold) {
        return false;
    }
    for (int i = 0; i < face.count; i++) {
        if (std::abs(dot(face.points[i], normal) - height) > coplanarHeightTolerance) {
            return false;
        }
    }
    if (dot(n, normal) < 0) {
        std::reverse(face.points, face.points + face.count);
    }
    canonicalize(face);
    return true;
}

bool connectedSurface(const Obstacle &source, const Obstacle &candidate, const Point &normal) {
    Obstacle contact = candidate;
    for (int i = 0; i < source.count && contact.count >= 3; i++) {
        Plane edge = edgePlane(source.points[i], source.points[(i + 1) % source.count], normal);
        edge.distance += surfaceSeamTolerance;
        contact.count = clip(contact.points, contact.count, edge);
    }
    return contact.count >= 3 && area(contact.points, contact.count, normal) > 0.0001;
}

// Add each coplanar brush once. Keep the original contact comparison so
// touching seams and tiny bevels retain the existing acceptance threshold.
bool appendConnectedBrushFaces(const Obstacle &source, const vec3_t mins, const vec3_t maxs,
                               const Point &anchorPoint, const Point &unit, double height,
                               std::vector<unsigned> &visited, std::vector<Obstacle> &surfaces) {
    std::vector<uint16_t> leaves(cm.numLeafs);
    int last;
    const int leafCount = CM_BoxLeafnums(mins, maxs, leaves.data(), leaves.size(), &last);
    std::vector<unsigned> indices;
    for (int i = 0; i < leafCount; i++) {
        worldBrushes(cm.leafs[leaves[i]].leafBrushNode, indices);
    }
    std::sort(indices.begin(), indices.end());
    indices.erase(std::unique(indices.begin(), indices.end()), indices.end());
    for (unsigned index : indices) {
        if (index >= cm.numBrushes ||
            std::find(visited.begin(), visited.end(), index) != visited.end()) {
            continue;
        }
        const cbrush_t &brush = cm.brushes[index];
        if (!(brush.contents & supportContentsMask) || brush.numsides > maxBrushSidePlanes) {
            continue; // Solid and player-solid glass.
        }
        for (unsigned face = 0; face < brush.numsides + axialBrushPlaneCount; face++) {
            const Plane top = plane(brush, face);
            if (dot(top.normal, unit) < parallelPlaneDotThreshold ||
                std::abs(top.distance - height) > coplanarHeightTolerance) {
                continue;
            }
            Obstacle candidate = {};
            candidate.count = brushFace(brush, face, anchorPoint, unit, candidate.points);
            if (candidate.count < 3) {
                continue;
            }
            Obstacle contact = candidate;
            for (int j = 0; j < source.count && contact.count >= 3; j++) {
                Plane edge =
                    edgePlane(source.points[j], source.points[(j + 1) % source.count], unit);
                edge.distance += surfaceSeamTolerance;
                contact.count = clip(contact.points, contact.count, edge);
            }
            if (contact.count < 3 || area(contact.points, contact.count, unit) < 0.0001) {
                continue;
            }
            visited.push_back(index);
            surfaces.push_back(candidate);
            if (surfaces.size() > maxLandingSurfaces) {
                return false; // Bound editor work; never silently return a partial component.
            }
            break;
        }
    }
    return true;
}

// Add only connected, coplanar collision triangles not already in the component.
bool appendConnectedTriangleFaces(const Obstacle &source, const vec3_t mins, const vec3_t maxs,
                                  const Point &unit, double height,
                                  std::vector<Obstacle> &surfaces) {
    std::vector<Obstacle> triangles;
    if (!collisionTriangles(mins, maxs, triangles)) {
        return false;
    }
    for (auto candidate : triangles) {
        if (!triangleFace(candidate, unit, height) || !connectedSurface(source, candidate, unit)) {
            continue;
        }
        bool duplicate = false;
        for (auto existing : surfaces) {
            canonicalize(existing);
            if (!polygonLess(candidate, existing) && !polygonLess(existing, candidate)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            continue;
        }
        surfaces.push_back(candidate);
        if (surfaces.size() > maxLandingSurfaces) {
            return false;
        }
    }
    return true;
}

// Grow the connected coplanar floor component, then put it in a stable order.
// On failure the partial component must be discarded.
bool collectLanding(const Point *points, int count, std::vector<Obstacle> &surfaces) {
    const Point normal = polygonNormal(points, count);
    const Point unit = add(Point{}, normal, 1 / std::sqrt(dot(normal, normal)));
    const double height = dot(points[0], unit);
    surfaces.resize(1);
    surfaces[0].count = count;
    std::copy(points, points + count, surfaces[0].points);
    // Bound work by face count and clipping complexity, not world-space size.
    // A long, simple floor is cheaper than a small, highly fragmented one.
    std::vector<unsigned> visited;
    for (size_t current = 0; current < surfaces.size(); current++) {
        const Obstacle source = surfaces[current];
        vec3_t mins;
        vec3_t maxs;
        for (int axis = 0; axis < 3; axis++) {
            double low = source.points[0].x[axis];
            double high = low;
            for (int j = 1; j < source.count; j++) {
                low = std::min(low, source.points[j].x[axis]);
                high = std::max(high, source.points[j].x[axis]);
            }
            mins[axis] = low - 0.05;
            maxs[axis] = high + 0.05;
        }
        if (!appendConnectedBrushFaces(source, mins, maxs, points[0], unit, height, visited,
                                       surfaces)) {
            return false;
        }
        if (!appendConnectedTriangleFaces(source, mins, maxs, unit, height, surfaces)) {
            return false;
        }
    }
    for (auto &surface : surfaces) {
        canonicalize(surface);
    }
    std::sort(surfaces.begin(), surfaces.end(), polygonLess);
    surfaces.erase(std::unique(surfaces.begin(), surfaces.end(),
                               [](const Obstacle &a, const Obstacle &b) {
                                   return !polygonLess(a, b) && !polygonLess(b, a);
                               }),
                   surfaces.end());
    return true;
}

// Same circular edge contact and slope-height allowance as checkpointArea::touchesPlayer.
// The bounding box used to collect candidates is only a broad-phase query.
bool playerContact(const Point *points, int count, const Point &origin, Point &seed,
                   double &contactDistanceSquared) {
    Point normal = polygonNormal(points, count);
    normal = add(Point{}, normal, 1 / std::sqrt(dot(normal, normal)));
    if (normal.x[2] < minimumSupportNormalZ) {
        return false;
    }
    bool inside = true;
    for (int i = 0; i < count; i++) {
        const Point edge = add(points[(i + 1) % count], points[i], -1);
        const Point delta = add(origin, points[i], -1);
        if (edge.x[0] * delta.x[1] - edge.x[1] * delta.x[0] <
            -0.0001 * std::hypot(edge.x[0], edge.x[1])) {
            inside = false;
        }
    }
    Point candidate = origin;
    candidate.x[2] =
        (dot(points[0], normal) - normal.x[0] * origin.x[0] - normal.x[1] * origin.x[1]) /
        normal.x[2];
    double nearestDistanceSquared = 0;
    if (!inside) {
        nearestDistanceSquared = 1e30;
        for (int i = 0; i < count; i++) {
            const Point a = points[i];
            const Point d = add(points[(i + 1) % count], a, -1);
            const double length = d.x[0] * d.x[0] + d.x[1] * d.x[1];
            if (length < 1e-12) {
                continue;
            }
            const double interpolationFactor = std::max(
                0.0,
                std::min(1.0, ((origin.x[0] - a.x[0]) * d.x[0] + (origin.x[1] - a.x[1]) * d.x[1]) /
                                  length));
            const Point p = add(a, d, interpolationFactor);
            const double dx = p.x[0] - origin.x[0];
            const double dy = p.x[1] - origin.x[1];
            if (dx * dx + dy * dy < nearestDistanceSquared) {
                nearestDistanceSquared = dx * dx + dy * dy;
                candidate = p;
            }
        }
    }
    const double heightAboveContact = origin.x[2] - candidate.x[2];
    if (nearestDistanceSquared > playerContactRadius * playerContactRadius ||
        heightAboveContact < -2 ||
        heightAboveContact > 4 + playerContactRadius * (1 / normal.x[2] - 1)) {
        return false;
    }
    seed = candidate;
    contactDistanceSquared = nearestDistanceSquared + heightAboveContact * heightAboveContact;
    return true;
}

// Expansion is only for identifying the real boundary of the union. It never
// enlarges a checkpoint. Interior props remain covered by the supporting floor.
bool classifyWalls(std::vector<Obstacle> &obstacles, const std::vector<Obstacle> &surfaces,
                   const Point &normal) {
    for (auto &obstacle : obstacles) {
        // Bounded round expansion avoids arbitrarily long miters at acute
        // triangle/brush corners, which could falsely connect an interior prop.
        Point u = {{normal.x[2], 0, -normal.x[0]}};
        u = add(Point{}, u, 1 / std::sqrt(dot(u, u)));
        const Point v = cross(normal, u);
        std::vector<Obstacle> offsets;
        for (int direction = 0; direction < 16; direction++) {
            const double angle = direction * (2 * 3.141592653589793 / 16);
            const Point offset =
                add(add(Point{}, u, 0.25 * std::cos(angle)), v, 0.25 * std::sin(angle));
            Obstacle translated = obstacle;
            for (int i = 0; i < translated.count; i++) {
                translated.points[i] = add(translated.points[i], offset, 1);
            }
            offsets.push_back(translated);
        }
        Obstacle expanded = {};
        if (!convexHull(offsets, expanded)) {
            return false;
        }
        std::vector<Obstacle> outside;
        if (!coveredHull(expanded, surfaces, normal, &outside)) {
            if (outside.empty()) {
                return false;
            }
            obstacle.wall = true;
        }
    }
    connectWalls(obstacles, normal);
    return true;
}

// Select a supported convex region, then validate its final float coordinates
// against gaps, walls and player contact before publishing the checkpoint.
bool finalizeLanding(Obstacle &hull, const std::vector<Obstacle> &surfaces,
                     std::vector<Obstacle> obstacles, const Point &origin, const Point &seed) {
    Point normal = polygonNormal(hull.points, hull.count);
    normal = add(Point{}, normal, 1 / std::sqrt(dot(normal, normal)));
    if (!classifyWalls(obstacles, surfaces, normal)) {
        return false;
    }
    std::vector<Obstacle> constraints;
    if (!coveredHull(hull, surfaces, normal, &constraints) && constraints.empty()) {
        return false;
    }
    for (auto wall : obstacles) {
        if (wall.wall) {
            wall.clearance = checkpointWallClearance;
            constraints.push_back(wall);
        }
    }
    for (auto &c : constraints) {
        canonicalize(c);
    }
    std::sort(constraints.begin(), constraints.end(), polygonLess);
    // Solve real gaps and walls together, before committing to one convex area.
    SupportedRegion search = {constraints, normal, seed};
    search.search(hull);
    if (search.exhausted || search.best.count < 3) {
        return false;
    }
    hull = search.best;
    // Validate the exact float coordinates GSC will receive, not just doubles.
    for (int i = 0; i < hull.count; i++) {
        for (double &coordinate : hull.points[i].x) {
            coordinate = float(coordinate);
        }
    }
    if (hull.count > maxCheckpointVertices || !coveredHull(hull, surfaces, normal)) {
        return false;
    }
    for (int i = 0; i < hull.count; i++) {
        const Point a = hull.points[i];
        const Point b = hull.points[(i + 1) % hull.count];
        const Point edge = add(b, a, -1);
        if (dot(edge, edge) < 0.0001 || std::abs(dot(add(a, hull.points[0], -1), normal)) > 0.25) {
            return false;
        }
        for (int j = 0; j < hull.count; j++) {
            if (j != i && j != (i + 1) % hull.count) {
                const Point d = add(hull.points[j], a, -1);
                if (edge.x[0] * d.x[1] - edge.x[1] * d.x[0] <=
                    0.0001 * std::hypot(edge.x[0], edge.x[1])) {
                    return false;
                }
            }
        }
    }
    for (const auto &wall : obstacles) {
        if (wall.wall) {
            Point overlap[maxPolygonVertices];
            std::copy(hull.points, hull.points + hull.count, overlap);
            const int n = intersection(overlap, hull.count, wall, normal);
            if (n >= 3 && area(overlap, n, normal) > 0.01) {
                return false;
            }
        }
    }
    Point contact;
    double distance;
    return playerContact(hull.points, hull.count, origin, contact, distance);
}

bool detectLanding(Point *points, int &count, const Point &origin) {
    std::vector<Obstacle> surfaces;
    if (!collectLanding(points, count, surfaces)) {
        return false;
    }
    Obstacle hull = {};
    if (!convexHull(surfaces, hull)) {
        return false;
    }
    const Point n = polygonNormal(hull.points, hull.count);
    const Point normal = add(Point{}, n, 1 / std::sqrt(dot(n, n)));
    Point seed;
    double distance;
    if (!playerContact(points, count, origin, seed, distance)) {
        return false;
    }
    std::vector<Obstacle> walls;
    if (!collectWalls(hull.points, hull.count, walls)) {
        return false;
    }
    // Inset only the outside hull for BSP seam/float precision; holes stay holes.
    const Obstacle boundary = hull;
    for (int i = 0; i < boundary.count && hull.count >= 3; i++) {
        Plane edge =
            edgePlane(boundary.points[i], boundary.points[(i + 1) % boundary.count], normal);
        edge.distance -= surfaceSeamTolerance;
        hull.count = clip(hull.points, hull.count, edge);
    }
    if (hull.count < 3 || !finalizeLanding(hull, surfaces, walls, origin, seed)) {
        return false;
    }
    count = hull.count;
    std::copy(hull.points, hull.points + count, points);
    return true;
}

struct SupportFaceSearch {
    Point origin;
    Point normal;
    Point inside;
    Point best[maxPolygonVertices];
    int count = 0;
    double bestArea = 0;
    double bestDistance = 1e30;
    bool footprint = false;
    void brush(unsigned index) {
        if (index >= cm.numBrushes) {
            return;
        }
        const cbrush_t &b = cm.brushes[index];
        if (!(b.contents & supportContentsMask) || b.numsides > maxBrushSidePlanes) {
            return; // solid world brushes only
        }
        for (unsigned i = 0; i < b.numsides + axialBrushPlaneCount; i++) {
            const Plane p = plane(b, i);
            const double reach =
                footprint
                    ? playerContactRadius * (std::abs(p.normal.x[0]) + std::abs(p.normal.x[1])) +
                          playerQueryHalfHeight * std::abs(p.normal.x[2])
                    : 0.5;
            if (dot(origin, p.normal) - p.distance > reach) {
                return;
            }
        }
        for (unsigned face = 0; face < b.numsides + axialBrushPlaneCount; face++) {
            const Plane top = plane(b, face);
            if (footprint) {
                if (top.normal.x[2] < minimumSupportNormalZ) {
                    continue;
                }
            } else if (dot(top.normal, normal) < parallelPlaneDotThreshold ||
                       std::abs(dot(origin, top.normal) - top.distance) > 0.5) {
                continue;
            }
            Point center =
                add(origin, top.normal,
                    (top.distance - dot(origin, top.normal)) / dot(top.normal, top.normal));
            Point pts[maxPolygonVertices];
            int n = brushFace(b, face, center, top.normal, pts);
            if (n < 3) {
                continue;
            }
            double area = 0;
            for (int i = 0; i < n; i++) {
                const Point a = add(pts[i], center, -1);
                const Point z = add(pts[(i + 1) % n], center, -1);
                area += dot(cross(a, z), top.normal);
            }
            area = std::abs(area);
            double supportDistance = 0;
            if (footprint) {
                Point contact;
                if (!playerContact(pts, n, origin, contact, supportDistance)) {
                    continue;
                }
            }
            if (area > 0 && (footprint ? supportDistance < bestDistance : area > bestArea)) {
                bestArea = area;
                bestDistance = supportDistance;
                count = n;
                std::copy(pts, pts + n, best);
            }
        }
    }
    // Follow the world leaf tree, not inline/moving brush models.
    void node(int index, int depth = 0) {
        if (index <= 0 || unsigned(index) >= cm.leafbrushNodesCount || depth > maxTraversalDepth) {
            return;
        }
        const cLeafBrushNode_t &n = cm.leafbrushNodes[index];
        if (n.leafBrushCount > 0) {
            for (int i = 0; i < n.leafBrushCount; i++) {
                brush(n.data.leaf.brushes[i]);
            }
            return;
        }
        if (n.leafBrushCount < 0) {
            node(index + 1, depth + 1);
        }
        if (n.axis > 2) {
            return;
        }
        double d = inside.x[n.axis] - n.data.children.dist;
        const double footprintReach =
            n.axis < 2 ? playerContactRadius + 0.5 : playerQueryHalfHeight;
        const double reach = footprint ? footprintReach : pointQueryReach;
        if (d >= -reach) {
            node(index + n.data.children.childOffset[0], depth + 1);
        }
        if (d <= reach) {
            node(index + n.data.children.childOffset[1], depth + 1);
        }
    }
    bool triangleSupport() {
        vec3_t mins;
        vec3_t maxs;
        for (int axis = 0; axis < 3; axis++) {
            const double footprintReach = axis == 2 ? playerQueryHalfHeight : playerContactRadius;
            const double reach = footprint ? footprintReach : pointQueryReach;
            mins[axis] = origin.x[axis] - reach;
            maxs[axis] = origin.x[axis] + reach;
        }
        std::vector<Obstacle> triangles;
        if (!collisionTriangles(mins, maxs, triangles)) {
            return false;
        }
        for (auto face : triangles) {
            Point up = cross(add(face.points[1], face.points[0], -1),
                             add(face.points[2], face.points[0], -1));
            const double length = std::sqrt(dot(up, up));
            if (length < 0.000001) {
                continue;
            }
            up = add(Point{}, up, 1 / length);
            if (up.x[2] < 0) {
                up = add(Point{}, up, -1);
            }
            if (up.x[2] < minimumSupportNormalZ ||
                (!footprint && dot(up, normal) < parallelPlaneDotThreshold)) {
                continue;
            }
            const double height = dot(face.points[0], up);
            if (!triangleFace(face, up, height)) {
                continue;
            }
            Point contact;
            double distance;
            if (!playerContact(face.points, face.count, origin, contact, distance)) {
                continue;
            }
            if (!footprint && distance > 0.25) {
                continue;
            }
            if (!count || (footprint && distance < bestDistance)) {
                count = face.count;
                std::copy(face.points, face.points + count, best);
                bestDistance = distance;
            }
        }
        return true;
    }
};
} // namespace
#endif

// Script getters reject missing/wrongly typed arguments before geometry is read.
// Undefined means no supported face or the search could not complete within its limits.
extern "C" void Gsc_Platform_Face()
{
#ifdef COD4
    vec3_t origin;
    vec3_t normal;
    stackGetParamVector(0, origin);
    stackGetParamVector(1, normal);
    SupportFaceSearch search;
    int footprint = 0;
    if (Scr_GetNumParam() > 2) {
        stackGetParamInt(2, &footprint);
    }
    search.footprint = footprint != 0;
    for (int i = 0; i < 3; i++) {
        if (!std::isfinite(origin[i]) || std::abs(origin[i]) > mapCoordinateLimit ||
            !std::isfinite(normal[i])) {
            stackPushUndefined();
            return;
        }
        search.origin.x[i] = origin[i];
        search.normal.x[i] = normal[i];
    }
    if (normal[2] < minimumSupportNormalZ ||
        std::abs(dot(search.normal, search.normal) - 1) > 0.01) {
        stackPushUndefined();
        return;
    }
    search.inside = search.footprint ? search.origin : add(search.origin, search.normal, -0.25);
    vec3_t inside;
    for (int i = 0; i < 3; i++) {
        inside[i] = search.inside.x[i];
    }
    if (search.footprint) {
        vec3_t mins;
        vec3_t maxs;
        for (int axis = 0; axis < 3; axis++) {
            const float extent = axis == 2 ? playerQueryHalfHeight : playerContactRadius;
            mins[axis] = origin[axis] - extent;
            maxs[axis] = origin[axis] + extent;
        }
        uint16_t leaves[maxSupportQueryLeaves];
        int lastLeaf;
        const int count = CM_BoxLeafnums(mins, maxs, leaves, maxSupportQueryLeaves, &lastLeaf);
        for (int i = 0; i < count; i++) {
            search.node(cm.leafs[leaves[i]].leafBrushNode);
        }
    } else {
        int leaf = CM_PointLeafnum(inside);
        if (leaf >= 0 && unsigned(leaf) < cm.numLeafs) {
            search.node(cm.leafs[leaf].leafBrushNode);
        }
    }
    if (!search.triangleSupport() || !search.count) {
        stackPushUndefined();
        return;
    }
    int trim = 0;
    if (Scr_GetNumParam() > 3) {
        stackGetParamInt(3, &trim);
    }
    if (trim) {
        if (!detectLanding(search.best, search.count, search.origin)) {
            stackPushUndefined();
            return;
        }
    }
    stackMakeArray();
    for (int i = 0; i < search.count; i++) {
        vec3_t p;
        for (int j = 0; j < 3; j++) {
            p[j] = search.best[i].x[j];
        }
        stackPushVector(p);
        stackPushArrayNext();
    }
#else
    stackPushUndefined(); // CoD2 continues to use the GSC detector.
#endif
}

// Read once when binding an editor checkpoint. Gameplay uses getGroundEntity().
// Result fields: inline model index, local minimum bounds, local maximum bounds.
extern "C" void Gsc_Platform_EntityInfo()
{
#ifdef COD4
    int entityNum;
    if (!stackGetParams("i", &entityNum) || entityNum < 0 || entityNum >= ENTITYNUM_WORLD ||
        !g_entities[entityNum].r.inuse) {
        stackPushUndefined();
        return;
    }
    const gentity_t &entity = g_entities[entityNum];
    stackMakeArray();
    stackPushInt(entity.r.bmodel ? entity.s.index : 0);
    stackPushArrayNext();
    stackPushVector(entity.r.mins);
    stackPushArrayNext();
    stackPushVector(entity.r.maxs);
    stackPushArrayNext();
#else
    stackPushUndefined();
#endif
}
