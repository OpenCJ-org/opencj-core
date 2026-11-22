#ifndef OPENCJ_STRAFE_LOGIC_HPP
#define OPENCJ_STRAFE_LOGIC_HPP
#include <math.h>
#include <string.h>

inline int CJ_InputSign(int value)
{
    return (value > 0) - (value < 0);
}

// 1 = phase switch, 2 = halfbeat single-key phase, 4 = backward counterpart.
// Adjacent directions (WA -> A, WA -> W) are adjustments, not phase switches.
inline int CJ_StrafeTransition(int af, int ar, int f, int r)
{
    af = CJ_InputSign(af);
    ar = CJ_InputSign(ar);
    f = CJ_InputSign(f);
    r = CJ_InputSign(r);
    if ((!af && !ar) || (!f && !r) || af * f + ar * r > 0) {
        return 0;
    }
    int flags = 1;
    if (!f && r && af && ar == -r) {
        flags |= 2 | (af < 0 ? 4 : 0);
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
    int time;
};

inline void CJ_ResetStrafe(CJ_StrafeState &state)
{
    memset(&state, 0, sizeof(state));
}

inline int CJ_UpdateStrafe(CJ_StrafeState &s, int forward, int right, bool airborne, int time)
{
    int f = CJ_InputSign(forward);
    int r = CJ_InputSign(right);
    if (!s.valid || time < s.time || time - s.time > 250 || !airborne || !s.airborne) {
        s.valid = true;
        s.airborne = airborne;
        s.anchorForward = f;
        s.anchorRight = r;
        s.forward = f;
        s.right = r;
        s.halfbeatForward = 0;
        s.time = time;
        return 0;
    }
    int flags = 0;
    if (f != s.forward || r != s.right) {
        flags = CJ_StrafeTransition(s.anchorForward, s.anchorRight, f, r);
        if (flags & 1) {
            s.anchorForward = f;
            s.anchorRight = r;
            s.halfbeatForward = (flags & 2) ? ((flags & 4) ? -1 : 1) : 0;
        } else if (!f && !r) {
            s.halfbeatForward = 0;
        } else if (f || r != s.right) {
            s.halfbeatForward = 0;
        }
        if ((f && r) || (!s.anchorForward && !s.anchorRight)) {
            s.anchorForward = f;
            s.anchorRight = r;
        }
        s.forward = f;
        s.right = r;
    }
    s.time = time;
    s.airborne = airborne;
    return flags;
}

// Compare actual acceleration with the engine's fullbeat result. Preserve
// pre-existing momentum, actual steering direction and all vertical velocity.
inline float CJ_CapHalfbeatGain(const float *before, const float *reference, float *actual)
{
    float prior = hypotf(before[0], before[1]);
    float allowed = fmaxf(prior, hypotf(reference[0], reference[1]));
    float speed = hypotf(actual[0], actual[1]);
    if (!isfinite(prior) || !isfinite(allowed) || !isfinite(speed) || speed <= allowed + 0.0001f ||
        speed <= 0) {
        return 0;
    }
    float scale = allowed / speed;
    actual[0] *= scale;
    actual[1] *= scale;
    return speed - allowed;
}
#endif
