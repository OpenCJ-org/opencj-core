#include "opencj_movement.hpp"
#ifdef COD4
#include "opencj_strafe_logic.hpp"
static CJ_StrafeState movement[MAX_CLIENTS];
static bool correctionEnabled[MAX_CLIENTS];
static unsigned corrections[MAX_CLIENTS];
static float removedGain[MAX_CLIENTS];
extern "C" void OpenCJ_PM_Accelerate(playerState_t *,const pml_t *,const float *,float,float);

extern "C" void opencj_resetMovement(int client)
{
    if(client<0||client>=MAX_CLIENTS)return;
    CJ_ResetStrafe(movement[client]);
}
extern "C" void opencj_initMovement(int client)
{
    if(client<0||client>=MAX_CLIENTS)return;
    opencj_resetMovement(client);correctionEnabled[client]=false;
    corrections[client]=0;removedGain[client]=0;
}
extern "C" void opencj_observeMovement(playerState_t *ps,const usercmd_t *cmd)
{
    if(!ps||!cmd||ps->clientNum<0||ps->clientNum>=MAX_CLIENTS)return;
    CJ_UpdateStrafe(movement[ps->clientNum],cmd->forwardmove,cmd->rightmove,
                    ps->pm_type==0&&ps->groundEntityNum==1023,cmd->serverTime);
}

// Called only at the original PM_AirMove acceleration site, before collision/
// bounce resolution. The reference uses the same engine function, player state,
// wish speed, view basis, dt and inertia settings; only W/S is added to A/D.
extern "C" void __attribute__((force_align_arg_pointer))
opencj_airAccelerate(pmove_t *pm,pml_t *pml,const float *wishdir,float wishspeed)
{
    playerState_t *ps=pm->ps;
    const int id=ps->clientNum;
    if(id<0||id>=MAX_CLIENTS) { OpenCJ_PM_Accelerate(ps,pml,wishdir,wishspeed,1);return; }
    CJ_UpdateStrafe(movement[id],pm->cmd.forwardmove,pm->cmd.rightmove,
                    ps->pm_type==0&&ps->groundEntityNum==1023,pm->cmd.serverTime);
    const int forward=movement[id].halfbeatForward;
    const bool eligible=correctionEnabled[id]&&forward&&ps->pm_type==0&&
        ps->groundEntityNum==1023&&!pml->groundPlane&&!pml->walking&&
        pml->frametime>0&&pml->frametime<=0.05f&&pm->cmd.forwardmove==0&&pm->cmd.rightmove!=0;
    if(!eligible) { OpenCJ_PM_Accelerate(ps,pml,wishdir,wishspeed,1);return; }

    playerState_t reference=*ps;
    float before[3]={ps->velocity[0],ps->velocity[1],ps->velocity[2]};
    float direction[3]={forward*pml->forward[0]+CJ_InputSign(pm->cmd.rightmove)*pml->right[0],
                        forward*pml->forward[1]+CJ_InputSign(pm->cmd.rightmove)*pml->right[1],0};
    const float length=hypotf(direction[0],direction[1]);
    OpenCJ_PM_Accelerate(ps,pml,wishdir,wishspeed,1);
    if(length<0.0001f)return;
    direction[0]/=length;direction[1]/=length;
    OpenCJ_PM_Accelerate(&reference,pml,direction,wishspeed,1);
    float removed=CJ_CapHalfbeatGain(before,reference.velocity,ps->velocity);
    if(removed>0) { ++corrections[id];removedGain[id]+=removed; }
}

extern "C" void opencj_setHalfbeatCorrection(int id,bool enabled)
{
    if(id<0||id>=MAX_CLIENTS)return;
    if(correctionEnabled[id]!=enabled)opencj_resetMovement(id);
    correctionEnabled[id]=enabled;
}
extern "C" void Gsc_Movement_SetHalfbeatCorrection(int id)
{
    if(id<0||id>=MAX_CLIENTS){stackPushUndefined();return;}
    int enabled=0;
    if(!stackGetParams("i",&enabled)){stackError("setHalfbeatCorrection(enabled)");return;}
    opencj_setHalfbeatCorrection(id,enabled!=0);stackPushBool(true);
}
extern "C" void Gsc_Movement_Reset(int id)
{
    opencj_resetMovement(id);opencj_invalidateMovementInput(id);stackPushBool(true);
}
extern "C" void Gsc_Movement_GetHalfbeatStats(int id)
{
    if(id<0||id>=MAX_CLIENTS){stackPushUndefined();return;}
    stackMakeArray();stackPushInt(corrections[id]);stackPushArrayNext();
    stackPushFloat(removedGain[id]);stackPushArrayNext();
    stackPushInt(movement[id].halfbeatForward);stackPushArrayNext();
}
extern "C" void Gsc_Movement_StrafeTransition()
{
    int af,ar,f,r;
    if(!stackGetParams("iiii",&af,&ar,&f,&r)){stackError("strafeTransition(anchorForward,anchorRight,forward,right)");return;}
    stackPushInt(CJ_StrafeTransition(af,ar,f,r));
}
#endif
