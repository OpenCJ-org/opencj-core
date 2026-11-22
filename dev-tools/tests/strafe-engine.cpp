// Isolated test plugin; never loaded into the production runtime.
#include "../../server-ext/opencj_movement.hpp"
#include "../../cod4x-server/src/opencj_main.hpp"
#include "../../server-ext/opencj_strafe_logic.hpp"
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <math.h>
#include <string.h>
extern "C" {
void Plugin_Printf(const char *, ...);
client_t *Plugin_GetClientForClientNum(int);
int Plugin_Cvar_VariableIntegerValue(const char *);
void OpenCJ_PM_Accelerate(playerState_t *, const pml_t *, const float *, float, float);
}
static int checks;
static int failures;
static void check(bool ok, const char *name) {
    ++checks;
    if (!ok) {
        ++failures;
    }
    Plugin_Printf("STRAFE NATIVE CHECK %d: %s\n", ok, name);
}
static bool same(const float *a, const float *b) {
    return fabsf(a[0] - b[0]) < 0.0001f && fabsf(a[1] - b[1]) < 0.0001f && a[2] == b[2];
}
static void setup(playerState_t &ps, pmove_t &pm, pml_t &pml, float rotation, float speed, float dt,
                  int right = 1, int forward = 1) {
    memset(&ps, 0, sizeof(ps));
    memset(&pm, 0, sizeof(pm));
    memset(&pml, 0, sizeof(pml));
    ps.clientNum = 63;
    ps.speed = 190;
    ps.groundEntityNum = 1023;
    float a = rotation * 0.01745329252f;
    float view = a + (forward < 0 ? 3.14159265359f : 0) + forward * right * 0.2f;
    ps.velocity[0] = speed * cosf(a);
    ps.velocity[1] = speed * sinf(a);
    ps.velocity[2] = 700;
    ps.oldVelocity[0] = ps.velocity[0];
    ps.oldVelocity[1] = ps.velocity[1];
    pml.forward[0] = cosf(view);
    pml.forward[1] = sinf(view);
    pml.right[0] = sinf(view);
    pml.right[1] = -cosf(view);
    pml.frametime = dt;
    pml.msec = int(dt * 1000);
    pm.ps = &ps;
    pm.cmd.serverTime = 1004;
    pm.cmd.rightmove = right * 127;
}
static void seed(playerState_t &ps, pmove_t &pm, bool enabled, int af = 1, int ar = -1) {
    opencj_initMovement(63);
    opencj_setHalfbeatCorrection(63, enabled);
    usercmd_t previous = pm.cmd;
    previous.serverTime = 1000;
    previous.forwardmove = 127 * af;
    previous.rightmove = 127 * ar;
    opencj_observeMovement(&ps, &previous);
}
static void run() {
    check(CJ_StrafeTransition(1, -1, 1, 1) == 1, "WA to WD is fullbeat");
    check(CJ_StrafeTransition(1, -1, 0, 1) == 3, "WA to D is halfbeat");
    check(CJ_StrafeTransition(1, 1, 0, -1) == 3, "WD to A is halfbeat");
    check(CJ_StrafeTransition(-1, -1, 0, 1) == 7, "backward halfbeat retains S counterpart");
    check(CJ_StrafeTransition(1, -1, 0, -1) == 0, "WA to A is a landing adjustment");
    check(CJ_StrafeTransition(1, 1, 0, 1) == 0, "WD to D is a landing adjustment");
    check(CJ_StrafeTransition(1, -1, 1, 0) == 0, "release to W is not a switch");
    check(CJ_StrafeTransition(0, 0, 1, 1) == 0, "neutral to input is not a switch");
    check(CJ_StrafeTransition(1, 0, -1, 0) == 1, "W to S phase change");
    CJ_StrafeState state = {};
    CJ_UpdateStrafe(state, 1, -1, true, 100);
    CJ_UpdateStrafe(state, 1, 0, true, 103);
    check(CJ_UpdateStrafe(state, 1, 1, true, 106) == 1,
          "intermediate W release preserves one fullbeat switch");
    CJ_UpdateStrafe(state, 0, -1, true, 109);
    check(state.halfbeatForward == 1, "halfbeat phase retained for native correction");
    CJ_UpdateStrafe(state, 1, -1, true, 110);
    CJ_UpdateStrafe(state, 0, 1, true, 111);
    check(state.halfbeatForward == 1,
          "mixed style returns to diagonal then recognizes opposite halfbeat");
    CJ_UpdateStrafe(state, 0, -1, false, 112);
    check(state.halfbeatForward == 0, "landing clears halfbeat phase");
    CJ_UpdateStrafe(state, 1, -1, true, 120);
    CJ_UpdateStrafe(state, 0, 1, true, 124);
    CJ_UpdateStrafe(state, 0, 1, true, 500);
    check(state.halfbeatForward == 0, "stale command gap clears correction");

    float before[3] = {300, 400, 20};
    float reference[3] = {340, sqrtf(500 * 500 - 340 * 340), 20};
    float actual[3];
    memcpy(actual, reference, sizeof(actual));
    check(CJ_CapHalfbeatGain(before, reference, actual) == 0,
          "constant-speed turn does not trigger a penalty");

    const float rotations[] = {0, 45, 90, 135, 230};
    const float durations[] = {0.002f, 0.003f, 0.004f, 0.008f, 0.016f, 0.05f};
    for (int forward = -1; forward <= 1; forward += 2) {
        for (int right = -1; right <= 1; right += 2) {
            for (float rotation : rotations) {
                for (float dt : durations) {
                    playerState_t ps;
                    pmove_t pm;
                    pml_t pml;
                    setup(ps, pm, pml, rotation, 500, dt, right, forward);
                    playerState_t original = ps;
                    playerState_t fullbeat = ps;
                    float direction[3] = {right * pml.right[0], right * pml.right[1], 0};
                    float diag[3] = {forward * pml.forward[0] + right * pml.right[0],
                                     forward * pml.forward[1] + right * pml.right[1], 0};
                    float len = hypotf(diag[0], diag[1]);
                    diag[0] /= len;
                    diag[1] /= len;
                    OpenCJ_PM_Accelerate(&original, &pml, direction, 190, 1);
                    OpenCJ_PM_Accelerate(&fullbeat, &pml, diag, 190, 1);
                    check(hypotf(original.velocity[0], original.velocity[1]) > 500.001f,
                          "fixture exercises positive halfbeat gain");
                    seed(ps, pm, false, forward, -right);
                    opencj_airAccelerate(&pm, &pml, direction, 190);
                    check(same(ps.velocity, original.velocity),
                          "allowed halfbeat matches original engine exactly");
                    setup(ps, pm, pml, rotation, 500, dt, right, forward);
                    seed(ps, pm, true, forward, -right);
                    opencj_airAccelerate(&pm, &pml, direction, 190);
                    float speed = hypotf(ps.velocity[0], ps.velocity[1]);
                    check(
                        speed >= 499.999f && speed <= fmaxf(500, hypotf(fullbeat.velocity[0],
                                                                        fullbeat.velocity[1])) +
                                                          0.001f,
                        "disallowed halfbeat bounded by engine fullbeat without removing momentum");
                    check(hypotf(original.velocity[0], original.velocity[1]) - speed > 0.001f,
                          "disallowed correction actually removes excess gain");
                    check(ps.velocity[2] == 700, "vertical rocket/bounce momentum preserved");
                    check(fabsf(ps.velocity[0] * original.velocity[1] -
                                ps.velocity[1] * original.velocity[0]) < 0.1f,
                          "actual steering direction preserved");
                }
            }
        }
    }
    for (int exclusion = 0; exclusion < 5; ++exclusion) {
        playerState_t ps;
        pmove_t pm;
        pml_t pml;
        setup(ps, pm, pml, 0, 900, 0.004f);
        if (exclusion == 0) {
            pml.groundPlane = 1;
        }
        if (exclusion == 1) {
            ps.pm_type = 2;
        }
        if (exclusion == 2) {
            pml.frametime = 0.1f;
        }
        playerState_t original = ps;
        float direction[3] = {pml.right[0], pml.right[1], 0};
        OpenCJ_PM_Accelerate(&original, &pml, direction, 190, 1);
        seed(ps, pm, true, 1, exclusion == 3 ? 1 : -1);
        if (exclusion == 4) {
            opencj_resetMovement(63);
        }
        opencj_airAccelerate(&pm, &pml, direction, 190);
        check(same(ps.velocity, original.velocity),
              "slope/noclip/large-step/landing-adjustment/reset exclusions preserve engine result");
    }
    opencj_initMovement(63);
    Plugin_Printf("STRAFE NATIVE COMPLETE failures=%d checks=%d\n", failures, checks);
}
extern "C" int OnInit() {
    return 0;
}
extern "C" void OnInfoRequest(pluginInfo_t *info) {
    memset(info, 0, sizeof(*info));
    info->handlerVersion.major = PLUGIN_HANDLER_VERSION_MAJOR;
    strcpy(info->fullName, "OpenCJ isolated strafe verification");
    info->pluginVersion.major = 1;
}
extern "C" void OnFrame() {
    static bool done = false;
    static bool callbackDone = false;
    if (!callbackDone && Plugin_Cvar_VariableIntegerValue("opencj_test_movement") == 2) {
        callbackDone = true;
        client_t *client = Plugin_GetClientForClientNum(0);
        if (client && client->gentity && client->gentity->client) {
            playerState_t &ps = client->gentity->client->ps;
            int ground = ps.groundEntityNum;
            ps.groundEntityNum = 1023;
            usercmd_t cmd = {};
            cmd.serverTime = client->lastUsercmd.serverTime + 10;
            cmd.forwardmove = 127;
            cmd.rightmove = -127;
            opencj_invalidateMovementInput(0);
            opencj_onClientMoveCommand(client, &cmd);
            cmd.serverTime += 3;
            cmd.rightmove = 127;
            opencj_onClientMoveCommand(client, &cmd);
            cmd.serverTime += 3;
            cmd.forwardmove = 0;
            opencj_onClientMoveCommand(client, &cmd);
            ps.groundEntityNum = ground;
        }
    }
    if (!done && Plugin_Cvar_VariableIntegerValue("opencj_test_movement")) {
        done = true;
        run();
    }
}
