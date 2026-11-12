#include "opencj_movement.hpp"
#ifdef COD4
#include "opencj_strafe_logic.hpp"

extern "C" void Gsc_Movement_Reset(int id)
{
    opencj_invalidateMovementInput(id);stackPushBool(true);
}
extern "C" void Gsc_Movement_StrafeTransition()
{
    int af,ar,f,r;
    if(!stackGetParams("iiii",&af,&ar,&f,&r)){stackError("strafeTransition(anchorForward,anchorRight,forward,right)");return;}
    stackPushInt(CJ_StrafeTransition(af,ar,f,r));
}
#endif
