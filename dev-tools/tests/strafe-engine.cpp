// Isolated test plugin; never loaded into the production runtime.
#include "../../server-ext/opencj_movement.hpp"
#include "../../cod4x-server/src/opencj_main.hpp"
#include "../../server-ext/opencj_strafe_logic.hpp"
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <math.h>
#include <string.h>
extern "C" {
void Plugin_Printf(const char *format, ...);
client_t *Plugin_GetClientForClientNum(int clientNum);
int Plugin_Cvar_VariableIntegerValue(const char *name);
void OpenCJ_PM_Accelerate(playerState_t *playerState, const pml_t *movementFrame,
                          const float *wishDirection, float wishSpeed, float acceleration);
}
// Use a slot outside the two connected test clients. All state is reset after the run.
static constexpr int CORRECTION_CLIENT_NUM = MAX_CLIENTS - 1;
static constexpr int FULL_KEY_INPUT = 127;
static constexpr float PLAYER_WISH_SPEED = 190;
static constexpr bool CORRECTION_ENABLED = true;
static constexpr bool CORRECTION_DISABLED = false;

static int checks;
static int failures;
static void check(bool ok, const char *name) {
    ++checks;
    if (!ok) {
        ++failures;
    }
    Plugin_Printf("STRAFE NATIVE CHECK %d: %s\n", ok, name);
}

static bool sameVelocity(const float *velocityAngle, const float *b) {
    return fabsf(velocityAngle[0] - b[0]) < 0.0001f && fabsf(velocityAngle[1] - b[1]) < 0.0001f &&
           velocityAngle[2] == b[2];
}

static void prepareMovement(playerState_t &playerState, pmove_t &movementContext,
                            pml_t &movementFrame, float rotationDegrees, float speed,
                            float frameSeconds, int right = 1, int forward = 1) {
    memset(&playerState, 0, sizeof(playerState));
    memset(&movementContext, 0, sizeof(movementContext));
    memset(&movementFrame, 0, sizeof(movementFrame));
    playerState.clientNum = CORRECTION_CLIENT_NUM;
    playerState.speed = PLAYER_WISH_SPEED;
    playerState.groundEntityNum = ENTITYNUM_NONE;
    float velocityAngle = rotationDegrees * 0.01745329252f;
    float viewAngle = velocityAngle + (forward < 0 ? 3.14159265359f : 0) + forward * right * 0.2f;
    playerState.velocity[0] = speed * cosf(velocityAngle);
    playerState.velocity[1] = speed * sinf(velocityAngle);
    playerState.velocity[2] = 700;
    playerState.oldVelocity[0] = playerState.velocity[0];
    playerState.oldVelocity[1] = playerState.velocity[1];
    movementFrame.forward[0] = cosf(viewAngle);
    movementFrame.forward[1] = sinf(viewAngle);
    movementFrame.right[0] = sinf(viewAngle);
    movementFrame.right[1] = -cosf(viewAngle);
    movementFrame.frametime = frameSeconds;
    movementFrame.msec = int(frameSeconds * 1000);
    movementContext.ps = &playerState;
    movementContext.cmd.serverTime = 1004;
    movementContext.cmd.rightmove = right * FULL_KEY_INPUT;
}

static void seedPreviousDiagonal(playerState_t &playerState, pmove_t &movementContext, bool enabled,
                                 int anchorForward = 1, int anchorRight = -1) {
    opencj_initMovement(CORRECTION_CLIENT_NUM);
    opencj_setHalfbeatCorrection(CORRECTION_CLIENT_NUM, enabled);
    usercmd_t previous = movementContext.cmd;
    previous.serverTime = 1000;
    previous.forwardmove = FULL_KEY_INPUT * anchorForward;
    previous.rightmove = FULL_KEY_INPUT * anchorRight;
    opencj_observeMovement(&playerState, &previous);
}

static void testStrafeTransitions() {
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
}

static void testConstantSpeedTurn() {
    float before[3] = {300, 400, 20};
    float reference[3] = {340, sqrtf(500 * 500 - 340 * 340), 20};
    float actual[3];
    memcpy(actual, reference, sizeof(actual));
    check(CJ_CapHalfbeatGain(before, reference, actual) == 0,
          "constant-speed turn does not trigger a penalty");
}

// Compare the real engine's diagonal and single-key results for one movement frame.
static void testCorrection(float rotationDegrees, float frameSeconds, int forward, int right) {
    playerState_t playerState;
    pmove_t movementContext;
    pml_t movementFrame;
    prepareMovement(playerState, movementContext, movementFrame, rotationDegrees, 500, frameSeconds,
                    right, forward);
    playerState_t original = playerState;
    playerState_t fullbeat = playerState;
    float direction[3] = {right * movementFrame.right[0], right * movementFrame.right[1], 0};
    float diagonalDirection[3] = {
        forward * movementFrame.forward[0] + right * movementFrame.right[0],
        forward * movementFrame.forward[1] + right * movementFrame.right[1], 0};
    float directionLength = hypotf(diagonalDirection[0], diagonalDirection[1]);
    diagonalDirection[0] /= directionLength;
    diagonalDirection[1] /= directionLength;
    OpenCJ_PM_Accelerate(&original, &movementFrame, direction, PLAYER_WISH_SPEED, 1);
    OpenCJ_PM_Accelerate(&fullbeat, &movementFrame, diagonalDirection, PLAYER_WISH_SPEED, 1);
    check(hypotf(original.velocity[0], original.velocity[1]) > 500.001f,
          "fixture exercises positive halfbeat gain");
    seedPreviousDiagonal(playerState, movementContext, CORRECTION_DISABLED, forward, -right);
    opencj_airAccelerate(&movementContext, &movementFrame, direction, PLAYER_WISH_SPEED);
    check(sameVelocity(playerState.velocity, original.velocity),
          "allowed halfbeat matches original engine exactly");
    prepareMovement(playerState, movementContext, movementFrame, rotationDegrees, 500, frameSeconds,
                    right, forward);
    seedPreviousDiagonal(playerState, movementContext, CORRECTION_ENABLED, forward, -right);
    opencj_airAccelerate(&movementContext, &movementFrame, direction, PLAYER_WISH_SPEED);
    float speed = hypotf(playerState.velocity[0], playerState.velocity[1]);
    check(speed >= 499.999f &&
              speed <= fmaxf(500, hypotf(fullbeat.velocity[0], fullbeat.velocity[1])) + 0.001f,
          "disallowed halfbeat bounded by engine fullbeat without removing momentum");
    check(hypotf(original.velocity[0], original.velocity[1]) - speed > 0.001f,
          "disallowed correction actually removes excess gain");
    check(playerState.velocity[2] == 700, "vertical rocket/bounce momentum preserved");
    check(fabsf(playerState.velocity[0] * original.velocity[1] -
                playerState.velocity[1] * original.velocity[0]) < 0.1f,
          "actual steering direction preserved");
}

static void testCorrectionAcrossDirections() {
    const float rotationAngles[] = {0, 45, 90, 135, 230};
    const float frameDurations[] = {0.002f, 0.003f, 0.004f, 0.008f, 0.016f, 0.05f};
    for (int forward = -1; forward <= 1; forward += 2) {
        for (int right = -1; right <= 1; right += 2) {
            for (float rotationDegrees : rotationAngles) {
                for (float frameSeconds : frameDurations) {
                    testCorrection(rotationDegrees, frameSeconds, forward, right);
                }
            }
        }
    }
}

enum CorrectionExclusion { SLOPE, NOCLIP, LARGE_FRAME, LANDING_ADJUSTMENT, RESET_HISTORY };

static void testExcludedMovement() {
    const CorrectionExclusion exclusions[] = {SLOPE, NOCLIP, LARGE_FRAME, LANDING_ADJUSTMENT,
                                              RESET_HISTORY};
    for (CorrectionExclusion exclusion : exclusions) {
        playerState_t playerState;
        pmove_t movementContext;
        pml_t movementFrame;
        prepareMovement(playerState, movementContext, movementFrame, 0, 900, 0.004f);
        if (exclusion == SLOPE) {
            movementFrame.groundPlane = 1;
        }
        if (exclusion == NOCLIP) {
            playerState.pm_type = 2;
        }
        if (exclusion == LARGE_FRAME) {
            movementFrame.frametime = 0.1f;
        }
        playerState_t original = playerState;
        float direction[3] = {movementFrame.right[0], movementFrame.right[1], 0};
        OpenCJ_PM_Accelerate(&original, &movementFrame, direction, PLAYER_WISH_SPEED, 1);
        seedPreviousDiagonal(playerState, movementContext, CORRECTION_ENABLED, 1,
                             exclusion == LANDING_ADJUSTMENT ? 1 : -1);
        if (exclusion == RESET_HISTORY) {
            opencj_resetMovement(CORRECTION_CLIENT_NUM);
        }
        opencj_airAccelerate(&movementContext, &movementFrame, direction, PLAYER_WISH_SPEED);
        check(sameVelocity(playerState.velocity, original.velocity),
              "slope/noclip/large-step/landing-adjustment/reset exclusions preserve engine result");
    }
}

static void run() {
    testStrafeTransitions();
    testConstantSpeedTurn();
    testCorrectionAcrossDirections();
    testExcludedMovement();
    opencj_initMovement(CORRECTION_CLIENT_NUM);
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
            playerState_t &playerState = client->gentity->client->ps;
            int savedGroundEntity = playerState.groundEntityNum;
            playerState.groundEntityNum = ENTITYNUM_NONE;
            usercmd_t command = {};
            command.serverTime = client->lastUsercmd.serverTime + 10;
            command.forwardmove = FULL_KEY_INPUT;
            command.rightmove = -FULL_KEY_INPUT;
            opencj_invalidateMovementInput(0);
            opencj_onClientMoveCommand(client, &command);
            command.serverTime += 3;
            command.rightmove = FULL_KEY_INPUT;
            opencj_onClientMoveCommand(client, &command);
            command.serverTime += 3;
            command.forwardmove = 0;
            opencj_onClientMoveCommand(client, &command);
            playerState.groundEntityNum = savedGroundEntity;
        }
    }
    if (!done && Plugin_Cvar_VariableIntegerValue("opencj_test_movement")) {
        done = true;
        run();
    }
}
