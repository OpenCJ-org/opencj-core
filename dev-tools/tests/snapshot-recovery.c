#include "msg.h"
#include "server.h"
#include "qcommon_io.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
svsHeader_t svsHeader;
objective_t opencj_playerObjectives[MAX_CLIENTS][16];
enum
{
    SnapshotTimeMs = 10000,
    FollowingMessageMarker = 0x13579bdf,
    RandomSeed = 7,
    RandomScenarioCount = 1000,
    TestedHudSlots = 32
};
static playerState_t predicted;
int SV_GetPredictedOriginAndTimeForClientNum(int clientNumber, float *origin)
{
    memcpy(origin, predicted.origin, sizeof(vec3_t));
    return predicted.commandTime;
}
void SV_GetMapCenterFromSVSHeader(float *origin)
{
    memset(origin, 0, sizeof(vec3_t));
}
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
    va_list arguments;
    va_start(arguments, format);
    vfprintf(stderr, format, arguments);
    va_end(arguments);
    exit(3);
}
double Vec3DistanceSq(const vec3_t a, const vec3_t b)
{
    float x = a[0] - b[0];
    float y = a[1] - b[1];
    float z = a[2] - b[2];
    return x * x + y * y + z * z;
}
qboolean Assert_MyHandler(const char *expression, const char *file, int line,
                          const char *functionName, const char *format, ...)
{
    fprintf(stderr, "Assertion: %s at %s:%d\n", expression, file, line);
    exit(4);
}

static int failures;
static void check(const char *name, int passed)
{
    printf("%s: %s\n", passed ? "PASS" : "FAIL", name);
    if(!passed)
    {
        failures++;
    }
}
// Full recovery must carry position and leave the following service message aligned.
static void verifySnapshot(const char *name, playerState_t *from, playerState_t *to, int archived,
                           int expectPositionUpdate)
{
    byte buffer[MAX_MSGLEN];
    msg_t message;
    struct snapshotInfo_s snapshotInfo = {0};
    snapshotInfo.archived = archived;
    MSG_Init(&message, buffer, sizeof(buffer));
    MSG_WriteDeltaPlayerstate(&snapshotInfo, &message, SnapshotTimeMs, from, to);
    check("snapshot did not overflow", !message.overflowed);
    MSG_WriteLong(&message, FollowingMessageMarker);
    MSG_BeginReading(&message);
    check(name, MSG_ReadBit(&message) == expectPositionUpdate);
    if(expectPositionUpdate)
    {
        playerState_t decodedState;
        MSG_BeginReading(&message);
        MSG_ReadDeltaPlayerstate(0, &message, SnapshotTimeMs, from, &decodedState, 1);
        check("round trip position", !memcmp(to->origin, decodedState.origin, sizeof(vec3_t)));
        check("round trip time", to->commandTime == decodedState.commandTime);
        check("next message remains aligned", MSG_ReadLong(&message) == FollowingMessageMarker);
        check("reader did not overflow", !message.overflowed);
    }
}
static void verifyRandomHudDeltas(playerState_t *state)
{
    int failuresBefore = failures;
    // Editor HUD changes share the same bitstream as following service commands.
    // Exercise deltas, removals, float/integer transitions, and timing/color fields.
    svsHeader.clientArchive = 0;
    srand(RandomSeed);
    for(int scenario = 0; scenario < RandomScenarioCount; scenario++)
    {
        playerState_t from = *state;
        int count = rand() % TestedHudSlots;
        memset(state->hud.current, 0, sizeof(state->hud.current));
        for(int i = 0; i < count; i++)
        {
            hudelem_t *hud = &state->hud.current[i];
            hud->type = 1 + rand() % 6;
            hud->x = (rand() % 2000 - 1000) * 0.25f;
            hud->y = (rand() % 2000 - 1000) * 0.25f;
            hud->text = rand() % 512;
            hud->label = rand() % 512;
            hud->fontScale = 1.4f + (rand() % 31) * 0.1f;
            hud->height = rand() % 1024;
            hud->width = rand() % 1024;
            hud->color.rgba = (unsigned)rand() * rand();
            hud->fromColor.rgba = (unsigned)rand() * rand();
            hud->fadeStartTime = rand() % 10000;
            hud->fadeTime = rand() % 65536;
            hud->moveTime = rand() % 65536;
            hud->fromX = (rand() % 2000 - 1000) * 0.3f;
        }
        byte buffer[MAX_MSGLEN];
        msg_t message;
        struct snapshotInfo_s snapshotInfo = {0};
        playerState_t decodedState;
        MSG_Init(&message, buffer, sizeof(buffer));
        MSG_WriteDeltaPlayerstate(&snapshotInfo, &message, SnapshotTimeMs, &from, state);
        MSG_WriteLong(&message, FollowingMessageMarker);
        MSG_BeginReading(&message);
        MSG_ReadDeltaPlayerstate(0, &message, SnapshotTimeMs, &from, &decodedState, 1);
        if(message.overflowed || MSG_ReadLong(&message) != FollowingMessageMarker)
        {
            check("randomized HUD delta message alignment", 0);
            break;
        }
    }
    check("1000 randomized HUD delta round trips", failures == failuresBefore);
}

int main(void)
{
    static playerState_t from;
    static playerState_t to;
    to.commandTime = SnapshotTimeMs;
    to.origin[0] = 1234;
    to.origin[1] = -567;
    to.origin[2] = 890;
    predicted = to;
    from = to;
    svsHeader.clientArchive = 1;
    verifySnapshot("full recovery sends position even when prediction matches", NULL, &to, 0, 1);
    verifySnapshot("ordinary matching delta retains optimization", &from, &to, 0, 0);
    predicted.commandTime--;
    verifySnapshot("outdated prediction sends position", &from, &to, 0, 1);
    predicted = to;
    predicted.origin[0] += 1;
    verifySnapshot("prediction mismatch sends position", &from, &to, 0, 1);
    predicted = to;
    svsHeader.clientArchive = 0;
    verifySnapshot("disabled client archive sends position", &from, &to, 0, 1);
    svsHeader.clientArchive = 1;
    verifySnapshot("archived snapshot sends position", &from, &to, 1, 1);
    for(int hudCount = 1; hudCount < TestedHudSlots; hudCount++)
    {
        to.hud.current[hudCount - 1].type = 1;
        to.hud.current[hudCount - 1].x = 320 + hudCount;
        to.hud.current[hudCount - 1].y = 200 + hudCount;
        to.hud.current[hudCount - 1].text = hudCount;
        to.hud.current[hudCount - 1].fontScale = 1.4f;
        to.hud.current[hudCount - 1].width = 344;
        to.hud.current[hudCount - 1].height = 172;
        to.hud.current[hudCount - 1].color.rgba = 0xffffffff;
        char name[80];
        snprintf(name, sizeof(name), "full snapshot with %d HUD elements", hudCount);
        verifySnapshot(name, NULL, &to, 0, 1);
    }

    verifyRandomHudDeltas(&to);
    return failures ? 1 : 0;
}
