#include <stdlib.h>

#include "gsc_saveposition.hpp"

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

typedef enum // GSC hardcodes these values!
{
    FPS_MODE_43 = 0, // CoD2 only
    FPS_MODE_76 = 1, // CoD2 only
    FPS_MODE_125 = 2,
    FPS_MODE_250 = 3, // CoD2 only
    FPS_MODE_333 = 4, // CoD2 only
    FPS_MODE_MIX = 5,
    FPS_MODE_HAX = 6, // CoD4 only
} opencj_fps_mode;

struct opencj_save
{
	opencj_save *olderSave;
	gentity_t *groundEntity;
	vec3_t origin;
	vec3_t angles;
    int checkpointID;
    int explosiveJumps;
    int doubleExplosives;
    opencj_fps_mode fpsMode;
    int flags;
    int saveNumber;
};

static const int SAVE_HISTORY_LIMIT = 100;
static opencj_save *newestSaveByPlayer[MAX_CLIENTS];
static opencj_save *selectedSaveByPlayer[MAX_CLIENTS];
static opencj_save *oldestSaveByPlayer[MAX_CLIENTS];
static int saveCountByPlayer[MAX_CLIENTS];
static unsigned historyGenerationByPlayer[MAX_CLIENTS];

// Clear borrowed selections before freeing a node from its owner's history.
static void releaseSave(opencj_save *save)
{
    // A selected save may belong to another player.
    for(int i = 0; i < MAX_CLIENTS; i++)
    {
        if(selectedSaveByPlayer[i] == save)
        {
            selectedSaveByPlayer[i] = NULL;
        }
    }
    free(save);
}

// Release this player's history and invalidate any outstanding page requests.
void gsc_saveposition_initclient(int playerIndex)
{
    opencj_save *save = newestSaveByPlayer[playerIndex];
    while(save)
    {
        opencj_save *older = save->olderSave;
        releaseSave(save);
        save = older;
    }
    oldestSaveByPlayer[playerIndex] = NULL;
    selectedSaveByPlayer[playerIndex] = NULL;
    newestSaveByPlayer[playerIndex] = NULL;
    saveCountByPlayer[playerIndex] = 0;
    ++historyGenerationByPlayer[playerIndex];
}

// Allocate a node from the script arguments; the caller owns the returned node.
static opencj_save *readSave()
{
    opencj_save *save = (opencj_save *)calloc(1, sizeof(opencj_save));
    if(!save)
    {
        return NULL;
    }
    stackGetParamVector(0, save->origin);
    stackGetParamVector(1, save->angles);
    if(stackGetParamType(2) == STACK_INT)
    {
        int entityIndex = -1;
        stackGetParamInt(2, &entityIndex);
        if(entityIndex >= 0 && entityIndex < MAX_GENTITIES)
        {
            save->groundEntity = &g_entities[entityIndex];
        }
    }
    stackGetParamInt(3, &save->explosiveJumps);
    stackGetParamInt(4, &save->doubleExplosives);
    save->checkpointID = -1;
    if(stackGetParamType(5) == STACK_INT)
    {
        stackGetParamInt(5, &save->checkpointID);
    }
    int fpsModeValue = 0;
    stackGetParamInt(6, &fpsModeValue);
    save->fpsMode = (opencj_fps_mode)fpsModeValue;
    stackGetParamInt(7, &save->flags);
    stackGetParamInt(8, &save->saveNumber);
    return save;
}

// Prepend a live save and remove the oldest node when the history reaches its cap.
void gsc_saveposition_save(int playerIndex)
{
    opencj_save *save = readSave();
    if(!save)
    {
        stackPushUndefined();
        return;
    }
    save->olderSave = newestSaveByPlayer[playerIndex];
    newestSaveByPlayer[playerIndex] = save;
    if(!oldestSaveByPlayer[playerIndex])
    {
        oldestSaveByPlayer[playerIndex] = save;
    }
    ++saveCountByPlayer[playerIndex];
    if(saveCountByPlayer[playerIndex] > SAVE_HISTORY_LIMIT)
    {
        opencj_save *previousOldestSave = newestSaveByPlayer[playerIndex];
        while(previousOldestSave->olderSave && previousOldestSave->olderSave->olderSave)
        {
            previousOldestSave = previousOldestSave->olderSave;
        }
        releaseSave(previousOldestSave->olderSave);
        previousOldestSave->olderSave = NULL;
        oldestSaveByPlayer[playerIndex] = previousOldestSave;
        --saveCountByPlayer[playerIndex];
    }
    stackPushInt(SAVE_INSERTED);
}

// Append restored history only in descending save-number order.
void gsc_saveposition_addolder(int playerIndex)
{
    if(saveCountByPlayer[playerIndex] >= SAVE_HISTORY_LIMIT)
    {
        stackPushInt(SAVE_HISTORY_FULL);
        return;
    }
    int saveNumber = 0;
    stackGetParamInt(8, &saveNumber);
    if(oldestSaveByPlayer[playerIndex] && saveNumber >= oldestSaveByPlayer[playerIndex]->saveNumber)
    {
        stackPushInt(SAVE_NOT_OLDER);
        return;
    }
    opencj_save *save = readSave();
    if(!save)
    {
        stackPushUndefined();
        return;
    }
    if(oldestSaveByPlayer[playerIndex])
    {
        oldestSaveByPlayer[playerIndex]->olderSave = save;
    }
    else
    {
        newestSaveByPlayer[playerIndex] = save;
    }
    oldestSaveByPlayer[playerIndex] = save;
    ++saveCountByPlayer[playerIndex];
    stackPushInt(SAVE_INSERTED);
}

void gsc_saveposition_historyinfo(int playerIndex)
{
    // count, oldest save number, generation, limit, newest save number.
    stackMakeArray();
    stackPushInt(saveCountByPlayer[playerIndex]);
    stackPushArrayNext();
    if(oldestSaveByPlayer[playerIndex])
    {
        stackPushInt(oldestSaveByPlayer[playerIndex]->saveNumber);
    }
    else
    {
        stackPushUndefined();
    }
    stackPushArrayNext();
    stackPushInt(historyGenerationByPlayer[playerIndex]);
    stackPushArrayNext();
    stackPushInt(SAVE_HISTORY_LIMIT);
    stackPushArrayNext();
    if(newestSaveByPlayer[playerIndex])
    {
        stackPushInt(newestSaveByPlayer[playerIndex]->saveNumber);
    }
    else
    {
        stackPushUndefined();
    }
    stackPushArrayNext();
}

// Select the newest save without the excluded flags, optionally from another player.
void gsc_saveposition_selectwithoutflag(int playerIndex)
{
    int excludedFlags = 0;
    stackGetParamInt(0, &excludedFlags);
    if (excludedFlags == 0)
    {
        stackPushUndefined();
        return;
    }

    // Player might be requesting it for a different player's saves (teleporting for example)
    int sourcePlayerIndex = playerIndex; // By default, the requesting player
    if (Scr_GetNumParam() > 1)
    {
        stackGetParamInt(1, &sourcePlayerIndex);
    }

    if (sourcePlayerIndex < 0 || sourcePlayerIndex >= MAX_CLIENTS)
    {
        stackPushUndefined();
        return;
    }

    // Select the last save that matches this criteria
    selectedSaveByPlayer[playerIndex] = newestSaveByPlayer[sourcePlayerIndex];
    int backwardsCount = 0;
    while (selectedSaveByPlayer[playerIndex] != NULL)
    {
        // Skip saves that carry any excluded flag.
        int saveFlags = selectedSaveByPlayer[playerIndex]->flags;
        if ((saveFlags & excludedFlags) == 0)
        {
            stackPushInt(backwardsCount); // Successfully found
            return;
        }

        // Check if there are any saves left
        if (selectedSaveByPlayer[playerIndex]->olderSave == NULL)
        {
            stackPushUndefined();
            return;
        }

        // Go back further
        selectedSaveByPlayer[playerIndex] = selectedSaveByPlayer[playerIndex]->olderSave;
        backwardsCount++;
    }
    stackPushUndefined();
}

// Select a retained save by its distance from the newest position.
void gsc_saveposition_selectsave(int playerIndex)
{
	int backwardsCount;
	stackGetParamInt(0, &backwardsCount);
	if(backwardsCount < 0 || backwardsCount >= SAVE_HISTORY_LIMIT)
	{
		selectedSaveByPlayer[playerIndex] = NULL;
		stackPushInt(SAVE_INDEX_UNAVAILABLE);
		return;
	}
	if(newestSaveByPlayer[playerIndex] == NULL)
	{
		stackPushInt(SAVE_HISTORY_EMPTY);
		return;
	}
	selectedSaveByPlayer[playerIndex] = newestSaveByPlayer[playerIndex];

	while(backwardsCount)
	{
		if(selectedSaveByPlayer[playerIndex]->olderSave != NULL)
		{
			selectedSaveByPlayer[playerIndex] = selectedSaveByPlayer[playerIndex]->olderSave;
		}
		else
		{
			stackPushInt(SAVE_INDEX_UNAVAILABLE);
			return;
		}
		backwardsCount--;
	}

	stackPushInt(SAVE_SELECTED);
}

void gsc_saveposition_getangles(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushVector(selectedSaveByPlayer[playerIndex]->angles);
}

void gsc_saveposition_getfpsmode(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->fpsMode);
}

void gsc_saveposition_getorigin(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushVector(selectedSaveByPlayer[playerIndex]->origin);
}

void gsc_saveposition_getsavenum(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->saveNumber);
}

void gsc_saveposition_getflags(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->flags);
}

void gsc_saveposition_getcheatstatus(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushVector(selectedSaveByPlayer[playerIndex]->origin);
}

void gsc_saveposition_getgroundentity(int playerIndex)
{
	if(!selectedSaveByPlayer[playerIndex])
	{
		stackPushUndefined();
		return;
	}
	if(selectedSaveByPlayer[playerIndex]->groundEntity == NULL)
	{
		stackPushUndefined();
	}
	else
	{
		stackPushEntity(selectedSaveByPlayer[playerIndex]->groundEntity);
	}
}

void gsc_saveposition_getexplosivejumps(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->explosiveJumps);
}

void gsc_saveposition_getdoubleexplosives(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->doubleExplosives);
}

void gsc_saveposition_getcheckpointid(int playerIndex)
{
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    if(selectedSaveByPlayer[playerIndex]->checkpointID != -1)
    {
        stackPushInt(selectedSaveByPlayer[playerIndex]->checkpointID);
    }
    else
    {
        stackPushUndefined();
    }
}

#ifdef __cplusplus
}
#endif // __cplusplus
