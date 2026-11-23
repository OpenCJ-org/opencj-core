// Disposable fixture only: inspect notification fades after HUD alpha encoding.
#define OnInit MemoryAuditInit
#include "player-memory-audit.cpp"
#undef OnInit
#include "../../cod4x-server/src/g_shared.h"
extern "C"
{
    int Plugin_Scr_GetInt(unsigned parameterIndex);
    void Plugin_Scr_AddInt(int value);
    void BG_LerpHudColors(const hudelem_t *hud, int timeMs, hudelem_color_t *color);
}
// Reproduce the alpha bits received by a client, then sample its current fade.
// Return -1 for invalid geometry; zero means no visible overlay at this update.
static void probeNotificationOverlay()
{
    constexpr int overlaySort = -1000;
    constexpr int screenWidth = 640;
    constexpr int screenHeight = 480;
    constexpr int edgeWidth = 64;
    constexpr int rightEdgeX = screenWidth - edgeWidth;
    constexpr unsigned char transmittedAlphaMask = 0xf8;
    const int clientNumber = Plugin_Scr_GetInt(0);
    const bool isResultOverlay = Plugin_Scr_GetInt(1) != 0;
    int alphaByte = 0;
    int overlayCount = 0;
    int leftCount = 0;
    int rightCount = 0;
    bool validGeometry = true;
    for (int i = 0; i < MAX_HUDELEMS; i++)
    {
        const game_hudelem_t &hud = g_hudelems[i];
        if (!hud.elem.type || hud.clientNum != clientNumber || hud.elem.sort != overlaySort)
        {
            continue;
        }
        ++overlayCount;
        hudelem_t encodedHud = hud.elem;
        hudelem_color_t interpolatedColor;
        encodedHud.color.split.a = (unsigned char)encodedHud.color.split.a & transmittedAlphaMask;
        encodedHud.fromColor.split.a =
            (unsigned char)encodedHud.fromColor.split.a & transmittedAlphaMask;
        BG_LerpHudColors(&encodedHud, level.time, &interpolatedColor);
        int currentAlphaByte = (unsigned char)interpolatedColor.split.a;
        if (overlayCount > 1 && currentAlphaByte != alphaByte)
        {
            validGeometry = false;
        }
        alphaByte = currentAlphaByte;
        if (!(encodedHud.flags & HUDDISPLAY_FOREGROUND) || encodedHud.height != screenHeight ||
            encodedHud.materialIndex == 0 || encodedHud.y != 0)
        {
            validGeometry = false;
        }
        if (isResultOverlay)
        {
            if (encodedHud.width != screenWidth || encodedHud.x != 0)
            {
                validGeometry = false;
            }
        }
        else
        {
            if (encodedHud.width != edgeWidth)
            {
                validGeometry = false;
            }
            if (encodedHud.x == 0)
            {
                ++leftCount;
            }
            else if (encodedHud.x == rightEdgeX)
            {
                ++rightCount;
            }
            else
            {
                validGeometry = false;
            }
        }
    }
    const int expectedOverlayCount = isResultOverlay ? 1 : 2;
    const bool missingEdgePair = !isResultOverlay && (leftCount != 1 || rightCount != 1);
    if (overlayCount && (overlayCount != expectedOverlayCount || missingEdgePair))
    {
        validGeometry = false;
    }
    Plugin_Scr_AddInt(validGeometry ? alphaByte : -1);
}
extern "C" int OnInit()
{
    MemoryAuditInit();
    Plugin_ScrAddFunction(const_cast<char *>("notificationHudProbe"), probeNotificationOverlay);
    return 0;
}
