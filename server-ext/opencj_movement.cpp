#include "opencj_movement.hpp"
#ifdef COD4
#include "opencj_strafe_logic.hpp"
#include "opencj_autofps.hpp"
static CJ_StrafeState strafeByClient[MAX_CLIENTS];
static bool correctionEnabledByClient[MAX_CLIENTS];
static unsigned correctionCountByClient[MAX_CLIENTS];
static float removedSpeedByClient[MAX_CLIENTS];
// Match PM_AirMove's acceleration and reject unusually long simulation steps.
static constexpr int NORMAL_MOVEMENT_TYPE = 0;
static constexpr float AIR_ACCELERATION = 1.0f;
static constexpr float MAX_CORRECTION_FRAME_SECONDS = 0.05f;
static constexpr float MIN_REFERENCE_DIRECTION_LENGTH = 0.0001f;

extern "C" void OpenCJ_PM_Accelerate(playerState_t *playerState, const pml_t *movementFrame,
                                     const float *wishDirection, float wishSpeed,
                                     float acceleration);

extern "C" void opencj_resetMovement(int clientNum)
{
    if (clientNum < 0 || clientNum >= MAX_CLIENTS) {
        return;
    }
    CJ_ResetStrafe(strafeByClient[clientNum]);
}

// Start a new player session with correction disabled and empty statistics.
extern "C" void opencj_initMovement(int clientNum)
{
    if (clientNum < 0 || clientNum >= MAX_CLIENTS) {
        return;
    }
    opencj_resetMovement(clientNum);
    correctionEnabledByClient[clientNum] = false;
    opencj_autoFpsInitClient(clientNum);
    correctionCountByClient[clientNum] = 0;
    removedSpeedByClient[clientNum] = 0;
}

extern "C" void opencj_observeMovement(playerState_t *playerState, const usercmd_t *command)
{
    if (!playerState || !command || playerState->clientNum < 0 ||
        playerState->clientNum >= MAX_CLIENTS) {
        return;
    }
    // Runs after this command moved the player, so the state is current.
    opencj_autoFpsObserve(playerState, command);
    CJ_UpdateStrafe(strafeByClient[playerState->clientNum], command->forwardmove,
                    command->rightmove,
                    playerState->pm_type == NORMAL_MOVEMENT_TYPE &&
                        playerState->groundEntityNum == ENTITYNUM_NONE,
                    command->serverTime);
}

// Called only at the original PM_AirMove acceleration site, before collision/
// bounce resolution. The engine owns these pointers for the duration of the call.
// The reference uses the same engine function, player state, wish speed, view
// basis, frame duration and inertia settings; only W/S is added to A/D.
extern "C" void __attribute__((force_align_arg_pointer))
opencj_airAccelerate(pmove_t *movementContext, pml_t *movementFrame, const float *wishDirection,
                     float wishSpeed)
{
    playerState_t *playerState = movementContext->ps;
    const int clientNum = playerState->clientNum;
    if (clientNum < 0 || clientNum >= MAX_CLIENTS) {
        OpenCJ_PM_Accelerate(playerState, movementFrame, wishDirection, wishSpeed,
                             AIR_ACCELERATION);
        return;
    }
    CJ_UpdateStrafe(strafeByClient[clientNum], movementContext->cmd.forwardmove,
                    movementContext->cmd.rightmove,
                    playerState->pm_type == NORMAL_MOVEMENT_TYPE &&
                        playerState->groundEntityNum == ENTITYNUM_NONE,
                    movementContext->cmd.serverTime);
    const int forward = strafeByClient[clientNum].halfbeatForward;
    const bool airborne = playerState->pm_type == NORMAL_MOVEMENT_TYPE &&
                          playerState->groundEntityNum == ENTITYNUM_NONE &&
                          !movementFrame->groundPlane && !movementFrame->walking;
    const bool boundedFrame =
        movementFrame->frametime > 0 && movementFrame->frametime <= MAX_CORRECTION_FRAME_SECONDS;
    const bool singleKeyPhase =
        forward && movementContext->cmd.forwardmove == 0 && movementContext->cmd.rightmove != 0;
    const bool eligible =
        correctionEnabledByClient[clientNum] && airborne && boundedFrame && singleKeyPhase;
    if (!eligible) {
        OpenCJ_PM_Accelerate(playerState, movementFrame, wishDirection, wishSpeed,
                             AIR_ACCELERATION);
        return;
    }

    playerState_t referenceState = *playerState;
    float priorVelocity[3] = {playerState->velocity[0], playerState->velocity[1],
                              playerState->velocity[2]};
    float referenceDirection[3] = {
        forward * movementFrame->forward[0] +
            CJ_InputSign(movementContext->cmd.rightmove) * movementFrame->right[0],
        forward * movementFrame->forward[1] +
            CJ_InputSign(movementContext->cmd.rightmove) * movementFrame->right[1],
        0};
    const float referenceLength = hypotf(referenceDirection[0], referenceDirection[1]);
    OpenCJ_PM_Accelerate(playerState, movementFrame, wishDirection, wishSpeed, AIR_ACCELERATION);
    if (referenceLength < MIN_REFERENCE_DIRECTION_LENGTH) {
        return;
    }
    referenceDirection[0] /= referenceLength;
    referenceDirection[1] /= referenceLength;
    OpenCJ_PM_Accelerate(&referenceState, movementFrame, referenceDirection, wishSpeed,
                         AIR_ACCELERATION);
    float removedSpeed =
        CJ_CapHalfbeatGain(priorVelocity, referenceState.velocity, playerState->velocity);
    if (removedSpeed > 0) {
        ++correctionCountByClient[clientNum];
        removedSpeedByClient[clientNum] += removedSpeed;
    }
}

extern "C" void opencj_setHalfbeatCorrection(int clientNum, bool enabled)
{
    if (clientNum < 0 || clientNum >= MAX_CLIENTS) {
        return;
    }
    if (correctionEnabledByClient[clientNum] != enabled) {
        opencj_resetMovement(clientNum);
    }
    correctionEnabledByClient[clientNum] = enabled;
}

extern "C" void Gsc_Movement_SetHalfbeatCorrection(int clientNum)
{
    if (clientNum < 0 || clientNum >= MAX_CLIENTS) {
        stackPushUndefined();
        return;
    }
    int enabled = 0;
    if (!stackGetParams("i", &enabled)) {
        stackError("setHalfbeatCorrection(enabled)");
        return;
    }
    opencj_setHalfbeatCorrection(clientNum, enabled != 0);
    stackPushBool(true);
}

extern "C" void Gsc_Movement_Reset(int clientNum)
{
    opencj_resetMovement(clientNum);
    opencj_invalidateMovementInput(clientNum);
    stackPushBool(true);
}

// GSC result order: correction count, removed horizontal speed, forward counterpart.
extern "C" void Gsc_Movement_GetHalfbeatStats(int clientNum)
{
    if (clientNum < 0 || clientNum >= MAX_CLIENTS) {
        stackPushUndefined();
        return;
    }
    stackMakeArray();
    stackPushInt(correctionCountByClient[clientNum]);
    stackPushArrayNext();
    stackPushFloat(removedSpeedByClient[clientNum]);
    stackPushArrayNext();
    stackPushInt(strafeByClient[clientNum].halfbeatForward);
    stackPushArrayNext();
}

extern "C" void Gsc_Movement_StrafeTransition()
{
    int anchorForward;
    int anchorRight;
    int forward;
    int right;
    if (!stackGetParams("iiii", &anchorForward, &anchorRight, &forward, &right)) {
        stackError("strafeTransition(anchorForward,anchorRight,forward,right)");
        return;
    }
    stackPushInt(CJ_StrafeTransition(anchorForward, anchorRight, forward, right));
}
#endif
