// CoD4 helpers formerly supplied by plugins/libcod_plugin.
// Keep the GSC interface while using the engine's own types and entry points.
#include "gsc_cod4_helpers.hpp"
#ifdef COD4
#include <string.h>
extern "C" {
#include "../cod4x-server/src/sys_net.h"
#include "../cod4x-server/src/cvar.h"

static bool validClient(int id)
{
    return sv_maxclients && id >= 0 && id < sv_maxclients->integer;
}

void Gsc_Cod4_GetAscii()
{
    const char *text = Scr_GetString(0);
    // Match the old plugin's signed first-byte result, including empty strings.
    Scr_AddInt(static_cast<signed char>(text[0]));
}

void Gsc_Cod4_ForceDownloadCvars()
{
    Cvar_RegisterBool("cl_allowdownload", qtrue, CVAR_SYSTEMINFO | CVAR_ROM, "");
    Cvar_RegisterBool("cl_wwwdownload", qtrue, CVAR_SYSTEMINFO | CVAR_ROM, "");
}

void Gsc_Cod4_FindConfigstringIndex()
{
    const char *name = Scr_GetString(0);
    const int start = Scr_GetInt(1);
    const int count = Scr_GetInt(2);
    // Slot zero of each table is reserved. Never allocate or alter configstrings.
    // Validate with subtraction so a malicious count cannot overflow the bound.
    if (!name[0] || start < 0 || start >= MAX_CONFIGSTRINGS ||
        count <= 1 || count > MAX_CONFIGSTRINGS - start)
    {
        Scr_AddInt(0);
        return;
    }
    char value[MAX_STRING_CHARS];
    for (int index = start + 1; index < start + count; ++index)
    {
        SV_GetConfigstring(index, value, sizeof(value));
        if (!Q_stricmp(value, name))
        {
            // GSC uses this in the client's configstring-update command, which
            // needs the absolute index, not the offset within this table.
            Scr_AddInt(index);
            return;
        }
    }
    Scr_AddInt(0);
}

void Gsc_Cod4_AddVelocity(int id)
{
    vec3_t velocity;
    Scr_GetVector(0, velocity);
    playerState_t *ps = validClient(id) ? SV_GameClientNum(id) : NULL;
    if (!ps) { Scr_AddInt(0); return; }
    for (int axis = 0; axis < 3; ++axis) ps->velocity[axis] += velocity[axis];
    Scr_AddInt(1);
}

void Gsc_Cod4_GetIP(int id)
{
    char address[NET_ADDRSTRMAXLEN] = {0};
    if (validClient(id))
        NET_AdrToStringShortMT(&svs.clients[id].netchan.remoteAddress, address, sizeof(address));
    Scr_AddString(address);
}

void Gsc_Cod4_IsSprinting(int id)
{
    playerState_t *ps = validClient(id) ? SV_GameClientNum(id) : NULL;
    Scr_AddInt(ps && ps->sprintState.lastSprintStart > ps->sprintState.lastSprintEnd);
}
}
#endif
