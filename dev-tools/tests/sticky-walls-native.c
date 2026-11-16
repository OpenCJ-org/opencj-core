
#include <stdio.h>
#include <string.h>
#include <math.h>
extern int __attribute__((regparm(3))) PM_SlideMove(void*,void*,int);
static int replay,done,detail;
static void sweep(unsigned char *f);
static void regression(unsigned char *pm,unsigned char *ps);
static void commands(unsigned char *pm,unsigned char *ps);
void StickyTrace(unsigned char *f) {
 unsigned char *ps=*(unsigned char**)(f-0x140);
 float *p=(float*)(ps+0x1c),*v=(float*)(ps+0x28);
 float *end=(float*)(f-0x24),*t=(float*)(f-0xb4);
 if(!done && !replay && p[1]>100000) {done=1;sweep(f);}
 if(replay && !detail)return;
 if(p[1]<100000 || p[1]>100600) return;
 static int count; if(count++>3000)return;
 printf("NATIVE TRACE bump=%d dt=%.9g p=(%.9g,%.9g,%.9g) v=(%.9g,%.9g,%.9g) end=(%.9g,%.9g,%.9g) frac=%.9g n=(%.9g,%.9g,%.9g) all=%d start=%d\n",
 *(int*)(f-0x148),*(float*)(f-0x144),p[0],p[1],p[2],v[0],v[1],v[2],end[0],end[1],end[2],t[0],t[1],t[2],t[3],f[-0x8c],f[-0x8b]);
}

static void sweep(unsigned char *f) {
 unsigned char *originalPM=*(unsigned char**)(f-0x150);
 unsigned char *originalPS=*(unsigned char**)(f-0x140);
 replay=1;

 for(int ms=1;ms<=8;ms++)
 for(int speed=60;speed<=360;speed+=60)
 for(int shift=-4;shift<=4;shift++)
 for(int period=1;period<=8;period*=2) {
   unsigned char ps[0x2f64] __attribute__((aligned(16))),pm[0x110] __attribute__((aligned(16))),pml[0x100] __attribute__((aligned(16)));
   memcpy(ps,originalPS,sizeof(ps));memcpy(pm,originalPM,sizeof(pm));memset(pml,0,sizeof(pml));
   *(void**)pm=ps;*(float*)(pml+0x24)=ms/1000.0f;*(int*)(pml+0x28)=ms;*(int*)(ps+0x18)=0;
   float *p=(float*)(ps+0x1c),*v=(float*)(ps+0x28);
   p[0]=-16296+0.498964429f*0.5f+0.866622448f*shift;
   p[1]=100312-0.866622448f*0.5f+0.498964429f*shift;p[2]=-24930;v[2]=50;
   int stalled=0;float minRise=1;
   for(int j=0;j<48;j++) {
    int angle=((j/period)%2)?165:75;
    v[0]=speed*cosf(angle*0.01745329251994f);v[1]=speed*sinf(angle*0.01745329251994f);
    detail=0;
    float z=p[2];PM_SlideMove(pm,pml,0);float rise=p[2]-z;
    if(rise<minRise)minRise=rise;
    if(rise<ms*0.05f*0.5f)stalled++;
   }
   printf("NATIVE ALTERNATE ms=%d speed=%d shift=%d period=%d stalls=%d minRise=%.9g vz=%.9g\n",ms,speed,shift,period,stalled,minRise,v[2]);
 }
 regression(originalPM,originalPS);
 commands(originalPM,originalPS);
 detail=0;replay=0;
}

extern void Cvar_Set(const char*,const char*);
static void TestSet(const char*n,int v){Cvar_Set(n,v?"1":"0");}
extern int Cvar_VariableIntegerValue(const char*);
extern void PM_playerTrace(void*,void*,const float*,const float*,const float*,const float*,int,int);
typedef struct {float fraction,n[3];int sf,cf;const char*material;int type;unsigned short id,model,part,group;unsigned char all,start,walk,pad;} TestTrace;
static int synthetic,planeCount;
static float planes[3][4];
void StickyTestPlayerTrace(void*pm,TestTrace*t,const float*start,const float*mins,const float*maxs,const float*end,int pass,int mask) {
 if(!synthetic){PM_playerTrace(pm,t,start,mins,maxs,end,pass,mask);return;}
 memset(t,0,sizeof(*t));t->fraction=1;t->id=1023;
 for(int k=0;k<planeCount;k++) {
  float a=-planes[k][3],b=a;
  for(int i=0;i<3;i++){a+=start[i]*planes[k][i];b+=end[i]*planes[k][i];}
  if(a<0 && b<0){t->start=t->all=1;t->fraction=0;return;}
  if(b>=a || b>=0.125f)continue;
  float f=fmaxf(0,(a-0.125f)/(a-b));
  if(f<t->fraction){t->fraction=f;memcpy(t->n,planes[k],12);t->type=1;t->id=1022;t->walk=t->n[2]>=.7f;}
 }
}
static void regression(unsigned char *originalPM,unsigned char *originalPS) {
 const char *names[]={"free_air","floor_landing","ceiling_hit","ramp_impact","inside_corner","corridor","large_axis_wall","near_origin_diagonal"};
 float starts[][3]={{0,0,40},{0,0,8},{0,0,8},{0,0,8},{8,8,40},{0,0,40},{100010,20,40},{8,8,40}};
 float speeds[][3]={{130,-75,250},{130,75,-250},{130,75,250},{130,75,-250},{-130,-75,50},{130,75,50},{-130,75,50},{-130,-75,50}};
 int prior=Cvar_VariableIntegerValue("opencj_stickyWalls"),failed=0,total=0;
 synthetic=1;setbuf(stdout,NULL);puts("NATIVE REGRESSION START");
 for(int c=0;c<8;c++)for(int ms=1;ms<=16;ms*=2) {
  planeCount=0;memset(planes,0,sizeof(planes));
  if(c==1){planeCount=1;planes[0][2]=1;}
  if(c==2){planeCount=1;planes[0][2]=-1;planes[0][3]=-16;}
  if(c==3){planeCount=1;planes[0][0]=-.6f;planes[0][2]=.8f;}
  if(c==4){planeCount=2;planes[0][0]=1;planes[1][1]=1;}
  if(c==5){planeCount=2;planes[0][0]=1;planes[0][3]=-8;planes[1][0]=-1;planes[1][3]=-8;}
  if(c==6){planeCount=1;planes[0][0]=1;planes[0][3]=100000;}
  if(c==7){planeCount=1;planes[0][0]=.6f;planes[0][1]=.8f;}
  printf("NATIVE START case=%d ms=%d\n",c,ms);
  float results[2][48][6];
  for(int mode=0;mode<2;mode++) {
   unsigned char ps[0x2f64],pm[0x110],pml[0x100];
   memcpy(ps,originalPS,sizeof(ps));memcpy(pm,originalPM,sizeof(pm));memset(pml,0,sizeof(pml));
   *(void**)pm=ps;*(float*)(pml+0x24)=ms*.001f;*(int*)(ps+0x18)=0;
   float *p=(float*)(ps+0x1c),*v=(float*)(ps+0x28);
   memcpy(p,starts[c],12);memcpy(v,speeds[c],12);
   TestSet("opencj_stickyWalls",mode);
   for(int j=0;j<48;j++){PM_SlideMove(pm,pml,0);memcpy(results[mode][j],p,12);memcpy(results[mode][j]+3,v,12);}
  }
  int same=memcmp(results[0],results[1],sizeof(results[0]))==0;
  total++;failed+=!same;
  printf("NATIVE REGRESSION case=%s ms=%d identical=%d\n",names[c],ms,same);
 }
 synthetic=0;TestSet("opencj_stickyWalls",prior);
 printf("NATIVE REGRESSION COMPLETE cases=%d failures=%d\n",total,failed);
}

extern void Pmove(void*);
static void commands(unsigned char *originalPM,unsigned char *originalPS) {
 int prior=Cvar_VariableIntegerValue("opencj_stickyWalls");
 for(int mode=0;mode<2;mode++)
 for(int ms=2;ms<=8;ms++)
 for(int period=40;period<=200;period+=40)
 for(int facing=85;facing<=120;facing+=35)
 for(int offset=-8;offset<=8;offset+=4)
 for(int height=0;height<=32;height+=32) {
   unsigned char ps[0x2f64] __attribute__((aligned(16))),pm[0x110] __attribute__((aligned(16)));
   memcpy(ps,originalPS,sizeof(ps));memcpy(pm,originalPM,sizeof(pm));*(void**)pm=ps;
   float *p=(float*)(ps+0x1c),*v=(float*)(ps+0x28);
   p[0]=-16296+0.498964429f*.5f+0.866622448f*offset;p[1]=100312-0.866622448f*.5f+0.498964429f*offset;p[2]=-24930+height;
   v[0]=180*cosf(facing*.0174532925f);v[1]=180*sinf(facing*.0174532925f);v[2]=250;
   *(int*)(ps+0x18)=0;*(int*)(ps+88)=800;*(int*)(ps+112)=1023;
   memset(ps+100,0,12);*(float*)(ps+264)=0;*(float*)(ps+268)=facing;*(float*)(ps+272)=0;
   TestSet("opencj_stickyWalls",mode);
   int stalled=0,steps=0;
   for(int elapsed=0;elapsed<400;elapsed+=ms) {
    memcpy(pm+36,pm+4,32);
    *(int*)(pm+4)=*(int*)ps+ms;*(int*)(pm+8)=0;
    *(int*)(pm+12)=0;*(int*)(pm+16)=(int)(facing*65536.0f/360);*(int*)(pm+20)=0;
    pm[26]=127;pm[27]=((elapsed/period)%2)?127:(unsigned char)-127;
    float before[3];memcpy(before,p,12);float vz=v[2];
    Pmove(pm);steps++;
    if(vz>30 && v[2]>0 && p[2]-before[2]<vz*ms*.001f*.4f)stalled++;
   }
   printf("NATIVE COMMAND mode=%d ms=%d period=%d yaw=%d offset=%d height=%d stalls=%d steps=%d end=(%.9g,%.9g,%.9g) velocity=(%.9g,%.9g,%.9g)\n",mode,ms,period,facing,offset,height,stalled,steps,p[0],p[1],p[2],v[0],v[1],v[2]);
 }
 TestSet("opencj_stickyWalls",prior);
}

/* Test-only baseline selection; the production helper is unconditional. */
extern void StickyWallFixed(const float*,float*,const float*,float);
void OpenCJ_StickyWallRecovery(const float *p,float *v,const float *n,float dt) {
    if(Cvar_VariableIntegerValue("opencj_stickyWalls"))
        StickyWallFixed(p,v,n,dt);
}
