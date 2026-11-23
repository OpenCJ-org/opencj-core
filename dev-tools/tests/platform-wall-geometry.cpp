// Pure geometry tests: no server, database, or live state.
#include "../../server-ext/opencj_platform.cpp"
#include <cassert>
#include <cstdio>
static Obstacle box(double x1, double y1, double x2, double y2, bool wall) {
    Obstacle polygon = {};
    polygon.count = 4;
    polygon.wall = wall;
    polygon.points[0] = {{x1, y1, 0}};
    polygon.points[1] = {{x2, y1, 0}};
    polygon.points[2] = {{x2, y2, 0}};
    polygon.points[3] = {{x1, y2, 0}};
    return polygon;
}

static double selectedArea(std::vector<Obstacle> walls, Point seed = {{10, 10, 0}}) {
    auto base = box(0, 0, 100, 100, false);
    const auto floor = base;
    if (!finalizeLanding(base, {floor}, walls, seed, seed)) {
        return -1;
    }
    return area(base.points, base.count, Point{{0, 0, 1}});
}

static Obstacle selectLanding(std::vector<Obstacle> walls,
                              Obstacle base = box(0, 0, 100, 100, false),
                              Point seed = {{50, 50, 0}}, Point normal = {{0, 0, 1}}) {
    const auto floor = base;
    assert(finalizeLanding(base, {floor}, walls, seed, seed));
    canonicalize(base);
    return base;
}

static void assertSameVertices(const Obstacle &a, const Obstacle &b) {
    assert(a.count == b.count);
    for (int i = 0; i < a.count; i++) {
        for (int j = 0; j < 3; j++) {
            assert(std::abs(a.points[i].x[j] - b.points[i].x[j]) < 0.005);
        }
    }
}

static Point tilt(Point p) {
    return {{0.8 * p.x[0] - 0.6 * p.x[1] + 20000, 0.6 * p.x[0] + 0.8 * p.x[1] - 12000,
             p.x[2] + 0.25 * p.x[0]}};
}

static Obstacle tilted(Obstacle p) {
    for (int i = 0; i < p.count; i++) {
        p.points[i] = tilt(p.points[i]);
    }
    return p;
}

static void combinedWalls() {
    const auto a = box(55, 55, 100, 100, true);
    const auto b = box(0, 0, 15, 5, true);
    const auto expected = selectLanding({a, b});
    assert(area(expected.points, expected.count, Point{{0, 0, 1}}) > 5200);
    assertSameVertices(expected, selectLanding({b, a}));
    // Rotate corner indices too: geometry is identical, only serialization differs.
    for (int ai = 0; ai < 4; ai++) {
        for (int bi = 0; bi < 4; bi++) {
            auto x = a;
            auto y = b;
            std::rotate(x.points, x.points + ai, x.points + 4);
            std::rotate(y.points, y.points + bi, y.points + 4);
            assertSameVertices(expected, selectLanding({x, y}));
            assertSameVertices(expected, selectLanding({y, x}));
        }
    }
    const auto base = tilted(box(0, 0, 100, 100, false));
    Point normal =
        cross(add(base.points[1], base.points[0], -1), add(base.points[2], base.points[0], -1));
    normal = add(Point{}, normal, 1 / std::sqrt(dot(normal, normal)));
    // Mix triangle-derived wall sections, a boundary brush, and an isolated prop
    // on a rotated/sloped landing at large world coordinates.
    Point triangles[2][3] = {{{{0, 80, -10}}, {{100, 80, -10}}, {{100, 90, 40}}},
                             {{{0, 80, -10}}, {{100, 90, 40}}, {{0, 90, 40}}}};
    std::vector<Obstacle> mixed = {tilted(b), tilted(box(30, 30, 40, 40, false))};
    const Plane slice = {normal, dot(base.points[0], normal) + normal.x[2] * 0.5};
    for (auto &triangle : triangles) {
        for (auto &vertex : triangle) {
            vertex = tilt(vertex);
        }
        Obstacle section;
        assert(triangleSection(triangle, slice, normal, section));
        mixed.push_back(section);
    }
    const auto reference = selectLanding(mixed, base, tilt(Point{{50, 50, 0}}), normal);
    int order[] = {0, 1, 2, 3};
    int permutations = 0;
    do {
        std::vector<Obstacle> shuffled;
        for (int i : order) {
            shuffled.push_back(mixed[i]);
        }
        assertSameVertices(reference,
                           selectLanding(shuffled, base, tilt(Point{{50, 50, 0}}), normal));
        permutations++;
    } while (std::next_permutation(order, order + 4));
    assert(permutations == 24);
    mixed.erase(mixed.begin() + 1);
    assertSameVertices(reference, selectLanding(mixed, base, tilt(Point{{50, 50, 0}}),
                                                normal)); // Prop has no effect.
    // Changing internal brush seams must not change the region for this divider.
    assertSameVertices(selectLanding({box(70, 0, 80, 100, true)}),
                       selectLanding({box(70, 0, 80, 45, true), box(70, 45, 80, 100, true)}));
    std::puts("PASS: global wall optimum, reordered/rotated corners, mixed mesh+brush+prop on "
              "sloped landing, divider seams");
}

static void unifiedConstraints() {
    for (bool slope : {false, true}) {
        auto transform = [slope](Obstacle o) {
            return slope ? tilted(o) : o;
        };
        auto point = [slope](Point p) {
            return slope ? tilt(p) : p;
        };
        // L-shaped floor: choosing the widest bottom section first would lose
        // most of it to the wall. Joint solving should retain the tall left arm.
        std::vector<Obstacle> floors = {transform(box(0, 0, 100, 40, false)),
                                        transform(box(0, 40, 40, 100, false))};
        std::vector<Obstacle> walls = {transform(box(45, 0, 55, 40, false)),
                                       transform(box(15, 30, 25, 38, false))};
        Obstacle hull = {};
        assert(convexHull(floors, hull));
        const Point seed = point(Point{{10, 10, 0}});
        auto expected = hull;
        assert(finalizeLanding(expected, floors, walls, seed, seed));
        Point normal =
            cross(add(hull.points[1], hull.points[0], -1), add(hull.points[2], hull.points[0], -1));
        normal = add(Point{}, normal, 1 / std::sqrt(dot(normal, normal)));
        assert(area(expected.points, expected.count, normal) > 3900);
        assert(coveredHull(expected, floors, normal));
        auto withoutProp = hull;
        assert(finalizeLanding(withoutProp, floors, {walls[0]}, seed, seed));
        assertSameVertices(expected, withoutProp);
        std::reverse(floors.begin(), floors.end());
        std::reverse(walls.begin(), walls.end());
        auto reversed = hull;
        assert(finalizeLanding(reversed, floors, walls, seed, seed));
        assertSameVertices(expected, reversed);
        // This loose object touches the would-be bottom-region cut y=40,
        // but neither the actual floor boundary nor a connected wall.
        std::vector<Obstacle> prop = {transform(box(15, 35, 25, 45, false))};
        assert(classifyWalls(prop, floors, normal));
        assert(!prop[0].wall);
    }
    // Acute interior geometry must not acquire an unbounded expansion miter.
    auto floorForProp = box(0, 0, 100, 100, false);
    auto needle = box(20, 20, 80, 20.001, false);
    needle.count = 3;
    needle.points[2] = {{79, 20.001, 0}};
    std::vector<Obstacle> needleProps = {needle};
    assert(classifyWalls(needleProps, {floorForProp}, Point{{0, 0, 1}}));
    assert(!needleProps[0].wall);
    // More than eight intermediate corners, reduced by one wall to a rectangle.
    Obstacle many = {};
    many.count = 12;
    for (int i = 0; i < 12; i++) {
        double angle = 2 * 3.141592653589793 * i / 12;
        many.points[i] = {{50 + 50 * std::cos(angle), 50 + 50 * std::sin(angle), 0}};
    }
    Obstacle hull = {};
    assert(convexHull({many}, hull));
    assert(hull.count == 12);
    std::vector<Obstacle> walls = {box(0, 0, 20, 100, false), box(80, 0, 100, 100, false),
                                   box(0, 0, 100, 20, false), box(0, 80, 100, 100, false)};
    const Point seed = {{50, 50, 0}};
    assert(finalizeLanding(hull, {many}, walls, seed, seed));
    assert(hull.count == 4);
    // Final regions smaller than one unit remain valid after wall clipping,
    // including rotated slopes at large coordinates.
    for (bool sloped : {false, true}) {
        for (double width : {0.25, 0.5, 1.0}) {
            auto transform = [sloped](Obstacle o) {
                return sloped ? tilted(o) : o;
            };
            auto base = transform(box(0, 0, 3, 20, false));
            auto wall = transform(box(0, 0, 3, 20 - width - 0.125, false));
            Point seed = {{1.5, 20 - width / 2, 0}};
            if (sloped) {
                seed = tilt(seed);
            }
            auto selected = base;
            assert(finalizeLanding(selected, {base}, {wall}, seed, seed));
            Point normal = cross(add(base.points[1], base.points[0], -1),
                                 add(base.points[2], base.points[0], -1));
            normal = add(Point{}, normal, 1 / std::sqrt(dot(normal, normal)));
            assert(coveredHull(selected, {base}, normal));
            assert(selected.count == 4);
        }
    }
    auto tinySquare = box(0, 0, 0.1, 0.1, false);
    const auto tinyFloor = tinySquare;
    const Point tinySeed = {{0.05, 0.05, 0}};
    assert(finalizeLanding(tinySquare, {tinyFloor}, {}, tinySeed, tinySeed));
    assert(tinySquare.count == 4);
    // Circular support, including corners and the slope allowance used by GSC.
    auto floor = box(0, 0, 100, 100, false);
    Point contact;
    double distance;
    assert(playerContact(floor.points, 4, Point{{-10, -10, 0.125}}, contact, distance));
    assert(!playerContact(floor.points, 4, Point{{-14, -14, 0.125}}, contact, distance));
    auto slope = tilted(floor);
    auto origin = tilt(Point{{50, 50, 0}});
    origin.x[2] += 4;
    assert(playerContact(slope.points, 4, origin, contact, distance));
    origin.x[2] += 10;
    assert(!playerContact(slope.points, 4, origin, contact, distance));
    std::puts("PASS: joint gaps+walls+props on flat/sloped floors, original-union wall "
              "classification, late corner limit, circular slope support");
}

static void testBevelSimplification() {
    Point bevel[4] = {
        {{-2759, 2647.77, 0}}, {{-2759, 2871, 0}}, {{-3047, 2871, 0}}, {{-3047, 2870.77, 0}}};
    const double originalArea = area(bevel, 4, Point{{0, 0, 1}});
    const int corners = simplify(bevel, 4, 1.0);
    assert(corners == 3 && area(bevel, corners, Point{{0, 0, 1}}) <= originalArea);
}

static void testPropAndWallSelection() {
    assert(selectedArea({box(40, 40, 60, 60, false)}) == 10000); // Freestanding prop.
    const auto wall = box(70, 0, 80, 100, true);
    assert(std::abs(selectedArea({wall}) - 6987.5) < 0.01);
    assert(std::abs(selectedArea({wall, box(30, 30, 50, 50, false)}) - 6987.5) <
           0.01);                                            // Prop does not crop.
    assert(selectedArea({wall}, Point{{90, 10, 0}}) > 1900); // Other side of same divider.
    assert(selectedArea({wall}, Point{{75, 10, 0}}) ==
           -1); // Unsafe seed must not emit raw geometry.
    assert(selectedArea({box(0, 70, 45, 80, true), box(45, 70, 100, 80, false)}) <
           7000); // Joined wall brushes.
    const double corner = selectedArea({box(70, 70, 100, 100, true)});
    assert(corner > 6900 && corner < 7000); // Concavity becomes safe convex portion.
}

static void testMeshWallSections() {
    // Two triangles forming one mesh wall: seams and winding must not matter.
    const Point up = {{0, 0, 1}};
    const Plane slice = {up, 0.5};
    Point mesh[2][3] = {{{{0, 70, -10}}, {{100, 70, -10}}, {{100, 70, 10}}},
                        {{{0, 70, -10}}, {{100, 70, 10}}, {{0, 70, 10}}}};
    for (int reverse = 0; reverse < 2; reverse++) {
        std::vector<Obstacle> sections;
        const auto boundary = box(0, 0, 100, 100, false);
        for (auto &triangle : mesh) {
            if (reverse) {
                std::swap(triangle[0], triangle[2]);
            }
            Obstacle section;
            assert(triangleSection(triangle, slice, up, section));
            sections.push_back(section);
        }
        const double clipped = selectedArea(sections);
        assert(clipped > 6980 && clipped < 7000);
    }
    Point prop[3] = {{{40, 40, -10}}, {{60, 40, -10}}, {{50, 40, 10}}};
    Obstacle section;
    assert(triangleSection(prop, slice, up, section));
    assert(selectedArea({section}) == 10000); // Interior mesh props do not truncate landings.
    Point floor[3] = {{{0, 0, 0}}, {{100, 0, 0}}, {{0, 100, 0}}};
    assert(!triangleSection(floor, slice, up, section)); // Supporting floor is not a wall.
    const Point slope = {{-0.242535625, 0, 0.9701425}};
    const Plane tilted = {slope, 0.5 * slope.x[2]};
    assert(triangleSection(mesh[1], tilted, slope, section));
    for (int i = 0; i < section.count; i++) {
        assert(std::abs(dot(section.points[i], slope)) < 0.00001);
    }
}

static void testFloorCoverage() {
    const Point up = {{0, 0, 1}};
    const auto full = box(0, 0, 100, 100, false);
    std::vector<Obstacle> frame = {box(0, 0, 100, 10, false), box(0, 90, 100, 100, false),
                                   box(0, 10, 10, 90, false), box(90, 10, 100, 90, false)};
    Obstacle hull = {};
    assert(convexHull(frame, hull));
    assert(!coveredHull(hull, frame, up)); // Empty frame must not fill air.
    frame.push_back(box(10, 10, 90, 90, false));
    assert(coveredHull(hull, frame, up));
    std::vector<Obstacle> gap = {box(0, 0, 49, 100, false), box(50, 0, 100, 100, false)};
    assert(!coveredHull(full, gap, up));
    std::vector<Obstacle> notch = {box(0, 0, 100, 40, false), box(0, 40, 40, 100, false)};
    assert(!coveredHull(full, notch, up));
    std::vector<Obstacle> overlap = {box(0, 0, 60, 100, false), box(40, 0, 100, 100, false)};
    assert(coveredHull(full, overlap, up)); // Overlap cannot count twice to hide a hole.
}

static void testGapPartitionInvariance() {
    const Point up = {{0, 0, 1}};
    const auto full = box(0, 0, 100, 100, false);
    // Equivalent notched frame gaps, partitioned and ordered differently.
    // Both must retain the complete lower strip around the actual player seed.
    const std::vector<Obstacle> partitions[] = {
        {box(10, 30, 90, 100, true), box(40, 20, 60, 30, true)},
        {box(40, 20, 60, 100, true), box(10, 30, 40, 100, true), box(60, 30, 90, 100, true)},
        {box(60, 30, 90, 100, true), box(10, 30, 40, 100, true), box(40, 20, 60, 100, true)}};
    for (const auto &gaps : partitions) {
        SupportedRegion search = {gaps, up, Point{{50, 10, 0}}};
        search.search(full);
        assert(search.best.count == 4);
        assert(std::abs(search.bestArea - 1999) < 0.01);
        double minX = 100;
        double maxX = 0;
        for (int i = 0; i < search.best.count; i++) {
            minX = std::min(minX, search.best.points[i].x[0]);
            maxX = std::max(maxX, search.best.points[i].x[0]);
        }
        assert(minX == 0 && maxX == 100);
        assert(search.visits < 4096);
    }
}

int main() {
    unifiedConstraints();
    combinedWalls();
    testBevelSimplification();
    testPropAndWallSelection();
    testMeshWallSections();
    testFloorCoverage();
    testGapPartitionInvariance();
    std::puts("PASS: isolated props, divider sides, attached wall chains, convex corner clipping, "
              "fail-closed overlap");
}
