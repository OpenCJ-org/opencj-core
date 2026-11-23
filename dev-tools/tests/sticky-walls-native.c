/* Exercise the real slide/Pmove code; only the private test binary has hooks. */
#include "../../cod4x-server/src/bg_public.h"

#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* These offsets belong to the saved EBP frame in _bg_slidemove.asm, not a C struct. */
enum
{
    SlideMovePointerOffset = 0x150,
    SlidePlayerPointerOffset = 0x140,
    SlideBumpIndexOffset = 0x148,
    SlideTimeRemainingOffset = 0x144,
    SlideEndPositionOffset = 0x24,
    SlideTraceOffset = 0xb4,
    LocalMovementStorageBytes = 0x100,
    SlideFramesPerCase = 48,
    CommandDurationMs = 400,
    MaximumTraceLines = 3001,
    MaximumCommandMovement = 127
};

/* Fail compilation if the headers stop describing the 32-bit assembly ABI. */
_Static_assert(sizeof(playerState_t) == 0x2f64, "player state ABI changed");
_Static_assert(sizeof(struct pmove_t) == 0x110, "movement ABI changed");
_Static_assert(sizeof(usercmd_t) == 32, "command ABI changed");
_Static_assert(sizeof(trace_t) == 44, "trace ABI changed");
_Static_assert(offsetof(playerState_t, pm_time) == 0x18, "movement timer offset");
_Static_assert(offsetof(playerState_t, origin) == 0x1c, "origin offset");
_Static_assert(offsetof(playerState_t, velocity) == 0x28, "velocity offset");
_Static_assert(offsetof(playerState_t, gravity) == 88, "gravity offset");
_Static_assert(offsetof(playerState_t, delta_angles) == 100, "angle delta offset");
_Static_assert(offsetof(playerState_t, groundEntityNum) == 112, "ground entity offset");
_Static_assert(offsetof(playerState_t, viewangles) == 264, "view angles offset");
_Static_assert(offsetof(struct pmove_t, cmd) == 4, "current command offset");
_Static_assert(offsetof(struct pmove_t, oldcmd) == 36, "previous command offset");
_Static_assert(offsetof(usercmd_t, angles) == 8, "command angles offset");
_Static_assert(offsetof(usercmd_t, forwardmove) == 22, "forward input offset");
_Static_assert(offsetof(usercmd_t, rightmove) == 23, "sideways input offset");
_Static_assert(offsetof(struct pml_t, frametime) == 0x24, "frame time offset");
_Static_assert(offsetof(struct pml_t, msec) == 0x28, "frame milliseconds offset");
_Static_assert(sizeof(struct pml_t) <= LocalMovementStorageBytes, "local movement storage");
_Static_assert(offsetof(trace_t, allsolid) == 40, "trace solid flag offset");
_Static_assert(offsetof(trace_t, startsolid) == 41, "trace start flag offset");

/* Keep the original scratch size because the assembly also accesses local state. */
typedef union
{
    struct pml_t state;
    unsigned char storage[LocalMovementStorageBytes];
} LocalMovement;

typedef struct
{
    vec3_t origin;
    vec3_t velocity;
} MovementSnapshot;

_Static_assert(sizeof(MovementSnapshot) == 6 * sizeof(float), "snapshot must have no padding");

typedef struct
{
    vec3_t normal;
    float distance;
} CollisionPlane;

typedef struct
{
    const char *name;
    vec3_t start;
    vec3_t velocity;
    int planeCount;
    CollisionPlane planes[2];
} CollisionScenario;

/* Captured mp_galaxy wall geometry and the original fixture's numeric precision. */
static const vec3_t WallOrigin = {-16296, 100312, -24930};
static const vec3_t WallNormal = {0.498964429f, -0.866622448f, 0};
static const vec3_t WallTangent = {0.866622448f, 0.498964429f, 0};
static const float WallSeparation = 0.5f;
static const float SweepDegreesToRadians = 0.01745329251994f;
static const float CommandDegreesToRadians = 0.0174532925f;
static const float MillisecondsToSeconds = 0.001f;
static const float SlideRisePerMs = 0.05f; /* The sweep starts at 50 units/second upward. */
static const float MinimumSlideRiseFraction = 0.5f;
static const float MinimumCommandRiseFraction = 0.4f;
static const float CollisionEpsilon = 0.125f;
static const float WalkableNormalZ = 0.7f;
static const float TraceRegionMinY = 100000;
static const float TraceRegionMaxY = 100600;

static int replayingMovement;
static int scenariosStarted;
static int useSyntheticPlanes;
static int collisionPlaneCount;
static CollisionPlane collisionPlanes[2];

extern int __attribute__((regparm(3))) PM_SlideMove(struct pmove_t *movement,
                                                    struct pml_t *localMovement, int applyGravity);
extern void Pmove(struct pmove_t *movement);
extern void Cvar_Set(const char *name, const char *value);
extern int Cvar_VariableIntegerValue(const char *name);
extern void PM_playerTrace(struct pmove_t *movement, trace_t *trace, const float *start,
                           const float *mins, const float *maxs, const float *end, int passEntity,
                           int mask);
extern void StickyWallFixed(const float *origin, float *velocity, const float *normal,
                            float frameSeconds);

static void runMovementScenarios(const struct pmove_t *originalMovement,
                                 const playerState_t *originalPlayer);

/* Called just after the first native player trace, with its saved assembly frame. */
void StickyTrace(unsigned char *slideFrame)
{
    playerState_t *player = *(playerState_t **)(slideFrame - SlidePlayerPointerOffset);
    if(!scenariosStarted && !replayingMovement && player->origin[1] > TraceRegionMinY)
    {
        /* Mark first: the replay calls this same hook recursively. */
        scenariosStarted = 1;
        struct pmove_t *movement = *(struct pmove_t **)(slideFrame - SlideMovePointerOffset);
        runMovementScenarios(movement, player);
    }
    if(replayingMovement)
    {
        return;
    }
    if(player->origin[1] < TraceRegionMinY || player->origin[1] > TraceRegionMaxY)
    {
        return;
    }
    static int traceLines;
    if(traceLines >= MaximumTraceLines)
    {
        return;
    }
    traceLines++;
    const float *end = (float *)(slideFrame - SlideEndPositionOffset);
    const trace_t *trace = (trace_t *)(slideFrame - SlideTraceOffset);
    int bumpIndex = *(int *)(slideFrame - SlideBumpIndexOffset);
    float remainingSeconds = *(float *)(slideFrame - SlideTimeRemainingOffset);
    printf("NATIVE TRACE bump=%d dt=%.9g p=(%.9g,%.9g,%.9g) v=(%.9g,%.9g,%.9g) "
           "end=(%.9g,%.9g,%.9g) frac=%.9g n=(%.9g,%.9g,%.9g) all=%d start=%d\n",
           bumpIndex, remainingSeconds, player->origin[0], player->origin[1], player->origin[2],
           player->velocity[0], player->velocity[1], player->velocity[2], end[0], end[1], end[2],
           trace->fraction, trace->normal[0], trace->normal[1], trace->normal[2], trace->allsolid,
           trace->startsolid);
}

static void copyMovementState(struct pmove_t *movement, playerState_t *player,
                              const struct pmove_t *originalMovement,
                              const playerState_t *originalPlayer)
{
    memcpy(player, originalPlayer, sizeof(*player));
    memcpy(movement, originalMovement, sizeof(*movement));
    movement->ps = player;
    player->pm_time = 0;
}

static void placeAtWall(playerState_t *player, int tangentOffset, int height)
{
    player->origin[0] =
        WallOrigin[0] + WallNormal[0] * WallSeparation + WallTangent[0] * tangentOffset;
    player->origin[1] =
        WallOrigin[1] + WallNormal[1] * WallSeparation + WallTangent[1] * tangentOffset;
    player->origin[2] = WallOrigin[2] + height;
}

static void setRecoveryMode(int enabled)
{
    Cvar_Set("opencj_stickyWalls", enabled ? "1" : "0");
}

/* Alternate horizontal velocity while measuring lost upward movement at the wall. */
static void runAlternatingCase(const struct pmove_t *originalMovement,
                               const playerState_t *originalPlayer, int frameMs,
                               int horizontalSpeed, int tangentOffset, int reversalFrames)
{
    playerState_t player __attribute__((aligned(16)));
    struct pmove_t movement __attribute__((aligned(16)));
    LocalMovement localMovement __attribute__((aligned(16)));
    copyMovementState(&movement, &player, originalMovement, originalPlayer);
    memset(&localMovement, 0, sizeof(localMovement));
    localMovement.state.frametime = frameMs / 1000.0f;
    localMovement.state.msec = frameMs;
    placeAtWall(&player, tangentOffset, 0);
    player.velocity[2] = 50;
    int stalls = 0;
    float minimumRise = 1;
    for(int frame = 0; frame < SlideFramesPerCase; frame++)
    {
        int yaw = ((frame / reversalFrames) % 2) ? 165 : 75;
        player.velocity[0] = horizontalSpeed * cosf(yaw * SweepDegreesToRadians);
        player.velocity[1] = horizontalSpeed * sinf(yaw * SweepDegreesToRadians);
        float previousZ = player.origin[2];
        PM_SlideMove(&movement, &localMovement.state, 0);
        float rise = player.origin[2] - previousZ;
        if(rise < minimumRise)
        {
            minimumRise = rise;
        }
        if(rise < frameMs * SlideRisePerMs * MinimumSlideRiseFraction)
        {
            stalls++;
        }
    }
    printf("NATIVE ALTERNATE ms=%d speed=%d shift=%d period=%d stalls=%d minRise=%.9g vz=%.9g\n",
           frameMs, horizontalSpeed, tangentOffset, reversalFrames, stalls, minimumRise,
           player.velocity[2]);
}

/* Only the controlled parity cases replace world traces with simple planes. */
void StickyTestPlayerTrace(struct pmove_t *movement, trace_t *trace, const float *start,
                           const float *mins, const float *maxs, const float *end, int passEntity,
                           int mask)
{
    if(!useSyntheticPlanes)
    {
        PM_playerTrace(movement, trace, start, mins, maxs, end, passEntity, mask);
        return;
    }
    memset(trace, 0, sizeof(*trace));
    trace->fraction = 1;
    trace->hitId = ENTITYNUM_NONE;
    for(int planeIndex = 0; planeIndex < collisionPlaneCount; planeIndex++)
    {
        const CollisionPlane *plane = &collisionPlanes[planeIndex];
        float startDistance = -plane->distance;
        float endDistance = startDistance;
        for(int axis = 0; axis < 3; axis++)
        {
            startDistance += start[axis] * plane->normal[axis];
            endDistance += end[axis] * plane->normal[axis];
        }
        if(startDistance < 0 && endDistance < 0)
        {
            trace->startsolid = 1;
            trace->allsolid = 1;
            trace->fraction = 0;
            return;
        }
        if(endDistance >= startDistance || endDistance >= CollisionEpsilon)
        {
            continue;
        }
        float hitFraction =
            fmaxf(0, (startDistance - CollisionEpsilon) / (startDistance - endDistance));
        if(hitFraction < trace->fraction)
        {
            trace->fraction = hitFraction;
            memcpy(trace->normal, plane->normal, sizeof(trace->normal));
            trace->hitType = TRACE_HITTYPE_ENTITY;
            trace->hitId = ENTITYNUM_WORLD;
            trace->walkable = trace->normal[2] >= WalkableNormalZ;
        }
    }
}

/* Capture every position and velocity, so parity cannot hide a transient change. */
static void recordCollisionCase(const struct pmove_t *originalMovement,
                                const playerState_t *originalPlayer,
                                const CollisionScenario *scenario, int frameMs,
                                MovementSnapshot *snapshots)
{
    playerState_t player;
    struct pmove_t movement;
    LocalMovement localMovement;
    copyMovementState(&movement, &player, originalMovement, originalPlayer);
    memset(&localMovement, 0, sizeof(localMovement));
    localMovement.state.frametime = frameMs * MillisecondsToSeconds;
    memcpy(player.origin, scenario->start, sizeof(player.origin));
    memcpy(player.velocity, scenario->velocity, sizeof(player.velocity));
    for(int frame = 0; frame < SlideFramesPerCase; frame++)
    {
        PM_SlideMove(&movement, &localMovement.state, 0);
        memcpy(snapshots[frame].origin, player.origin, sizeof(player.origin));
        memcpy(snapshots[frame].velocity, player.velocity, sizeof(player.velocity));
    }
}

static void verifyOrdinaryCollisions(const struct pmove_t *originalMovement,
                                     const playerState_t *originalPlayer)
{
    const CollisionScenario scenarios[] = {
        {"free_air", {0, 0, 40}, {130, -75, 250}, 0, {{{0, 0, 0}, 0}}},
        {"floor_landing", {0, 0, 8}, {130, 75, -250}, 1, {{{0, 0, 1}, 0}}},
        {"ceiling_hit", {0, 0, 8}, {130, 75, 250}, 1, {{{0, 0, -1}, -16}}},
        {"ramp_impact", {0, 0, 8}, {130, 75, -250}, 1, {{{-0.6f, 0, 0.8f}, 0}}},
        {"inside_corner", {8, 8, 40}, {-130, -75, 50}, 2, {{{1, 0, 0}, 0}, {{0, 1, 0}, 0}}},
        {"corridor", {0, 0, 40}, {130, 75, 50}, 2, {{{1, 0, 0}, -8}, {{-1, 0, 0}, -8}}},
        {"large_axis_wall", {100010, 20, 40}, {-130, 75, 50}, 1, {{{1, 0, 0}, 100000}}},
        {"near_origin_diagonal", {8, 8, 40}, {-130, -75, 50}, 1, {{{0.6f, 0.8f, 0}, 0}}},
    };
    int previousMode = Cvar_VariableIntegerValue("opencj_stickyWalls");
    int failures = 0;
    int cases = 0;
    useSyntheticPlanes = 1;
    setbuf(stdout, NULL);
    puts("NATIVE REGRESSION START");
    for(unsigned int caseIndex = 0; caseIndex < sizeof(scenarios) / sizeof(*scenarios); caseIndex++)
    {
        const CollisionScenario *scenario = &scenarios[caseIndex];
        collisionPlaneCount = scenario->planeCount;
        memcpy(collisionPlanes, scenario->planes, sizeof(collisionPlanes));
        for(int frameMs = 1; frameMs <= 16; frameMs *= 2)
        {
            printf("NATIVE START case=%u ms=%d\n", caseIndex, frameMs);
            MovementSnapshot snapshots[2][SlideFramesPerCase];
            for(int mode = 0; mode < 2; mode++)
            {
                setRecoveryMode(mode);
                recordCollisionCase(originalMovement, originalPlayer, scenario, frameMs,
                                    snapshots[mode]);
            }
            int identical = memcmp(snapshots[0], snapshots[1], sizeof(snapshots[0])) == 0;
            cases++;
            failures += !identical;
            printf("NATIVE REGRESSION case=%s ms=%d identical=%d\n", scenario->name, frameMs,
                   identical);
        }
    }
    useSyntheticPlanes = 0;
    setRecoveryMode(previousMode);
    printf("NATIVE REGRESSION COMPLETE cases=%d failures=%d\n", cases, failures);
}

/* Replay WA/WD commands through full native acceleration, gravity and collision. */
static void runCommandCase(const struct pmove_t *originalMovement,
                           const playerState_t *originalPlayer, int mode, int frameMs,
                           int reversalMs, int yaw, int tangentOffset, int height)
{
    playerState_t player __attribute__((aligned(16)));
    struct pmove_t movement __attribute__((aligned(16)));
    copyMovementState(&movement, &player, originalMovement, originalPlayer);
    placeAtWall(&player, tangentOffset, height);
    player.velocity[0] = 180 * cosf(yaw * CommandDegreesToRadians);
    player.velocity[1] = 180 * sinf(yaw * CommandDegreesToRadians);
    player.velocity[2] = 250;
    player.gravity = 800;
    player.groundEntityNum = ENTITYNUM_NONE;
    memset(player.delta_angles, 0, sizeof(player.delta_angles));
    player.viewangles[0] = 0;
    player.viewangles[1] = yaw;
    player.viewangles[2] = 0;
    setRecoveryMode(mode);
    int stalls = 0;
    int steps = 0;
    for(int elapsedMs = 0; elapsedMs < CommandDurationMs; elapsedMs += frameMs)
    {
        movement.oldcmd = movement.cmd;
        movement.cmd.serverTime = player.commandTime + frameMs;
        movement.cmd.buttons = 0;
        movement.cmd.angles[0] = 0;
        /* Native user commands encode a full turn in 16 bits. */
        movement.cmd.angles[1] = (int)(yaw * 65536.0f / 360);
        movement.cmd.angles[2] = 0;
        movement.cmd.forwardmove = MaximumCommandMovement;
        movement.cmd.rightmove =
            ((elapsedMs / reversalMs) % 2) ? MaximumCommandMovement : -MaximumCommandMovement;
        float previousZ = player.origin[2];
        float previousVerticalSpeed = player.velocity[2];
        Pmove(&movement);
        steps++;
        float minimumRise =
            previousVerticalSpeed * frameMs * MillisecondsToSeconds * MinimumCommandRiseFraction;
        if(previousVerticalSpeed > 30 && player.velocity[2] > 0 &&
           player.origin[2] - previousZ < minimumRise)
        {
            stalls++;
        }
    }
    printf("NATIVE COMMAND mode=%d ms=%d period=%d yaw=%d offset=%d height=%d stalls=%d "
           "steps=%d end=(%.9g,%.9g,%.9g) velocity=(%.9g,%.9g,%.9g)\n",
           mode, frameMs, reversalMs, yaw, tangentOffset, height, stalls, steps, player.origin[0],
           player.origin[1], player.origin[2], player.velocity[0], player.velocity[1],
           player.velocity[2]);
}

static void verifyCommandSequences(const struct pmove_t *originalMovement,
                                   const playerState_t *originalPlayer)
{
    int previousMode = Cvar_VariableIntegerValue("opencj_stickyWalls");
    /* This Cartesian product is the test matrix: 700 cases per recovery mode. */
    for(int mode = 0; mode < 2; mode++)
    {
        for(int frameMs = 2; frameMs <= 8; frameMs++)
        {
            for(int reversalMs = 40; reversalMs <= 200; reversalMs += 40)
            {
                for(int yaw = 85; yaw <= 120; yaw += 35)
                {
                    for(int tangentOffset = -8; tangentOffset <= 8; tangentOffset += 4)
                    {
                        for(int height = 0; height <= 32; height += 32)
                        {
                            runCommandCase(originalMovement, originalPlayer, mode, frameMs,
                                           reversalMs, yaw, tangentOffset, height);
                        }
                    }
                }
            }
        }
    }
    setRecoveryMode(previousMode);
}

static void runMovementScenarios(const struct pmove_t *originalMovement,
                                 const playerState_t *originalPlayer)
{
    replayingMovement = 1;
    /* Keep the full 1,728-case matrix; the leaf helper owns each replay. */
    for(int frameMs = 1; frameMs <= 8; frameMs++)
    {
        for(int horizontalSpeed = 60; horizontalSpeed <= 360; horizontalSpeed += 60)
        {
            for(int tangentOffset = -4; tangentOffset <= 4; tangentOffset++)
            {
                for(int reversalFrames = 1; reversalFrames <= 8; reversalFrames *= 2)
                {
                    runAlternatingCase(originalMovement, originalPlayer, frameMs, horizontalSpeed,
                                       tangentOffset, reversalFrames);
                }
            }
        }
    }
    verifyOrdinaryCollisions(originalMovement, originalPlayer);
    verifyCommandSequences(originalMovement, originalPlayer);
    replayingMovement = 0;
}

/* Test-only baseline selection; the production helper is unconditional. */
void OpenCJ_StickyWallRecovery(const float *origin, float *velocity, const float *normal,
                               float frameSeconds)
{
    if(Cvar_VariableIntegerValue("opencj_stickyWalls"))
    {
        StickyWallFixed(origin, velocity, normal, frameSeconds);
    }
}
