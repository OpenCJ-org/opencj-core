#include "../../server-ext/opencj_demo_technique.hpp"
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <vector>
#include <algorithm>
struct Frame {int index,flags,load,rpg;float yaw;};
int main(int argc,char **argv){
 if(argc!=2 && argc!=3){std::fprintf(stderr,"Usage: demo-camera-recording <index yaw flags load rpg TSV> [mode]\n");return 2;}std::ifstream in(argv[1]);std::vector<Frame> f;Frame n;
 while(in>>n.index>>n.yaw>>n.flags>>n.load>>n.rpg)f.push_back(n);
 auto read=[&](int i){bool excluded=f[i].flags&(128|256);
  return CJ_DemoInput{int(bool(f[i].flags&4))-int(bool(f[i].flags&8)),int(bool(f[i].flags&2))-int(bool(f[i].flags&1)),bool(f[i].flags&8192),bool(f[i].load),excluded,bool(f[i].rpg)};};
 int mode=argc==3?std::atoi(argv[2]):2;
 CJ_DemoSection section={};float previous=0;int spikes=0,changed=0,shortFB=0,excludedFB=0,unknownFB=0;
 std::ofstream out(std::string(argv[1])+".after.tsv");
 for(int i=0;i<int(f.size());++i){
  if(i<section.begin || i>=section.end)section=CJ_AnalyzeDemoTechnique(f.size(),i,read);
  auto input=read(i);auto result=CJ_ApplyDemoTechnique(i,mode,input,section);
  auto camera=[&](int j){
   auto input=read(j);auto view=CJ_ApplyDemoTechnique(j,mode,input,section);
   bool locked=j<section.begin || j>=section.end || input.ground || input.excluded || view.fallback;
   return CJ_DemoCameraSample{f[j].yaw,locked?0:view.yawOffset,input.cut,locked,input.shot};
  };
  float yaw=std::remainder(CJ_SmoothDemoYaw(f.size(),i,camera),360.f);
  if(result.changed)++changed;
  if(!input.ground && input.forward && input.right && section.anchorR && input.right==-section.anchorR && result.forward){
   if(input.excluded)++excludedFB;else if(!section.style)++unknownFB;else if(input.forward==section.anchorF && i>=section.takeoffEnd)++shortFB;
  }
  float original=i?std::remainder(f[i].yaw-f[i-1].yaw,360.f):0;
  float delta=i?std::remainder(yaw-previous,360.f):0;
  if(i && !input.ground && !read(i-1).ground && !input.cut && std::abs(delta)>30 && std::abs(original)<15){
   if(spikes++<12)std::printf("SPIKE i=%d yaw=%.1f rawDelta=%.1f convertedDelta=%.1f input=%d,%d result=%d,%d style=%d\n",i,f[i].yaw,original,delta,input.forward,input.right,result.forward,result.right,section.style);
  }
  out<<i<<" "<<yaw<<" "<<result.forward<<" "<<result.right<<" "<<result.fallback<<"\n";
  previous=yaw;
 }
 std::printf("frames=%zu converted=%d artificialSpikes=%d unconvertedShort=%d RPGExcluded=%d ambiguous=%d\n",f.size(),changed,spikes,shortFB,excludedFB,unknownFB);
}
