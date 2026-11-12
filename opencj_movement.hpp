#ifndef OPENCJ_MOVEMENT_HPP
#define OPENCJ_MOVEMENT_HPP
#ifdef COD4
#include "shared.hpp"
extern "C" {
void opencj_invalidateMovementInput(int client);
void Gsc_Movement_Reset(int id);
void Gsc_Movement_StrafeTransition();
}
#endif
#endif
