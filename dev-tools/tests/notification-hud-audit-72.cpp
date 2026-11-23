// Disposable fixture only: inspect notification fades after HUD alpha encoding.
#define OnInit MemoryAuditInit
#include "player-memory-audit.cpp"
#undef OnInit
#include "../../cod4x-server/src/g_shared.h"
extern "C"
{
    int Plugin_Scr_GetInt(unsigned);
    void Plugin_Scr_AddInt(int);
    void BG_LerpHudColors(const hudelem_t *, int, hudelem_color_t *);
}
static void probe()
{
    const int client = Plugin_Scr_GetInt(0), result = Plugin_Scr_GetInt(1);
    int alpha = 0, count = 0, left = 0, right = 0;
    bool valid = true;
    for (int i = 0; i < MAX_HUDELEMS; i++)
    {
        const game_hudelem_t &hud = g_hudelems[i];
        if (!hud.elem.type || hud.clientNum != client || hud.elem.sort != -1000)
        {
            continue;
        }
        ++count;
        hudelem_t wire = hud.elem;
        hudelem_color_t c;
        wire.color.split.a = (unsigned char)wire.color.split.a & 0xf8;
        wire.fromColor.split.a = (unsigned char)wire.fromColor.split.a & 0xf8;
        BG_LerpHudColors(&wire, level.time, &c);
        int current = (unsigned char)c.split.a;
        if (count > 1 && current != alpha)
        {
            valid = false;
        }
        alpha = current;
        if (!(wire.flags & HUDDISPLAY_FOREGROUND) || wire.height != 480 ||
            wire.materialIndex == 0 || wire.y != 0)
        {
            valid = false;
        }
        if (result)
        {
            if (wire.width != 640 || wire.x != 0)
            {
                valid = false;
            }
        }
        else
        {
            if (wire.width != 64)
            {
                valid = false;
            }
            if (wire.x == 0)
            {
                ++left;
            }
            else if (wire.x == 576)
            {
                ++right;
            }
            else
            {
                valid = false;
            }
        }
    }
    if (count && (count != (result ? 1 : 2) || (!result && (left != 1 || right != 1))))
    {
        valid = false;
    }
    Plugin_Scr_AddInt(valid ? alpha : -1);
}
extern "C" int OnInit()
{
    MemoryAuditInit();
    Plugin_ScrAddFunction(const_cast<char *>("notificationHudProbe"), probe);
    return 0;
}
