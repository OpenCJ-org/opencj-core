// Pure geometry tests: no server, database, or live state.
#include "../../server-ext/opencj_platform.cpp"
#include <cassert>
#include <cstdio>
static Obstacle box(double x1,double y1,double x2,double y2,bool wall) {
    Obstacle o={};o.count=4;o.wall=wall;
    o.points[0]={{x1,y1,0}};o.points[1]={{x2,y1,0}};
    o.points[2]={{x2,y2,0}};o.points[3]={{x1,y2,0}};return o;
}
static double run(std::vector<Obstacle> walls,Point seed={{10,10,0}}) {
    const auto base=box(0,0,100,100,false);Point p[64];std::copy(base.points,base.points+4,p);int n=4;
    if(!clipWalls(p,n,Point{{0,0,1}},seed,walls))return -1;
    for(const auto& wall:walls)if(wall.wall) {
        Point overlap[64];std::copy(p,p+n,overlap);int k=intersection(overlap,n,wall,Point{{0,0,1}});
        assert(k<3 || area(overlap,k,Point{{0,0,1}})<0.01);
    }
    return area(p,n,Point{{0,0,1}});
}
static Obstacle solve(std::vector<Obstacle> walls,Obstacle base=box(0,0,100,100,false),Point seed={{50,50,0}},Point normal={{0,0,1}}) {
    int n=base.count;assert(clipWalls(base.points,n,normal,seed,walls));base.count=n;canonicalize(base);
    for(const auto& wall:walls)if(wall.wall) {
        Point overlap[64];std::copy(base.points,base.points+n,overlap);
        int k=intersection(overlap,n,wall,normal);assert(k<3 || area(overlap,k,normal)<=0.01);
    }
    return base;
}
static void same(const Obstacle& a,const Obstacle& b) {
    assert(a.count==b.count);
    for(int i=0;i<a.count;i++)for(int j=0;j<3;j++)assert(std::abs(a.points[i].x[j]-b.points[i].x[j])<0.00001);
}
static Point tilt(Point p) { return {{0.8*p.x[0]-0.6*p.x[1]+20000,0.6*p.x[0]+0.8*p.x[1]-12000,p.x[2]+0.25*p.x[0]}}; }
static Obstacle tilted(Obstacle p) { for(int i=0;i<p.count;i++)p.points[i]=tilt(p.points[i]);return p; }
static void combinedWalls() {
    const auto a=box(55,55,100,100,true),b=box(0,0,15,5,true);
    const auto expected=solve({a,b});
    assert(area(expected.points,expected.count,Point{{0,0,1}})>5200);
    same(expected,solve({b,a}));
    // Rotate corner indices too: geometry is identical, only serialization differs.
    for(int ai=0;ai<4;ai++)for(int bi=0;bi<4;bi++) {
        auto x=a,y=b;std::rotate(x.points,x.points+ai,x.points+4);std::rotate(y.points,y.points+bi,y.points+4);
        same(expected,solve({x,y}));same(expected,solve({y,x}));
    }
    const auto base=tilted(box(0,0,100,100,false));
    Point normal=cross(add(base.points[1],base.points[0],-1),add(base.points[2],base.points[0],-1));normal=add(Point{},normal,1/std::sqrt(dot(normal,normal)));
    // Mix triangle-derived wall sections, a boundary brush, and an isolated prop
    // on a rotated/sloped landing at large world coordinates.
    Point triangles[2][3]={{{{0,80,-10}},{{100,80,-10}},{{100,90,40}}},{{{0,80,-10}},{{100,90,40}},{{0,90,40}}}};
    std::vector<Obstacle> mixed={tilted(b),tilted(box(30,30,40,40,false))};
    const Plane slice={normal,dot(base.points[0],normal)+normal.x[2]*0.5};
    for(auto& triangle:triangles) {
        for(auto& vertex:triangle)vertex=tilt(vertex);
        Obstacle section;assert(triangleSection(triangle,slice,normal,section));markBoundary(section,base.points,base.count,normal);mixed.push_back(section);
    }
    const auto reference=solve(mixed,base,tilt(Point{{50,50,0}}),normal);
    int order[]={0,1,2,3};int permutations=0;
    do {
        std::vector<Obstacle> shuffled;for(int i:order)shuffled.push_back(mixed[i]);
        same(reference,solve(shuffled,base,tilt(Point{{50,50,0}}),normal));permutations++;
    }while(std::next_permutation(order,order+4));
    assert(permutations==24);
    mixed.erase(mixed.begin()+1);same(reference,solve(mixed,base,tilt(Point{{50,50,0}}),normal)); // Prop has no effect.
    // Changing internal brush seams must not change the region for this divider.
    same(solve({box(70,0,80,100,true)}),solve({box(70,0,80,45,true),box(70,45,80,100,true)}));
    std::puts("PASS: global wall optimum, reordered/rotated corners, mixed mesh+brush+prop on sloped landing, divider seams");
}
int main() {
    combinedWalls();
    Point bevel[4]={{{-2759,2647.77,0}},{{-2759,2871,0}},{{-3047,2871,0}},{{-3047,2870.77,0}}};
    const double originalArea=area(bevel,4,Point{{0,0,1}});
    const int corners=simplify(bevel,4,1.0);
    assert(corners==3 && area(bevel,corners,Point{{0,0,1}})<=originalArea);

    assert(run({box(40,40,60,60,false)})==10000); // Freestanding prop.
    const auto wall=box(70,0,80,100,true);
    assert(std::abs(run({wall})-6987.5)<0.01);
    assert(std::abs(run({wall,box(30,30,50,50,false)})-6987.5)<0.01); // Prop does not crop.
    assert(run({wall},Point{{90,10,0}})>1900); // Other side of same divider.
    assert(run({wall},Point{{75,10,0}})==-1); // Unsafe seed must not emit raw geometry.
    assert(run({box(0,70,45,80,true),box(45,70,100,80,false)})<7000); // Joined wall brushes.
    const double corner=run({box(70,70,100,100,true)});
    assert(corner>6900 && corner<7000); // Concavity becomes safe convex portion.
    // Two triangles forming one mesh wall: seams and winding must not matter.
    const Point up={{0,0,1}};
    const Plane slice={up,0.5};
    Point mesh[2][3]={{{{0,70,-10}},{{100,70,-10}},{{100,70,10}}},
                      {{{0,70,-10}},{{100,70,10}},{{0,70,10}}}};
    for(int reverse=0;reverse<2;reverse++) {
        std::vector<Obstacle> sections;
        const auto boundary=box(0,0,100,100,false);
        for(auto& triangle:mesh) {
            if(reverse)std::swap(triangle[0],triangle[2]);
            Obstacle section;assert(triangleSection(triangle,slice,up,section));
            markBoundary(section,boundary.points,boundary.count,up);sections.push_back(section);
        }
        const double clipped=run(sections);
        assert(clipped>6980 && clipped<7000);
    }
    Point prop[3]={{{40,40,-10}},{{60,40,-10}},{{50,40,10}}};
    Obstacle section;assert(triangleSection(prop,slice,up,section));
    assert(run({section})==10000); // Interior mesh props do not truncate landings.
    Point floor[3]={{{0,0,0}},{{100,0,0}},{{0,100,0}}};
    assert(!triangleSection(floor,slice,up,section)); // Supporting floor is not a wall.
    const Point slope={{-0.242535625,0,0.9701425}};
    const Plane tilted={slope,0.5*slope.x[2]};
    assert(triangleSection(mesh[1],tilted,slope,section));
    for(int i=0;i<section.count;i++)assert(std::abs(dot(section.points[i],slope))<0.00001);

    const auto full=box(0,0,100,100,false);
    std::vector<Obstacle> frame={box(0,0,100,10,false),box(0,90,100,100,false),box(0,10,10,90,false),box(90,10,100,90,false)};
    Obstacle hull={};assert(convexHull(frame,hull));
    assert(!coveredHull(hull,frame,up)); // Empty frame must not fill air.
    frame.push_back(box(10,10,90,90,false));assert(coveredHull(hull,frame,up));
    std::vector<Obstacle> gap={box(0,0,49,100,false),box(50,0,100,100,false)};
    assert(!coveredHull(full,gap,up));
    std::vector<Obstacle> notch={box(0,0,100,40,false),box(0,40,40,100,false)};
    assert(!coveredHull(full,notch,up));
    std::vector<Obstacle> overlap={box(0,0,60,100,false),box(40,0,100,100,false)};
    assert(coveredHull(full,overlap,up)); // Overlap cannot count twice to hide a hole.
    // Equivalent notched frame gaps, partitioned and ordered differently.
    // Both must retain the complete lower strip around the actual player seed.
    const std::vector<Obstacle> partitions[]={
        {box(10,30,90,100,true),box(40,20,60,30,true)},
        {box(40,20,60,100,true),box(10,30,40,100,true),box(60,30,90,100,true)},
        {box(60,30,90,100,true),box(10,30,40,100,true),box(40,20,60,100,true)}
    };
    for(const auto& gaps:partitions) {
        SupportedRegion search={gaps,up,Point{{50,10,0}}};
        search.search(full);
        assert(search.best.count==4);
        assert(std::abs(search.bestArea-1999)<0.01);
        double minX=100,maxX=0;
        for(int i=0;i<search.best.count;i++){minX=std::min(minX,search.best.points[i].x[0]);maxX=std::max(maxX,search.best.points[i].x[0]);}
        assert(minX==0 && maxX==100);
        assert(search.visits<4096);
    }
    std::puts("PASS: isolated props, divider sides, attached wall chains, convex corner clipping, fail-closed overlap");
}
