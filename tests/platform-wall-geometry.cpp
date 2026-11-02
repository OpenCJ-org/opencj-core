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
int main() {
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
    const Point up={{0,0,1}};
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
