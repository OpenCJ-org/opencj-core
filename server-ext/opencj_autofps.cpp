///
/// Tutorial-mode automatic FPS selection (CoD4).
///
/// The engine rounds velocity to whole units after every client frame, so the
/// frame rate changes the physics. At 333 FPS a falling player loses 2 units/s of
/// vertical speed per 3 ms frame (effective gravity 666); at 250 and 125 FPS it is
/// 750. 333 therefore gives more height and more hang time.
///
/// Rule (checked against engine replays of recorded jumps):
/// - On the ground: 333.
/// - In the air: whichever of 333, 250 and 125 gives the most horizontal speed
///   over 48 ms with the current movement keys and strafe angle (the view
///   turning with the velocity, as when strafing), re-evaluated every command,
///   so strafe switches bring 333 back (e.g. 333-250-333-250-125).
/// - Height: when, flying the current way, the player would reach the next
///   checkpoint horizontally below its height at 250/125 but at or above it at
///   333, use 333 (lighter gravity, so more height and hang time). When even 333
///   falls short, as before a bounce, the FPS cannot help and speed decides.
///   Also 333 while climbing towards it when the peak at 250/125 would stay less
///   than 48 units above it but the peak at 333 reaches it (the arrival time
///   above ignores that strafing adds speed, so after a bounce it is too late).
///   Scripts report the nearest point of that checkpoint (the nearest edge of a
///   landing area).
/// - Height is no longer needed (this and the RPG rise below) once 250, with the
///   speed it adds at the current keys and strafe angle, would still reach that
///   point 32 units above it; then speed decides.
/// - A change is sent with an extra snapshot right away (server setting
///   opencj_autofps_immediate, default on) instead of with the next server frame.
/// - During a rise started by an RPG push (also an RPG on a bounce): 333 until
///   shortly before its peak, for height. An RPG push lands while the server
///   processes a movement command, exactly like a bounce (seen in server logs
///   while testing), so speed alone cannot tell them apart. A push is therefore
///   an upward speed gain at the end of a command together with an RPG fired by
///   the player within RPG_PUSH_WINDOW_MS, in either order. The switch away from
///   333 is made early by the client's ping, because a new com_maxfps only takes
///   effect once the client receives it.
///

#include "opencj_autofps.hpp"
#ifdef COD4

#include <math.h>
#include <string.h>

extern "C" void OpenCJ_PM_Accelerate(playerState_t *ps, const pml_t *pml,
                                     const float *wishDirection, float wishSpeed,
                                     float accelerationScale);
extern "C" void Sys_SnapVector(float *vector);

/**************************************************************************
 * Constants                                                              *
 **************************************************************************/

enum AutoFrameRate
{
    AUTO_FPS_NONE = 0,
    AUTO_FPS_125 = 125,
    AUTO_FPS_250 = 250,
    AUTO_FPS_333 = 333,
};

// Engine value for "standing on nothing".
static const int GROUND_ENTITY_NONE = 1023;
static const int PM_TYPE_NORMAL = 0;

// Vertical speed lost per second at 333 FPS after per-frame rounding (2 per 3 ms),
// and at 250/125 FPS (3 per 4 ms, 6 per 8 ms).
static const float EFFECTIVE_GRAVITY_AT_333 = 666.0f;
static const float EFFECTIVE_GRAVITY_AT_250 = 750.0f;

// The height check needs the player to be on the way to the checkpoint: closer
// than this, they are already over it; slower than this towards it, the arrival
// time is meaningless.
static const float TARGET_REACHED_DISTANCE_UNITS = 32.0f;
static const float MIN_APPROACH_SPEED = 50.0f;

// A climb keeps 333 until its peak at 250/125 would be this far above the next
// checkpoint, so the player lands with some room rather than exactly at the peak.
static const float PEAK_MARGIN_UNITS = 48.0f;

// A climb kept at 333 for height (RPG push or peak rule) goes back to the speed
// choice once 250, with the speed it adds, would still reach the nearest point of
// the next checkpoint this far above it. On recorded RPG climbs of a
// mp_futile_fixed jump (2026-11-22) this came about 1 s before the peak; holding
// 333 to the peak kept speed flat.
static const float ARRIVAL_MARGIN_UNITS = 32.0f;

// Horizon for comparing 333, 250 and 125. 48 ms is a whole number of 3, 4 and
// 8 ms frames, so every candidate gets exactly the same time. On a recorded
// futile attempt (2026-11-22) a 48 ms horizon with the strafe angle kept picked
// the FPS that the engine, replaying the player's own mouse, found fastest for
// 93% of commands; the earlier 240 ms with a held view only 74%, and it missed
// 333 at strafe switches.
static const int SPEED_COMPARISON_HORIZON_MS = 48;

// Speed (units/s, after the horizon) by which 333 or 125 must beat 250 to be
// chosen. At a strafe angle around 90 degrees no FPS gains speed and 333 came out
// ahead by 0.1-0.4, which kept a player on 333 at the end of a climb where 250 was
// what they aimed for (recorded mp_futile_fixed attempt, 2026-11-22). A real
// strafe-switch advantage of 333 there was about 2.
static const double MIN_SPEED_ADVANTAGE = 0.5;

// Ping above this is treated as this, so a bad connection cannot make the
// first rise end immediately after takeoff.
static const int MAX_SWITCH_LEAD_MS = 300;

// Reliable commands still unacknowledged by the client. Above this, changes
// wait, so a client that stops acknowledging cannot overflow its command queue.
static const int MAX_PENDING_RELIABLE_COMMANDS = 32;

// Server command for setting a client dvar, as used by GSC setClientDvar.
static const char CLIENT_DVAR_COMMAND = 'v';

// Upward speed gained over one movement command that may be a push. Gravity
// only removes speed, so a gain comes from a collision (bounce) or a push; the
// margin ignores small engine corrections.
static const float UPWARD_GAIN_MIN_SPEED = 50.0f;

// A gain counts as an RPG push when the player fired an RPG this long before or
// after it. Covers the rocket's flight to a nearby surface; the server learns
// about the shot in a script callback, possibly after the gain was observed.
static const int RPG_PUSH_WINDOW_MS = 500;

/**************************************************************************
 * Per-client state                                                       *
 **************************************************************************/

struct AutoFpsClient
{
    bool enabled;
    // True from an RPG push until shortly before the following peak.
    bool inPushRise;
    // Last com_maxfps sent to the client; AUTO_FPS_NONE forces the next send.
    int sentFrameRate;
    // Vertical speed when the previous movement command ended.
    bool hasPreviousEnd;
    float previousEndVerticalSpeed;
    // Server times (svs.time) of the last RPG shot and of the last airborne
    // upward gain not yet explained by an RPG shot.
    bool hasRPGFired;
    int lastRPGFiredTime;
    bool hasUnexplainedGain;
    int lastUnexplainedGainTime;
    // Position of the player's next checkpoint, set by script; see opencj_autoFpsNeedsHeight.
    bool hasTarget;
    float target[3];
    // Server time (svs.time) of the last snapshot sent right after a change.
    bool hasImmediateSnapshot;
    int lastImmediateSnapshotTime;
};

static AutoFpsClient autoFpsClients[MAX_CLIENTS];

static bool isValidClientNum(int clientNum)
{
    return clientNum >= 0 && clientNum < MAX_CLIENTS;
}

/**************************************************************************
 * Frame-rate choice                                                      *
 **************************************************************************/

static int frameDurationMs(int frameRate)
{
    if (frameRate == AUTO_FPS_333)
    {
        return 3;
    }
    if (frameRate == AUTO_FPS_250)
    {
        return 4;
    }
    return 8;
}

// Returns the horizontal speed after SPEED_COMPARISON_HORIZON_MS of air
// acceleration at frameRate, holding the current keys and the strafe angle: the
// view turns with the velocity, as a strafing player's mouse does. Uses the
// engine's own acceleration, inertia update and per-frame velocity rounding.
static double horizontalSpeedAfterHorizon(const playerState_t *ps, float yawRadians,
                                          int forwardMove, int rightMove, float wishSpeed,
                                          int frameRate)
{
    playerState_t candidate = *ps;
    pml_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.msec = frameDurationMs(frameRate);
    frame.frametime = frame.msec * 0.001f;
    float startVelocityYaw = atan2f(ps->velocity[1], ps->velocity[0]);

    for (int elapsedMs = 0; elapsedMs < SPEED_COMPARISON_HORIZON_MS; elapsedMs += frame.msec)
    {
        float velocityYaw = atan2f(candidate.velocity[1], candidate.velocity[0]);
        float velocityTurn = velocityYaw - startVelocityYaw;
        float frameYaw = yawRadians + velocityTurn;
        // Air movement uses the flattened view direction, so only yaw matters.
        float wishDirection[3] = {
            forwardMove * cosf(frameYaw) + rightMove * sinf(frameYaw),
            forwardMove * sinf(frameYaw) - rightMove * cosf(frameYaw),
            0,
        };
        float wishLength = hypotf(wishDirection[0], wishDirection[1]);
        wishDirection[0] /= wishLength;
        wishDirection[1] /= wishLength;
        OpenCJ_PM_Accelerate(&candidate, &frame, wishDirection, wishSpeed, 1);
        // Pmove updates inertia before rounding the current velocity.
        for (int axis = 0; axis < 2; ++axis)
        {
            float velocityChange = candidate.velocity[axis] - candidate.oldVelocity[axis];
            candidate.oldVelocity[axis] += frame.frametime * velocityChange;
        }
        Sys_SnapVector(candidate.velocity);
    }
    return hypot(double(candidate.velocity[0]), double(candidate.velocity[1]));
}

// Chooses 333, 250 or 125 for an airborne player: whichever keeps the most
// horizontal speed. Without movement keys 250; 333 or 125 only when they beat
// 250 by at least MIN_SPEED_ADVANTAGE, otherwise 250.
static int chooseSpeedFrameRate(const playerState_t *ps, const usercmd_t *cmd)
{
    bool hasMovementKeys = cmd->forwardmove != 0 || cmd->rightmove != 0;
    bool hasValidVelocity = isfinite(ps->velocity[0]) && isfinite(ps->velocity[1]);
    if (!hasMovementKeys || !hasValidVelocity || ps->speed <= 0)
    {
        return AUTO_FPS_250;
    }

    float yawRadians = ps->viewangles[1] * float(M_PI / 180.0);
    float wishSpeed = float(ps->speed);
    double speedAt250 = horizontalSpeedAfterHorizon(ps, yawRadians, cmd->forwardmove,
                                                    cmd->rightmove, wishSpeed, AUTO_FPS_250);
    double speedAt125 = horizontalSpeedAfterHorizon(ps, yawRadians, cmd->forwardmove,
                                                    cmd->rightmove, wishSpeed, AUTO_FPS_125);
    double speedAt333 = horizontalSpeedAfterHorizon(ps, yawRadians, cmd->forwardmove,
                                                    cmd->rightmove, wishSpeed, AUTO_FPS_333);
    int bestFrameRate = AUTO_FPS_250;
    double bestSpeed = speedAt250;
    if (speedAt333 > bestSpeed + MIN_SPEED_ADVANTAGE)
    {
        bestFrameRate = AUTO_FPS_333;
        bestSpeed = speedAt333;
    }
    if (speedAt125 > bestSpeed + MIN_SPEED_ADVANTAGE)
    {
        bestFrameRate = AUTO_FPS_125;
    }
    return bestFrameRate;
}

// Horizontal acceleration (units/s^2) at 250 FPS over the comparison horizon,
// holding the keys and strafe angle; 0 without keys or when 250 gains nothing.
static float horizontalAccelerationAt250(const playerState_t *ps, const usercmd_t *cmd)
{
    bool hasMovementKeys = cmd->forwardmove != 0 || cmd->rightmove != 0;
    bool hasValidVelocity = isfinite(ps->velocity[0]) && isfinite(ps->velocity[1]);
    if (!hasMovementKeys || !hasValidVelocity || ps->speed <= 0)
    {
        return 0;
    }
    float yawRadians = ps->viewangles[1] * float(M_PI / 180.0);
    double speedAt250 = horizontalSpeedAfterHorizon(ps, yawRadians, cmd->forwardmove,
                                                    cmd->rightmove, float(ps->speed), AUTO_FPS_250);
    double gain = speedAt250 - hypot(double(ps->velocity[0]), double(ps->velocity[1]));
    if (gain <= 0)
    {
        return 0;
    }
    return float(gain * 1000.0 / SPEED_COMPARISON_HORIZON_MS);
}

// The client's ping, limited to MAX_SWITCH_LEAD_MS.
static int clientSwitchLeadMs(int clientNum)
{
    int pingMs = svs.clients[clientNum].ping;
    if (pingMs < 0)
    {
        return 0;
    }
    if (pingMs > MAX_SWITCH_LEAD_MS)
    {
        return MAX_SWITCH_LEAD_MS;
    }
    return pingMs;
}

// Applies the speed and RPG parts of the rule at the top of this file and updates
// *inPushRise. Pure apart from *inPushRise, so offline replays run the shipped rule.
extern "C" int opencj_autoFpsChooseFrameRate(bool *inPushRise, const playerState_t *ps,
                                            const usercmd_t *cmd, int switchLeadMs)
{
    bool isStanding = ps->groundEntityNum != GROUND_ENTITY_NONE;
    if (isStanding)
    {
        *inPushRise = false;
        return AUTO_FPS_333;
    }

    if (*inPushRise)
    {
        float verticalSpeed = ps->velocity[2];
        float msUntilPeak = verticalSpeed / EFFECTIVE_GRAVITY_AT_333 * 1000.0f;
        bool peakIsBeyondLead = verticalSpeed > 0 && msUntilPeak > switchLeadMs;
        if (peakIsBeyondLead)
        {
            return AUTO_FPS_333;
        }
        *inPushRise = false;
    }
    return chooseSpeedFrameRate(ps, cmd);
}

// Height of a player after secondsAhead of free flight under effectiveGravity.
static float heightAfter(const playerState_t *ps, float secondsAhead, float effectiveGravity)
{
    return ps->origin[2] + ps->velocity[2] * secondsAhead -
           0.5f * effectiveGravity * secondsAhead * secondsAhead;
}

// True when the airborne player is on the way to the target: not over it yet
// and moving towards it fast enough for an arrival time to mean something.
// Gives the horizontal distance and the speed towards it.
static bool isApproachingTarget(const playerState_t *ps, const float *target,
                                float *horizontalDistance, float *speedTowardsTarget)
{
    if (ps->groundEntityNum != GROUND_ENTITY_NONE)
    {
        return false;
    }
    float toTargetX = target[0] - ps->origin[0];
    float toTargetY = target[1] - ps->origin[1];
    *horizontalDistance = hypotf(toTargetX, toTargetY);
    if (*horizontalDistance < TARGET_REACHED_DISTANCE_UNITS)
    {
        return false;
    }
    *speedTowardsTarget = (ps->velocity[0] * toTargetX + ps->velocity[1] * toTargetY) /
                          *horizontalDistance;
    return *speedTowardsTarget >= MIN_APPROACH_SPEED;
}

// Highest point of the current climb at 250/125 FPS; the current height when
// not climbing.
static float peakAt250(const playerState_t *ps)
{
    float verticalSpeed = ps->velocity[2];
    if (verticalSpeed <= 0)
    {
        return ps->origin[2];
    }
    return ps->origin[2] + verticalSpeed * verticalSpeed / (2 * EFFECTIVE_GRAVITY_AT_250);
}

// True when the player, switching to 250/125 now and gaining speed at
// horizontalAcceleration along the way, would reach the target horizontally at
// least ARRIVAL_MARGIN_UNITS above its height: more height is not needed and
// speed can decide. False when not on the way to the target.
extern "C" bool opencj_autoFpsArrivesHighEnoughAt250(const playerState_t *ps, const float *target,
                                                    float horizontalAcceleration)
{
    float horizontalDistance;
    float speedTowardsTarget;
    if (!isApproachingTarget(ps, target, &horizontalDistance, &speedTowardsTarget))
    {
        return false;
    }
    // Only the part of the gain that points at the target shortens the way.
    float horizontalSpeed = hypotf(ps->velocity[0], ps->velocity[1]);
    float accelerationTowardsTarget = 0;
    if (horizontalAcceleration > 0 && horizontalSpeed > 0)
    {
        accelerationTowardsTarget = horizontalAcceleration * speedTowardsTarget / horizontalSpeed;
    }
    // distance = speed * t + acceleration / 2 * t^2
    float secondsToArrival = horizontalDistance / speedTowardsTarget;
    if (accelerationTowardsTarget > 0)
    {
        float discriminant = speedTowardsTarget * speedTowardsTarget +
                             2 * accelerationTowardsTarget * horizontalDistance;
        secondsToArrival = (sqrtf(discriminant) - speedTowardsTarget) / accelerationTowardsTarget;
    }
    float arrivalHeight = heightAfter(ps, secondsToArrival, EFFECTIVE_GRAVITY_AT_250);
    return arrivalHeight >= target[2] + ARRIVAL_MARGIN_UNITS;
}

// True when 333 decides whether the airborne player, flying the current way,
// reaches the target high enough: at 250/125 they would arrive below its height,
// at 333 at or above it. When even 333 falls short, the route needs something
// else (a bounce, an RPG), so speed matters more. Arrival time is the horizontal
// distance over the speed towards the target; when the player is not heading
// there (or is already over it) there is no answer and this is false.
extern "C" bool opencj_autoFpsNeedsHeight(const playerState_t *ps, const float *target)
{
    float horizontalDistance;
    float speedTowardsTarget;
    if (!isApproachingTarget(ps, target, &horizontalDistance, &speedTowardsTarget))
    {
        return false;
    }
    float secondsToArrival = horizontalDistance / speedTowardsTarget;
    bool tooLowAt250 = heightAfter(ps, secondsToArrival, EFFECTIVE_GRAVITY_AT_250) < target[2];
    bool highEnoughAt333 = heightAfter(ps, secondsToArrival, EFFECTIVE_GRAVITY_AT_333) >= target[2];
    if (tooLowAt250 && highEnoughAt333)
    {
        return true;
    }

    // The arrival time assumes the current horizontal speed, but strafing keeps
    // adding speed, so after a bounce it can be a second too late and wrongly say
    // that even 333 falls short. The peak does not depend on it: a climb whose
    // peak at 250/125 stays below the checkpoint (plus a margin) can only get
    // there at 333.
    float verticalSpeed = ps->velocity[2];
    if (verticalSpeed <= 0)
    {
        return false;
    }
    float peakAt333 = ps->origin[2] +
                      verticalSpeed * verticalSpeed / (2 * EFFECTIVE_GRAVITY_AT_333);
    return peakAt250(ps) < target[2] + PEAK_MARGIN_UNITS && peakAt333 >= target[2];
}

// True when a command ended rising, with at least UPWARD_GAIN_MIN_SPEED more
// upward speed than the previous command ended with.
extern "C" bool opencj_autoFpsIsUpwardGain(float previousEndVerticalSpeed, float endVerticalSpeed)
{
    bool isRising = endVerticalSpeed > 0;
    bool gainedEnough = endVerticalSpeed - previousEndVerticalSpeed >= UPWARD_GAIN_MIN_SPEED;
    return isRising && gainedEnough;
}

// True when two server times are at most RPG_PUSH_WINDOW_MS apart.
extern "C" bool opencj_autoFpsIsWithinRPGWindow(int firstTime, int secondTime)
{
    int distanceMs = secondTime - firstTime;
    if (distanceMs < 0)
    {
        distanceMs = -distanceMs;
    }
    return distanceMs <= RPG_PUSH_WINDOW_MS;
}

// An RPG push starts a new rise: 333 for height until shortly before its peak.
static void startPushRise(AutoFpsClient &state)
{
    state.inPushRise = true;
    state.hasUnexplainedGain = false;
}

/**************************************************************************
 * Sending                                                                *
 **************************************************************************/

static bool hasRoomForReliableCommand(int clientNum)
{
    const client_t *client = &svs.clients[clientNum];
    int pendingCommands = client->reliableSequence - client->reliableAcknowledge;
    return pendingCommands < MAX_PENDING_RELIABLE_COMMANDS;
}

// Server setting: deliver changes with an extra snapshot right away (default on).
static cvar_t *immediateDeliveryCvar = NULL;

static bool isImmediateDeliveryEnabled()
{
    if (!immediateDeliveryCvar)
    {
        immediateDeliveryCvar = Cvar_RegisterBool(
            "opencj_autofps_immediate", qtrue, 0,
            "Tutorial auto-FPS: send a com_maxfps change with an extra snapshot right away "
            "instead of with the next server frame (up to 50 ms later)");
    }
    return immediateDeliveryCvar->boolean;
}

// Sends com_maxfps like GSC setClientDvar does. Returns false when it must wait.
// A reliable command normally leaves with the next server frame's snapshot (up to
// 50 ms later); when enabled, the first change in a server frame is sent with an
// extra snapshot right away, so a player gets at most one extra snapshot per frame.
static bool sendClientFrameRate(int clientNum, int frameRate)
{
    if (!hasRoomForReliableCommand(clientNum))
    {
        return false;
    }
    SV_GameSendServerCommand(clientNum, 1,
                             va("%c com_maxfps \"%d\"", CLIENT_DVAR_COMMAND, frameRate));

    AutoFpsClient &state = autoFpsClients[clientNum];
    bool alreadySentThisFrame = state.hasImmediateSnapshot &&
                                state.lastImmediateSnapshotTime == svs.time;
    if (isImmediateDeliveryEnabled() && !alreadySentThisFrame)
    {
        SV_SendClientSnapshotNow(&svs.clients[clientNum]);
        state.hasImmediateSnapshot = true;
        state.lastImmediateSnapshotTime = svs.time;
    }
    return true;
}

/**************************************************************************
 * API                                                                    *
 **************************************************************************/

extern "C" void opencj_autoFpsInitClient(int clientNum)
{
    if (!isValidClientNum(clientNum))
    {
        return;
    }
    memset(&autoFpsClients[clientNum], 0, sizeof(autoFpsClients[clientNum]));
}

extern "C" void opencj_autoFpsObserve(const playerState_t *ps, const usercmd_t *cmd)
{
    if (!ps || !cmd || !isValidClientNum(ps->clientNum))
    {
        return;
    }
    AutoFpsClient &state = autoFpsClients[ps->clientNum];
    if (!state.enabled)
    {
        return;
    }

    bool hadPreviousEnd = state.hasPreviousEnd;
    float previousEndVerticalSpeed = state.previousEndVerticalSpeed;
    state.hasPreviousEnd = true;
    state.previousEndVerticalSpeed = ps->velocity[2];
    if (ps->pm_type != PM_TYPE_NORMAL)
    {
        return;
    }

    bool isAirborne = ps->groundEntityNum == GROUND_ENTITY_NONE;
    bool gainedUpwardSpeed = hadPreviousEnd &&
                             opencj_autoFpsIsUpwardGain(previousEndVerticalSpeed, ps->velocity[2]);
    if (isAirborne && gainedUpwardSpeed)
    {
        bool rpgFiredRecently = state.hasRPGFired &&
                                opencj_autoFpsIsWithinRPGWindow(state.lastRPGFiredTime, svs.time);
        if (rpgFiredRecently)
        {
            startPushRise(state);
        }
        else
        {
            // Probably a bounce, unless the shot is reported shortly after.
            state.hasUnexplainedGain = true;
            state.lastUnexplainedGainTime = svs.time;
        }
    }

    // Height (RPG push or a climb short of the next checkpoint) comes before
    // speed, but only while 250, with the speed it would add, would not reach the
    // next checkpoint high enough.
    bool heightIsEnough = false;
    bool mayNeedHeight = state.inPushRise ||
                         (state.hasTarget && opencj_autoFpsNeedsHeight(ps, state.target));
    if (state.hasTarget && mayNeedHeight)
    {
        heightIsEnough = opencj_autoFpsArrivesHighEnoughAt250(ps, state.target,
                                                              horizontalAccelerationAt250(ps, cmd));
    }
    if (state.inPushRise && heightIsEnough)
    {
        state.inPushRise = false;
    }
    int frameRate = opencj_autoFpsChooseFrameRate(&state.inPushRise, ps, cmd,
                                                  clientSwitchLeadMs(ps->clientNum));
    bool needsHeight = state.hasTarget && !heightIsEnough &&
                       opencj_autoFpsNeedsHeight(ps, state.target);
    if (frameRate != AUTO_FPS_333 && needsHeight)
    {
        frameRate = AUTO_FPS_333;
    }
    if (frameRate == state.sentFrameRate)
    {
        return;
    }
    if (sendClientFrameRate(ps->clientNum, frameRate))
    {
        state.sentFrameRate = frameRate;
    }
}

extern "C" void Gsc_AutoFps_NotifyRPGFired(int clientNum)
{
    if (!isValidClientNum(clientNum))
    {
        stackPushBool(qfalse);
        return;
    }
    AutoFpsClient &state = autoFpsClients[clientNum];
    state.hasRPGFired = true;
    state.lastRPGFiredTime = svs.time;

    // The push may already have been observed in this or a recent command.
    bool gainJustBefore = state.hasUnexplainedGain &&
                          opencj_autoFpsIsWithinRPGWindow(state.lastUnexplainedGainTime, svs.time);
    if (state.enabled && gainJustBefore)
    {
        startPushRise(state);
    }
    stackPushBool(qtrue);
}

extern "C" void Gsc_AutoFps_SetEnabled(int clientNum)
{
    int enabled = 0;
    if (!stackGetParams("i", &enabled))
    {
        stackError("setAutoFPSEnabled(enabled) argument is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }
    if (!isValidClientNum(clientNum))
    {
        stackPushBool(qfalse);
        return;
    }

    AutoFpsClient &state = autoFpsClients[clientNum];
    state.enabled = enabled != 0;
    // Re-enabling must send again even if the value is unchanged: the player or
    // other scripts may have changed com_maxfps in between.
    state.sentFrameRate = AUTO_FPS_NONE;
    state.inPushRise = false;
    state.hasPreviousEnd = false;
    state.hasUnexplainedGain = false;
    stackPushBool(qtrue);
}

extern "C" void Gsc_AutoFps_SetTarget(int clientNum)
{
    float target[3] = {0, 0, 0};
    if (!stackGetParams("fff", &target[0], &target[1], &target[2]))
    {
        stackError("setAutoFPSTarget(x, y, z) argument is undefined or has a wrong type");
        stackPushUndefined();
        return;
    }
    bool isFinite = isfinite(target[0]) && isfinite(target[1]) && isfinite(target[2]);
    if (!isValidClientNum(clientNum) || !isFinite)
    {
        stackPushBool(qfalse);
        return;
    }
    AutoFpsClient &state = autoFpsClients[clientNum];
    state.hasTarget = true;
    memcpy(state.target, target, sizeof(state.target));
    stackPushBool(qtrue);
}

extern "C" void Gsc_AutoFps_ClearTarget(int clientNum)
{
    if (!isValidClientNum(clientNum))
    {
        stackPushBool(qfalse);
        return;
    }
    autoFpsClients[clientNum].hasTarget = false;
    stackPushBool(qtrue);
}

extern "C" void Gsc_AutoFps_GetCurrent(int clientNum)
{
    if (!isValidClientNum(clientNum) || !autoFpsClients[clientNum].enabled)
    {
        stackPushInt(AUTO_FPS_NONE);
        return;
    }
    stackPushInt(autoFpsClients[clientNum].sentFrameRate);
}

#endif
