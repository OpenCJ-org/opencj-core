/* Exercise the real packet handler and netchan parser with delayed-session headers. */
#include "qcommon.h"
#include "server.h"
#include "qcommon_io.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
static cvar_t running,quiet;
cvar_t *com_sv_running=&running,*showdrop=&quiet,*showpackets=&quiet;
serverStatic_t svs;
static client_t client;
static byte fragmentBuffer[4096];
static int executed,decoded,failures;
void QDECL Com_Printf(conChannel_t c,const char *f,...) {}
void QDECL Com_PrintWarning(conChannel_t c,const char *f,...) {}
void QDECL Com_PrintError(conChannel_t c,const char *f,...) {}
void QDECL Com_Error(int code,const char *f,...) { exit(3); }
void QDECL Com_DPrintf(conChannel_t c,const char *f,...) {}
void Com_Memset(void *p,byte c,int n) { memset(p,c,n); }
qboolean Assert_MyHandler(const char *e,const char *file,int line,const char *fn,const char *fmt,...) { fprintf(stderr,"Assertion: %s at %s:%d\n",e,file,line);exit(4); }
client_t *SV_ReadPackets(netadr_t *from,unsigned short qport) { return qport==10804 ? &client : NULL; }
void SV_ConnectionlessPacket(netadr_t *from,msg_t *msg) { abort(); }
void ReliableMessagesReceiveNextFragment(netreliablemsg_t *state,msg_t *msg) { abort(); }
void SV_Netchan_Decode(client_t *cl,byte *data,int n) { decoded++; }
__optimize3 __regparm2 void SV_ExecuteClientMessage(client_t *cl,msg_t *msg) { executed++; }
void NET_OutOfBandPrint(netsrc_t sock,netadr_t *adr,const char *fmt,...) { abort(); }
const char *NET_AdrToString(netadr_t *a) { return "test"; }
#include "packet-event-under-test.c"
static void check(const char *name,int ok) { printf("%s: %s\n",ok?"PASS":"FAIL",name);failures+=!ok; }
static void reset(void) {
 memset(&client,0,sizeof(client));running.boolean=qtrue;client.state=CS_ACTIVE;client.netchan.sock=NS_SERVER;
 client.netchan.incomingSequence=1400;client.netchan.outgoingSequence=400;client.serverId=3586;
 client.messageAcknowledge=398;client.reliableSequence=686;client.reliableAcknowledge=685;client.configDataAcknowledge=4;
 client.netchan.fragmentBuffer=fragmentBuffer;client.netchan.fragmentBufferSize=sizeof(fragmentBuffer);
 executed=decoded=0;
}
static void packet(int seq,int serverId,int ack,int reliable,int length) {
 byte data[256];msg_t msg;netadr_t adr={0};MSG_Init(&msg,data,sizeof(data));
 MSG_WriteLong(&msg,seq);MSG_WriteShort(&msg,10804);MSG_WriteLong(&msg,serverId);
 MSG_WriteLong(&msg,ack);MSG_WriteLong(&msg,reliable);MSG_WriteLong(&msg,4);MSG_WriteByte(&msg,3);
 if(length>=0) msg.cursize=length;
 SV_PacketEvent(&adr,&msg);
}
static void rejected(const char *name,int ack,int reliable,int length) {
 reset();packet(194783,1799686,ack,reliable,length);
 check(name,client.netchan.incomingSequence==1400 && client.serverId==3586 && client.messageAcknowledge==398 && client.reliableAcknowledge==685 && !executed && !decoded);
 packet(1401,3586,399,686,-1);
 check("next current-session packet is accepted",client.netchan.incomingSequence==1401 && client.messageAcknowledge==399 && client.reliableAcknowledge==686 && executed==1 && decoded==1);
}

static void fragment(int seq,int offset,const byte *payload,int length) {
 byte data[2048];msg_t msg;netadr_t adr={0};MSG_Init(&msg,data,sizeof(data));
 MSG_WriteLong(&msg,seq | 0x80000000u);MSG_WriteShort(&msg,10804);
 MSG_WriteLong(&msg,offset);MSG_WriteShort(&msg,length);MSG_WriteData(&msg,payload+offset,length);
 SV_PacketEvent(&adr,&msg);
}
static void fragmented(int invalid) {
 byte payload[1304];msg_t msg;MSG_Init(&msg,payload,sizeof(payload));
 MSG_WriteLong(&msg,invalid?1799686:3586);MSG_WriteLong(&msg,invalid?52496:399);
 MSG_WriteLong(&msg,invalid?88937:686);MSG_WriteLong(&msg,4);
 memset(payload+msg.cursize,0,sizeof(payload)-msg.cursize);
 reset();fragment(invalid?194783:1401,0,payload,1300);
 check("partial fragment does not advance sequence",client.netchan.incomingSequence==1400 && !executed);
 fragment(invalid?194783:1401,1300,payload,4);
 if(invalid) {
  check("invalid fragmented header leaves connection intact",client.netchan.incomingSequence==1400 && client.reliableAcknowledge==685 && !executed);
  packet(1401,3586,399,686,-1);
  check("valid traffic resumes after invalid fragmented packet",client.netchan.incomingSequence==1401 && executed==1);
 } else {
  check("complete valid fragment commits the unflagged sequence",client.netchan.incomingSequence==1401 && client.reliableAcknowledge==686 && executed==1);
 }
}

int main(void) {
 rejected("exact delayed packet cannot poison the connection",52496,88937,-1);
 rejected("future reliable acknowledgment is rejected",399,88937,-1);
 rejected("expired reliable acknowledgment is rejected",399,500,-1);
 rejected("negative snapshot acknowledgment is rejected",-1,686,-1);
 rejected("future snapshot acknowledgment is rejected",52496,686,-1);
 rejected("truncated header is rejected",399,686,17);
 fragmented(0);fragmented(1);
 reset();packet(1401,3586,399,686,-1);packet(1401,3586,399,686,-1);
 check("valid packets advance once; duplicates stay rejected",executed==1 && client.netchan.incomingSequence==1401);
 return failures?1:0;
}
