#ifndef OPENCJ_STRAFE_LOGIC_HPP
#define OPENCJ_STRAFE_LOGIC_HPP

inline int CJ_InputSign(int value) { return (value > 0) - (value < 0); }

// 1 = phase switch, 2 = halfbeat single-key phase, 4 = backward counterpart.
// Adjacent directions (WA -> A, WA -> W) are adjustments, not phase switches.
inline int CJ_StrafeTransition(int af, int ar, int f, int r)
{
    af=CJ_InputSign(af); ar=CJ_InputSign(ar); f=CJ_InputSign(f); r=CJ_InputSign(r);
    if ((!af && !ar) || (!f && !r) || af*f+ar*r>0) return 0;
    int flags=1;
    if (!f && r && af && ar==-r) flags|=2|(af<0 ? 4:0);
    return flags;
}

#endif
