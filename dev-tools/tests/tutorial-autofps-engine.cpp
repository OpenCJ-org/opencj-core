// Engine plugin test for the tutorial auto-FPS rule (server-ext/opencj_autofps.cpp).
// Runs inside an isolated server built with that file, because the rule uses the
// engine's own air acceleration. Calls the shipped selection function on
// synthetic player states; it does not send anything to a client.
// The module header declares the rule and brings in the engine types.
#include "/workspace/server-ext/opencj_autofps.hpp"
#include "/workspace/cod4x-server/plugins/plugin_declarations.h"
#include <string.h>
#include <limits.h>

extern "C"
{
void Plugin_Printf(const char *format, ...);
int Plugin_Cvar_VariableIntegerValue(const char *name);
}

static const int GROUND_ENTITY_NONE = 1023;
static const int GROUND_ENTITY_WORLD = 1022;
static const int PLAYER_SPEED = 190;
// Vertical speed of a normal jump, 371 ms from its peak at 333 FPS.
static const float JUMP_TAKEOFF_SPEED = 247.0f;
// Vertical speed just after a typical bounce.
static const float BOUNCE_CLIMB_SPEED = 900.0f;

static int checks;
static int failures;

static void check(bool passed, const char *label, int got)
{
    ++checks;
    if (passed)
    {
        Plugin_Printf("TUTORIAL AUTOFPS PASS: %s\n", label);
        return;
    }
    ++failures;
    Plugin_Printf("TUTORIAL AUTOFPS FAIL: %s (got %d)\n", label, got);
}

static playerState_t playerState(int groundEntity, float verticalSpeed)
{
    playerState_t state;
    memset(&state, 0, sizeof(state));
    state.pm_type = 0;
    state.speed = PLAYER_SPEED;
    state.gravity = 800;
    state.groundEntityNum = groundEntity;
    state.velocity[0] = 250;
    state.velocity[1] = 100;
    state.velocity[2] = verticalSpeed;
    state.oldVelocity[0] = 250;
    state.oldVelocity[1] = 100;
    state.viewangles[1] = 30;
    return state;
}

static usercmd_t command(int forwardMove, int rightMove)
{
    usercmd_t cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.forwardmove = forwardMove;
    cmd.rightmove = rightMove;
    return cmd;
}

static bool isFrameRate(int frameRate)
{
    return frameRate == 333 || frameRate == 250 || frameRate == 125;
}

static void runTests()
{
    usercmd_t strafe = command(127, 127);
    usercmd_t noKeys = command(0, 0);

    // Standing: 333, and standing ends any RPG push rise.
    bool inPushRise = true;
    playerState_t standing = playerState(GROUND_ENTITY_WORLD, 0);
    int chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &standing, &strafe, 0);
    check(chosen == 333, "standing gets 333", chosen);
    check(!inPushRise, "standing ends a push rise", inPushRise);

    // A normal jump is not a push rise: the air choice is the fastest of all three.
    playerState_t rising = playerState(GROUND_ENTITY_NONE, JUMP_TAKEOFF_SPEED);
    chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &rising, &strafe, 50);
    check(isFrameRate(chosen), "a normal jump gets the fastest frame rate", chosen);
    check(!inPushRise, "a normal jump does not start a push rise", inPushRise);

    // RPG push rise: 333 while the peak is beyond the lead, then it ends.
    inPushRise = true;
    chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &rising, &strafe, 50);
    check(chosen == 333, "push rise with peak beyond lead keeps 333", chosen);
    check(inPushRise, "push rise continues", inPushRise);
    chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &rising, &strafe, 400);
    check(isFrameRate(chosen), "lead past the peak ends the push rise", chosen);
    check(!inPushRise, "push rise ended", inPushRise);

    // Falling without movement keys: nothing to compare, keep 250.
    playerState_t falling = playerState(GROUND_ENTITY_NONE, -300);
    chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &falling, &noKeys, 0);
    check(chosen == 250, "falling without keys gets 250", chosen);

    // A strafe switch from a recorded mp_futile_fixed attempt (2026-11-22): W+A
    // just after switching from W+D. Replaying the player's own mouse through
    // the engine, 333 gained the most speed (and the player chose 333 there);
    // the earlier 240 ms held-view comparison picked 250.
    playerState_t strafeSwitch = playerState(GROUND_ENTITY_NONE, -823);
    strafeSwitch.pm_flags = 16384;
    strafeSwitch.velocity[0] = 297;
    strafeSwitch.velocity[1] = -505;
    strafeSwitch.oldVelocity[0] = 245.0117f;
    strafeSwitch.oldVelocity[1] = -373.8143f;
    strafeSwitch.viewangles[1] = -28.3228f;
    usercmd_t forwardLeft = command(127, -127);
    chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &strafeSwitch, &forwardLeft, 0);
    check(chosen == 333, "recorded strafe switch gets 333", chosen);

    // Landing returns to 333.
    chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &standing, &strafe, 0);
    check(chosen == 333, "landing returns to 333", chosen);

    // Upward gains over one command (bounce or push). Values from the dev
    // server log: a bounce at -920 -> 942, an RPG while climbing 916 -> 975.
    check(opencj_autoFpsIsUpwardGain(-920, 942), "bounce is an upward gain", 1);
    check(opencj_autoFpsIsUpwardGain(916, 975), "RPG while climbing is an upward gain", 1);
    check(!opencj_autoFpsIsUpwardGain(-961, -701), "slowing a fall without rising is no gain", 0);
    check(!opencj_autoFpsIsUpwardGain(200, 230), "small upward change is ignored", 0);
    check(!opencj_autoFpsIsUpwardGain(300, 298), "gravity is no gain", 0);

    // A gain is an RPG push only near a shot, before or after it.
    check(opencj_autoFpsIsWithinRPGWindow(1000, 1300), "gain 300 ms after shot is linked", 1);
    check(opencj_autoFpsIsWithinRPGWindow(1300, 1000), "shot 300 ms after gain is linked", 1);
    check(opencj_autoFpsIsWithinRPGWindow(1000, 1500), "500 ms is still linked", 1);
    check(!opencj_autoFpsIsWithinRPGWindow(1000, 1501), "over 500 ms is not linked", 0);

    check(!opencj_autoFpsIsWithinRPGWindow(INT_MIN, 0), "distant times cannot overflow into a push", 0);
    check(!opencj_autoFpsIsWithinRPGWindow(0, INT_MIN), "reversed distant times remain unrelated", 0);
    check(!opencj_autoFpsIsWithinRPGWindow(INT_MIN, INT_MAX), "opposite integer limits remain unrelated", 0);
    check(opencj_autoFpsIsWithinRPGWindow(INT_MAX - 500, INT_MAX), "nearby upper-limit times still link", 1);
    check(opencj_autoFpsIsWithinRPGWindow(INT_MIN, INT_MIN + 500), "nearby lower-limit times still link", 1);

    // After a push the rule treats the climb as a new rise: 333 for height.
    inPushRise = true;
    playerState_t pushed = playerState(GROUND_ENTITY_NONE, BOUNCE_CLIMB_SPEED);
    chosen = opencj_autoFpsChooseFrameRate(&inPushRise, &pushed, &strafe, 50);
    check(chosen == 333, "climb after a push gets 333", chosen);

    // Arrival height at 400 units/s along +x, climbing at 300 from z 1000.
    // After 340 units (0.85 s): z 984 at 250/125 (gravity 750), z 1014 at 333 (666).
    // After 200 units (0.5 s): above 1000 either way. After 800 units (2 s): far
    // below either way, so the FPS cannot make the difference.
    playerState_t flying = playerState(GROUND_ENTITY_NONE, 300);
    flying.origin[2] = 1000;
    flying.velocity[0] = 400;
    flying.velocity[1] = 0;
    const float decidingTarget[3] = {340, 0, 1000};
    const float nearTarget[3] = {200, 0, 1000};
    const float farTarget[3] = {800, 0, 1000};
    const float behindTarget[3] = {-340, 0, 1000};
    const float overheadTarget[3] = {10, 0, 1200};
    check(opencj_autoFpsNeedsHeight(&flying, decidingTarget), "333 needed when only 333 arrives high enough", 1);
    check(!opencj_autoFpsNeedsHeight(&flying, nearTarget), "not needed when 250 arrives high enough", 0);
    check(!opencj_autoFpsNeedsHeight(&flying, farTarget), "not needed when even 333 falls short", 0);
    check(!opencj_autoFpsNeedsHeight(&flying, behindTarget), "a checkpoint behind gives no answer", 0);
    check(!opencj_autoFpsNeedsHeight(&flying, overheadTarget), "a checkpoint already reached gives no answer", 0);
    // Falling counts too: after 200 units (0.5 s) z 856 at 250/125, z 867 at 333.
    playerState_t descending = playerState(GROUND_ENTITY_NONE, -100);
    descending.origin[2] = 1000;
    descending.velocity[0] = 400;
    descending.velocity[1] = 0;
    const float lowerTarget[3] = {200, 0, 860};
    check(opencj_autoFpsNeedsHeight(&descending, lowerTarget), "falling: 333 hang time reaches a lower checkpoint", 1);
    // Just after the bounce of a recorded no-RPG attempt on mp_futile_fixed
    // (2026-11-22), 2780 units from the next checkpoint (z -3705). At the current
    // horizontal speed even 333 would arrive too low, but the player speeds up;
    // the peak decides: at 250 it is z -3815, below the checkpoint, at 333 z -3608.
    playerState_t bounced = playerState(GROUND_ENTITY_NONE, 1572);
    bounced.origin[0] = 11063;
    bounced.origin[1] = -9814;
    bounced.origin[2] = -5463;
    bounced.velocity[0] = 460;
    bounced.velocity[1] = -573;
    const float nextCheckpoint[3] = {13158, -11635, -3705};
    const float unreachableCheckpoint[3] = {13158, -11635, -3500};
    const float lowCheckpoint[3] = {13158, -11635, -3870};
    check(opencj_autoFpsNeedsHeight(&bounced, nextCheckpoint), "recorded bounce: 333 when only its peak reaches the checkpoint", 1);
    check(!opencj_autoFpsNeedsHeight(&bounced, unreachableCheckpoint), "no 333 when even its peak stays below", 0);
    check(!opencj_autoFpsNeedsHeight(&bounced, lowCheckpoint), "no 333 when the 250 peak clears it by the margin", 0);
    // RPG climb of a recorded attempt that landed (mp_futile_fixed, 2026-11-22),
    // 3.8 s in: z -3999 climbing at 807, 769 units/s towards the landing edge
    // 1436 units away at z -3706. Gaining 171 units/s^2 at 250 it arrives about
    // 1.59 s later at z -3663 (43 above), so 333 is no longer needed; without
    // that gain it would arrive at z -3799, too low.
    playerState_t rpgClimb = playerState(GROUND_ENTITY_NONE, 807);
    rpgClimb.origin[0] = 0;
    rpgClimb.origin[1] = 0;
    rpgClimb.origin[2] = -3999;
    rpgClimb.velocity[0] = 769;
    rpgClimb.velocity[1] = 0;
    const float landingEdge[3] = {1436, 0, -3706};
    const float edgeBehind[3] = {-1436, 0, -3706};
    check(opencj_autoFpsArrivesHighEnoughAt250(&rpgClimb, landingEdge, 171), "RPG climb: 250 with its speed gain reaches the edge", 1);
    check(!opencj_autoFpsArrivesHighEnoughAt250(&rpgClimb, landingEdge, 0), "RPG climb: without a speed gain 250 is too low", 0);
    check(!opencj_autoFpsArrivesHighEnoughAt250(&rpgClimb, edgeBehind, 171), "an edge behind gives no answer", 0);
    playerState_t standingNear = playerState(GROUND_ENTITY_WORLD, 0);
    check(!opencj_autoFpsNeedsHeight(&standingNear, farTarget), "a standing player never needs height", 0);

    Plugin_Printf("TUTORIAL AUTOFPS COMPLETE failures=%d checks=%d\n", failures, checks);
}

extern "C" int OnInit()
{
    return 0;
}

extern "C" void OnInfoRequest(pluginInfo_t *info)
{
    memset(info, 0, sizeof(*info));
    info->handlerVersion.major = PLUGIN_HANDLER_VERSION_MAJOR;
    strcpy(info->fullName, "OpenCJ tutorial auto-FPS rule test");
    info->pluginVersion.major = 1;
}

// Waits until the map runs so the engine's movement tables are initialized.
extern "C" void OnFrame()
{
    static int framesRunning = 0;
    static bool testsDone = false;
    if (testsDone || Plugin_Cvar_VariableIntegerValue("sv_running") == 0)
    {
        return;
    }
    ++framesRunning;
    if (framesRunning < 20)
    {
        return;
    }
    testsDone = true;
    runTests();
}
