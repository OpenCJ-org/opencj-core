///
/// Player & item visibility (hiding from players/everyone etc), shared between libcod and cod4x
///

/**************************************************************************
 * Includes                                                               *
 **************************************************************************/

#include "shared.hpp"
#include "opencj_demo.hpp"

#include <string.h>

/**************************************************************************
 * Defines                                                                *
 **************************************************************************/


/**************************************************************************
 * Types                                                                  *
 **************************************************************************/

typedef enum
{
    HIDE_NONE = 0,  // Don't hide players (except ignored and muted ones)
    HIDE_NEAR = 1,  // Hide near players
    HIDE_ALL  = 2,  // Hide all players
} eHideMode_t;

typedef struct
{
    int radiusSquared;  // To prevent expensive operations every frame
    int height;         // Cylinder pattern for hiding
} sHideRadiusInfo_t;

/**************************************************************************
 * Globals                                                                *
 **************************************************************************/

// This array contains the players that are hidden for everyone (i.e. muted)
static bool opencj_globalHideList[MAX_CLIENTS];

// This array is a list for each entity, containing space for each clientNum to be ignored
// [dimension1][dimension2] -> dimension1 is the entity for whose list is it
static bool opencj_playerHideList[MAX_CLIENTS][MAX_CLIENTS];

// This array contains the hide radius + Z distance (cylinder shape) for each player
static sHideRadiusInfo_t opencj_hideCylinder[MAX_CLIENTS];

// This array contains the visibility configuration for each player
static eHideMode_t opencj_hideModeConfig[MAX_CLIENTS];

/**************************************************************************
 * Local functions                                                        *
 **************************************************************************/

static int getFirstParamEntityNum()
{
    if (Scr_GetNumParam() < 1)
    {
        stackError("Expected (at least) 1 argument: entityNum");
        return -1;
    }

    int entNum = -1;
    stackGetParamInt(0, &entNum);
    if (entNum == -1)
    {
        stackError("Entity to ignore is NULL");
        return -1;
    }

    return entNum;
}

static void setEntityVisibilityForPlayer(gentity_t *ent, gentity_t *player, bool shouldHide)
{
    ent->flags &= (~ENTFLAG_INVISIBLE);
    int clientMaskIdx = player->s.number / (sizeof(uint32_t) * 8);
    if (shouldHide)
    {
        ent->r.clientMask[clientMaskIdx] |=  (1L << ((uint8_t)player->s.number & 0x1f));
    }
    else
    {
        ent->r.clientMask[clientMaskIdx] &= ~(1L << ((uint8_t)player->s.number & 0x1f));
    }
}

static void clearEntityVisibilityForAllPlayers(gentity_t *ent)
{
    ent->flags &= (~ENTFLAG_INVISIBLE);
    ent->r.clientMask[0] = ent->r.clientMask[1] = 0;
}

/**************************************************************************
 * API functions                                                          *
 **************************************************************************/

// For entities/items
void Gsc_Vis_HideFromPlayer(int toHideId)
{
    int clientNum = getFirstParamEntityNum();
    if (clientNum < 0) return;

    gentity_t *ent = &g_entities[toHideId];
    gentity_t *player = &g_entities[clientNum];
    setEntityVisibilityForPlayer(ent, player, true);
}

void Gsc_Vis_ShowToAllPlayers(int toShowId)
{
    gentity_t *ent = &g_entities[toShowId];
    clearEntityVisibilityForAllPlayers(ent);
}


// For players
void Gsc_Vis_AddPlayerToHideList(int clientNum)
{
    int toHideId = getFirstParamEntityNum();
    if (toHideId < 0) return;

    opencj_playerHideList[clientNum][toHideId] = true;
}

void Gsc_Vis_RemovePlayerFromHideList(int clientNum)
{
    int toShowId = getFirstParamEntityNum();
    if (toShowId < 0) return;

    opencj_playerHideList[clientNum][toShowId] = false;
}

void Gsc_Vis_HideForAll(int toHideId)
{
    int shouldBeHidden = 0;
    if (Scr_GetNumParam() >= 1)
    {
        stackGetParamInt(0, &shouldBeHidden);
    }

    opencj_globalHideList[toHideId] = (shouldBeHidden > 0);
}

static const int MAX_HIDE_RADIUS_UNITS = 4096;

void Gsc_Vis_SetHideRadius(int playerId)
{
    int radius = 0;
    if (stackGetParams("i", &radius) != 1)
    {
        stackError("Expected 1 argument: radius (int)");
        return;
    }

    if (radius < 0 || radius > MAX_HIDE_RADIUS_UNITS)
    {
        stackError("Hide radius must be between 0 and 4096");
        return;
    }
    opencj_hideCylinder[playerId].radiusSquared = (radius * radius);
    opencj_hideCylinder[playerId].height = (radius * 2);
}

// Separate functions are slightly cleaner for GSC so it doesn't have to remember ints or strings that match the hide mode
void Gsc_Vis_SetHideModeNone(int id)
{
    opencj_hideModeConfig[id] = HIDE_NONE;
}
void Gsc_Vis_SetHideModeNear(int id)
{
    opencj_hideModeConfig[id] = HIDE_NEAR;
}
void Gsc_Vis_SetHideModeAll(int id)
{
    opencj_hideModeConfig[id] = HIDE_ALL;
}

// Called by GSC upon initialization before it pushes the new config for a player
void Gsc_Vis_InitVisibility(int playerId)
{
    memset(opencj_playerHideList[playerId], false, sizeof(opencj_playerHideList[playerId]));
    opencj_hideCylinder[playerId].radiusSquared = 0;
    opencj_hideCylinder[playerId].height = 0;
    opencj_hideModeConfig[playerId] = HIDE_NONE;

    for (int i = 0; i < MAX_CLIENTS; i++)
    {
        opencj_playerHideList[i][playerId] = false;
    }
}

// Called only for active players with valid client state.
// A demo body is visible to its owner and spectators following that owner.
static bool shouldHidePlayer(int viewerNum, int subjectNum)
{
    bool viewerIsSpectating =
        svs.clients[viewerNum].gentity->client->sess.sessionState == SESS_STATE_SPECTATOR;
    if (OpenCJ_Demo_IsPresentationActive(subjectNum))
    {
        bool isFollowingSubject =
            viewerIsSpectating && SV_GameClientNum(viewerNum)->clientNum == subjectNum;
        return !isFollowingSubject;
    }
    if (viewerIsSpectating)
    {
        return false;
    }
    if (opencj_globalHideList[subjectNum] || opencj_playerHideList[viewerNum][subjectNum])
    {
        return true;
    }
    if (opencj_hideModeConfig[viewerNum] == HIDE_NONE)
    {
        return false;
    }
    if (opencj_hideModeConfig[viewerNum] == HIDE_ALL)
    {
        return true;
    }

    const gentity_t *viewer = &g_entities[viewerNum];
    const gentity_t *subject = &g_entities[subjectNum];
    // Keep the existing integer coordinate rounding used by the hide-cylinder boundary.
    int offsetX = (subject->r.currentOrigin[0] - viewer->r.currentOrigin[0]) + 0.5;
    int offsetY = (subject->r.currentOrigin[1] - viewer->r.currentOrigin[1]) + 0.5;
    int offsetZ = (subject->r.currentOrigin[2] - viewer->r.currentOrigin[2]) + 0.5;
    if (abs(offsetZ) > opencj_hideCylinder[viewerNum].height)
    {
        return false;
    }
    int distanceSquared = offsetX * offsetX + offsetY * offsetY;
    return distanceSquared <= opencj_hideCylinder[viewerNum].radiusSquared;
}

// Update each viewer/subject pair once; a player's own body stays visible to them.
void Gsc_Vis_UpdatePlayerVisibility()
{
    for (int viewerNum = 0; viewerNum < sv_maxclients->integer; viewerNum++)
    {
        gentity_t *viewer = &g_entities[viewerNum];
        if (!viewer->client || svs.clients[viewerNum].state != CS_ACTIVE)
        {
            continue;
        }
        if (!svs.clients[viewerNum].gentity || !svs.clients[viewerNum].gentity->client)
        {
            continue;
        }

        for (int subjectNum = 0; subjectNum < sv_maxclients->integer; subjectNum++)
        {
            if (subjectNum == viewerNum)
            {
                continue;
            }
            gentity_t *subject = &g_entities[subjectNum];
            if (!subject->client || svs.clients[subjectNum].state != CS_ACTIVE)
            {
                continue;
            }
            setEntityVisibilityForPlayer(subject, viewer, shouldHidePlayer(viewerNum, subjectNum));
        }
    }
}
