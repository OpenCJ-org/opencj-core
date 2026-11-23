#ifndef OPENCJ_STRAFE_LOGIC_HPP
#define OPENCJ_STRAFE_LOGIC_HPP
#include <math.h>
#include <string.h>

// These flag values are also returned by the strafeTransition GSC function.
enum CJ_StrafeTransitionFlags {
    CJ_STRAFE_PHASE_SWITCH = 1,
    CJ_STRAFE_HALFBEAT = 2,
    CJ_STRAFE_BACKWARD = 4
};

// A long command gap no longer describes one continuous strafe.
static constexpr int CJ_STRAFE_MAX_COMMAND_GAP_MS = 250;
static constexpr float CJ_HALFBEAT_SPEED_TOLERANCE = 0.0001f;

inline int CJ_InputSign(int value)
{
    return (value > 0) - (value < 0);
}

// Compare key directions and return the phase flags. Adjacent directions
// (WA -> A, WA -> W) are adjustments, not phase switches.
inline int CJ_StrafeTransition(int anchorForward, int anchorRight, int forward, int right)
{
    anchorForward = CJ_InputSign(anchorForward);
    anchorRight = CJ_InputSign(anchorRight);
    forward = CJ_InputSign(forward);
    right = CJ_InputSign(right);
    const bool missingDirection = (!anchorForward && !anchorRight) || (!forward && !right);
    const bool adjacentDirection = anchorForward * forward + anchorRight * right > 0;
    if (missingDirection || adjacentDirection) {
        return 0;
    }

    int flags = CJ_STRAFE_PHASE_SWITCH;
    const bool oppositeSingleKey = !forward && right && anchorForward && anchorRight == -right;
    if (oppositeSingleKey) {
        flags |= CJ_STRAFE_HALFBEAT;
        if (anchorForward < 0) {
            flags |= CJ_STRAFE_BACKWARD;
        }
    }
    return flags;
}

struct CJ_StrafeState {
    bool valid;
    bool airborne;
    int anchorForward;
    int anchorRight;
    int forward;
    int right;
    int halfbeatForward;
    int commandTimeMs;
};

inline void CJ_ResetStrafe(CJ_StrafeState &state)
{
    memset(&state, 0, sizeof(state));
}

// Track phase changes within one airborne sequence. Landing, a rewind or a
// command gap starts a new sequence so an old halfbeat cannot affect movement.
inline int CJ_UpdateStrafe(CJ_StrafeState &state, int forward, int right, bool airborne,
                           int commandTimeMs)
{
    const int forwardSign = CJ_InputSign(forward);
    const int rightSign = CJ_InputSign(right);
    const bool commandGap =
        state.valid && (commandTimeMs < state.commandTimeMs ||
                        commandTimeMs - state.commandTimeMs > CJ_STRAFE_MAX_COMMAND_GAP_MS);
    const bool continuousFlight = airborne && state.airborne;
    if (!state.valid || commandGap || !continuousFlight) {
        state.valid = true;
        state.airborne = airborne;
        state.anchorForward = forwardSign;
        state.anchorRight = rightSign;
        state.forward = forwardSign;
        state.right = rightSign;
        state.halfbeatForward = 0;
        state.commandTimeMs = commandTimeMs;
        return 0;
    }

    int flags = 0;
    if (forwardSign != state.forward || rightSign != state.right) {
        flags = CJ_StrafeTransition(state.anchorForward, state.anchorRight, forwardSign, rightSign);
        if (flags & CJ_STRAFE_PHASE_SWITCH) {
            state.anchorForward = forwardSign;
            state.anchorRight = rightSign;
            state.halfbeatForward = 0;
            if (flags & CJ_STRAFE_HALFBEAT) {
                state.halfbeatForward = (flags & CJ_STRAFE_BACKWARD) ? -1 : 1;
            }
        } else if (!forwardSign && !rightSign) {
            state.halfbeatForward = 0;
        } else if (forwardSign || rightSign != state.right) {
            state.halfbeatForward = 0;
        }
        if ((forwardSign && rightSign) || (!state.anchorForward && !state.anchorRight)) {
            state.anchorForward = forwardSign;
            state.anchorRight = rightSign;
        }
        state.forward = forwardSign;
        state.right = rightSign;
    }
    state.commandTimeMs = commandTimeMs;
    state.airborne = airborne;
    return flags;
}

// Compare actual acceleration with the engine's fullbeat result. Preserve
// pre-existing momentum, actual steering direction and all vertical velocity.
// Non-finite speeds leave the input velocity unchanged and report no correction.
inline float CJ_CapHalfbeatGain(const float *priorVelocity, const float *referenceVelocity,
                                float *actualVelocity)
{
    const float priorSpeed = hypotf(priorVelocity[0], priorVelocity[1]);
    const float allowedSpeed =
        fmaxf(priorSpeed, hypotf(referenceVelocity[0], referenceVelocity[1]));
    const float actualSpeed = hypotf(actualVelocity[0], actualVelocity[1]);
    const bool finiteSpeeds =
        isfinite(priorSpeed) && isfinite(allowedSpeed) && isfinite(actualSpeed);
    if (!finiteSpeeds || actualSpeed <= allowedSpeed + CJ_HALFBEAT_SPEED_TOLERANCE ||
        actualSpeed <= 0) {
        return 0;
    }

    const float speedScale = allowedSpeed / actualSpeed;
    actualVelocity[0] *= speedScale;
    actualVelocity[1] *= speedScale;
    return actualSpeed - allowedSpeed;
}
#endif
