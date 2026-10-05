#include "msg.h"
#include "server.h"
#include "qcommon_io.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <assert.h>
svsHeader_t svsHeader;
objective_t opencj_playerObjectives[MAX_CLIENTS][16];
static playerState_t predicted;
int SV_GetPredictedOriginAndTimeForClientNum(int n, float *origin) { memcpy(origin,predicted.origin,sizeof(vec3_t)); return predicted.commandTime; }
void SV_GetMapCenterFromSVSHeader(float *v) { memset(v,0,sizeof(vec3_t)); }
void QDECL Com_Printf(conChannel_t c,const char *f,...) {}
void QDECL Com_PrintWarning(conChannel_t c,const char *f,...) {}
void QDECL Com_PrintError(conChannel_t c,const char *f,...) {}
void QDECL Com_Error(int code,const char *f,...) { va_list ap;va_start(ap,f);vfprintf(stderr,f,ap);va_end(ap);exit(3); }
double Vec3DistanceSq(const vec3_t a,const vec3_t b) { float x=a[0]-b[0],y=a[1]-b[1],z=a[2]-b[2];return x*x+y*y+z*z; }
qboolean Assert_MyHandler(const char *e,const char *file,int line,const char *fn,const char *fmt,...) { fprintf(stderr,"Assertion: %s at %s:%d\n",e,file,line);exit(4); }

static int failures;
static void check(const char *name,int ok) { printf("%s: %s\n",ok?"PASS":"FAIL",name); if(!ok) failures++; }
static void snapshot(const char *name,playerState_t *from,playerState_t *to,int archive,int expected) {
    byte buffer[131072];msg_t msg;struct snapshotInfo_s info={0};info.archived=archive;
    MSG_Init(&msg,buffer,sizeof(buffer));
    MSG_WriteDeltaPlayerstate(&info,&msg,10000,from,to);
    check("snapshot did not overflow",!msg.overflowed);
    MSG_WriteLong(&msg,0x13579bdf);
    MSG_BeginReading(&msg);
    check(name,MSG_ReadBit(&msg)==expected);
    if(expected) {
        playerState_t out;
        MSG_BeginReading(&msg);
        MSG_ReadDeltaPlayerstate(0,&msg,10000,from,&out,1);
        check("round trip position",!memcmp(to->origin,out.origin,sizeof(vec3_t)));
        check("round trip time",to->commandTime==out.commandTime);
        check("next message remains aligned",MSG_ReadLong(&msg)==0x13579bdf);
        check("reader did not overflow",!msg.overflowed);
    }
}
int main(void) {
    static playerState_t from,to;
    to.commandTime=10000;to.origin[0]=1234;to.origin[1]=-567;to.origin[2]=890;
    predicted=to;from=to;svsHeader.clientArchive=1;
    snapshot("full recovery sends position even when prediction matches",NULL,&to,0,1);
    snapshot("ordinary matching delta retains optimization",&from,&to,0,0);
    predicted.commandTime--;
    snapshot("outdated prediction sends position",&from,&to,0,1);
    predicted=to;predicted.origin[0]+=1;
    snapshot("prediction mismatch sends position",&from,&to,0,1);
    predicted=to;svsHeader.clientArchive=0;
    snapshot("disabled client archive sends position",&from,&to,0,1);
    svsHeader.clientArchive=1;
    snapshot("archived snapshot sends position",&from,&to,1,1);
    for(int n=1;n<=31;n++) {
        to.hud.current[n-1].type=1;
        to.hud.current[n-1].x=320+n;
        to.hud.current[n-1].y=200+n;
        to.hud.current[n-1].text=n;
        to.hud.current[n-1].fontScale=1.4f;
        to.hud.current[n-1].width=344;
        to.hud.current[n-1].height=172;
        to.hud.current[n-1].color.rgba=0xffffffff;
        char name[80];snprintf(name,sizeof(name),"full snapshot with %d HUD elements",n);
        snapshot(name,NULL,&to,0,1);
    }

    // Editor HUD changes share the same bitstream as following service commands.
    // Exercise deltas, removals, float/integer transitions, and timing/color fields.
    svsHeader.clientArchive=0;
    srand(7);
    for(int n=0;n<1000;n++) {
        from=to;
        int count=rand()%32;
        memset(to.hud.current,0,sizeof(to.hud.current));
        for(int i=0;i<count;i++) {
            hudelem_t *h=&to.hud.current[i];
            h->type=1+rand()%6;h->x=(rand()%2000-1000)*0.25f;h->y=(rand()%2000-1000)*0.25f;
            h->text=rand()%512;h->label=rand()%512;h->fontScale=1.4f+(rand()%31)*0.1f;
            h->height=rand()%1024;h->width=rand()%1024;h->color.rgba=(unsigned)rand()*rand();
            h->fromColor.rgba=(unsigned)rand()*rand();h->fadeStartTime=rand()%10000;
            h->fadeTime=rand()%65536;h->moveTime=rand()%65536;h->fromX=(rand()%2000-1000)*0.3f;
        }
        byte buffer[131072];msg_t msg;struct snapshotInfo_s info={0};playerState_t out;
        MSG_Init(&msg,buffer,sizeof(buffer));MSG_WriteDeltaPlayerstate(&info,&msg,10000,&from,&to);
        MSG_WriteLong(&msg,0x13579bdf);MSG_BeginReading(&msg);
        MSG_ReadDeltaPlayerstate(0,&msg,10000,&from,&out,1);
        if(msg.overflowed || MSG_ReadLong(&msg)!=0x13579bdf) { check("randomized HUD delta message alignment",0);break; }
    }
    check("1000 randomized HUD delta round trips",failures==0);
    return failures?1:0;
}
