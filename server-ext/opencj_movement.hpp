#ifndef OPENCJ_MOVEMENT_HPP
#define OPENCJ_MOVEMENT_HPP
#ifdef COD4
#include "shared.hpp"
extern "C" {
void opencj_resetMovement(int clientNum);
void opencj_initMovement(int clientNum);
void opencj_invalidateMovementInput(int clientNum);
void opencj_setHalfbeatCorrection(int clientNum, bool enabled);
void opencj_observeMovement(playerState_t *playerState, const usercmd_t *command);
void opencj_airAccelerate(pmove_t *movementContext, pml_t *movementFrame,
                          const float *wishDirection, float wishSpeed);
void Gsc_Movement_SetHalfbeatCorrection(int clientNum);
void Gsc_Movement_Reset(int clientNum);
void Gsc_Movement_GetHalfbeatStats(int clientNum);
void Gsc_Movement_StrafeTransition();
}
#endif
#endif
