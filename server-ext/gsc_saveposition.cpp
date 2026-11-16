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
	opencj_save *prevsave;
	gentity_t *groundentity;
	vec3_t origin;
	vec3_t angles;
    int checkPointId;
    int explosiveJumps;
    int doubleExplosives;
    opencj_fps_mode FPSMode;
    int flags;
    int saveNum;
};

static const int SAVE_HISTORY_LIMIT=100;
static opencj_save *playersaves[MAX_CLIENTS];
static opencj_save *playersaves_selected[MAX_CLIENTS];
static opencj_save *playersaves_oldest[MAX_CLIENTS];
static int playersaves_count[MAX_CLIENTS];
static unsigned playersaves_generation[MAX_CLIENTS];

static void releaseSave(opencj_save *save)
{
    // A selected save may belong to another player.
    for(int i=0;i<MAX_CLIENTS;i++)
        if(playersaves_selected[i]==save)playersaves_selected[i]=NULL;
    free(save);
}

void gsc_saveposition_initclient(int id)
{
    opencj_save *save=playersaves[id];
    while(save)
    {
        opencj_save *older=save->prevsave;
        releaseSave(save);save=older;
    }
    playersaves[id]=playersaves_selected[id]=playersaves_oldest[id]=NULL;
    playersaves_count[id]=0;
    ++playersaves_generation[id];
}

static opencj_save *readSave()
{
    opencj_save *save=(opencj_save*)calloc(1,sizeof(opencj_save));
    if(!save)return NULL;
    stackGetParamVector(0,save->origin);
    stackGetParamVector(1,save->angles);
    if(stackGetParamType(2)==STACK_INT)
    {
        int entnum=-1;stackGetParamInt(2,&entnum);
        if(entnum>=0 && entnum<1024)save->groundentity=&g_entities[entnum];
    }
    stackGetParamInt(3,&save->explosiveJumps);
    stackGetParamInt(4,&save->doubleExplosives);
    save->checkPointId=-1;
    if(stackGetParamType(5)==STACK_INT)stackGetParamInt(5,&save->checkPointId);
    int fps=0;stackGetParamInt(6,&fps);save->FPSMode=(opencj_fps_mode)fps;
    stackGetParamInt(7,&save->flags);
    stackGetParamInt(8,&save->saveNum);
    return save;
}

void gsc_saveposition_save(int id)
{
    opencj_save *save=readSave();
    if(!save){stackPushUndefined();return;}
    save->prevsave=playersaves[id];playersaves[id]=save;
    if(!playersaves_oldest[id])playersaves_oldest[id]=save;
    ++playersaves_count[id];
    if(playersaves_count[id]>SAVE_HISTORY_LIMIT)
    {
        opencj_save *tail=playersaves[id];
        while(tail->prevsave && tail->prevsave->prevsave)tail=tail->prevsave;
        releaseSave(tail->prevsave);tail->prevsave=NULL;
        playersaves_oldest[id]=tail;--playersaves_count[id];
    }
    stackPushInt(0);
}

void gsc_saveposition_addolder(int id)
{
    if(playersaves_count[id]>=SAVE_HISTORY_LIMIT){stackPushInt(1);return;}
    int number=0;stackGetParamInt(8,&number);
    if(playersaves_oldest[id] && number>=playersaves_oldest[id]->saveNum)
    {stackPushInt(2);return;}
    opencj_save *save=readSave();
    if(!save){stackPushUndefined();return;}
    if(playersaves_oldest[id])playersaves_oldest[id]->prevsave=save;
    else playersaves[id]=save;
    playersaves_oldest[id]=save;++playersaves_count[id];
    stackPushInt(0);
}

void gsc_saveposition_historyinfo(int id)
{
    // count, oldest save number, generation, limit, newest save number.
    stackMakeArray();
    stackPushInt(playersaves_count[id]);stackPushArrayNext();
    if(playersaves_oldest[id])stackPushInt(playersaves_oldest[id]->saveNum);else stackPushUndefined();
    stackPushArrayNext();
    stackPushInt(playersaves_generation[id]);stackPushArrayNext();
    stackPushInt(SAVE_HISTORY_LIMIT);stackPushArrayNext();
    if(playersaves[id])stackPushInt(playersaves[id]->saveNum);else stackPushUndefined();
    stackPushArrayNext();
}

void gsc_saveposition_selectwithoutflag(int id) // player gsc_saveposition_selectwithoutflag(flags, [otherEntityNum])
{
    int flags = 0;
    stackGetParamInt(0, &flags);
    if (flags == 0)
    {
        stackPushUndefined();
        return;
    }

    // Player might be requesting it for a different player's saves (teleporting for example)
    int otherPlayerId = id; // By default, the requesting player
    if (Scr_GetNumParam() > 1)
    {
        stackGetParamInt(1, &otherPlayerId);
    }

    if(otherPlayerId<0 || otherPlayerId>=MAX_CLIENTS){stackPushUndefined();return;}

    // Select the last save that matches this criteria
    playersaves_selected[id] = playersaves[otherPlayerId];
    int backwardsCount = 0;
    while (playersaves_selected[id] != NULL)
    {
        // Check if this save matches the criteria of not having specific flags
        int saveFlags = playersaves_selected[id]->flags;
        if ((saveFlags & flags) == 0)
        {
            stackPushInt(backwardsCount); // Successfully found
            return;
        }

        // Check if there are any saves left
        if (playersaves_selected[id]->prevsave == NULL)
        {
            stackPushUndefined();
            return;
        }

        // Go back further
        playersaves_selected[id] = playersaves_selected[id]->prevsave;
        backwardsCount++;
    }
    stackPushUndefined();
}

void gsc_saveposition_selectsave(int id) //player savePosition_selectSave(backwardsCount)
{
	int backwardscount;
	stackGetParamInt(0, &backwardscount);
    if(backwardscount<0 || backwardscount>=SAVE_HISTORY_LIMIT){playersaves_selected[id]=NULL;stackPushInt(2);return;}
	if(playersaves[id] == NULL)
	{
		stackPushInt(1);
		return;
	}
	playersaves_selected[id] = playersaves[id];

	while(backwardscount)
	{
		if(playersaves_selected[id]->prevsave != NULL)
		{
			playersaves_selected[id] = playersaves_selected[id]->prevsave;
		}
		else
		{
			stackPushInt(2);
			return;
		}
		backwardscount--;
	}
    
	stackPushInt(0);
}

void gsc_saveposition_getangles(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
	stackPushVector(playersaves_selected[id]->angles);
}

void gsc_saveposition_getfpsmode(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
	stackPushInt(playersaves_selected[id]->FPSMode);
}

void gsc_saveposition_getorigin(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
	stackPushVector(playersaves_selected[id]->origin);
}

void gsc_saveposition_getsavenum(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
	stackPushInt(playersaves_selected[id]->saveNum);
}

void gsc_saveposition_getflags(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
	stackPushInt(playersaves_selected[id]->flags);
}

void gsc_saveposition_getcheatstatus(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
	stackPushVector(playersaves_selected[id]->origin);
}

void gsc_saveposition_getgroundentity(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
	if(playersaves_selected[id]->groundentity == NULL)
		stackPushUndefined();
	else
		stackPushEntity(playersaves_selected[id]->groundentity);
}

void gsc_saveposition_getexplosivejumps(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
    stackPushInt(playersaves_selected[id]->explosiveJumps);
}

void gsc_saveposition_getdoubleexplosives(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
    stackPushInt(playersaves_selected[id]->doubleExplosives);
}

void gsc_saveposition_getcheckpointid(int id)
{
    if(!playersaves_selected[id]){stackPushUndefined();return;}
    if(playersaves_selected[id]->checkPointId != -1)
    {
        stackPushInt(playersaves_selected[id]->checkPointId);
    }
    else
    {
        stackPushUndefined();
    }
}

#ifdef __cplusplus
}
#endif // __cplusplus
