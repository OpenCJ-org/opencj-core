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

// CoD4 getters raise script errors; CoD2 getters report failure instead.
// Check the CoD4 type first so malformed inputs share a nonmutating failure path.
static bool readIntegerArgument(int argumentIndex, int *value)
{
#ifdef COD2
    return stackGetParamInt(argumentIndex, value) != 0;
#else
    if(argumentIndex >= Scr_GetNumParam() || stackGetParamType(argumentIndex) != STACK_INT)
    {
        return false;
    }
    stackGetParamInt(argumentIndex, value);
    return true;
#endif
}

static bool isPlayerIndexValid(int playerIndex)
{
    return playerIndex >= 0 && playerIndex < MAX_CLIENTS;
}

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
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
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

// Parse and validate before allocating: a rejected call cannot leak a node or
// publish a partially populated position into the player's history.
static opencj_save *readSave()
{
    const int saveArgumentCount = 9;
    const int noCheckpoint = -1;
    if(Scr_GetNumParam() < saveArgumentCount ||
       stackGetParamType(0) != STACK_VECTOR || stackGetParamType(1) != STACK_VECTOR)
    {
        return NULL;
    }

    opencj_save parsedSave = {};
    stackGetParamVector(0, parsedSave.origin);
    stackGetParamVector(1, parsedSave.angles);
    if(stackGetParamType(2) != STACK_UNDEFINED)
    {
        int entityIndex = -1;
        if(!readIntegerArgument(2, &entityIndex) || entityIndex < 0 || entityIndex >= MAX_GENTITIES)
        {
            return NULL;
        }
        parsedSave.groundEntity = &g_entities[entityIndex];
    }

    parsedSave.checkpointID = noCheckpoint;
    if(stackGetParamType(5) != STACK_UNDEFINED &&
       !readIntegerArgument(5, &parsedSave.checkpointID))
    {
        return NULL;
    }

    int fpsModeValue = 0;
    if(!readIntegerArgument(3, &parsedSave.explosiveJumps) ||
       !readIntegerArgument(4, &parsedSave.doubleExplosives) ||
       !readIntegerArgument(6, &fpsModeValue) ||
       !readIntegerArgument(7, &parsedSave.flags) ||
       !readIntegerArgument(8, &parsedSave.saveNumber))
    {
        return NULL;
    }
    if(fpsModeValue < FPS_MODE_43 || fpsModeValue > FPS_MODE_HAX)
    {
        return NULL;
    }
    parsedSave.fpsMode = (opencj_fps_mode)fpsModeValue;

    opencj_save *save = (opencj_save *)malloc(sizeof(opencj_save));
    if(!save)
    {
        return NULL;
    }
    *save = parsedSave;
    return save;
}

// Prepend a live save and remove the oldest node when the history reaches its cap.
void gsc_saveposition_save(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
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
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(saveCountByPlayer[playerIndex] >= SAVE_HISTORY_LIMIT)
    {
        stackPushInt(SAVE_HISTORY_FULL);
        return;
    }
    int saveNumber = 0;
    if(!readIntegerArgument(8, &saveNumber))
    {
        stackPushUndefined();
        return;
    }
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
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
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
// A failed selection clears the old result so getters cannot return an unrelated save.
void gsc_saveposition_selectwithoutflag(int playerIndex)
{
    if (!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    selectedSaveByPlayer[playerIndex] = NULL;

    int excludedFlags = 0;
    if (!readIntegerArgument(0, &excludedFlags) || excludedFlags == 0)
    {
        stackPushUndefined();
        return;
    }

    int sourcePlayerIndex = playerIndex;
    if (Scr_GetNumParam() > 1 && !readIntegerArgument(1, &sourcePlayerIndex))
    {
        stackPushUndefined();
        return;
    }
    if (!isPlayerIndexValid(sourcePlayerIndex))
    {
        stackPushUndefined();
        return;
    }

    opencj_save *candidate = newestSaveByPlayer[sourcePlayerIndex];
    int backwardsCount = 0;
    while (candidate != NULL)
    {
        if ((candidate->flags & excludedFlags) == 0)
        {
            selectedSaveByPlayer[playerIndex] = candidate;
            stackPushInt(backwardsCount);
            return;
        }
        candidate = candidate->olderSave;
        backwardsCount++;
    }
    stackPushUndefined();
}

// Select by distance from the newest save; publish a pointer only on success.
void gsc_saveposition_selectsave(int playerIndex)
{
	if(!isPlayerIndexValid(playerIndex))
	{
		stackPushUndefined();
		return;
	}
	selectedSaveByPlayer[playerIndex] = NULL;

	int backwardsCount = 0;
	if(!readIntegerArgument(0, &backwardsCount))
	{
		stackPushUndefined();
		return;
	}
	if(backwardsCount < 0 || backwardsCount >= SAVE_HISTORY_LIMIT)
	{
		stackPushInt(SAVE_INDEX_UNAVAILABLE);
		return;
	}
	if(newestSaveByPlayer[playerIndex] == NULL)
	{
		stackPushInt(SAVE_HISTORY_EMPTY);
		return;
	}

	opencj_save *candidate = newestSaveByPlayer[playerIndex];
	while(backwardsCount)
	{
		if(candidate->olderSave == NULL)
		{
			stackPushInt(SAVE_INDEX_UNAVAILABLE);
			return;
		}
		candidate = candidate->olderSave;
		backwardsCount--;
	}
	selectedSaveByPlayer[playerIndex] = candidate;
	stackPushInt(SAVE_SELECTED);
}

void gsc_saveposition_getangles(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushVector(selectedSaveByPlayer[playerIndex]->angles);
}

void gsc_saveposition_getfpsmode(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->fpsMode);
}

void gsc_saveposition_getorigin(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushVector(selectedSaveByPlayer[playerIndex]->origin);
}

void gsc_saveposition_getsavenum(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->saveNumber);
}

void gsc_saveposition_getflags(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->flags);
}

void gsc_saveposition_getcheatstatus(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushVector(selectedSaveByPlayer[playerIndex]->origin);
}

void gsc_saveposition_getgroundentity(int playerIndex)
{
	if(!isPlayerIndexValid(playerIndex))
	{
		stackPushUndefined();
		return;
	}
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
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->explosiveJumps);
}

void gsc_saveposition_getdoubleexplosives(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
    if(!selectedSaveByPlayer[playerIndex])
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(selectedSaveByPlayer[playerIndex]->doubleExplosives);
}

void gsc_saveposition_getcheckpointid(int playerIndex)
{
    if(!isPlayerIndexValid(playerIndex))
    {
        stackPushUndefined();
        return;
    }
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
