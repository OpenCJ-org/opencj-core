// Synthetic collision-map integration: real collection/merging/clipping, no server.
#include "../../server-ext/opencj_platform.cpp"
#include <cassert>
#include <cstdio>
extern "C" {
clipMap_t cm={};
int CM_BoxLeafnums(const vec3_t,const vec3_t,uint16_t* out,int capacity,int* last) {
    *last=0;if(!cm.numLeafs || !capacity)return 0;out[0]=0;return 1;
}
}
struct Encoded { float p[3][4]; };
static Encoded encode(Point a,Point b,Point c) {
    const Point ab=add(b,a,-1),ac=add(c,a,-1);
    Point n=cross(ab,ac);n=add(Point{},n,1/std::sqrt(dot(n,n)));
    Point u=cross(ac,n);u=add(Point{},u,1/dot(u,ab));
    Point v=cross(n,ab);v=add(Point{},v,1/dot(v,ac));
    Encoded out={};Point rows[]={n,u,v};
    for(int i=0;i<3;i++){for(int j=0;j<3;j++)out.p[i][j]=rows[i].x[j];out.p[i][3]=dot(rows[i],a);}
    return out;
}
static std::vector<Encoded> quad(Point a,Point b,Point c,Point d) {return {encode(a,b,c),encode(a,c,d)};}
struct Model {
    std::vector<Encoded> triangles;ModelCollisionSurface surface={};XModel asset={};cStaticModel_t model={};Point axes[3];double scale;
    Model(std::vector<Encoded> data,double pitch=0,double size=1):triangles(data),scale(size) {
        axes[0]={{0.8*std::cos(pitch),0.6*std::cos(pitch),std::sin(pitch)}};
        axes[1]={{-0.6,0.8,0}};axes[2]=cross(axes[0],axes[1]);
        for(int i=0;i<3;i++)for(int j=0;j<3;j++)model.invScaledAxis[i][j]=axes[j].x[i]/scale;
        model.origin[0]=20000;model.origin[1]=-12000;model.origin[2]=1000;
        for(int i=0;i<3;i++){model.absmin[i]=model.origin[i]-1000;model.absmax[i]=model.origin[i]+1000;}
        surface.triangles=reinterpret_cast<const float(*)[3][4]>(triangles.data());surface.triangleCount=triangles.size();surface.contents=1;
        asset.collSurfs=reinterpret_cast<XModelCollSurf_t*>(&surface);asset.numCollSurfs=1;asset.collLod=0;model.xmodel=&asset;
    }
    Point world(Point p)const {Point out={{model.origin[0],model.origin[1],model.origin[2]}};for(int i=0;i<3;i++)out=add(out,axes[i],p.x[i]*scale);return out;}
    Point local(Point p)const {Point d=add(p,Point{{model.origin[0],model.origin[1],model.origin[2]}},-1);return {{dot(d,axes[0])/scale,dot(d,axes[1])/scale,dot(d,axes[2])/scale}};}
};
static Obstacle detect(Point origin) {
    Search search;search.origin=origin;search.normal={{0,0,1}};search.footprint=true;
    assert(search.triangleSupport() && search.count>=3);
    assert(detectLanding(search.best,search.count,origin));
    Obstacle out={};out.count=search.count;std::copy(search.best,search.best+search.count,out.points);return out;
}
static void modelCombinations() {
    for(double pitch:{0.0,0.3})for(double scale:{0.5,2.0}) {
        Model floor(quad({{0,0,0}},{{100,0,0}},{{100,100,0}},{{0,100,0}}),pitch,scale);
        Model prop(quad({{40,40,-10}},{{60,40,-10}},{{60,45,30}},{{40,45,30}}),pitch,scale);
        Model wall(quad({{70,0,-10}},{{70,100,-10}},{{75,100,30}},{{75,0,30}}),pitch,scale);
        cStaticModel_t models[]={floor.model,prop.model,wall.model};cm.staticModelList=models;cm.numStaticModels=1;
        Point origin=floor.world({{30,30,0}});origin.x[2]+=0.125;
        const auto base=detect(origin);assert(base.count==4);
        cm.numStaticModels=2;const auto withProp=detect(origin);assert(withProp.count==base.count);
        for(int i=0;i<base.count;i++)for(int a=0;a<3;a++)assert(std::abs(base.points[i].x[a]-withProp.points[i].x[a])<0.001);
        cm.numStaticModels=3;const auto clipped=detect(origin);assert(clipped.count==4);
        for(int i=0;i<clipped.count;i++){Point p=floor.local(clipped.points[i]);assert(p.x[0]<72 && p.x[0]>-0.1);assert(std::abs(p.x[2])<0.01);}
        // Exact triangle decoding and arbitrary model scale/rotation, not AABB approximation.
        Obstacle decoded;assert(modelTriangle(floor.triangles[0].p,floor.model,decoded));
        Point expected[]={floor.world({{0,0,0}}),floor.world({{100,0,0}}),floor.world({{100,100,0}})};
        for(int i=0;i<3;i++)for(int a=0;a<3;a++)assert(std::abs(decoded.points[i].x[a]-expected[i].x[a])<0.001);
    }
    cm.staticModelList=nullptr;cm.numStaticModels=0;
}
static void terrainFloor() {
    cLeaf_t leaf={};leaf.collAabbCount=1;cm.numLeafs=1;cm.leafs=&leaf;
    CollisionAabbTree_t tree={};tree.origin[0]=50;tree.origin[1]=50;tree.origin[2]=12.5;for(float& h:tree.halfSize)h=100;
    cm.aabbTreeCount=1;cm.aabbTrees=&tree;
    CollisionPartition_t partition={};partition.triCount=2;cm.partitionCount=1;cm.partitions=&partition;
    dmaterial_t material={};material.contentFlags=0x10;cm.numMaterials=1;cm.materials=&material; // Glass mesh floor.
    float vertices[4][3]={{0,0,0},{100,0,25},{100,100,25},{0,100,0}};
    uint16_t indices[]={0,1,2,0,2,3};cm.vertCount=4;cm.verts=vertices;cm.triCount=2;cm.triIndices=indices;
    const auto face=detect({{50,50,12.625}});assert(face.count==4);
    for(int i=0;i<face.count;i++)assert(std::abs(face.points[i].x[2]-face.points[i].x[0]*0.25)<0.00001);
    // Reverse triangle enumeration and winding without changing geometric coverage.
    uint16_t reversed[]={3,2,0,2,1,0};cm.triIndices=reversed;
    const auto other=detect({{50,50,12.625}});assert(other.count==face.count);
    for(int i=0;i<face.count;i++)for(int a=0;a<3;a++)assert(std::abs(face.points[i].x[a]-other.points[i].x[a])<0.00001);
    // One sloped landing assembled from terrain triangles and a static model,
    // with brush walls/props on top: every source must share one geometry path.
    vertices[1][0]=50;vertices[1][2]=12.5;vertices[2][0]=50;vertices[2][2]=12.5;
    Model extension(quad({{50,0,12.5}},{{100,0,25}},{{100,100,25}},{{50,100,12.5}}));
    for(int i=0;i<3;i++){extension.model.origin[i]=0;extension.model.absmin[i]=-1000;extension.model.absmax[i]=1000;for(int j=0;j<3;j++)extension.model.invScaledAxis[i][j]=(i==j);}
    cm.staticModelList=&extension.model;cm.numStaticModels=1;
    const auto joined=detect({{25,50,6.375}});assert(joined.count==4);
    double farX=0;for(int i=0;i<joined.count;i++)farX=std::max(farX,joined.points[i].x[0]);assert(farX>99.9);
    cbrush_t brushes[2]={};
    float bounds[2][6]={{70,0,-10,80,100,100},{20,20,-10,30,30,100}};
    for(int i=0;i<2;i++){brushes[i].contents=1;for(int j=0;j<3;j++){brushes[i].mins[j]=bounds[i][j];brushes[i].maxs[j]=bounds[i][j+3];}}
    cLeafBrushNode_t nodes[2]={};uint16_t brushIndices[]={0,1};nodes[1].leafBrushCount=1;nodes[1].data.leaf.brushes=brushIndices;
    cm.brushes=brushes;cm.numBrushes=2;cm.leafbrushNodes=nodes;cm.leafbrushNodesCount=2;leaf.leafBrushNode=1;
    const auto wall=detect({{25,50,6.375}});
    nodes[1].leafBrushCount=2;const auto wallAndProp=detect({{25,50,6.375}});assert(wall.count==wallAndProp.count);
    for(int i=0;i<wall.count;i++){assert(wall.points[i].x[0]<70);for(int a=0;a<3;a++)assert(std::abs(wall.points[i].x[a]-wallAndProp.points[i].x[a])<0.00001);}
    cm={};
}

// Same geometric union with arbitrary internal subdivisions and brush order.
// The starting brush extends into a small notch; preserving it in full must
// not prevent selecting the larger supported strip through all its neighbors.
static void brushAssemblies() {
    for(int pieces:{3,8,32,128,256})for(bool reverse:{false,true})for(bool thin:{false,true}) {
        const double width=thin?pieces*0.5:std::max(167,pieces*2), length=std::max(960,pieces*10);
        std::vector<cbrush_t> brushes(pieces);std::vector<uint16_t> indices(pieces);
        for(int i=0;i<pieces;i++) {
            auto& b=brushes[i];b.contents=(i%2)?1:0x10;
            b.mins[0]=double(i)*width/pieces;b.maxs[0]=double(i+1)*width/pieces;
            b.mins[1]=(i==0)?6:0;b.maxs[1]=length;b.mins[2]=-6;b.maxs[2]=0;
            indices[i]=reverse?pieces-1-i:i;
        }
        cLeaf_t leaf={};leaf.leafBrushNode=1;cLeafBrushNode_t nodes[2]={};
        nodes[1].leafBrushCount=pieces;nodes[1].data.leaf.brushes=indices.data();
        cm={};cm.numLeafs=1;cm.leafs=&leaf;cm.numBrushes=pieces;cm.brushes=brushes.data();cm.leafbrushNodesCount=2;cm.leafbrushNodes=nodes;
        for(int start:{0,pieces/2,pieces-1}) {
            Search search;search.origin={{(brushes[start].mins[0]+brushes[start].maxs[0])/2,500,0.125}};
            search.normal={{0,0,1}};search.footprint=true;search.node(1);assert(search.count>=3);
            assert(detectLanding(search.best,search.count,search.origin));
            double lo=1000,hi=-1000;for(int i=0;i<search.count;i++){lo=std::min(lo,search.best[i].x[0]);hi=std::max(hi,search.best[i].x[0]);}
            if(!(lo<0.02 && hi>width-0.02))std::fprintf(stderr,"pieces=%d reverse=%d start=%d lo=%f hi=%f width=%f\n",pieces,reverse,start,lo,hi,width);
            assert(lo<0.02 && hi>width-0.02);
            assert(area(search.best,search.count,{{0,0,1}})>(width-0.021)*(length-6.021));
            Obstacle result={};result.count=search.count;std::copy(search.best,search.best+search.count,result.points);
            std::vector<Obstacle> floors;
            for(const auto& b:brushes){Obstacle f={};f.count=4;f.points[0]={{b.mins[0],b.mins[1],0}};f.points[1]={{b.maxs[0],b.mins[1],0}};f.points[2]={{b.maxs[0],b.maxs[1],0}};f.points[3]={{b.mins[0],b.maxs[1],0}};floors.push_back(f);}
            assert(coveredHull(result,floors,{{0,0,1}}));
        }
    }
    cm={};std::puts("PASS: 3/8/32/128/256 mixed solid+glass brushes, reversed enumeration, three seed brushes, real notch retained");
}

static void largeBrushFloors() {
    cbrush_t brushes[2]={};
    for(int i=0;i<2;i++){brushes[i].contents=1;brushes[i].mins[0]=i?8000:0;brushes[i].maxs[0]=i?16000:8000;brushes[i].maxs[1]=100;brushes[i].mins[2]=-5;}
    cLeaf_t leaf={};leaf.leafBrushNode=1;cLeafBrushNode_t nodes[2]={};uint16_t indices[]={0,1};nodes[1].leafBrushCount=2;nodes[1].data.leaf.brushes=indices;
    cm={};cm.numLeafs=1;cm.leafs=&leaf;cm.brushes=brushes;cm.numBrushes=2;cm.leafbrushNodes=nodes;cm.leafbrushNodesCount=2;
    for(double x:{5.0,7999.0,15995.0}) {
        Search search;search.origin={{x,50,0.125}};search.footprint=true;search.node(1);assert(search.count==4);
        assert(detectLanding(search.best,search.count,search.origin));
        assert(search.count==4);
        double lo=1e30,hi=-1e30;
        for(int i=0;i<search.count;i++){lo=std::min(lo,search.best[i].x[0]);hi=std::max(hi,search.best[i].x[0]);}
        assert(std::abs(lo)<0.01 && std::abs(hi-16000)<0.01);
    }
    cm={};
    std::puts("PASS: complete large connected floor from either end and brush seam");
}

int main(){largeBrushFloors();brushAssemblies();modelCombinations();terrainFloor();std::puts("PASS: rotated/scaled static collision models, sloped floors, leaning model walls, ignored model props, glass terrain floors, triangle ordering");}
