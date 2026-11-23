/* Exercise the real packet handler and netchan parser with delayed-session headers. */
#include "qcommon.h"
#include "server.h"
#include "qcommon_io.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// Fixed session values reproduce a delayed packet from an earlier connection.
enum
{
    TestQport = 10804,
    InitialIncomingSequence = 1400,
    NextIncomingSequence = 1401,
    OutgoingSequence = 400,
    CurrentServerID = 3586,
    InitialSnapshotAck = 398,
    NextSnapshotAck = 399,
    ReliableSequence = 686,
    InitialReliableAck = 685,
    DelayedIncomingSequence = 194783,
    DelayedServerID = 1799686,
    DelayedSnapshotAck = 52496,
    DelayedReliableAck = 88937,
    ConfigDataAck = 4,
    FragmentTailBytes = 4,
    TruncatedHeaderBytes = 17,
    ExpiredReliableAck = 500,
    PreservePacketLength = -1
};

static cvar_t serverRunning;
static cvar_t quietLogging;
cvar_t *com_sv_running = &serverRunning;
cvar_t *showdrop = &quietLogging;
cvar_t *showpackets = &quietLogging;
serverStatic_t svs;
static client_t client;
static byte fragmentBuffer[4096];
static int executedMessages;
static int decodedMessages;
static int failures;
void QDECL Com_Printf(conChannel_t channel, const char *format, ...)
{
}
void QDECL Com_PrintWarning(conChannel_t channel, const char *format, ...)
{
}
void QDECL Com_PrintError(conChannel_t channel, const char *format, ...)
{
}
void QDECL Com_Error(int code, const char *format, ...)
{
    exit(3);
}
void QDECL Com_DPrintf(conChannel_t channel, const char *format, ...)
{
}
void Com_Memset(void *destination, byte channel, int byteCount)
{
    memset(destination, channel, byteCount);
}
qboolean Assert_MyHandler(const char *expression, const char *file, int line,
                          const char *functionName, const char *format, ...)
{
    fprintf(stderr, "Assertion: %s at %s:%d\n", expression, file, line);
    exit(4);
}
client_t *SV_ReadPackets(netadr_t *from, unsigned short qport)
{
    return qport == TestQport ? &client : NULL;
}
// These paths are outside the connected-packet scenarios; any call is a failure.
void SV_ConnectionlessPacket(netadr_t *from, msg_t *message)
{
    abort();
}
void ReliableMessagesReceiveNextFragment(netreliablemsg_t *state, msg_t *message)
{
    abort();
}
void SV_Netchan_Decode(client_t *sender, byte *data, int byteCount)
{
    decodedMessages++;
}
__optimize3 __regparm2 void SV_ExecuteClientMessage(client_t *sender, msg_t *message)
{
    executedMessages++;
}
void NET_OutOfBandPrint(netsrc_t sock, netadr_t *address, const char *format, ...)
{
    abort();
}
const char *NET_AdrToString(netadr_t *address)
{
    return "test";
}
#include "packet-event-under-test.c"
static void check(const char *name, int passed)
{
    printf("%s: %s\n", passed ? "PASS" : "FAIL", name);
    failures += !passed;
}
static void resetConnection(void)
{
    memset(&client, 0, sizeof(client));
    serverRunning.boolean = qtrue;
    client.state = CS_ACTIVE;
    client.netchan.sock = NS_SERVER;
    client.netchan.incomingSequence = InitialIncomingSequence;
    client.netchan.outgoingSequence = OutgoingSequence;
    client.serverId = CurrentServerID;
    client.messageAcknowledge = InitialSnapshotAck;
    client.reliableSequence = ReliableSequence;
    client.reliableAcknowledge = InitialReliableAck;
    client.configDataAcknowledge = ConfigDataAck;
    client.netchan.fragmentBuffer = fragmentBuffer;
    client.netchan.fragmentBufferSize = sizeof(fragmentBuffer);
    executedMessages = 0;
    decodedMessages = 0;
}
static void deliverPacket(int sequence, int serverId, int snapshotAcknowledge,
                          int reliableAcknowledge, int packetLength)
{
    byte data[256];
    msg_t message;
    netadr_t address = {0};
    MSG_Init(&message, data, sizeof(data));
    MSG_WriteLong(&message, sequence);
    MSG_WriteShort(&message, TestQport);
    MSG_WriteLong(&message, serverId);
    MSG_WriteLong(&message, snapshotAcknowledge);
    MSG_WriteLong(&message, reliableAcknowledge);
    MSG_WriteLong(&message, ConfigDataAck);
    MSG_WriteByte(&message, clc_EOF);
    if(packetLength >= 0)
    {
        message.cursize = packetLength;
    }
    SV_PacketEvent(&address, &message);
}
// Rejecting a stale header must leave the next valid packet usable.
static void verifyRejectedHeader(const char *name, int snapshotAcknowledge, int reliableAcknowledge,
                                 int packetLength)
{
    resetConnection();
    deliverPacket(DelayedIncomingSequence, DelayedServerID, snapshotAcknowledge,
                  reliableAcknowledge, packetLength);
    check(name, client.netchan.incomingSequence == InitialIncomingSequence &&
                    client.serverId == CurrentServerID &&
                    client.messageAcknowledge == InitialSnapshotAck &&
                    client.reliableAcknowledge == InitialReliableAck && !executedMessages &&
                    !decodedMessages);
    deliverPacket(NextIncomingSequence, CurrentServerID, NextSnapshotAck, ReliableSequence,
                  PreservePacketLength);
    check("next current-session packet is accepted",
          client.netchan.incomingSequence == NextIncomingSequence &&
              client.messageAcknowledge == NextSnapshotAck &&
              client.reliableAcknowledge == ReliableSequence && executedMessages == 1 &&
              decodedMessages == 1);
}

static void deliverFragment(int sequence, int offset, const byte *payload, int packetLength)
{
    byte data[2048];
    msg_t message;
    netadr_t address = {0};
    MSG_Init(&message, data, sizeof(data));
    MSG_WriteLong(&message, sequence | FRAGMENT_BIT);
    MSG_WriteShort(&message, TestQport);
    MSG_WriteLong(&message, offset);
    MSG_WriteShort(&message, packetLength);
    MSG_WriteData(&message, payload + offset, packetLength);
    SV_PacketEvent(&address, &message);
}
// A partial datagram must not commit its sequence before its header is validated.
static void verifyFragmentedHeader(int invalidHeader)
{
    byte payload[FRAGMENT_SIZE + FragmentTailBytes];
    msg_t message;
    MSG_Init(&message, payload, sizeof(payload));
    MSG_WriteLong(&message, invalidHeader ? DelayedServerID : CurrentServerID);
    MSG_WriteLong(&message, invalidHeader ? DelayedSnapshotAck : NextSnapshotAck);
    MSG_WriteLong(&message, invalidHeader ? DelayedReliableAck : ReliableSequence);
    MSG_WriteLong(&message, ConfigDataAck);
    memset(payload + message.cursize, 0, sizeof(payload) - message.cursize);
    resetConnection();
    deliverFragment(invalidHeader ? DelayedIncomingSequence : NextIncomingSequence, 0, payload,
                    FRAGMENT_SIZE);
    check("partial fragment does not advance sequence",
          client.netchan.incomingSequence == InitialIncomingSequence && !executedMessages);
    deliverFragment(invalidHeader ? DelayedIncomingSequence : NextIncomingSequence, FRAGMENT_SIZE,
                    payload, FragmentTailBytes);
    if(invalidHeader)
    {
        check("invalid fragmented header leaves connection intact",
              client.netchan.incomingSequence == InitialIncomingSequence &&
                  client.reliableAcknowledge == InitialReliableAck && !executedMessages);
        deliverPacket(NextIncomingSequence, CurrentServerID, NextSnapshotAck, ReliableSequence,
                      PreservePacketLength);
        check("valid traffic resumes after invalid fragmented packet",
              client.netchan.incomingSequence == NextIncomingSequence && executedMessages == 1);
    }
    else
    {
        check("complete valid fragment commits the unflagged sequence",
              client.netchan.incomingSequence == NextIncomingSequence &&
                  client.reliableAcknowledge == ReliableSequence && executedMessages == 1);
    }
}

int main(void)
{
    verifyRejectedHeader("exact delayed packet cannot poison the connection", DelayedSnapshotAck,
                         DelayedReliableAck, PreservePacketLength);
    verifyRejectedHeader("future reliable acknowledgment is rejected", NextSnapshotAck,
                         DelayedReliableAck, PreservePacketLength);
    verifyRejectedHeader("expired reliable acknowledgment is rejected", NextSnapshotAck,
                         ExpiredReliableAck, PreservePacketLength);
    verifyRejectedHeader("negative snapshot acknowledgment is rejected", -1, ReliableSequence,
                         PreservePacketLength);
    verifyRejectedHeader("future snapshot acknowledgment is rejected", DelayedSnapshotAck,
                         ReliableSequence, PreservePacketLength);
    verifyRejectedHeader("truncated header is rejected", NextSnapshotAck, ReliableSequence,
                         TruncatedHeaderBytes);
    verifyFragmentedHeader(0);
    verifyFragmentedHeader(1);
    resetConnection();
    deliverPacket(NextIncomingSequence, CurrentServerID, NextSnapshotAck, ReliableSequence,
                  PreservePacketLength);
    deliverPacket(NextIncomingSequence, CurrentServerID, NextSnapshotAck, ReliableSequence,
                  PreservePacketLength);
    check("valid packets advance once; duplicates stay rejected",
          executedMessages == 1 && client.netchan.incomingSequence == NextIncomingSequence);
    return failures ? 1 : 0;
}
