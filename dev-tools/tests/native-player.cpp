// Exercise production visibility decisions and ping statistics without a game server.
#include "../../server-ext/opencj_visibility.cpp"
#include "../../server-ext/gsc_custom_player.cpp"
#include <cassert>
#include <cstdio>
#include <cstring>

serverStatic_t svs = {};
gentity_t g_entities[MAX_CLIENTS] = {};
static cvar_t maxClients = {};
cvar_t *sv_maxclients = &maxClients;
static gclient_t gameClients[2] = {};
static playerState_t playerStates[2] = {};
static bool presentingDemo[2] = {};
static int returnedInteger;
static unsigned int clockMs = 10000;
static int checks;

unsigned int Sys_Milliseconds()
{
    return clockMs;
}

void Scr_AddInt(int value)
{
    returnedInteger = value;
}

void Scr_AddUndefined()
{
    assert(false && "Unexpected undefined script result");
}

playerState_t *SV_GameClientNum(int clientNum)
{
    assert(clientNum >= 0 && clientNum < 2);
    return &playerStates[clientNum];
}

bool OpenCJ_Demo_IsPresentationActive(int clientNum)
{
    assert(clientNum >= 0 && clientNum < 2);
    return presentingDemo[clientNum];
}

static void check(bool passed, const char *scenario)
{
    ++checks;
    if (!passed)
    {
        std::fprintf(stderr, "NATIVE PLAYER FAIL: %s\n", scenario);
        std::exit(1);
    }
}

static void resetPlayers()
{
    maxClients.integer = 2;
    for (int clientNum = 0; clientNum < 2; ++clientNum)
    {
        g_entities[clientNum] = {};
        gameClients[clientNum] = {};
        playerStates[clientNum] = {};
        g_entities[clientNum].s.number = clientNum;
        g_entities[clientNum].client = &gameClients[clientNum];
        svs.clients[clientNum].gentity = &g_entities[clientNum];
        svs.clients[clientNum].state = CS_ACTIVE;
        gameClients[clientNum].sess.sessionState = SESS_STATE_PLAYING;
        Gsc_Vis_InitVisibility(clientNum);
        opencj_globalHideList[clientNum] = false;
        presentingDemo[clientNum] = false;
    }
}

static void checkVisibility()
{
    resetPlayers();
    check(!shouldHidePlayer(0, 1), "ordinary players remain visible");
    opencj_hideModeConfig[0] = HIDE_ALL;
    check(shouldHidePlayer(0, 1), "hide-all applies to another player");
    gameClients[0].sess.sessionState = SESS_STATE_SPECTATOR;
    check(!shouldHidePlayer(0, 1), "spectators bypass ordinary hide settings");

    presentingDemo[1] = true;
    playerStates[0].clientNum = 1;
    check(!shouldHidePlayer(0, 1), "following spectator sees the demo body");
    playerStates[0].clientNum = 0;
    check(shouldHidePlayer(0, 1), "unrelated spectator cannot see the demo body");
    gameClients[0].sess.sessionState = SESS_STATE_PLAYING;
    opencj_hideModeConfig[0] = HIDE_NONE;
    check(shouldHidePlayer(0, 1), "ordinary hide-none cannot reveal a demo body");

    presentingDemo[1] = false;
    opencj_playerHideList[0][1] = true;
    check(shouldHidePlayer(0, 1), "explicit player hide overrides hide-none");
    opencj_playerHideList[0][1] = false;
    opencj_globalHideList[1] = true;
    check(shouldHidePlayer(0, 1), "global hide overrides hide-none");
    opencj_globalHideList[1] = false;
    opencj_hideModeConfig[0] = HIDE_NEAR;
    opencj_hideCylinder[0] = {10000, 200};
    g_entities[1].r.currentOrigin[0] = 100;
    check(shouldHidePlayer(0, 1), "hide cylinder includes its horizontal boundary");
    g_entities[1].r.currentOrigin[0] = 101;
    check(!shouldHidePlayer(0, 1), "outside the hide cylinder remains visible");
    g_entities[1].r.currentOrigin[0] = 0;
    g_entities[1].r.currentOrigin[2] = 201;
    check(!shouldHidePlayer(0, 1), "above the hide cylinder remains visible");

    g_entities[1].r.currentOrigin[2] = 0;
    g_entities[1].r.currentOrigin[0] = 50000;
    check(!shouldHidePlayer(0, 1), "distant players cannot overflow into the hide cylinder");
    g_entities[1].r.currentOrigin[0] = 0;
    Gsc_Vis_UpdatePlayerVisibility();
    check((g_entities[1].r.clientMask[0] & 1u) != 0, "update hides the subject from its viewer");
    check((g_entities[1].r.clientMask[0] & 2u) == 0, "update leaves the subject visible to itself");
}

static void checkVisibilityMaskBits()
{
    gentity_t viewer = {};
    gentity_t subject = {};
    viewer.s.number = 31;
    setEntityVisibilityForPlayer(&subject, &viewer, true);
    check(subject.r.clientMask[0] == 0x80000000u, "last bit of first client mask is set");
    viewer.s.number = 63;
    setEntityVisibilityForPlayer(&subject, &viewer, true);
    check(subject.r.clientMask[1] == 0x80000000u, "last bit of second client mask is set");
    setEntityVisibilityForPlayer(&subject, &viewer, false);
    check(subject.r.clientMask[1] == 0 && subject.r.clientMask[0] == 0x80000000u,
          "showing one viewer preserves the other mask word");
}

static void checkPingVariation()
{
    resetPlayers();
    svs.clients[0].netchan.remoteAddress.type = NA_IP;
    std::memset(svs.clients[0].frames, 0, sizeof(svs.clients[0].frames));
    Gsc_Player_GetPingVariation(-1);
    check(returnedInteger == -1, "negative client has no ping variation");
    Gsc_Player_GetPingVariation(2);
    check(returnedInteger == -1, "client beyond the configured limit has no variation");
    Gsc_Player_GetPingVariation(0);
    check(returnedInteger == -1, "missing recent samples have no variation");

    // These four independent samples have mean 25 and standard deviation about 11.18 ms.
    const unsigned int roundTrips[] = {10, 20, 30, 40};
    for (int index = 0; index < 4; ++index)
    {
        svs.clients[0].frames[index].messageSent = clockMs - 100;
        svs.clients[0].frames[index].messageAcked = clockMs - 100 + roundTrips[index];
    }
    Gsc_Player_GetPingVariation(0);
    check(returnedInteger == 11, "four recent samples produce rounded standard deviation");
    svs.clients[0].frames[0].messageAcked = 0xFFFFFFFFu;
    Gsc_Player_GetPingVariation(0);
    check(returnedInteger == -1, "unacknowledged sample does not meet the minimum");
    svs.clients[0].netchan.remoteAddress.type = NA_BOT;
    Gsc_Player_GetPingVariation(0);
    check(returnedInteger == -1, "bot has no network ping variation");
}

int main()
{
    checkVisibility();
    checkVisibilityMaskBits();
    checkPingVariation();
    std::printf("NATIVE PLAYER COMPLETE checks=%d\n", checks);
}
