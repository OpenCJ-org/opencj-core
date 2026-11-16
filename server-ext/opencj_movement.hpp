#ifndef OPENCJ_MOVEMENT_HPP
#define OPENCJ_MOVEMENT_HPP
#ifdef COD4
#include "shared.hpp"
extern "C" {
void opencj_resetMovement(int client);
void opencj_initMovement(int client);
void opencj_invalidateMovementInput(int client);
void opencj_setHalfbeatCorrection(int client,bool enabled);
void opencj_observeMovement(playerState_t *ps,const usercmd_t *cmd);
void opencj_airAccelerate(pmove_t *pm,pml_t *pml,const float *wishdir,float wishspeed);
void Gsc_Movement_SetHalfbeatCorrection(int id);
void Gsc_Movement_Reset(int id);
void Gsc_Movement_GetHalfbeatStats(int id);
void Gsc_Movement_StrafeTransition();
}
#endif
#endif
