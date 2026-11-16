#include <chrono>
#include "../../server-ext/opencj_demo_technique.hpp"
#include <vector>
#include <cstdio>
#include <cstdlib>
static int checks=0;
static void check(bool ok,const char *label) {
    ++checks;if(!ok){std::fprintf(stderr,"TECHNIQUE FAIL %s\n",label);std::exit(1);}
}
static void phase(std::vector<CJ_DemoInput> &v,int f,int r,int count,bool ground=false) {
    for(int i=0;i<count;++i)v.push_back({f,r,ground,false,false,false});
}
static CJ_DemoTechnique result(const std::vector<CJ_DemoInput> &v,int index,int mode) {
    return CJ_InterpretDemoTechnique(v.size(),index,mode,[&](int i){return v[i];});
}
int main() {
    for(int f: {-1,1})for(int r: {-1,1}) {
        std::vector<CJ_DemoInput> hb;
        phase(hb,f,r,3);phase(hb,0,-r,4);phase(hb,f,r,3);
        for(int i=3;i<7;++i) {
            auto converted=result(hb,i,1);
            check(converted.changed && converted.forward==f && converted.right==-r,"HB to FB input");
            check(std::fabs(std::remainder(converted.yawOffset+CJ_DemoInputAngle(converted.forward,converted.right)-CJ_DemoInputAngle(0,-r),360.0f))<.001,"HB conversion preserves world wish direction");
        }
        check(!result(hb,4,0).changed && !result(hb,4,2).changed,"original/already HB remain source");
        std::vector<CJ_DemoInput> fb;
        phase(fb,f,r,1);phase(fb,f,-r,4);phase(fb,f,r,3);
        auto converted=result(fb,2,2);
        check(converted.changed && converted.forward==0 && converted.right==-r,"FB to HB retains initial diagonal");
        check(std::fabs(std::remainder(converted.yawOffset+CJ_DemoInputAngle(0,-r)-CJ_DemoInputAngle(f,-r),360.0f))<.001,"FB conversion preserves world wish direction");
        check(!result(fb,2,1).changed,"already FB remains source");
    }
    std::vector<CJ_DemoInput> v;
    phase(v,1,-1,3);phase(v,0,1,4);
    check(result(v,4,1).fallback && !result(v,4,1).changed,"single key without repeating return is ambiguous");
    v.clear();phase(v,1,-1,3);phase(v,0,-1,4);phase(v,1,-1,3);
    check(!result(v,4,1).changed,"landing release is not halfbeat");
    v.clear();phase(v,1,-1,3);phase(v,0,1,2);phase(v,1,-1,3);
    check(!result(v,4,1).changed,"sub 150ms tap does not establish halfbeat");
    v.clear();phase(v,1,-1,3);phase(v,0,1,3);phase(v,1,-1,3);
    check(result(v,4,1).changed,"150ms phase accepted");
    v[4].excluded=true;
    check(result(v,4,1).fallback && !result(v,4,1).changed,"RPG aim/mantle section stays original");
    v[4].excluded=false;v[3].cut=true;
    check(!result(v,4,1).changed,"cannot borrow anchor across load cut");
    v.clear();phase(v,1,-1,3);phase(v,1,1,3);phase(v,0,1,3);phase(v,1,-1,3);
    check(result(v,7,1).changed && !result(v,7,1).fallback,"mixed confirmed styles normalize to the requested fullbeat view");
    v.clear();phase(v,1,-1,3);phase(v,0,1,3);phase(v,1,-1,3);phase(v,0,1,3,true);
    check(!result(v,10,1).changed && !result(v,10,1).fallback,"ground movement unchanged");
    v.clear();phase(v,1,-1,600);phase(v,1,1,10);
    check(result(v,550,2).fallback,"oversized jump scan bounded");
    v.clear();phase(v,1,-1,128);phase(v,1,1,128);phase(v,1,-1,128);phase(v,1,1,127);
    size_t reads=0;
    auto read=[&](int i){++reads;return v[i];};
    const auto started=std::chrono::steady_clock::now();
    for(int viewer=0;viewer<32;++viewer) {
        CJ_DemoSection cached=CJ_AnalyzeDemoTechnique(v.size(),0,read);
        for(int i=0;i<int(v.size());++i) {
            auto actual=CJ_ApplyDemoTechnique(i,2,read(i),cached);
            check(actual.right==v[i].right && actual.forward==(v[i].right>0?0:1),"cached section retains correct conversion");
        }
    }
    const auto us=std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now()-started).count();
    check(reads<32*511*5,"classification work grows linearly across 32 viewers");
    std::printf("DEMO TECHNIQUE PERFORMANCE viewers=32 samples=511 reads=%zu microseconds=%lld sectionBytes=%zu\n",reads,(long long)us,sizeof(CJ_DemoSection));
    std::vector<CJ_DemoCameraSample> camera;
    for(int i=0;i<30;++i)camera.push_back({0,(i>=5 && i<20)?45.f:0.f,false,false,false});
    auto sample=[&](int i){return camera[i];};
    float previous=CJ_SmoothDemoYaw(camera.size(),0,sample);
    for(int i=1;i<int(camera.size());++i) {
        float yaw=CJ_SmoothDemoYaw(camera.size(),i,sample);
        check(std::fabs(yaw-previous)<=15.01f,"conversion transitions have no instantaneous 45-degree camera step");
        previous=yaw;
    }
    check(CJ_SmoothDemoYaw(camera.size(),12,sample)==45,"steady converted strafe keeps its exact angle");
    camera[12].locked=true;camera[12].offset=0;
    camera[13].locked=true;camera[13].offset=0;
    check(CJ_SmoothDemoYaw(camera.size(),12,sample)==0 && CJ_SmoothDemoYaw(camera.size(),13,sample)==0,"RPG aiming samples remain exact");
    check(CJ_SmoothDemoYaw(camera.size(),11,sample)<15 && CJ_SmoothDemoYaw(camera.size(),14,sample)<15,"camera eases into and out of protected aiming");
    camera[12].cut=true;
    float beforeCut=CJ_SmoothDemoYaw(camera.size(),11,sample);
    camera[12].yaw=120;camera[13].yaw=150;
    check(CJ_SmoothDemoYaw(camera.size(),11,sample)==beforeCut,"camera lookahead cannot cross load cuts");
    check(CJ_SmoothDemoYaw(camera.size(),12,sample)==120,"load cut orientation remains exact");
    std::vector<float> forwards;
    for(int i=0;i<int(camera.size());++i)forwards.push_back(CJ_SmoothDemoYaw(camera.size(),i,sample));
    for(int i=int(camera.size())-1;i>=0;--i)
        check(CJ_SmoothDemoYaw(camera.size(),i,sample)==forwards[i],"camera is deterministic when reversing and seeking");
    camera.clear();
    for(int i=0;i<10;++i)camera.push_back({i<5?179.f:-179.f,i<5?0.f:1.f,false,false,false});
    check(std::fabs(std::remainder(CJ_SmoothDemoYaw(camera.size(),4,sample)-180,360.f))<3,"camera smoothing crosses angle wrap by the shortest arc");
    camera.clear();for(int i=0;i<10;++i)camera.push_back({float(i*i),0,false,false,false});
    for(int i=0;i<int(camera.size());++i)
        check(CJ_SmoothDemoYaw(camera.size(),i,sample)==camera[i].yaw,"unconverted original camera is untouched");

    v.clear();phase(v,1,-1,5);phase(v,1,1,15);phase(v,1,-1,5);v[10].shot=true;
    for(int i=5;i<20;++i)check(result(v,i,2).forward==0 && result(v,i,2).right==1,"RPG strafe remains the converted single key throughout");
    check(result(v,2,2).forward==1 && result(v,22,2).forward==1,"diagonal takeoff preserved before consistent halfbeat");
    v[2].shot=true;
    check(result(v,15,2).changed && !result(v,15,2).fallback,"RPG on either side does not disable halfbeat");
    v.clear();phase(v,1,-1,5);phase(v,1,1,15);v[10].shot=true;
    for(int i=5;i<20;++i)check(result(v,i,2).forward==0,"two-phase jump converts without requiring a return strafe");

    // Invert keeps takeoff, then uses A/D on both sides for the rest of flight.
    for(int f: {-1,1})for(int r: {-1,1}) {
        v.clear();phase(v,f,r,4);phase(v,f,-r,4);phase(v,f,r,4);phase(v,f,-r,4,true);
        check(!result(v,2,3).changed,"Invert retains the diagonal takeoff");
        for(int i=4;i<12;++i) {
            auto x=result(v,i,3);
            check(x.forward==0 && x.right==v[i].right,"Invert converts both airborne strafe sides");
            check(std::fabs(std::remainder(x.yawOffset+CJ_DemoInputAngle(x.forward,x.right)-CJ_DemoInputAngle(v[i].forward,v[i].right),360.f))<.001,"Invert keeps intended world movement direction");
        }
        check(!result(v,13,3).changed,"Invert leaves grounded movement unchanged");
    }
    v.clear();phase(v,1,-1,4);phase(v,0,1,4);phase(v,0,-1,4);phase(v,0,1,4);
    check(result(v,9,1).forward==1 && result(v,5,1).forward==1,"native Invert converts to Fullbeat on both sides");
    check(result(v,9,2).forward==1 && result(v,5,2).forward==0,"native Invert converts to Halfbeat");
    check(!result(v,9,3).changed,"native Invert stays unchanged in Invert view");
    v.clear();phase(v,0,-1,4);phase(v,0,1,4);phase(v,0,-1,4);
    check(result(v,5,1).forward==1,"cropped Invert section can normalize without inventing takeoff");
    camera.clear();for(int i=0;i<15;++i)camera.push_back({0,45,false,false,i==7});
    check(CJ_SmoothDemoYaw(camera.size(),7,sample)==0,"quick RPG flick retains exact firing angle");
    check(CJ_SmoothDemoYaw(camera.size(),6,sample)==22.5 && CJ_SmoothDemoYaw(camera.size(),8,sample)==22.5,"quick RPG flick has one intermediate sample each way");
    check(CJ_SmoothDemoYaw(camera.size(),5,sample)==45 && CJ_SmoothDemoYaw(camera.size(),9,sample)==45,"RPG turn completes within 100 ms each way");
    forwards.clear();for(int i=0;i<15;++i)forwards.push_back(CJ_SmoothDemoYaw(camera.size(),i,sample));
    for(int i=14;i>=0;--i)check(CJ_SmoothDemoYaw(camera.size(),i,sample)==forwards[i],"RPG flick is identical in reverse");
    std::printf("DEMO TECHNIQUE COMPLETE checks=%d failures=0\n",checks);
}
