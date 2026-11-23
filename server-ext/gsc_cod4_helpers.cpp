// CoD4 helpers formerly supplied by plugins/libcod_plugin.
// Keep the GSC interface while using the engine's own types and entry points.
#include "gsc_cod4_helpers.hpp"
#ifdef COD4
#include <string.h>
extern "C" {
#include "../cod4x-server/src/sys_net.h"
#include "../cod4x-server/src/cvar.h"

static bool isValidClient(int clientNum)
{
    return sv_maxclients && clientNum >= 0 && clientNum < sv_maxclients->integer;
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

// Find an existing table entry; return zero when the range or name is unavailable.
void Gsc_Cod4_FindConfigstringIndex()
{
    const char *configstringName = Scr_GetString(0);
    const int tableStartIndex = Scr_GetInt(1);
    const int tableEntryCount = Scr_GetInt(2);
    // Slot zero of each table is reserved. Never allocate or alter configstrings.
    // Validate with subtraction so a malicious count cannot overflow the bound.
    if (!configstringName[0] || tableStartIndex < 0 || tableStartIndex >= MAX_CONFIGSTRINGS ||
        tableEntryCount <= 1 || tableEntryCount > MAX_CONFIGSTRINGS - tableStartIndex)
    {
        Scr_AddInt(0);
        return;
    }
    char configstringValue[MAX_STRING_CHARS];
    for (int index = tableStartIndex + 1; index < tableStartIndex + tableEntryCount; ++index)
    {
        SV_GetConfigstring(index, configstringValue, sizeof(configstringValue));
        if (!Q_stricmp(configstringValue, configstringName))
        {
            // GSC uses this in the client's configstring-update command, which
            // needs the absolute index, not the offset within this table.
            Scr_AddInt(index);
            return;
        }
    }
    Scr_AddInt(0);
}

void Gsc_Cod4_AddVelocity(int clientNum)
{
    vec3_t velocity;
    Scr_GetVector(0, velocity);
    playerState_t *playerState = isValidClient(clientNum) ? SV_GameClientNum(clientNum) : NULL;
    if (!playerState)
    {
        Scr_AddInt(0);
        return;
    }
    for (int axis = 0; axis < 3; ++axis)
    {
        playerState->velocity[axis] += velocity[axis];
    }
    Scr_AddInt(1);
}

void Gsc_Cod4_GetIP(int clientNum)
{
    char address[NET_ADDRSTRMAXLEN] = {0};
    if (isValidClient(clientNum))
    {
        NET_AdrToStringShortMT(&svs.clients[clientNum].netchan.remoteAddress, address,
                               sizeof(address));
    }
    Scr_AddString(address);
}

void Gsc_Cod4_IsSprinting(int clientNum)
{
    playerState_t *playerState = isValidClient(clientNum) ? SV_GameClientNum(clientNum) : NULL;
    Scr_AddInt(playerState &&
               playerState->sprintState.lastSprintStart > playerState->sprintState.lastSprintEnd);
}
}
#endif
