///
/// Player demos, shared between libcod and cod4x
///

/**************************************************************************
 * Includes                                                               *
 **************************************************************************/

#include "opencj_demo_fps.hpp"
#include "opencj_demo_technique.hpp"
#include "mysql_async_pool.hpp"
#include <chrono>
// Read zlib declarations before CoD2 defines its legacy "level" macro.
#ifdef COD4
#include "../cod4x-server/src/zlib/zlib.h"
#else
#include <zlib.h>
#endif
#include "shared.hpp"

#include <cstring>
#include <map>
#include <new>
#include <cmath>
#include <algorithm>
#include <string>
#include <vector>
#ifdef COD4
extern "C" {
#include "../cod4x-server/src/filesystem.h"
#include "../cod4x-server/src/bg.h"
#include "../cod4x-server/src/bg_public.h"
// Animation selection only: no Pmove, weapon simulation or gameplay events.
void BG_AnimUpdatePlayerStateConditions(pmove_t *);
int BG_AnimScriptAnimation(playerState_t *, int, int, int);
int BG_AnimScriptEvent(playerState_t *, int, int, int);
void BG_SetConditionValue(int, int, unsigned long long);
}
#endif

/**************************************************************************
 * Defines                                                                *
 **************************************************************************/

// Max number of demos per map that are available for playback
#define MAX_NR_DEMOS_PER_MAP            128

// Shared with the GSC demo HUD and persisted recordings.
enum DemoFrameFlag {
    DEMO_LEFT = 1,
    DEMO_RIGHT = 2,
    DEMO_FORWARD = 4,
    DEMO_BACK = 8,
    DEMO_SPRINT_BUTTON = 16,
    DEMO_JUMP_BUTTON = 32,
    DEMO_SPRINTING = 64,
    DEMO_MANTLING = 128,
    DEMO_LADDER = 256,
    DEMO_STANDING = 512,
    DEMO_CROUCHED = 1024,
    DEMO_PRONE = 2048,
    DEMO_RPG_WEAPON = 4096,
    DEMO_GROUNDED = 8192,
    DEMO_BOUNCE = 16384
};
constexpr int DEMO_DIRECTION_MASK = DEMO_LEFT | DEMO_RIGHT | DEMO_FORWARD | DEMO_BACK;
constexpr int DEMO_ACTIVE_INPUT_MASK = DEMO_DIRECTION_MASK | DEMO_SPRINT_BUTTON |
                                       DEMO_JUMP_BUTTON | DEMO_SPRINTING |
                                       DEMO_MANTLING | DEMO_LADDER;
constexpr int DEMO_FRAME_TIME_MS = 50;
constexpr float DEMO_FRAMES_PER_SECOND = 20;
constexpr float DEMO_VELOCITY_SCALE = 4;
constexpr float DEMO_LADDER_SCALE = 32767;
constexpr int DEMO_INITIAL_CAPACITY = 1024;
constexpr int DEMO_MANUAL_HISTORY_LIMIT = 1200;
constexpr int DEMO_TRANSITION_SCAN_FRAMES = 80;
constexpr int DEMO_NORMAL_MOVEMENT = 0;
constexpr int DEMO_WEAPON_LIMIT = 128;
constexpr int DEMO_WEAPON_READY_STATE = 0;
constexpr int DEMO_WEAPON_FIRING_STATE = 5;
constexpr int DEMO_WEAPON_HOLD_TIME_MS = 1000;
constexpr int DEMO_TELEPORT_TOGGLE = 2;
constexpr int DEMO_FROZEN_MOVEMENT_FLAG = 0x800;
constexpr int DEMO_SPECTATOR_INTERPOLATION_FLAG = 2;
constexpr int DEMO_DISABLED_WEAPON_FLAG = 0x80;
constexpr int DEMO_MANTLE_MOVEMENT_FLAG = 4;
constexpr int DEMO_LADDER_MOVEMENT_FLAG = 8;
constexpr float DEMO_MAX_CONTINUOUS_DISTANCE = 256;

// Magic number to know if a demo is initialized / used for validity checking
#define DEMO_MAGIC_NUMBER               (uint32_t)0x7fd126ea

/**************************************************************************
 * Types                                                                  *
 **************************************************************************/

struct DemoVisual {
    bool valid;
    uint16_t weapon;
    uint16_t weaponTime;
    uint16_t weaponDelay;
    uint16_t animation;
    uint8_t weaponState;
    uint8_t bobCycle;
    float viewHeight;
    float ads;
    int16_t velocity[3];
    int16_t ladder[3];
    uint16_t sprintElapsed;
    uint16_t mantleTimer;
    uint16_t mantleYaw;
    uint8_t mantleTransition;
    uint8_t mantleFlags;
    uint8_t landingEvent;
    uint8_t landingImpact;
};

#ifdef COD4
static playerState_t *demoReturnVisual[MAX_CLIENTS];
static int demoPresentedWeapon[MAX_CLIENTS];
static int demoPresentedFrame[MAX_CLIENTS];
static qboolean demoReturnFrozen[MAX_CLIENTS];
struct DemoBody {
    bool valid;
    int legs;
    int torso;
    int legsDuration;
    int torsoDuration;
    int direction;
    int event;
    int eventFrame;
    int eventWeapon;
    int eventDuration;
    int eventLegs;
    int eventTorso;
    int eventLegsDuration;
    int eventTorsoDuration;
};
static DemoBody demoPresentedBody[MAX_CLIENTS];

static_assert(__builtin_offsetof(gclient_t, bFrozen)==0x3080, "CoD4 freeze-controls layout mismatch");
static const char *demoWeaponName(unsigned weapon)
{
    if (!weapon)
    {
        return "none";
    }
    const WeaponDef *def = BG_GetWeaponDef(weapon);
    return def ? def->szInternalName : "none";
}

static std::map<unsigned,std::string> demoFireSounds;
static const char *demoFireSound(unsigned weapon)
{
    auto found = demoFireSounds.find(weapon);
    if (found != demoFireSounds.end())
    {
        return found->second.c_str();
    }
    // Dedicated-server weapon defs omit sound assets; use the same weapon file
    // that supplied the gameplay definition. Cache once per weapon/map.
    std::string alias;
    std::string path = "weapons/mp/";
    path += demoWeaponName(weapon);
    void *buffer = nullptr;
    int length = FS_ReadFile(path.c_str(), &buffer);
    if (length > 0 && buffer)
    {
        std::string data(static_cast<char *>(buffer), length);
        const std::string key = "\\fireSoundPlayer\\";
        size_t begin = data.find(key);
        if (begin != std::string::npos)
        {
            begin += key.size();
            size_t end = data.find('\\', begin);
            if (end != std::string::npos && end - begin < 128)
            {
                alias = data.substr(begin, end - begin);
            }
        }
    }
    if (buffer)
    {
        FS_FreeFile(buffer);
    }
    return demoFireSounds.emplace(weapon, alias).first->second.c_str();
}

static uint16_t demoU16(int value) {
    return std::max(0, std::min(65535, value));
}

// Capture viewmodel and movement state, converting damage events to harmless landing motion.
static DemoVisual captureDemoVisual(const playerState_t &playerState, bool rpg, int previousEventSequence)
{
    DemoVisual visual = {};
    visual.valid = true;
    visual.weapon = playerState.weapon;
    visual.weaponTime = demoU16(playerState.weaponTime);
    visual.weaponDelay = demoU16(playerState.weaponDelay);
    visual.animation = playerState.weapAnim;
    visual.weaponState = playerState.weaponstate;
    visual.bobCycle = playerState.bobCycle;
    visual.viewHeight = playerState.viewHeightCurrent;
    visual.ads = playerState.fWeaponPosFrac;
    for (int i = 0; i < 3; ++i)
    {
        visual.velocity[i] = std::max(-32767, std::min(32767, int(playerState.velocity[i] * DEMO_VELOCITY_SCALE)));
        visual.ladder[i] = std::max(-32767, std::min(32767, int(playerState.vLadderVec[i] * DEMO_LADDER_SCALE)));
    }
    visual.sprintElapsed = demoU16(playerState.commandTime - playerState.sprintState.lastSprintStart);
    visual.mantleTimer = demoU16(playerState.mantleState.timer);
    visual.mantleYaw = uint16_t(int(playerState.mantleState.yaw * 65536.0f / 360.0f));
    visual.mantleTransition = playerState.mantleState.transIndex;
    visual.mantleFlags = playerState.mantleState.flags;
    // Only new engine events since the preceding recorded frame. The ring and
    // sequence wrap at 4 and 256 respectively. Never replay fall damage.
    int count = std::min(4, (playerState.eventSequence - previousEventSequence) & 255);
    for (int i = count; i > 0; --i)
    {
        int slot = (playerState.eventSequence - i) & 3;
        int event = playerState.events[slot];
        int impact = playerState.eventParms[slot];
        if (event >= EV_LANDING_PAIN_DEFAULT && event <= EV_LANDING_PAIN_PAINTEDMETAL)
        {
            float minimum = Cvar_VariableValue("bg_fallDamageMinHeight");
            float height =
                minimum + (Cvar_VariableValue("bg_fallDamageMaxHeight") - minimum) * impact * 0.01f;
            impact = height > 12 ? std::min(24, int(4 + (height - 12) * 4 / 26)) : 0;
            event -= EV_LANDING_PAIN_DEFAULT - EV_LANDING_DEFAULT;
        }
        if (event >= EV_LANDING_DEFAULT && event <= EV_LANDING_PAINTEDMETAL && impact > 0)
        {
            visual.landingEvent = event;
            visual.landingImpact = std::min(24, impact);
        }
    }
    // Do not retain ordinary gun/pistol firing animations.
    if (!rpg && playerState.weaponstate == DEMO_WEAPON_FIRING_STATE)
    {
        visual.weaponState = DEMO_WEAPON_READY_STATE;
        visual.weaponTime = 0;
        visual.weaponDelay = 0;
        visual.animation = 0;
    }
    return visual;
}
#endif

typedef struct
{
    DemoVisual visual;
    float origin[3];    // Origin of the player at this frame
    float angles[3];    // Angles of the player at this frame
    short flags;		// flags that store button/stance/weapon stuff
    int checkpointId;
    short fps; 			// fps
    bool saveNow;		// if this was a frame on which the player saved
    bool loadNow;		// if this was a frame on which the player loaded
    bool rpgNow;		// if this was a frame on which the player rpg'd
    bool eleKnown;
    bool eleUsed; // Actual elevation event; unknown in legacy recordings.
    bool isKeyFrame;    // Is this frame a 'key' frame, i.e. did the player's complete run contain this frame?
                        // This may change during the demo, if the player loads back to before this frame
    int prevKeyFrame;   // When skipping backwards through demos
    int nextKeyFrame;   // When skipping forwards through demos

    // More fields after PoC
} sDemoFrame_t;

typedef struct
{
    uint32_t magic;             // Magic number to hopefully provide clear errors when unexpected memory is accessed
    int id;                     // Unique ID of the demo (== runID of player)
    bool isComplete;            // Whether (or not) this demo has been completed and thus its size will not increase
    bool isFirstFrameFilled;    // Whether or not the first frame is already filled (at the start, currentFrame is 0 but it has not been filled yet)
    int size;                   // Size. This can change if the demo was not yet finished
    sDemoFrame_t *pDemoFrames;  // Pointer to all frames of this demo (not used as handle because can be re-allocated)
    int nrAllocatedFrames;      // Number of currently allocated frames for this demo
    int currentFrame;           // Index of the last frame of this demo (actively updated)
    int lastKeyFrame;           // To remember which demo frame is the current last key frame
    int captureEventSequence;
    int captureTime;
    int captureTeleportBit;
    unsigned long long generation;
    // Mutations invalidate viewer samples without changing SQL load ownership.
    unsigned long long editVersion;
    unsigned pins;
    bool releasePending;
} sDemo_t;

typedef struct
{
    const sDemo_t *pDemo;   // The demo that is being watched
    int selectedFrame;      // The last selected frame (i.e. player is watching this frame)
} sDemoPlayback_t;

/**************************************************************************
 * Globals                                                                *
 **************************************************************************/

// For now max. number of demos per map
static sDemo_t opencj_demos[MAX_NR_DEMOS_PER_MAP];
// For faster access every time an id is provided, use a map
static std::map<uint32_t, uint16_t> opencj_demoIdToIdx;

// A player can only watch 1 demo at a time
static sDemoPlayback_t opencj_playback[MAX_CLIENTS];
// Per-viewer edit lists share the original recording; no duplicate DB payloads.
static std::vector<int> demoPlaybackTimeline[MAX_CLIENTS];
static DemoFPSText demoFPSText[MAX_CLIENTS];
static unsigned long long demoGeneration=0;

static bool rejectInvalidDemoClient(int clientNum);

// A recording can be empty or shortened after this viewer selected it.
static bool hasSelectedDemoFrame(const sDemoPlayback_t &playback)
{
    return playback.pDemo && playback.pDemo->pDemoFrames &&
           playback.selectedFrame >= 0 && playback.selectedFrame < playback.pDemo->size;
}

// One transformed sample per viewer, never another copy of the full recording.
struct DemoTechniqueState {
    int mode;
    int index;
    unsigned long long generation;
    unsigned long long frameVersion;
    bool valid;
    bool fallback;
    sDemoFrame_t frame;
    CJ_DemoSection section;
    unsigned long long sectionGeneration;
    unsigned long long sectionVersion;
    int sectionSize;
};
static DemoTechniqueState demoTechnique[MAX_CLIENTS];
// Transform a borrowed source frame into one viewer-owned sample; never edit the recording.
static sDemoFrame_t &techniqueFrame(int client, const sDemo_t &demo, int index)
{
    DemoTechniqueState &state = demoTechnique[client];
    if (state.valid && state.generation == demo.generation && state.frameVersion == demo.editVersion &&
        state.index == index)
    {
        return state.frame;
    }
    state.frame = demo.pDemoFrames[index];
    state.generation = demo.generation;
    state.frameVersion = demo.editVersion;
    state.index = index;
    state.valid = true;
    state.fallback = false;
    if (!state.mode)
    {
        return state.frame;
    }
    auto readInput = [&](int i) {
        const sDemoFrame_t &frame = demo.pDemoFrames[i];
        bool excluded = (frame.flags & (DEMO_MANTLING | DEMO_LADDER)) != 0;
        return CJ_DemoInput{int(bool(frame.flags & DEMO_FORWARD)) - int(bool(frame.flags & DEMO_BACK)),
                            int(bool(frame.flags & DEMO_RIGHT)) - int(bool(frame.flags & DEMO_LEFT)),
                            bool(frame.flags & DEMO_GROUNDED),
                            frame.loadNow,
                            excluded,
                            frame.rpgNow};
    };
    if (state.sectionGeneration != demo.generation || state.sectionVersion != demo.editVersion ||
        state.sectionSize != demo.size ||
        index < state.section.beginFrame || index >= state.section.endFrame)
    {
        state.section = CJ_AnalyzeDemoTechnique(demo.size, index, readInput);
        state.sectionGeneration = demo.generation;
        state.sectionVersion = demo.editVersion;
        state.sectionSize = demo.size;
    }
    CJ_DemoTechnique result = CJ_ApplyDemoTechnique(index, state.mode, readInput(index), state.section);
    state.fallback = result.fallback;
    state.frame.flags &= ~DEMO_DIRECTION_MASK;
    if (result.forward > 0)
    {
        state.frame.flags |= DEMO_FORWARD;
    }
    else if (result.forward < 0)
    {
        state.frame.flags |= DEMO_BACK;
    }
    if (result.right > 0)
    {
        state.frame.flags |= DEMO_RIGHT;
    }
    else if (result.right < 0)
    {
        state.frame.flags |= DEMO_LEFT;
    }
    auto readCamera = [&](int i) {
        const CJ_DemoInput input = readInput(i);
        const bool outside = i < state.section.beginFrame || i >= state.section.endFrame;
        CJ_DemoTechnique view = CJ_ApplyDemoTechnique(i, state.mode, input, state.section);
        // Shot aiming is a short camera-only flick, independent of the general
        // strafe smoothing and the converted keys.
        const bool locked = outside || input.ground || input.excluded || view.fallback;
        return CJ_DemoCameraSample{demo.pDemoFrames[i].angles[1], locked ? 0 : view.yawOffset,
                                   input.cut, locked, input.shot};
    };
    state.frame.angles[1] = std::remainder(CJ_SmoothDemoYaw(demo.size, index, readCamera), 360.0f);
    return state.frame;
}

void Gsc_Demo_SetTechnique(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    int mode;
    if (!stackGetParams("i", &mode) || mode < CJ_DEMO_ORIGINAL || mode > CJ_DEMO_INVERT) {
        stackPushBool(false);
        return;
    }
    demoTechnique[client].mode = mode;
    demoTechnique[client].valid = false;
    demoFPSText[client].clear();
    stackPushBool(true);
}

void Gsc_Demo_TechniqueFallback(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (!hasSelectedDemoFrame(playback)) {
        stackPushBool(false);
        return;
    }
    techniqueFrame(client, *playback.pDemo, playback.selectedFrame);
    stackPushBool(demoTechnique[client].fallback);
}


void Gsc_Demo_TechniquePhase(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (!hasSelectedDemoFrame(playback)) {
        stackPushInt(0);
        return;
    }
    techniqueFrame(client, *playback.pDemo, playback.selectedFrame);
    const auto &state = demoTechnique[client];
    const auto &section = state.section;
    if (!state.mode || state.fallback || !section.style) {
        stackPushInt(0);
        return;
    }
    int mode = state.mode;
    if ((mode == CJ_DEMO_HALFBEAT || mode == CJ_DEMO_INVERT) && playback.selectedFrame < section.takeoffEndFrame) {
        mode = CJ_DEMO_FULLBEAT;
    }
    stackPushInt((mode << 4) | (section.anchorForward > 0 ? DEMO_FORWARD : DEMO_BACK) |
                 (section.anchorRight > 0 ? DEMO_RIGHT : DEMO_LEFT));
}

void Gsc_Demo_ReadFrame_Checkpoint(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (!hasSelectedDemoFrame(playback)) {
        stackPushUndefined();
        return;
    }
    stackPushInt(playback.pDemo->pDemoFrames[playback.selectedFrame].checkpointId);
}


/**************************************************************************
 * Local functions                                                        *
 **************************************************************************/

static sDemo_t *findDemoById(int demoId)
{
    sDemo_t *pDemo = NULL;
    auto it = opencj_demoIdToIdx.find(demoId);
    if (it == opencj_demoIdToIdx.end())
    {
        printf("Demo with id %d was not found or is empty\n", demoId);
    }
    else
    {
        pDemo = &opencj_demos[it->second];
    }

    return pDemo;
}

static void cancelDemoLoads(const sDemo_t &demo);

static void clearDemoById(int demoId)
{
    auto it = opencj_demoIdToIdx.find(demoId);
    if (it != opencj_demoIdToIdx.end())
    {
        sDemo_t *pDemo = &opencj_demos[it->second];
        opencj_demoIdToIdx.erase(it);

        // Clear demo data, free up this spot
        if ((pDemo->magic != DEMO_MAGIC_NUMBER) || (pDemo->id <= 0))
        {
            printf("Demo is already clear (%p)\n", pDemo);
            return;
        }

        cancelDemoLoads(*pDemo);
        printf("Clearing demo with pointer %p\n", pDemo);
        if (pDemo->pDemoFrames)
        {
            delete[] pDemo->pDemoFrames;
            pDemo->pDemoFrames = nullptr;
        }

        for (int i = 0; i < MAX_CLIENTS; ++i)
        {
            if (opencj_playback[i].pDemo == pDemo)
            {
                std::vector<int>().swap(demoPlaybackTimeline[i]);
                demoFPSText[i].clear();
                memset(&opencj_playback[i], 0, sizeof(opencj_playback[i]));
            }
        }
        memset(pDemo, 0, sizeof(*pDemo));
    }
}

static void clearAllDemos()
{
    for (int i = 0; i < MAX_CLIENTS; ++i) {
        demoFPSText[i].clear();
        std::vector<int>().swap(demoPlaybackTimeline[i]);
    }
    memset(demoTechnique, 0, sizeof(demoTechnique));
    printf("Clearing all demos\n");
#ifdef COD4
    for (int i = 0; i < MAX_CLIENTS; ++i) {
        delete demoReturnVisual[i];
        demoReturnVisual[i] = nullptr;
    }
    demoFireSounds.clear();
#endif
    for (int i = 0; i < (int)(sizeof(opencj_demos) / sizeof(opencj_demos[0])); i++) {
        clearDemoById(opencj_demos[i].id);
    }
}

// Bound all allocations, including fixed history copies, on the 32-bit server.
static const size_t demoMemoryLimit = 128 * 1024 * 1024;
static size_t allocatedDemoBytes()
{
    size_t bytes = 0;
    for (int i = 0; i < MAX_NR_DEMOS_PER_MAP; ++i)
    {
        bytes += opencj_demos[i].nrAllocatedFrames * sizeof(sDemoFrame_t);
    }
    return bytes;
}

static sDemo_t *createDemo(int demoId, int capacity = DEMO_INITIAL_CAPACITY)
{
    if (findDemoById(demoId) != NULL)
    {
        printf("Demo with id %d already exists!\n", demoId);
        return NULL;
    }

    printf("Creating demo with id %d\n", demoId);

    if (capacity < 1 || size_t(capacity) > demoMemoryLimit / sizeof(sDemoFrame_t) ||
        allocatedDemoBytes() + size_t(capacity) * sizeof(sDemoFrame_t) > demoMemoryLimit)
    {
        return NULL;
    }
    sDemo_t *pDemo = NULL;
    for (int i = 0; i < (int)(sizeof(opencj_demos) / sizeof(opencj_demos[0])); i++)
    {
        printf("Checking for free slot at %d\n", i);
        if (opencj_demos[i].id <= 0)
        {
            // Free slot
            pDemo = &opencj_demos[i];
            opencj_demoIdToIdx[demoId] = i;
            break;
        }
    }

    if (pDemo)
    {
        memset(pDemo, 0, sizeof(*pDemo));

        pDemo->magic = DEMO_MAGIC_NUMBER;
        pDemo->id = demoId;
        pDemo->generation = ++demoGeneration;

        pDemo->nrAllocatedFrames = capacity;
        pDemo->pDemoFrames = new (std::nothrow) sDemoFrame_t[pDemo->nrAllocatedFrames]();
        if (!pDemo->pDemoFrames)
        {
            clearDemoById(demoId);
            return NULL;
        }
    }

    return pDemo;
}

// Reserve a whole operation before changing its frames or key-frame links.
// Both buffers coexist while copying, so the memory budget includes that peak.
static bool reserveDemoFrames(sDemo_t *demo, size_t requiredFrames)
{
    if (requiredFrames <= size_t(demo->nrAllocatedFrames))
    {
        return true;
    }
    const size_t capacity = std::max(size_t(demo->nrAllocatedFrames) * 2, requiredFrames);
    if (capacity > demoMemoryLimit / sizeof(sDemoFrame_t) ||
        allocatedDemoBytes() + capacity * sizeof(sDemoFrame_t) > demoMemoryLimit)
    {
        return false;
    }
    sDemoFrame_t *frames = new (std::nothrow) sDemoFrame_t[capacity]();
    if (!frames)
    {
        return false;
    }
    memcpy(frames, demo->pDemoFrames, demo->size * sizeof(*frames));
    delete[] demo->pDemoFrames;
    demo->pDemoFrames = frames;
    demo->nrAllocatedFrames = capacity;
    return true;
}

static bool appendDemoFrame(sDemo_t *demo, const sDemoFrame_t &frame)
{
    if (demo->isComplete || !reserveDemoFrames(demo, size_t(demo->size) + 1))
    {
        return false;
    }
    const int index = demo->size;
    sDemoFrame_t &next = demo->pDemoFrames[index];
    next = frame;
    next.nextKeyFrame = index;
    next.prevKeyFrame = index ? demo->lastKeyFrame : 0;
    if (next.isKeyFrame)
    {
        for (int i = demo->lastKeyFrame; i < index; ++i)
        {
            demo->pDemoFrames[i].nextKeyFrame = index;
        }
        demo->lastKeyFrame = index;
    }
    demo->size++;
    ++demo->editVersion;
    demo->currentFrame = index;
    demo->isFirstFrameFilled = true;
    return true;
}

/**************************************************************************
 * Helper functions                                                       *
 **************************************************************************/

static bool rejectInvalidDemoClient(int clientNum)
{
    if ((clientNum < 0) || (clientNum >= MAX_CLIENTS))
    {
        stackError("clientNum %d out of range", clientNum);
        return true;
    }

    return false;
}

static bool Base_Gsc_GetValidDemoId(int *pDemoId, int nrArgsExpected)
{
    if (!pDemoId)
    {
        return false;
    }

    int nrReceivedArgs = Scr_GetNumParam();
    if (nrReceivedArgs != nrArgsExpected)
    {
        stackError("Expected %d arguments, but got %d", nrArgsExpected, nrReceivedArgs);
        stackPushUndefined();
        return false;
    }

    int demoId = -1;
    if (stackGetParamType(0) != STACK_INT)
    {
        stackError("Argument 1 (demoId) is not an int");
        stackPushUndefined();
        return false;
    }
    stackGetParamInt(0, &demoId);

    if (demoId <= 0)
    {
        stackError("Argument 1 (demoId) is not > 0");
        stackPushUndefined();
        return false;
    }

    *pDemoId = demoId;
    return true;
}

// Follow at most one link per stored frame, even for an extreme script argument.
static int skipDemoKeyFrames(const sDemo_t &demo, int selectedFrame, int framesToSkip)
{
    const bool reverse = framesToSkip < 0;
    const long long requestedSteps = std::abs(static_cast<long long>(framesToSkip));
    const long long steps = std::min(requestedSteps, static_cast<long long>(demo.size));
    for (long long step = 0; step < steps; ++step)
    {
        const sDemoFrame_t &frame = demo.pDemoFrames[selectedFrame];
        const int nextFrame = reverse ? frame.prevKeyFrame : frame.nextKeyFrame;
        if (nextFrame == selectedFrame || nextFrame < 0 || nextFrame >= demo.size)
        {
            break;
        }
        selectedFrame = nextFrame;
    }
    return selectedFrame;
}

// Clamp seeks to recorded frames. Widen before adding or negating script integers.
static void Base_Gsc_Demo_FrameSkip(int client, int framesToSkip, bool keyFrames)
{
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    sDemoPlayback_t &playback = opencj_playback[client];
    const sDemo_t *demo = playback.pDemo;
    if (!demo || !demo->pDemoFrames || demo->size <= 0)
    {
        stackPushUndefined();
        return;
    }

    const int selectedFrame = std::clamp(playback.selectedFrame, 0, demo->size - 1);
    long long requestedFrame = static_cast<long long>(selectedFrame) + framesToSkip;
    const auto &timeline = demoPlaybackTimeline[client];
    if (keyFrames && !timeline.empty())
    {
        const auto selected = std::lower_bound(timeline.begin(), timeline.end(), selectedFrame);
        const long long timelineIndex = selected - timeline.begin();
        const long long requestedIndex = std::clamp(
            timelineIndex + framesToSkip, 0LL, static_cast<long long>(timeline.size()) - 1);
        requestedFrame = timeline[requestedIndex];
    }
    else if (keyFrames)
    {
        requestedFrame = skipDemoKeyFrames(*demo, selectedFrame, framesToSkip);
    }
    playback.selectedFrame = std::clamp(requestedFrame, 0LL, static_cast<long long>(demo->size) - 1);
    stackPushInt(playback.selectedFrame);
}

//==========================================================================
// Functions that do work for any demo                                        
//==========================================================================

void Gsc_Demo_ClearAllDemos()
{
    clearAllDemos();
}

void Gsc_Demo_HasKeyFrames()
{
    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, 1))
    {
        return;
    }

    const sDemo_t *pDemo = findDemoById(demoId);
    if (!pDemo)
    {
        stackPushUndefined();
    }
    else
    {
        //printf("Returning %d numberOfFrames for demo %d\n", pDemo->size, demoId);
        stackPushInt((pDemo->lastKeyFrame == 0) ? 0 : 1);
    }
}

void Gsc_Demo_NumberOfFrames()
{
    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, 1))
    {
        return;
    }

    const sDemo_t *pDemo = findDemoById(demoId);
    if (!pDemo)
    {
        stackPushUndefined();
    }
    else
    {
        //printf("Returning %d numberOfFrames for demo %d\n", pDemo->size, demoId);
        stackPushInt(pDemo->size);
    }
}

void Gsc_Demo_NumberOfKeyFrames()
{
    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, 1))
    {
        return;
    }

    const sDemo_t *pDemo = findDemoById(demoId);
    if (!pDemo)
    {
        stackPushUndefined();
    }
    else
    {
        int nrOfKeyFrames = 0;
        int iter = 0;
        while (iter < pDemo->size)
        {
            sDemoFrame_t *pFrame = &pDemo->pDemoFrames[iter];
            if (pFrame->isKeyFrame)
            {
                nrOfKeyFrames++;
            }

            // Sanity check for development
            int nextKeyFrame = pFrame->nextKeyFrame;
            if (nextKeyFrame < iter)
            {
                printf("Key frame %d goes backwards to key frame %d??\n", iter, nextKeyFrame);
                stackPushUndefined();
                return;
            }

            // Check if we found the last key frame
            if (nextKeyFrame == iter)
            {
                break;
            }

            // Skip to next key frame. TODO: how will this go with keyframe branching?
            iter = nextKeyFrame;
        }
        printf("Returning %d numberOfKeyFrames for demo %d\n", nrOfKeyFrames, demoId);
        stackPushInt(nrOfKeyFrames);
    }
}

void Gsc_Demo_CreateDemo()
{
    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, 1))
    {
        return;
    }

    sDemo_t *pDemo = findDemoById(demoId);
    if (pDemo)
    {
        printf("Demo with id %d already loaded!\n", demoId);
        stackPushInt(-1);
        return;
    }

    pDemo = createDemo(demoId);
    if (!pDemo)
    {
        printf("No free demo slots available (wow)!\n");
        stackPushInt(-2);
        return;
    }

    stackPushInt(demoId);
    printf("Created demo with id %d\n", demoId);
}

void Gsc_Demo_DestroyDemo()
{
    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, 1))
    {
        return;
    }

    printf("Destroying demo with id %d\n", demoId);
    sDemo_t *demo = findDemoById(demoId);
    if (demo && demo->pins)
    {
        demo->releasePending = true;
    } else
    {
        clearDemoById(demoId);
    }
}

void Gsc_Demo_AddFrame()
{
    const int nrExpectedArgs = Scr_GetNumParam();
    if (nrExpectedArgs != 9 && nrExpectedArgs != 10 && nrExpectedArgs != 11 && nrExpectedArgs != 12)
    {
        stackPushUndefined();
        stackError("AddFrame expects 9 arguments: demoId, origin, angles, isKeyFrame, flags, "
                   "saveNow, loadNow, rpgNow, fps");
        return;
    }

    // Argument 1: demoId
    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, nrExpectedArgs))
    {
        return;
    }

    // Argument 2: origin
    if (stackGetParamType(1) != STACK_VECTOR)
    {
        stackPushUndefined();
        stackError("Argument 2 (origin) is not a vector");
        return;
    }
    vec3_t origin;
    stackGetParamVector(1, origin);

    // Argument 3: angles
    if (stackGetParamType(2) != STACK_VECTOR)
    {
        stackPushUndefined();
        stackError("Argument 3 (angles) is not a vector");
        return;
    }
    vec3_t angles;
    stackGetParamVector(2, angles);

    // Argument 4: isKeyFrame
    int keyFrame = -1;
    if (stackGetParamType(3) != STACK_INT)
    {
        stackPushUndefined();
        stackError("Argument 4 (keyFrame) is not an int");
        return;
    }
    stackGetParamInt(3, &keyFrame);

    if (keyFrame < 0)
    {
        stackPushUndefined();
        stackError("keyFrame < 0: %d", keyFrame);
    }

    int flags;
    if (stackGetParamType(4) != STACK_INT)
    {
        stackPushUndefined();
        stackError("Argument 5 (flags) is not an int");
        return;
    }
    stackGetParamInt(4, &flags);

    int saveNow;
    if (stackGetParamType(5) != STACK_INT)
    {
        stackPushUndefined();
        stackError("Argument 6 (saveNow) is not an int");
        return;
    }
    stackGetParamInt(5, &saveNow);
    int loadNow;
    if (stackGetParamType(6) != STACK_INT)
    {
        stackPushUndefined();
        stackError("Argument 7 (loadNow) is not an int");
        return;
    }
    stackGetParamInt(6, &loadNow);
    int rpgNow;
    if (stackGetParamType(7) != STACK_INT)
    {
        stackPushUndefined();
        stackError("Argument 8 (rpgNow) is not an int");
        return;
    }
    stackGetParamInt(7, &rpgNow);

    int fps;
    if (stackGetParamType(8) != STACK_INT)
    {
        stackPushUndefined();
        stackError("Argument 9 (fps) is not an int");
        return;
    }
    stackGetParamInt(8, &fps);

    sDemo_t *pDemo = findDemoById(demoId);
    if (!pDemo)
    {
        stackPushUndefined();
        printf("Demo with id %d was not found.. stop adding frames please\n", demoId);
        return;
    }

    sDemoFrame_t frame = {};
    memcpy(frame.origin, origin, sizeof(origin));
    memcpy(frame.angles, angles, sizeof(angles));
    frame.isKeyFrame = keyFrame != 0;
    frame.flags = flags;
    frame.fps = fps;
    frame.saveNow = saveNow != 0;
    frame.loadNow = loadNow != 0;
    frame.rpgNow = rpgNow != 0;
    if (nrExpectedArgs >= 10)
    {
        stackGetParamInt(9, &frame.checkpointId);
    }
#ifdef COD4
    const playerState_t *capturedPlayer = nullptr;
    if (nrExpectedArgs >= 11)
    {
        int client;
        stackGetParamInt(10, &client);
        if (client < 0 || client >= MAX_CLIENTS || !g_entities[client].client)
        {
            stackPushUndefined();
            return;
        }
        const playerState_t &playerState = *SV_GameClientNum(client);
        bool continuous = pDemo->size && playerState.commandTime >= pDemo->captureTime &&
                          playerState.commandTime - pDemo->captureTime <= 100;
        if (continuous && (playerState.eFlags & DEMO_TELEPORT_TOGGLE) != pDemo->captureTeleportBit)
        {
            frame.loadNow = true;
        }
        frame.visual = captureDemoVisual(playerState, (flags & DEMO_RPG_WEAPON) != 0,
                                         continuous && !frame.loadNow ? pDemo->captureEventSequence
                                                                      : playerState.eventSequence);
        capturedPlayer = &playerState;
    }
#endif
    if (nrExpectedArgs >= 12)
    {
        int ele = 0;
        stackGetParamInt(11, &ele);
        frame.eleKnown = true;
        frame.eleUsed = ele != 0;
    }
    if (appendDemoFrame(pDemo, frame))
    {
#ifdef COD4
        if (capturedPlayer)
        {
            pDemo->captureEventSequence = capturedPlayer->eventSequence;
            pDemo->captureTime = capturedPlayer->commandTime;
            pDemo->captureTeleportBit = capturedPlayer->eFlags & DEMO_TELEPORT_TOGGLE;
        }
#endif
        stackPushInt(demoId);
    }
    else
    {
        stackPushUndefined();
    }
}

void Gsc_Demo_CompleteDemo()
{
    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, 1))
    {
        return;
    }

    sDemo_t *pDemo = findDemoById(demoId);
    if (!pDemo)
    {
        printf("Demo with id %d not found, can't complete..\n", demoId);
        return;
    }

    pDemo->isComplete = true;

    // TODO: keyframe branching?
}

//==========================================================================
// Functions related to playback & control                                        
//==========================================================================

void Gsc_Demo_SelectPlaybackDemo(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    int demoId = -1;
    if (!Base_Gsc_GetValidDemoId(&demoId, 1))
    {
        return;
    }

    printf("[%d] requesting playback demoId %d\n", playerId, demoId);

    // Clear the player's current playback state
    sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    pPlayback->selectedFrame = 0;
    demoTechnique[playerId].valid = false;
    std::vector<int>().swap(demoPlaybackTimeline[playerId]);
    demoFPSText[playerId].clear();
    pPlayback->pDemo = findDemoById(demoId);
    if (!pPlayback->pDemo)
    {
        stackPushUndefined();
    }
    else
    {
        printf("[%d] requested playback demoId %d was found\n", playerId, demoId);
        stackPushInt(1);
    }
}

void Gsc_Demo_ReadFrame_Origin(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    const sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    const sDemo_t *pDemo = pPlayback->pDemo;
    if (!hasSelectedDemoFrame(*pPlayback))
    {
        stackPushUndefined();
    }
    else
    {
        sDemoFrame_t *pDemoFrame = &pDemo->pDemoFrames[pPlayback->selectedFrame]; // CoD2 stock Scr_AddVector doesn't like const here
        stackPushVector(pDemoFrame->origin);
    }
}

void Gsc_Demo_ReadFrame_SaveNow(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    const sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    const sDemo_t *pDemo = pPlayback->pDemo;
    if (!hasSelectedDemoFrame(*pPlayback))
    {
        stackPushUndefined();
    }
    else
    {
        sDemoFrame_t *pDemoFrame = &pDemo->pDemoFrames[pPlayback->selectedFrame];
        stackPushInt(pDemoFrame->saveNow);
    }
}

void Gsc_Demo_ReadFrame_LoadNow(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    const sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    const sDemo_t *pDemo = pPlayback->pDemo;
    if (!hasSelectedDemoFrame(*pPlayback))
    {
        stackPushUndefined();
    }
    else
    {
        const sDemoFrame_t *pDemoFrame = &pDemo->pDemoFrames[pPlayback->selectedFrame];
        stackPushInt(pDemoFrame->loadNow);
    }
}

void Gsc_Demo_ReadFrame_FPS(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    const sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    const sDemo_t *pDemo = pPlayback->pDemo;
    if (!hasSelectedDemoFrame(*pPlayback))
    {
        stackPushUndefined();
    }
    else
    {
        const sDemoFrame_t *pDemoFrame = &pDemo->pDemoFrames[pPlayback->selectedFrame];
        stackPushInt(pDemoFrame->fps);
    }
}

void Gsc_Demo_ReadFrame_Flags(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    const sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    const sDemo_t *pDemo = pPlayback->pDemo;
    if (!hasSelectedDemoFrame(*pPlayback))
    {
        stackPushUndefined();
    }
    else
    {
        const sDemoFrame_t *pDemoFrame =
            &techniqueFrame(playerId, *pDemo, pPlayback->selectedFrame);
        stackPushInt(pDemoFrame->flags);
    }
}

void Gsc_Demo_ReadFrame_RPGNow(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    const sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    const sDemo_t *pDemo = pPlayback->pDemo;
    if (!hasSelectedDemoFrame(*pPlayback))
    {
        stackPushUndefined();
    }
    else
    {
        const sDemoFrame_t *pDemoFrame = &pDemo->pDemoFrames[pPlayback->selectedFrame];
        stackPushInt(pDemoFrame->rpgNow);
    }
}

void Gsc_Demo_ReadFrame_Angles(int playerId)
{
    if (rejectInvalidDemoClient(playerId))
    {
        return;
    }

    const sDemoPlayback_t *pPlayback = &opencj_playback[playerId];
    const sDemo_t *pDemo = pPlayback->pDemo;
    if (!hasSelectedDemoFrame(*pPlayback))
    {
        stackPushUndefined();
    }
    else
    {
        sDemoFrame_t *pDemoFrame = &techniqueFrame(
            playerId, *pDemo,
            pPlayback->selectedFrame); // CoD2 stock Scr_AddVector doesn't like const here
        stackPushVector(pDemoFrame->angles);
    }
}

void Gsc_Demo_SkipFrame(int playerId)
{
    if (Scr_GetNumParam() != 1)
    {
        stackError("Expected 1 argument: nrFramesToSkip");
        return;
    }

    int nrFramesToSkip = 0;
    if (stackGetParamType(0) != STACK_INT)
    {
        stackError("Argument 1 (nrFramesToSkip) is not an int");
        return;
    }
    stackGetParamInt(0, &nrFramesToSkip);

    Base_Gsc_Demo_FrameSkip(playerId, nrFramesToSkip, false);
}

void Gsc_Demo_SkipKeyFrame(int playerId)
{
    if (Scr_GetNumParam() != 1)
    {
        stackError("Expected 1 argument: nrKeyFramesToSkip");
        return;
    }

    int nrFramesToSkip = 0;
    if (stackGetParamType(0) != STACK_INT)
    {
        stackError("Argument 1 (nrFramesToSkip) is not an int");
        return;
    }
    stackGetParamInt(0, &nrFramesToSkip);

    Base_Gsc_Demo_FrameSkip(playerId, nrFramesToSkip, true);
}

void Gsc_Demo_NextFrame(int playerId)
{
    Base_Gsc_Demo_FrameSkip(playerId, 1, false);
}

void Gsc_Demo_PrevFrame(int playerId)
{
    Base_Gsc_Demo_FrameSkip(playerId, -1, false);
}

void Gsc_Demo_ReadFrame_NextKeyFrame(int playerId)
{
    Base_Gsc_Demo_FrameSkip(playerId, 1, true);
}

void Gsc_Demo_ReadFrame_PrevKeyFrame(int playerId)
{
    Base_Gsc_Demo_FrameSkip(playerId, -1, true);
}


// OCJ4 adds a failed-path flag; OCJ1-3 remain readable. No extra bytes/frame.
// OCJ1: 27 bytes/frame. OCJ2: optional 31-byte presentation and weapon names
// only on changes (plus a chunk-start anchor). Both formats use zlib.
// Hex is only the GSC/SQL transport; MySQL stores UNHEX(payload) as binary.
static void putDemoInt(unsigned char *destination, uint32_t value, int byteCount)
{
    for (int byte = 0; byte < byteCount; ++byte)
    {
        destination[byte] = (value >> (8 * byte)) & 255;
    }
}

static uint32_t getDemoInt(const unsigned char *source, int byteCount)
{
    uint32_t value = 0;
    for (int byte = 0; byte < byteCount; ++byte)
    {
        value |= uint32_t(source[byte]) << (8 * byte);
    }
    return value;
}

// Stored OCJ1-5 layouts are little-endian. These offsets and flags are part of
// existing recordings, not the native struct layout.
namespace DemoWire
{
constexpr size_t HEADER_SIZE = 8;
constexpr size_t FRAME_COUNT = 4;
constexpr int MAX_FRAMES = 64;
constexpr int FRAME_SIZE = 27;
constexpr int VISUAL_SIZE = 31;
constexpr int BUFFER_SIZE = 8192;
constexpr size_t MAX_WEAPON_NAME = 63;
constexpr int LANDING_SIZE = 2;
constexpr int COMPRESSION_LEVEL = 6;
constexpr float ANGLE_STEPS_PER_TURN = 65536.0f;
constexpr float VIEW_HEIGHT_SCALE = 256.0f;
constexpr float ADS_SCALE = 255.0f;
constexpr float MAX_ORIGIN_COORDINATE = 131072;
constexpr float MAX_VIEW_HEIGHT = 100;
constexpr unsigned MAX_WEAPON_STATE = 32;
constexpr unsigned FIRST_LANDING_EVENT = 77;
constexpr unsigned LAST_LANDING_EVENT = 105;
constexpr unsigned MAX_LANDING_IMPACT = 24;

enum FrameOffset
{
    ORIGIN = 0,
    ANGLES = 12,
    FLAGS = 18,
    FPS = 20,
    CHECKPOINT = 22,
    EVENTS = 26
};

enum VisualOffset
{
    WEAPON_TIME = 0,
    WEAPON_DELAY = 2,
    WEAPON_ANIMATION = 4,
    WEAPON_STATE = 6,
    BOB_CYCLE = 7,
    VIEW_HEIGHT = 8,
    ADS = 10,
    VELOCITY = 11,
    LADDER = 17,
    SPRINT_ELAPSED = 23,
    MANTLE_TIMER = 25,
    MANTLE_YAW = 27,
    MANTLE_TRANSITION = 29,
    MANTLE_FLAGS = 30
};

enum FrameEvent
{
    SAVE = 1,
    LOAD = 2,
    RPG = 4,
    VISUAL = 8,
    LANDING = 16,
    FAILED_PATH = 32,
    ELEVATION_KNOWN = 64,
    ELEVATION_USED = 128
};

static_assert(HEADER_SIZE + MAX_FRAMES *
                                (FRAME_SIZE + VISUAL_SIZE + 1 + MAX_WEAPON_NAME + LANDING_SIZE) <=
                  BUFFER_SIZE,
              "A complete demo chunk must fit before compression");
} // namespace DemoWire

static void encodeDemoFrameFields(const sDemoFrame_t &frame, unsigned char *encodedFrame)
{
    for (int axis = 0; axis < 3; ++axis)
    {
        uint32_t bits;
        memcpy(&bits, &frame.origin[axis], 4);
        putDemoInt(encodedFrame + DemoWire::ORIGIN + axis * 4, bits, 4);
        putDemoInt(encodedFrame + DemoWire::ANGLES + axis * 2,
                   uint16_t(int(frame.angles[axis] * DemoWire::ANGLE_STEPS_PER_TURN / 360.0f)), 2);
    }
    putDemoInt(encodedFrame + DemoWire::FLAGS, uint16_t(frame.flags), 2);
    putDemoInt(encodedFrame + DemoWire::FPS, uint16_t(frame.fps), 2);
    putDemoInt(encodedFrame + DemoWire::CHECKPOINT, frame.checkpointId, 4);
    encodedFrame[DemoWire::EVENTS] =
        (frame.saveNow ? DemoWire::SAVE : 0) | (frame.loadNow ? DemoWire::LOAD : 0) |
        (frame.rpgNow ? DemoWire::RPG : 0) | (frame.isKeyFrame ? 0 : DemoWire::FAILED_PATH) |
        (frame.eleKnown ? DemoWire::ELEVATION_KNOWN : 0) |
        (frame.eleUsed ? DemoWire::ELEVATION_USED : 0);
}

// Keep the weapon anchor within each chunk so chunks can load independently.
struct DemoEncodeBuffer
{
    unsigned char bytes[DemoWire::BUFFER_SIZE] = {'O', 'C', 'J', '5'};
    size_t used = DemoWire::HEADER_SIZE;
    uint16_t previousWeapon = 0;
    bool hasWeapon = false;
};

#ifdef COD4
static void encodeDemoVisualFields(const DemoVisual &visual, unsigned char *encodedVisual)
{
    putDemoInt(encodedVisual + DemoWire::WEAPON_TIME, visual.weaponTime, 2);
    putDemoInt(encodedVisual + DemoWire::WEAPON_DELAY, visual.weaponDelay, 2);
    putDemoInt(encodedVisual + DemoWire::WEAPON_ANIMATION, visual.animation, 2);
    encodedVisual[DemoWire::WEAPON_STATE] = visual.weaponState;
    encodedVisual[DemoWire::BOB_CYCLE] = visual.bobCycle;
    putDemoInt(encodedVisual + DemoWire::VIEW_HEIGHT,
               int(visual.viewHeight * DemoWire::VIEW_HEIGHT_SCALE), 2);
    encodedVisual[DemoWire::ADS] =
        std::max(0, std::min(255, int(std::lround(visual.ads * DemoWire::ADS_SCALE))));
    for (int axis = 0; axis < 3; ++axis)
    {
        putDemoInt(encodedVisual + DemoWire::VELOCITY + axis * 2, uint16_t(visual.velocity[axis]),
                   2);
        putDemoInt(encodedVisual + DemoWire::LADDER + axis * 2, uint16_t(visual.ladder[axis]), 2);
    }
    putDemoInt(encodedVisual + DemoWire::SPRINT_ELAPSED, visual.sprintElapsed, 2);
    putDemoInt(encodedVisual + DemoWire::MANTLE_TIMER, visual.mantleTimer, 2);
    putDemoInt(encodedVisual + DemoWire::MANTLE_YAW, visual.mantleYaw, 2);
    encodedVisual[DemoWire::MANTLE_TRANSITION] = visual.mantleTransition;
    encodedVisual[DemoWire::MANTLE_FLAGS] = visual.mantleFlags;
}

static bool encodeDemoVisual(const DemoVisual &visual, DemoEncodeBuffer &buffer,
                             unsigned char &events)
{
    events |= DemoWire::VISUAL;
    encodeDemoVisualFields(visual, buffer.bytes + buffer.used);
    buffer.used += DemoWire::VISUAL_SIZE;
    const char *weaponName = "";
    if (!buffer.hasWeapon || buffer.previousWeapon != visual.weapon)
    {
        weaponName = demoWeaponName(visual.weapon);
    }
    const size_t nameLength = strlen(weaponName);
    if (nameLength > DemoWire::MAX_WEAPON_NAME ||
        buffer.used + 1 + nameLength > sizeof(buffer.bytes))
    {
        return false;
    }
    buffer.bytes[buffer.used++] = nameLength;
    memcpy(buffer.bytes + buffer.used, weaponName, nameLength);
    buffer.used += nameLength;
    buffer.previousWeapon = visual.weapon;
    buffer.hasWeapon = true;
    if (visual.landingEvent)
    {
        events |= DemoWire::LANDING;
        buffer.bytes[buffer.used++] = visual.landingEvent;
        buffer.bytes[buffer.used++] = visual.landingImpact;
    }
    return true;
}
#endif

// Encode only a validated frame range. The caller owns the returned compressed bytes.
static bool encodeDemoChunk(sDemo_t *demo, int first, int count, std::string &output)
{
    if (!demo || first < 0 || count < 1 || count > DemoWire::MAX_FRAMES ||
        first > demo->size - count)
    {
        return false;
    }
    DemoEncodeBuffer buffer;
    putDemoInt(buffer.bytes + DemoWire::FRAME_COUNT, count, 4);
    for (int index = first; index < first + count; ++index)
    {
        const sDemoFrame_t &frame = demo->pDemoFrames[index];
        unsigned char *encodedFrame = buffer.bytes + buffer.used;
        buffer.used += DemoWire::FRAME_SIZE;
        encodeDemoFrameFields(frame, encodedFrame);
#ifdef COD4
        if (frame.visual.valid &&
            !encodeDemoVisual(frame.visual, buffer, encodedFrame[DemoWire::EVENTS]))
        {
            return false;
        }
#endif
    }
    unsigned char packed[DemoWire::BUFFER_SIZE];
    uLongf packedSize = sizeof(packed);
    if (compress2(packed, &packedSize, buffer.bytes, buffer.used, DemoWire::COMPRESSION_LEVEL) !=
        Z_OK)
    {
        return false;
    }
    output.assign(reinterpret_cast<const char *>(packed), packedSize);
    return true;
}

static std::string demoHex(const std::string &packed)
{
    const char *digits = "0123456789abcdef";
    std::string hex(packed.size() * 2, '0');
    for (size_t i = 0; i < packed.size(); ++i) {
        unsigned char c = packed[i];
        hex[2 * i] = digits[c >> 4];
        hex[2 * i + 1] = digits[c & 15];
    }
    return hex;
}

void Gsc_Demo_EncodeChunk()
{
    int id;
    int first;
    int count;
    if (!Base_Gsc_GetValidDemoId(&id, 3)) {
        return;
    }
    stackGetParamInt(1, &first);
    stackGetParamInt(2, &count);
    std::string packed;
    if (!encodeDemoChunk(findDemoById(id), first, count, packed)) {
        stackPushUndefined();
        return;
    }
    stackPushString(demoHex(packed).c_str());
}

static int demoHexDigit(char c)
{
    if (c >= '0' && c <= '9')
    {
        return c - '0';
    }
    if (c >= 'a' && c <= 'f')
    {
        return c - 'a' + 10;
    }
    if (c >= 'A' && c <= 'F')
    {
        return c - 'A' + 10;
    }
    return -1;
}

// Borrow the decompressed buffer only while validating a chunk. No frame is
// published until the complete cursor has been consumed and capacity reserved.
struct DemoDecodeCursor
{
    const unsigned char *bytes;
    size_t size;
    char version;
    size_t used = DemoWire::HEADER_SIZE;
    uint16_t previousWeapon = 0;
    bool hasWeapon = false;

    const unsigned char *take(size_t length)
    {
        if (length > size - used)
        {
            return nullptr;
        }
        const unsigned char *field = bytes + used;
        used += length;
        return field;
    }
};

static bool decodeDemoFrameFields(const unsigned char *encodedFrame, char version,
                                  sDemoFrame_t &frame)
{
    for (int axis = 0; axis < 3; ++axis)
    {
        uint32_t bits = getDemoInt(encodedFrame + DemoWire::ORIGIN + axis * 4, 4);
        memcpy(&frame.origin[axis], &bits, 4);
        if (!std::isfinite(frame.origin[axis]) ||
            fabs(frame.origin[axis]) > DemoWire::MAX_ORIGIN_COORDINATE)
        {
            return false;
        }
        frame.angles[axis] = getDemoInt(encodedFrame + DemoWire::ANGLES + axis * 2, 2) * 360.0f /
                             DemoWire::ANGLE_STEPS_PER_TURN;
    }
    frame.flags = getDemoInt(encodedFrame + DemoWire::FLAGS, 2);
    frame.fps = getDemoInt(encodedFrame + DemoWire::FPS, 2);
    frame.checkpointId = getDemoInt(encodedFrame + DemoWire::CHECKPOINT, 4);
    frame.saveNow = encodedFrame[DemoWire::EVENTS] & DemoWire::SAVE;
    frame.loadNow = encodedFrame[DemoWire::EVENTS] & DemoWire::LOAD;
    frame.rpgNow = encodedFrame[DemoWire::EVENTS] & DemoWire::RPG;
    frame.isKeyFrame = version < '4' || !(encodedFrame[DemoWire::EVENTS] & DemoWire::FAILED_PATH);
    frame.eleKnown = version >= '5' && (encodedFrame[DemoWire::EVENTS] & DemoWire::ELEVATION_KNOWN);
    frame.eleUsed = frame.eleKnown && (encodedFrame[DemoWire::EVENTS] & DemoWire::ELEVATION_USED);
    return true;
}

static void decodeDemoVisualFields(const unsigned char *encodedVisual, DemoVisual &visual)
{
    visual.weaponTime = getDemoInt(encodedVisual + DemoWire::WEAPON_TIME, 2);
    visual.weaponDelay = getDemoInt(encodedVisual + DemoWire::WEAPON_DELAY, 2);
    visual.animation = getDemoInt(encodedVisual + DemoWire::WEAPON_ANIMATION, 2);
    visual.weaponState = encodedVisual[DemoWire::WEAPON_STATE];
    visual.bobCycle = encodedVisual[DemoWire::BOB_CYCLE];
    visual.viewHeight =
        int16_t(getDemoInt(encodedVisual + DemoWire::VIEW_HEIGHT, 2)) / DemoWire::VIEW_HEIGHT_SCALE;
    visual.ads = encodedVisual[DemoWire::ADS] / DemoWire::ADS_SCALE;
    for (int axis = 0; axis < 3; ++axis)
    {
        visual.velocity[axis] = getDemoInt(encodedVisual + DemoWire::VELOCITY + axis * 2, 2);
        visual.ladder[axis] = getDemoInt(encodedVisual + DemoWire::LADDER + axis * 2, 2);
    }
    visual.sprintElapsed = getDemoInt(encodedVisual + DemoWire::SPRINT_ELAPSED, 2);
    visual.mantleTimer = getDemoInt(encodedVisual + DemoWire::MANTLE_TIMER, 2);
    visual.mantleYaw = getDemoInt(encodedVisual + DemoWire::MANTLE_YAW, 2);
    visual.mantleTransition = encodedVisual[DemoWire::MANTLE_TRANSITION];
    visual.mantleFlags = encodedVisual[DemoWire::MANTLE_FLAGS];
}

static bool decodeDemoVisual(DemoDecodeCursor &cursor, unsigned char events, DemoVisual &visual)
{
    const unsigned char *encodedVisual = cursor.take(DemoWire::VISUAL_SIZE);
    const unsigned char *encodedNameLength = cursor.take(1);
    if (!encodedVisual || !encodedNameLength)
    {
        return false;
    }
    visual.valid = true;
    decodeDemoVisualFields(encodedVisual, visual);
    const size_t nameLength = *encodedNameLength;
    if (nameLength > DemoWire::MAX_WEAPON_NAME || (!nameLength && !cursor.hasWeapon) ||
        visual.viewHeight < 0 || visual.viewHeight > DemoWire::MAX_VIEW_HEIGHT ||
        visual.weaponState > DemoWire::MAX_WEAPON_STATE)
    {
        return false;
    }
    const unsigned char *encodedName = cursor.take(nameLength);
    if (!encodedName)
    {
        return false;
    }
#ifdef COD4
    if (nameLength)
    {
        char weaponName[DemoWire::MAX_WEAPON_NAME + 1];
        memcpy(weaponName, encodedName, nameLength);
        weaponName[nameLength] = 0;
        if (strlen(weaponName) != nameLength)
        {
            return false;
        }
        cursor.previousWeapon =
            !strcmp(weaponName, "none") ? 0 : G_GetWeaponIndexForName(weaponName);
        cursor.hasWeapon = true;
    }
#endif
    visual.weapon = cursor.previousWeapon;
    if (cursor.version >= '3' && (events & DemoWire::LANDING))
    {
        const unsigned char *landing = cursor.take(DemoWire::LANDING_SIZE);
        if (!landing || landing[0] < DemoWire::FIRST_LANDING_EVENT ||
            landing[0] > DemoWire::LAST_LANDING_EVENT || !landing[1] ||
            landing[1] > DemoWire::MAX_LANDING_IMPACT)
        {
            return false;
        }
        visual.landingEvent = landing[0];
        visual.landingImpact = landing[1];
    }
    return true;
}

// Reject malformed or unaffordable chunks without changing the target recording.
static int decodeDemoChunk(sDemo_t *demo, const unsigned char *packed, size_t length)
{
    if (!demo || demo->isComplete || !length || length > DemoWire::BUFFER_SIZE)
    {
        return 0;
    }
    unsigned char raw[DemoWire::BUFFER_SIZE];
    uLongf rawSize = sizeof(raw);
    if (uncompress(raw, &rawSize, packed, length) != Z_OK || rawSize < DemoWire::HEADER_SIZE ||
        memcmp(raw, "OCJ", 3) || raw[3] < '1' || raw[3] > '5')
    {
        return 0;
    }
    const uint32_t frameCount = getDemoInt(raw + DemoWire::FRAME_COUNT, 4);
    DemoDecodeCursor cursor{raw, rawSize, static_cast<char>(raw[3])};
    if (!frameCount || frameCount > DemoWire::MAX_FRAMES ||
        (cursor.version == '1' &&
         rawSize != DemoWire::HEADER_SIZE + frameCount * DemoWire::FRAME_SIZE))
    {
        return 0;
    }
    sDemoFrame_t frames[DemoWire::MAX_FRAMES] = {};
    for (uint32_t index = 0; index < frameCount; ++index)
    {
        const unsigned char *encodedFrame = cursor.take(DemoWire::FRAME_SIZE);
        if (!encodedFrame || !decodeDemoFrameFields(encodedFrame, cursor.version, frames[index]))
        {
            return 0;
        }
        const unsigned char events = encodedFrame[DemoWire::EVENTS];
        if (cursor.version != '1' && (events & DemoWire::VISUAL) &&
            !decodeDemoVisual(cursor, events, frames[index].visual))
        {
            return 0;
        }
    }
    if (cursor.used != cursor.size || !reserveDemoFrames(demo, size_t(demo->size) + frameCount))
    {
        return 0;
    }
    for (uint32_t index = 0; index < frameCount; ++index)
    {
        if (!appendDemoFrame(demo, frames[index]))
        {
            return 0;
        }
    }
    return frameCount;
}

void Gsc_Demo_DecodeChunk()
{
    int id;
    const char *hex;
    if (!Base_Gsc_GetValidDemoId(&id, 2)) {
        return;
    }
    stackGetParamString(1, &hex);
    size_t length = strlen(hex);
    if (!length || length > DemoWire::BUFFER_SIZE * 2 || length % 2) {
        stackPushUndefined();
        return;
    }
    unsigned char packed[DemoWire::BUFFER_SIZE];
    for (size_t i = 0; i < length; i += 2) {
        int a = demoHexDigit(hex[i]);
        int b = demoHexDigit(hex[i + 1]);
        if (a < 0 || b < 0) {
            stackPushUndefined();
            return;
        }
        packed[i / 2] = (a << 4) | b;
    }
    int count = decodeDemoChunk(findDemoById(id), packed, length / 2);
    if (count) {
        stackPushInt(count);
    } else {
        stackPushUndefined();
    }
}

void Gsc_Demo_MarkFailedSince()
{
    int id;
    int count;
    if (!Base_Gsc_GetValidDemoId(&id, 2))
    {
        return;
    }
    stackGetParamInt(1, &count);
    sDemo_t *demo = findDemoById(id);
    if (!demo || demo->isComplete || count < 0 || count > demo->size)
    {
        stackPushUndefined();
        return;
    }
    for (int i = count; i < demo->size; ++i)
    {
        demo->pDemoFrames[i].isKeyFrame = false;
    }
    int last = count ? count - 1 : 0;
    while (last > 0 && !demo->pDemoFrames[last].isKeyFrame)
    {
        --last;
    }
    demo->lastKeyFrame = last;
    for (int i = last; i < demo->size; ++i)
    {
        demo->pDemoFrames[i].nextKeyFrame = i;
        if (i > last)
        {
            demo->pDemoFrames[i].prevKeyFrame = last;
        }
    }
    ++demo->editVersion;
    stackPushInt(demo->size);
}

// Idle means grounded with an unchanged position AND view. Do not remove
// aiming, stance changes, reloads, RPG shots, or transitions across a load.
static bool demoIdleTogether(const sDemoFrame_t &firstFrame, const sDemoFrame_t &secondFrame)
{
    if (!(firstFrame.flags & DEMO_GROUNDED) || firstFrame.flags != secondFrame.flags || (firstFrame.flags & DEMO_ACTIVE_INPUT_MASK) ||
        firstFrame.checkpointId != secondFrame.checkpointId || firstFrame.loadNow || secondFrame.loadNow || firstFrame.saveNow || secondFrame.saveNow ||
        firstFrame.rpgNow || secondFrame.rpgNow)
    {
        return false;
    }
    for (int axis = 0; axis < 3; ++axis)
    {
        if (fabs(firstFrame.origin[axis] - secondFrame.origin[axis]) > 0.01f ||
            fabs(std::remainder(firstFrame.angles[axis] - secondFrame.angles[axis], 360.0f)) > 0.01f)
        {
            return false;
        }
    }
    const auto &firstVisual = firstFrame.visual;
    const auto &secondVisual = secondFrame.visual;
    if (firstVisual.valid != secondVisual.valid)
    {
        return false;
    }
    if (firstVisual.valid &&
        (firstVisual.weapon != secondVisual.weapon || firstVisual.weaponState || secondVisual.weaponState || firstVisual.weaponTime || secondVisual.weaponTime ||
         firstVisual.weaponDelay || secondVisual.weaponDelay || firstVisual.landingEvent || secondVisual.landingEvent ||
         fabs(firstVisual.ads - secondVisual.ads) > 0.001f || fabs(firstVisual.viewHeight - secondVisual.viewHeight) > 0.01f))
    {
        return false;
    }
    return true;
}

enum DemoPlaybackStyle
{
    DEMO_COMPLETE_RUN = 0,
    DEMO_SUCCESSFUL_PATH = 1,
    DEMO_WALKTHROUGH = 2
};
constexpr size_t DEMO_IDLE_PAUSE_FRAMES = 20;
constexpr size_t DEMO_IDLE_EDGE_FRAMES = 2;

// Shorten true idle pauses while retaining both ends and explicit trim boundaries.
static void shortenDemoIdlePauses(const sDemo_t &demo, int begin, int end,
                                  std::vector<int> &timeline)
{
    // 20 Hz capture: shorten pauses of at least a second to 0.2 seconds.
    // Keep both ends so movement starts/ends at its original recorded pose.
    size_t retainedCount = 0;
    for (size_t pauseBegin = 0; pauseBegin < timeline.size();)
    {
        size_t pauseEnd = pauseBegin + 1;
        while (pauseEnd < timeline.size() && timeline[pauseEnd] == timeline[pauseEnd - 1] + 1 &&
               timeline[pauseEnd] != begin && timeline[pauseEnd - 1] != end &&
               demoIdleTogether(demo.pDemoFrames[timeline[pauseBegin]],
                                demo.pDemoFrames[timeline[pauseEnd]]))
        {
            ++pauseEnd;
        }
        for (size_t i = pauseBegin; i < pauseEnd; ++i)
        {
            if (pauseEnd - pauseBegin < DEMO_IDLE_PAUSE_FRAMES ||
                i < pauseBegin + DEMO_IDLE_EDGE_FRAMES || i >= pauseEnd - DEMO_IDLE_EDGE_FRAMES)
            {
                timeline[retainedCount++] = timeline[i];
            }
        }
        pauseBegin = pauseEnd;
    }
    timeline.resize(retainedCount);
}

// Walkthrough frames that teach the jump keep their recorded speed. Counts are
// 20 Hz frames: a 1.5 s run-up, 0.5 s after landing, 0.5 s around RPG shots
// and checkpoint arrivals. The landing tail also ends checkpoint segments.
constexpr int DEMO_TAKEOFF_LEAD_FRAMES = 30;
constexpr int DEMO_LANDING_TAIL_FRAMES = 10;
constexpr int DEMO_EVENT_WINDOW_FRAMES = 10;
// Shorter grounded setup is not worth speeding up.
constexpr size_t DEMO_FAST_FORWARD_MIN_FRAMES = 30;
// Playback interpolates across gaps of at most 4 frames (updateDemoInterpolation),
// so a step of 3 plays setup three times faster without any abrupt jump.
constexpr size_t DEMO_FAST_FORWARD_STEP = 3;

static void markRealTimeFrames(std::vector<bool> &realTime, int first, int last)
{
    const int lastFrame = int(realTime.size()) - 1;
    for (int frameIndex = std::max(0, first); frameIndex <= std::min(lastFrame, last); ++frameIndex)
    {
        realTime[frameIndex] = true;
    }
}

// Mark the frames a walkthrough must play at recorded speed: anything off the
// ground, loads, the run-up to each takeoff, landings, RPG shots, checkpoint
// arrivals and the requested range boundaries.
static std::vector<bool> walkthroughRealTimeFrames(const sDemo_t &demo, int begin, int end)
{
    std::vector<bool> realTime(demo.size, false);
    const int climbingFlags = DEMO_LADDER | DEMO_MANTLING;
    for (int frameIndex = 0; frameIndex < demo.size; ++frameIndex)
    {
        const sDemoFrame_t &frame = demo.pDemoFrames[frameIndex];
        const bool grounded = (frame.flags & DEMO_GROUNDED) != 0;
        if (!grounded || (frame.flags & climbingFlags) || frame.loadNow)
        {
            realTime[frameIndex] = true;
        }
        if (frame.rpgNow)
        {
            markRealTimeFrames(realTime, frameIndex - DEMO_EVENT_WINDOW_FRAMES,
                               frameIndex + DEMO_EVENT_WINDOW_FRAMES);
        }
        if (frameIndex + 1 >= demo.size)
        {
            continue;
        }
        const sDemoFrame_t &next = demo.pDemoFrames[frameIndex + 1];
        const bool nextGrounded = (next.flags & DEMO_GROUNDED) != 0;
        // A load is a cut, not a takeoff or landing.
        if (grounded && !nextGrounded && !next.loadNow)
        {
            markRealTimeFrames(realTime, frameIndex - DEMO_TAKEOFF_LEAD_FRAMES + 1, frameIndex);
        }
        if (!grounded && nextGrounded && !next.loadNow)
        {
            markRealTimeFrames(realTime, frameIndex + 1, frameIndex + DEMO_LANDING_TAIL_FRAMES);
        }
        if (next.checkpointId != frame.checkpointId)
        {
            markRealTimeFrames(realTime, frameIndex + 1 - DEMO_EVENT_WINDOW_FRAMES,
                               frameIndex + 1 + DEMO_EVENT_WINDOW_FRAMES);
        }
    }
    realTime[begin] = true;
    realTime[end] = true;
    return realTime;
}

// Walkthroughs drop still waiting and fast-forward the rest of the grounded setup
// (walking back, lining up, turning). Every retained step stays within playback
// interpolation, so the player never visibly teleports.
static void compactWalkthroughSetup(const sDemo_t &demo, int begin, int end,
                                    std::vector<int> &timeline)
{
    shortenDemoIdlePauses(demo, begin, end, timeline);
    const std::vector<bool> realTime = walkthroughRealTimeFrames(demo, begin, end);
    size_t retainedCount = 0;
    for (size_t runBegin = 0; runBegin < timeline.size();)
    {
        // A setup run is consecutive recorded frames that may play faster.
        size_t runEnd = runBegin + 1;
        if (!realTime[timeline[runBegin]])
        {
            while (runEnd < timeline.size() && !realTime[timeline[runEnd]] &&
                   timeline[runEnd] == timeline[runEnd - 1] + 1)
            {
                ++runEnd;
            }
        }
        const size_t runLength = runEnd - runBegin;
        for (size_t i = runBegin; i < runEnd; ++i)
        {
            const bool fastForward = runLength >= DEMO_FAST_FORWARD_MIN_FRAMES;
            const bool lastOfRun = i == runEnd - 1;
            if (!fastForward || (i - runBegin) % DEMO_FAST_FORWARD_STEP == 0 || lastOfRun)
            {
                timeline[retainedCount++] = timeline[i];
            }
        }
        runBegin = runEnd;
    }
    timeline.resize(retainedCount);
}

// Build a viewer-owned edit list over shared immutable frame indices.
void Gsc_Demo_PlaybackStyle(int client)
{
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    int style;
    int begin;
    int end;
    if (!stackGetParams("iii", &style, &begin, &end))
    {
        return;
    }
    const sDemo_t *demo = opencj_playback[client].pDemo;
    if (!demo || style < DEMO_COMPLETE_RUN || style > DEMO_WALKTHROUGH || begin < 0 ||
        end >= demo->size || begin > end)
    {
        stackPushUndefined();
        return;
    }
    if (style == DEMO_COMPLETE_RUN)
    {
        std::vector<int>().swap(demoPlaybackTimeline[client]);
        opencj_playback[client].selectedFrame = begin;
        stackMakeArray();
        stackPushInt(begin);
        stackPushArrayNext();
        stackPushInt(end);
        stackPushArrayNext();
        return;
    }
    std::vector<int> timeline;
    for (int i = 0; i < demo->size; ++i)
    {
        if (demo->pDemoFrames[i].isKeyFrame)
        {
            timeline.push_back(i);
        }
    }
    if (style == DEMO_WALKTHROUGH)
    {
        compactWalkthroughSetup(*demo, begin, end, timeline);
    }
    auto rangeBegin = std::lower_bound(timeline.begin(), timeline.end(), begin);
    auto rangeEnd = std::upper_bound(timeline.begin(), timeline.end(), end);
    if (rangeBegin == rangeEnd)
    {
        stackPushUndefined();
        return;
    }
    const int firstFrame = *rangeBegin;
    const int lastFrame = *(rangeEnd - 1);
    // Publish only after the requested range contains playable frames.
    demoPlaybackTimeline[client].swap(timeline);
    opencj_playback[client].selectedFrame = firstFrame;
    stackMakeArray();
    stackPushInt(firstFrame);
    stackPushArrayNext();
    stackPushInt(lastFrame);
    stackPushArrayNext();
}

void Gsc_Demo_PlaybackTime(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    int begin;
    int end;
    if (!stackGetParams("ii", &begin, &end)) {
        return;
    }
    const sDemo_t *demo = opencj_playback[client].pDemo;
    if (!demo || begin < 0 || end < begin || end >= demo->size) {
        stackPushUndefined();
        return;
    }
    const auto &timeline = demoPlaybackTimeline[client];
    int frame = opencj_playback[client].selectedFrame;
    if (timeline.empty()) {
        stackMakeArray();
        stackPushInt(std::max(0, std::min(end, frame) - begin));
        stackPushArrayNext();
        stackPushInt(end - begin);
        stackPushArrayNext();
        return;
    }
    auto rangeBegin = std::lower_bound(timeline.begin(), timeline.end(), begin);
    auto rangeEnd = std::upper_bound(timeline.begin(), timeline.end(), end);
    auto selectedPosition = std::lower_bound(rangeBegin, rangeEnd, frame);
    stackMakeArray();
    stackPushInt(int(selectedPosition - rangeBegin));
    stackPushArrayNext();
    stackPushInt(std::max(0, int(rangeEnd - rangeBegin) - 1));
    stackPushArrayNext();
}

void Gsc_Demo_Truncate()
{
    int id;
    int count;
    if (!Base_Gsc_GetValidDemoId(&id, 2))
    {
        return;
    }
    stackGetParamInt(1, &count);
    sDemo_t *demo = findDemoById(id);
    if (!demo || demo->isComplete || count < 0 || count > demo->size)
    {
        stackPushUndefined();
        return;
    }
    demo->size = count;
    demo->currentFrame = count ? count - 1 : 0;
    demo->isFirstFrameFilled = count != 0;
    demo->lastKeyFrame = 0;
    for (int i = 0; i < count; ++i)
    {
        sDemoFrame_t &frame = demo->pDemoFrames[i];
        frame.isKeyFrame = true;
        frame.prevKeyFrame = i ? i - 1 : 0;
        frame.nextKeyFrame = i + 1 < count ? i + 1 : i;
        demo->lastKeyFrame = i;
    }
    ++demo->editVersion;
    stackPushInt(count);
}

constexpr float DEMO_SETUP_RADIUS = 256;

struct DemoFrameRange
{
    int first = -1;
    int last = -1;
};

static float demoOriginDistanceSquared(const sDemoFrame_t &frame, const float origin[3])
{
    float distanceSquared = 0;
    for (int axis = 0; axis < 3; ++axis)
    {
        const float difference = frame.origin[axis] - origin[axis];
        distanceSquared += difference * difference;
    }
    return distanceSquared;
}

// Include the checkpoint's departure and up to half a second of its landing.
// A new load, takeoff, failed section or checkpoint stops that landing tail.
static DemoFrameRange findCheckpointDemoRange(const sDemo_t &demo, int checkpointId,
                                              bool skipFailures)
{
    DemoFrameRange range;
    for (int index = 0; index < demo.size; ++index)
    {
        const sDemoFrame_t &frame = demo.pDemoFrames[index];
        if (skipFailures && !frame.isKeyFrame)
        {
            continue;
        }
        if (frame.checkpointId == checkpointId)
        {
            if (range.first < 0)
            {
                range.first = index;
            }
            range.last = index;
        }
        else if (range.first >= 0)
        {
            range.last = index;
            const int destinationCheckpoint = frame.checkpointId;
            int groundedFrames = (frame.flags & DEMO_GROUNDED) ? 1 : 0;
            for (int nextIndex = index + 1;
                 groundedFrames > 0 && groundedFrames < DEMO_LANDING_TAIL_FRAMES &&
                 nextIndex < demo.size;
                 ++nextIndex)
            {
                const sDemoFrame_t &landingFrame = demo.pDemoFrames[nextIndex];
                if ((skipFailures && !landingFrame.isKeyFrame) || landingFrame.loadNow ||
                    landingFrame.checkpointId != destinationCheckpoint ||
                    !(landingFrame.flags & DEMO_GROUNDED))
                {
                    break;
                }
                range.last = nextIndex;
                ++groundedFrames;
            }
            break;
        }
    }
    return range;
}

// Compare all grounded setup positions, not just checkpoint arrival. Large
// platforms can span hundreds of units; airborne travel is not a setup match.
static bool demoSetupIsNearby(const sDemo_t &demo, const DemoFrameRange &range, int checkpointId,
                              const float origin[3], bool skipFailures)
{
    bool hasGroundedSetup = false;
    for (int index = range.first; index <= range.last; ++index)
    {
        const sDemoFrame_t &frame = demo.pDemoFrames[index];
        if (frame.checkpointId == checkpointId && (!skipFailures || frame.isKeyFrame) &&
            (frame.flags & DEMO_GROUNDED))
        {
            hasGroundedSetup = true;
        }
    }
    for (int index = range.first; index <= range.last; ++index)
    {
        const sDemoFrame_t &frame = demo.pDemoFrames[index];
        if (frame.checkpointId != checkpointId || (skipFailures && !frame.isKeyFrame) ||
            (hasGroundedSetup && !(frame.flags & DEMO_GROUNDED)))
        {
            continue;
        }
        if (demoOriginDistanceSquared(frame, origin) <= DEMO_SETUP_RADIUS * DEMO_SETUP_RADIUS)
        {
            return true;
        }
    }
    return false;
}

// Older recordings can be matched by position when checkpoint IDs are unavailable.
static DemoFrameRange findNearestDemoRange(const sDemo_t &demo, const float origin[3],
                                           bool skipFailures, bool requireNearby)
{
    DemoFrameRange range;
    int segmentBegin = 0;
    int groundedFrames = 0;
    bool wasAirborne = false;
    float nearestDistanceSquared = DEMO_SETUP_RADIUS * DEMO_SETUP_RADIUS;
    float segmentDistanceSquared = nearestDistanceSquared;
    for (int index = 0; index < demo.size; ++index)
    {
        const sDemoFrame_t &frame = demo.pDemoFrames[index];
        if (skipFailures && !frame.isKeyFrame)
        {
            continue;
        }
        segmentDistanceSquared =
            std::min(segmentDistanceSquared, demoOriginDistanceSquared(frame, origin));
        if (frame.flags & DEMO_GROUNDED)
        {
            ++groundedFrames;
        }
        else
        {
            groundedFrames = 0;
            wasAirborne = true;
        }
        if ((wasAirborne && groundedFrames >= DEMO_LANDING_TAIL_FRAMES) || index == demo.size - 1)
        {
            if (segmentDistanceSquared < nearestDistanceSquared)
            {
                range.first = segmentBegin;
                range.last = index;
                nearestDistanceSquared = segmentDistanceSquared;
            }
            segmentBegin = index;
            groundedFrames = 0;
            wasAirborne = false;
            segmentDistanceSquared = DEMO_SETUP_RADIUS * DEMO_SETUP_RADIUS;
        }
    }
    // Explicit legacy callers retain the whole-route fallback. Automatic
    // location selection rejects a recording with no nearby passage.
    if (range.first < 0 && !requireNearby)
    {
        range.first = 0;
        range.last = demo.size - 1;
    }
    return range;
}

void Gsc_Demo_FindSegment()
{
    int demoId;
    int checkpointId;
    int matchByPosition;
    vec3_t origin;
    const int argumentCount = Scr_GetNumParam();
    if (argumentCount != 4 && argumentCount != 5 && argumentCount != 6)
    {
        stackPushUndefined();
        return;
    }
    if (!Base_Gsc_GetValidDemoId(&demoId, argumentCount))
    {
        return;
    }
    stackGetParamInt(1, &checkpointId);
    stackGetParamVector(2, origin);
    stackGetParamInt(3, &matchByPosition);
    const sDemo_t *demo = findDemoById(demoId);
    if (!demo || demo->size < 2)
    {
        stackPushUndefined();
        return;
    }
    int skipFailures = 0;
    int requireNearby = 0;
    if (argumentCount > 4)
    {
        stackGetParamInt(4, &skipFailures);
    }
    if (argumentCount > 5)
    {
        stackGetParamInt(5, &requireNearby);
    }

    DemoFrameRange range;
    if (matchByPosition)
    {
        range = findNearestDemoRange(*demo, origin, skipFailures, requireNearby);
    }
    else
    {
        range = findCheckpointDemoRange(*demo, checkpointId, skipFailures);
        if (range.first >= 0 &&
            !demoSetupIsNearby(*demo, range, checkpointId, origin, skipFailures))
        {
            range.first = -1;
        }
    }
    if (range.first < 0 || range.last <= range.first)
    {
        stackPushUndefined();
        return;
    }

    int shotCount = 0;
    int frameCount = 0;
    for (int index = range.first; index <= range.last; ++index)
    {
        const sDemoFrame_t &frame = demo->pDemoFrames[index];
        if (skipFailures && !frame.isKeyFrame)
        {
            continue;
        }
        ++frameCount;
        if (frame.rpgNow)
        {
            ++shotCount;
        }
    }
    // Preserve the script result order: range, local RPG usage, successful samples.
    stackMakeArray();
    stackPushInt(range.first);
    stackPushArrayNext();
    stackPushInt(range.last);
    stackPushArrayNext();
    stackPushInt(shotCount);
    stackPushArrayNext();
    stackPushInt(frameCount);
    stackPushArrayNext();
}
bool OpenCJ_Demo_IsPresentationActive(int client)
{
#ifdef COD4
    return client >= 0 && client < MAX_CLIENTS && demoReturnVisual[client] != nullptr;
#else
    return false;
#endif
}

void OpenCJ_Demo_ApplyBody(int client)
{
#ifdef COD4
    if (!OpenCJ_Demo_IsPresentationActive(client) || !demoPresentedBody[client].valid)
    {
        return;
    }
    const DemoBody &body = demoPresentedBody[client];
    playerState_t &playerState = *SV_GameClientNum(client);
    playerState.legsAnim = body.legs;
    playerState.torsoAnim = body.torso;
    playerState.legsTimer = 0;
    playerState.torsoTimer = 0;
    playerState.legsAnimDuration = body.legsDuration;
    playerState.torsoAnimDuration = body.torsoDuration;
    playerState.movementDir = body.direction;
    g_entities[client].s.legsAnim = body.legs;
    g_entities[client].s.torsoAnim = body.torso;
    g_entities[client].s.lerp.u.player.movementDir = body.direction;
#endif
}

#ifdef COD4
// Numeric values follow the stock tables in _bg_animation_mp.asm.
namespace DemoAnimation
{
enum Movement
{
    IDLE = 1,
    IDLE_CROUCHED = 2,
    IDLE_PRONE = 3,
    WALK = 4,
    WALK_CROUCHED = 6,
    WALK_PRONE = 8,
    RUN = 10,
    RUN_CROUCHED = 12,
    CLIMB_UP = 18,
    CLIMB_DOWN = 19,
    SPRINT = 20,
    MANTLE = 21
};
enum Event
{
    JUMP = 3,
    JUMP_BACKWARD = 4,
    LAND = 5,
    CROUCH_TO_PRONE = 11,
    PRONE_TO_CROUCH = 12,
    STAND_TO_CROUCH = 13,
    CROUCH_TO_STAND = 14,
    STAND_TO_PRONE = 15,
    PRONE_TO_STAND = 16
};
constexpr int STRAFING_CONDITION = 8;
constexpr int INDEX_MASK = 511;
constexpr int RESTART_BIT = 512;
} // namespace DemoAnimation

static void applyDemoBodyEvent(DemoBody &body, playerState_t &pose, int event, int frame,
                               int elapsed)
{
    if (body.event != event || body.eventFrame != frame || body.eventWeapon != int(pose.weapon))
    {
        playerState_t transition = pose;
        int duration = BG_AnimScriptEvent(&transition, event, 0, 1);
        // Some stock weapon sets omit direct stand/prone transitions.
        // Their crouch/prone transition still supplies the raising/lowering motion.
        if (duration <= 0 &&
            (event == DemoAnimation::STAND_TO_PRONE || event == DemoAnimation::PRONE_TO_STAND))
        {
            duration = BG_AnimScriptEvent(&transition,
                                          event == DemoAnimation::STAND_TO_PRONE
                                              ? DemoAnimation::CROUCH_TO_PRONE
                                              : DemoAnimation::PRONE_TO_CROUCH,
                                          0, 1);
        }
        body.event = event;
        body.eventFrame = frame;
        body.eventWeapon = pose.weapon;
        body.eventDuration = duration;
        body.eventLegs = transition.legsAnim;
        body.eventTorso = transition.torsoAnim;
        body.eventLegsDuration = transition.legsAnimDuration;
        body.eventTorsoDuration = transition.torsoAnimDuration;
    }
    // Choose a variant once per transition. Repeated calls otherwise reroll
    // the stock animation script's random selection and flicker between poses.
    if (body.eventDuration > elapsed)
    {
        pose.legsAnim = body.eventLegs;
        pose.torsoAnim = body.eventTorso;
        pose.legsAnimDuration = body.eventLegsDuration;
        pose.torsoAnimDuration = body.eventTorsoDuration;
    }
}

// Legacy recordings lack velocity. Infer it only between nearby continuous frames.
static void readDemoBodyVelocity(const sDemo_t &demo, int index, float velocity[3])
{
    const sDemoFrame_t &frame = demo.pDemoFrames[index];
    std::fill(velocity, velocity + 3, 0);
    if (frame.visual.valid)
    {
        for (int axis = 0; axis < 3; ++axis)
        {
            velocity[axis] = frame.visual.velocity[axis] / DEMO_VELOCITY_SCALE;
        }
        return;
    }
    if (index <= 0 || frame.loadNow)
    {
        return;
    }
    const sDemoFrame_t &previousFrame = demo.pDemoFrames[index - 1];
    const float dx = frame.origin[0] - previousFrame.origin[0];
    const float dy = frame.origin[1] - previousFrame.origin[1];
    if (dx * dx + dy * dy < DEMO_MAX_CONTINUOUS_DISTANCE * DEMO_MAX_CONTINUOUS_DISTANCE)
    {
        velocity[0] = dx * DEMO_FRAMES_PER_SECOND;
        velocity[1] = dy * DEMO_FRAMES_PER_SECOND;
        velocity[2] = (frame.origin[2] - previousFrame.origin[2]) * DEMO_FRAMES_PER_SECOND;
    }
}

// Choose stock locomotion from recorded state, independent of the frozen viewer.
static int selectDemoBodyMovement(const sDemoFrame_t &frame, float speed, float verticalVelocity,
                                  bool moving, bool backward, int playerSpeed)
{
    const bool crouched = frame.flags & DEMO_CROUCHED;
    const bool prone = frame.flags & DEMO_PRONE;
    if (frame.flags & DEMO_LADDER)
    {
        return verticalVelocity < 0 ? DemoAnimation::CLIMB_DOWN : DemoAnimation::CLIMB_UP;
    }
    if (frame.flags & DEMO_MANTLING)
    {
        return DemoAnimation::MANTLE;
    }
    if (!moving)
    {
        if (prone)
        {
            return DemoAnimation::IDLE_PRONE;
        }
        return crouched ? DemoAnimation::IDLE_CROUCHED : DemoAnimation::IDLE;
    }

    const bool walking = speed < std::max(1, playerSpeed) * 0.6f || frame.visual.ads > 0;
    int movement;
    if (prone)
    {
        movement = DemoAnimation::WALK_PRONE;
    }
    else if (crouched)
    {
        movement = walking ? DemoAnimation::WALK_CROUCHED : DemoAnimation::RUN_CROUCHED;
    }
    else
    {
        movement = walking ? DemoAnimation::WALK : DemoAnimation::RUN;
    }
    // Each walk/run entry is immediately followed by its backward variant.
    if (backward)
    {
        ++movement;
    }
    if (!prone && !crouched && (frame.flags & DEMO_SPRINTING))
    {
        movement = DemoAnimation::SPRINT;
    }
    return movement;
}

static int demoStanceTransition(int previousStance, int stance)
{
    if (stance == DEMO_PRONE)
    {
        return previousStance == DEMO_CROUCHED ? DemoAnimation::CROUCH_TO_PRONE
                                               : DemoAnimation::STAND_TO_PRONE;
    }
    if (previousStance == DEMO_PRONE)
    {
        return stance == DEMO_CROUCHED ? DemoAnimation::PRONE_TO_CROUCH
                                       : DemoAnimation::PRONE_TO_STAND;
    }
    return stance == DEMO_CROUCHED ? DemoAnimation::STAND_TO_CROUCH
                                   : DemoAnimation::CROUCH_TO_STAND;
}

// Seek/reverse reconstructs a short transition from source-frame time.
// Stop at loads so an earlier take cannot supply the current body's pose.
static void applyRecentDemoBodyTransition(DemoBody &body, playerState_t &pose, const sDemo_t &demo,
                                          int index)
{
    for (int frameIndex = index; frameIndex > 0 && index - frameIndex < DEMO_TRANSITION_SCAN_FRAMES;
         --frameIndex)
    {
        const sDemoFrame_t &frame = demo.pDemoFrames[frameIndex];
        const sDemoFrame_t &previousFrame = demo.pDemoFrames[frameIndex - 1];
        if (frame.loadNow)
        {
            break;
        }
        int event = -1;
        if ((frame.flags & DEMO_GROUNDED) &&
            !(previousFrame.flags & (DEMO_GROUNDED | DEMO_MANTLING | DEMO_LADDER)))
        {
            event = DemoAnimation::LAND;
        }
        const int stance = frame.flags & (DEMO_CROUCHED | DEMO_PRONE);
        const int previousStance = previousFrame.flags & (DEMO_CROUCHED | DEMO_PRONE);
        if (stance != previousStance)
        {
            event = demoStanceTransition(previousStance, stance);
        }
        if (event >= 0)
        {
            applyDemoBodyEvent(body, pose, event, frameIndex,
                               (index - frameIndex) * DEMO_FRAME_TIME_MS);
            break;
        }
    }
}

// Keep the restart toggle unless the final animation changes. Intermediate
// locomotion selection must not restart a jump/landing loop on every tick.
static int retainDemoAnimationToggle(int selectedAnimation, int previousAnimation)
{
    const int animationIndex = selectedAnimation & DemoAnimation::INDEX_MASK;
    if (animationIndex == (previousAnimation & DemoAnimation::INDEX_MASK))
    {
        return previousAnimation;
    }
    return animationIndex |
           ((previousAnimation ^ DemoAnimation::RESTART_BIT) & DemoAnimation::RESTART_BIT);
}

static void applyDemoBody(int client, const sDemo_t &demo, int index)
{
    const sDemoFrame_t &frame = techniqueFrame(client, demo, index);
    playerState_t &playerState = *SV_GameClientNum(client);
    DemoBody &body = demoPresentedBody[client];
    playerState_t pose = playerState;
    pose.clientNum = client;
    pose.pm_type = DEMO_NORMAL_MOVEMENT;
    pose.legsAnim = body.legs;
    pose.torsoAnim = body.torso;
    pose.legsTimer = 0;
    pose.torsoTimer = 0;
    pose.legsAnimDuration = body.legsDuration;
    pose.torsoAnimDuration = body.torsoDuration;
    pose.pm_flags = 0;
    if (frame.flags & DEMO_PRONE)
    {
        pose.pm_flags = 1;
    }
    else if (frame.flags & DEMO_CROUCHED)
    {
        pose.pm_flags = 2;
    }
    if (frame.flags & DEMO_LADDER)
    {
        pose.pm_flags |= DEMO_LADDER_MOVEMENT_FLAG;
    }
    pose.eFlags &= ~0x300; // Never inherit the viewer's mounted-weapon state.

    float velocity[3];
    readDemoBodyVelocity(demo, index, velocity);
    const float speed = std::sqrt(velocity[0] * velocity[0] + velocity[1] * velocity[1]);
    const int forward = bool(frame.flags & DEMO_FORWARD) - bool(frame.flags & DEMO_BACK);
    const int right = bool(frame.flags & DEMO_RIGHT) - bool(frame.flags & DEMO_LEFT);
    const bool backward = forward < 0;
    const bool grounded = frame.flags & DEMO_GROUNDED;
    const bool moving = speed > 5 && (forward || right);
    const int movement =
        selectDemoBodyMovement(frame, speed, velocity[2], moving, backward, playerState.speed);
    int strafeCondition = 0;
    if (forward == 0)
    {
        if (right < 0)
        {
            strafeCondition = 1;
        }
        else if (right > 0)
        {
            strafeCondition = 2;
        }
    }
    pmove_t movementState = {};
    movementState.ps = &pose;
    bgs_s *previousBgs = bgs;
    bgs = &level_bgs;
    BG_AnimUpdatePlayerStateConditions(&movementState);
    BG_SetConditionValue(client, DemoAnimation::STRAFING_CONDITION, strafeCondition);
    BG_AnimScriptAnimation(&pose, 0, movement, 0);
    if (!(frame.flags & (DEMO_MANTLING | DEMO_LADDER)))
    {
        if (grounded)
        {
            applyRecentDemoBodyTransition(body, pose, demo, index);
        }
        else
        {
            // Pose only; this cannot emit a jump or run player physics.
            const int jumpEvent = backward ? DemoAnimation::JUMP_BACKWARD : DemoAnimation::JUMP;
            applyDemoBodyEvent(body, pose, jumpEvent, -1, 0);
        }
    }
    bgs = previousBgs;

    body.legs = retainDemoAnimationToggle(pose.legsAnim, body.legs);
    body.torso = retainDemoAnimationToggle(pose.torsoAnim, body.torso);
    body.valid = true;
    body.legsDuration = pose.legsAnimDuration;
    body.torsoDuration = pose.torsoAnimDuration;
    float direction = 0;
    if (grounded && moving)
    {
        direction = std::remainder(std::atan2(velocity[1], velocity[0]) * 180.0f / 3.14159265f -
                                       frame.angles[1] + (backward ? 180 : 0),
                                   360.0f);
    }
    body.direction = std::max(-90, std::min(90, int(direction)));
    // Publish now and reapply after linked Pmove chooses an idle body pose.
    OpenCJ_Demo_ApplyBody(client);
}
#endif

// Presentation only: never replay input through weapon simulation or spawn missiles.
void Gsc_Demo_BeginPresentation(int client)
{
#ifdef COD4
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    if (!g_entities[client].client)
    {
        stackPushBool(false);
        return;
    }
    // Repeated starts must retain the state from before playback began.
    if (demoReturnVisual[client])
    {
        stackPushBool(true);
        return;
    }
    playerState_t *returnState = new (std::nothrow) playerState_t(*SV_GameClientNum(client));
    if (!returnState)
    {
        stackPushBool(false);
        return;
    }
    demoReturnVisual[client] = returnState;
    demoPresentedWeapon[client] = -1;
    demoPresentedFrame[client] = -1;
    demoPresentedBody[client] = {};
    demoReturnFrozen[client] = g_entities[client].client->bFrozen;
    stackPushBool(demoReturnVisual[client] != nullptr);
#else
    stackPushBool(false);
#endif
}

#ifdef COD4
// Break interpolation only at a load, a seek, or a discontinuity too large for
// the recorded speed. This also handles older recordings without load markers.
static void updateDemoInterpolation(int client, const sDemoPlayback_t &playback,
                                    const sDemoFrame_t &frame, playerState_t &playerState)
{
    const DemoVisual &visual = frame.visual;
    if (demoPresentedFrame[client] != playback.selectedFrame)
    {
        bool cut =
            frame.loadNow || (demoPresentedFrame[client] >= 0 &&
                              std::abs(playback.selectedFrame - demoPresentedFrame[client]) > 4);
        int previous = demoPresentedFrame[client];
        if (previous >= 0 && previous < playback.pDemo->size)
        {
            const sDemoFrame_t &before = playback.pDemo->pDemoFrames[previous];
            float distance = 0;
            float speed = 0;
            for (int i = 0; i < 3; ++i)
            {
                float delta = frame.origin[i] - before.origin[i];
                distance += delta * delta;
                float velocity = visual.velocity[i] / DEMO_VELOCITY_SCALE;
                speed += velocity * velocity;
            }
            // Older recordings lack teleport markers. Do not blend map portals
            // across the map; allow for genuine high-speed movement.
            cut |= distance > std::max(256.0f * 256.0f, speed * 0.01f);
        }
        if (cut)
        {
            playerState.eFlags ^= DEMO_TELEPORT_TOGGLE;
        }
        demoPresentedFrame[client] = playback.selectedFrame;
    }
}

// Restore this temporary inventory and viewmodel state when presentation ends.
static void applyDemoViewmodel(int client, const DemoVisual &visual, playerState_t &playerState)
{
    // Match the existing seamless-switch protocol so client prediction does not
    // keep re-equipping the viewer's own weapon. Restore inventory on exit.
    if (visual.weapon)
    {
        playerState.weapons[visual.weapon / 32] |= 1u << (visual.weapon % 32);
    }
    if (demoPresentedWeapon[client] != visual.weapon)
    {
        SV_GameSendServerCommand(client, 1, va("a %u", unsigned(visual.weapon)));
        demoPresentedWeapon[client] = visual.weapon;
    }
    // disableWeapons makes PM_Weapon lower the weapon to "none". Freeze
    // live input instead, and drive the animation directly from the recording.
    // Never feed recorded fire delays/states back into weapon simulation:
    // a delayed RPG shot could otherwise spawn a real missile.
    g_entities[client].client->bFrozen = qtrue;
    playerState.pm_flags |= DEMO_FROZEN_MOVEMENT_FLAG;
    // Use the client's spectator interpolation path. Local prediction would
    // zero velocity for frozen controls, suppressing recorded weapon bob/sway.
    playerState.otherFlags |= DEMO_SPECTATOR_INTERPOLATION_FLAG;
    playerState.weapFlags &= ~DEMO_DISABLED_WEAPON_FLAG;
    // Viewmodel rocket tags depend on clip ammo even when animation is driven
    // directly. Supply presentation ammo; the saved inventory is restored on exit.
    const WeaponDef *weapon = BG_GetWeaponDef(visual.weapon);
    if (weapon)
    {
        if (weapon->iClipIndex >= 0 && weapon->iClipIndex < int(sizeof(playerState.ammoclip) /
                                                                sizeof(playerState.ammoclip[0])))
        {
            playerState.ammoclip[weapon->iClipIndex] = 1;
        }
        if (weapon->iAmmoIndex >= 0 &&
            weapon->iAmmoIndex < int(sizeof(playerState.ammo) / sizeof(playerState.ammo[0])))
        {
            playerState.ammo[weapon->iAmmoIndex] = 1;
        }
    }
    playerState.weapon = visual.weapon;
    playerState.weaponTime = DEMO_WEAPON_HOLD_TIME_MS;
    playerState.weaponDelay = 0;
    playerState.weapAnim = visual.animation;
    playerState.weaponstate = DEMO_WEAPON_READY_STATE;
}

// Apply recorded stance and motion for presentation, without running Pmove.
static void applyDemoRecordedPose(const sDemoFrame_t &frame, playerState_t &playerState)
{
    const DemoVisual &visual = frame.visual;
    playerState.bobCycle = visual.bobCycle;
    playerState.viewHeightCurrent = visual.viewHeight;
    playerState.viewHeightTarget = int(visual.viewHeight);
    playerState.viewHeightLerpTime = 0;
    playerState.fWeaponPosFrac = visual.ads;
    if (!(frame.flags & DEMO_GROUNDED) && playerState.groundEntityNum != ENTITYNUM_NONE)
    {
        playerState.jumpTime = playerState.commandTime;
        playerState.jumpOriginZ = frame.origin[2];
    }
    playerState.groundEntityNum = (frame.flags & DEMO_GROUNDED) ? ENTITYNUM_WORLD : ENTITYNUM_NONE;
    playerState.pm_flags =
        (playerState.pm_flags & ~(DEMO_MANTLE_MOVEMENT_FLAG | DEMO_LADDER_MOVEMENT_FLAG)) |
        ((frame.flags & DEMO_MANTLING) ? DEMO_MANTLE_MOVEMENT_FLAG : 0) |
        ((frame.flags & DEMO_LADDER) ? DEMO_LADDER_MOVEMENT_FLAG : 0);
    for (int i = 0; i < 3; ++i)
    {
        playerState.velocity[i] = visual.velocity[i] / DEMO_VELOCITY_SCALE;
        playerState.vLadderVec[i] = visual.ladder[i] / DEMO_LADDER_SCALE;
    }
    playerState.sprintState.lastSprintStart = playerState.commandTime - visual.sprintElapsed;
    playerState.sprintState.lastSprintEnd = (frame.flags & DEMO_SPRINTING)
                                                ? playerState.sprintState.lastSprintStart - 1
                                                : playerState.commandTime;
    playerState.mantleState.timer = visual.mantleTimer;
    playerState.mantleState.yaw = visual.mantleYaw * 360.0f / 65536;
    playerState.mantleState.transIndex = visual.mantleTransition;
    playerState.mantleState.flags = visual.mantleFlags;
}
#endif

void Gsc_Demo_ApplyPresentation(int client)
{
#ifdef COD4
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (!demoReturnVisual[client] || !hasSelectedDemoFrame(playback))
    {
        stackPushBool(false);
        return;
    }
    const sDemoFrame_t &frame = playback.pDemo->pDemoFrames[playback.selectedFrame];
    if (!frame.visual.valid)
    {
        applyDemoBody(client, *playback.pDemo, playback.selectedFrame);
        stackPushBool(false);
        return;
    }
    if (frame.visual.weapon >= DEMO_WEAPON_LIMIT)
    {
        stackPushBool(false);
        return;
    }
    playerState_t &playerState = *SV_GameClientNum(client);
    updateDemoInterpolation(client, playback, frame, playerState);
    applyDemoViewmodel(client, frame.visual, playerState);
    applyDemoRecordedPose(frame, playerState);
    applyDemoBody(client, *playback.pDemo, playback.selectedFrame);
    stackPushBool(true);
#else
    stackPushBool(false);
#endif
}

// Find checkpoint boundaries in the retained recording, not the map's route graph.
void Gsc_Demo_SeekCheckpoint(int client)
{
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    int direction;
    if (!stackGetParamInt(0, &direction) || (direction != -1 && direction != 1))
    {
        stackPushUndefined();
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (!playback.pDemo)
    {
        stackPushUndefined();
        return;
    }
    const auto &timeline = demoPlaybackTimeline[client];
    const sDemoFrame_t *frames = playback.pDemo->pDemoFrames;
    if (timeline.empty())
    {
        int current = playback.selectedFrame;
        int target = current;
        if (direction > 0)
        {
            while (target + 1 < playback.pDemo->size &&
                   frames[target + 1].checkpointId == frames[current].checkpointId)
            {
                ++target;
            }
            if (target + 1 < playback.pDemo->size)
            {
                ++target;
            }
        }
        else
        {
            while (target > 0 && frames[target - 1].checkpointId == frames[current].checkpointId)
            {
                --target;
            }
            if (target > 0)
            {
                --target;
                while (target > 0 && frames[target - 1].checkpointId == frames[target].checkpointId)
                {
                    --target;
                }
            }
        }
        stackPushInt(target);
        return;
    }
    int current = int(std::lower_bound(timeline.begin(), timeline.end(), playback.selectedFrame) -
                      timeline.begin());
    current = std::min(current, int(timeline.size()) - 1);
    int target = current;
    if (direction > 0)
    {
        while (target + 1 < int(timeline.size()) &&
               frames[timeline[target + 1]].checkpointId == frames[timeline[current]].checkpointId)
        {
            ++target;
        }
        if (target + 1 < int(timeline.size()))
        {
            ++target;
        }
    }
    else
    {
        while (target > 0 &&
               frames[timeline[target - 1]].checkpointId == frames[timeline[current]].checkpointId)
        {
            --target;
        }
        if (target > 0)
        {
            --target;
            while (target > 0 && frames[timeline[target - 1]].checkpointId ==
                                     frames[timeline[target]].checkpointId)
            {
                --target;
            }
        }
    }
    stackPushInt(timeline[target]);
}

void Gsc_Demo_PlayLanding(int client)
{
#ifdef COD4
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (demoReturnVisual[client] && hasSelectedDemoFrame(playback))
    {
        const sDemoFrame_t &frame = playback.pDemo->pDemoFrames[playback.selectedFrame];
        if (frame.visual.landingEvent && !frame.loadNow)
        {
            // A normal landing event gives the owner the original camera dip;
            // pain events were converted during capture and cannot deal damage.
            BG_AddPredictableEventToPlayerstate(BGEvent(frame.visual.landingEvent),
                                                frame.visual.landingImpact,
                                                g_entities[client].client);
            stackPushBool(true);
            return;
        }
    }
#endif
    stackPushBool(false);
}

void Gsc_Demo_EndPresentation(int client)
{
#ifdef COD4
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    demoTechnique[client] = {};
    playerState_t *saved = demoReturnVisual[client];
    if (!saved)
    {
        return;
    }
    playerState_t &playerState = *SV_GameClientNum(client);
    g_entities[client].client->bFrozen = demoReturnFrozen[client];
    playerState.otherFlags = (playerState.otherFlags & ~DEMO_SPECTATOR_INTERPOLATION_FLAG) |
                             (saved->otherFlags & DEMO_SPECTATOR_INTERPOLATION_FLAG);
    playerState.pm_flags = (playerState.pm_flags & ~DEMO_FROZEN_MOVEMENT_FLAG) |
                           (saved->pm_flags & DEMO_FROZEN_MOVEMENT_FLAG);
    playerState.weapFlags = (playerState.weapFlags & ~DEMO_DISABLED_WEAPON_FLAG) |
                            (saved->weapFlags & DEMO_DISABLED_WEAPON_FLAG);
    memcpy(playerState.weapons, saved->weapons, sizeof(playerState.weapons));
    memcpy(playerState.weaponold, saved->weaponold, sizeof(playerState.weaponold));
    memcpy(playerState.weaponrechamber, saved->weaponrechamber, sizeof(playerState.weaponrechamber));
    memcpy(playerState.ammo, saved->ammo, sizeof(playerState.ammo));
    memcpy(playerState.ammoclip, saved->ammoclip, sizeof(playerState.ammoclip));
    playerState.weapon = saved->weapon;
    playerState.weaponTime = saved->weaponTime;
    playerState.weaponDelay = saved->weaponDelay;
    SV_GameSendServerCommand(client, 1, va("a %u", saved->weapon));
    playerState.weapAnim = saved->weapAnim;
    playerState.weaponstate = saved->weaponstate;
    playerState.bobCycle = saved->bobCycle;
    playerState.viewHeightCurrent = saved->viewHeightCurrent;
    playerState.viewHeightTarget = saved->viewHeightTarget;
    playerState.viewHeightLerpTime = saved->viewHeightLerpTime;
    playerState.viewHeightLerpTarget = saved->viewHeightLerpTarget;
    playerState.viewHeightLerpDown = saved->viewHeightLerpDown;
    playerState.fWeaponPosFrac = saved->fWeaponPosFrac;
    playerState.pm_flags = (playerState.pm_flags & ~(DEMO_MANTLE_MOVEMENT_FLAG | DEMO_LADDER_MOVEMENT_FLAG)) | (saved->pm_flags & (DEMO_MANTLE_MOVEMENT_FLAG | DEMO_LADDER_MOVEMENT_FLAG));
    memcpy(playerState.velocity, saved->velocity, sizeof(playerState.velocity));
    memcpy(playerState.vLadderVec, saved->vLadderVec, sizeof(playerState.vLadderVec));
    int elapsed = playerState.commandTime - saved->commandTime;
    playerState.groundEntityNum = saved->groundEntityNum;
    playerState.jumpTime = saved->jumpTime + elapsed;
    playerState.jumpOriginZ = saved->jumpOriginZ;
    playerState.sprintState = saved->sprintState;
    playerState.sprintState.lastSprintStart += elapsed;
    playerState.sprintState.lastSprintEnd += elapsed;
    playerState.mantleState = saved->mantleState;
    playerState.legsAnim = saved->legsAnim;
    playerState.torsoAnim = saved->torsoAnim;
    playerState.legsTimer = saved->legsTimer;
    playerState.torsoTimer = saved->torsoTimer;
    playerState.legsAnimDuration = saved->legsAnimDuration;
    playerState.torsoAnimDuration = saved->torsoAnimDuration;
    playerState.movementDir = saved->movementDir;
    g_entities[client].s.legsAnim = playerState.legsAnim;
    g_entities[client].s.torsoAnim = playerState.torsoAnim;
    g_entities[client].s.lerp.u.player.movementDir = playerState.movementDir;
    delete saved;
    demoReturnVisual[client] = nullptr;
    std::vector<int>().swap(demoPlaybackTimeline[client]);
    demoFPSText[client].clear();
#endif
}

void Gsc_Demo_ReadFrame_Weapon(int client)
{
#ifdef COD4
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (hasSelectedDemoFrame(playback)) {
        const DemoVisual &visual = playback.pDemo->pDemoFrames[playback.selectedFrame].visual;
        if (visual.valid) {
            stackPushString(demoWeaponName(visual.weapon));
            return;
        }
    }
#endif
    stackPushUndefined();
}

void Gsc_Demo_ReadFrame_RPGSound(int client)
{
#ifdef COD4
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    const sDemoPlayback_t &playback = opencj_playback[client];
    if (hasSelectedDemoFrame(playback))
    {
        const sDemoFrame_t &frame = playback.pDemo->pDemoFrames[playback.selectedFrame];
        if (frame.visual.valid && frame.rpgNow && (frame.flags & DEMO_RPG_WEAPON))
        {
            const char *sound = demoFireSound(frame.visual.weapon);
            if (*sound)
            {
                stackPushString(sound);
                return;
            }
        }
    }
#endif
    stackPushUndefined();
}

// Clip handles occupy unused native IDs; database clip IDs remain independent.
static int transientDemoId()
{
    static int next = 2147483647;
    while (next > 0 && findDemoById(next))
    {
        --next;
    }
    return next > 0 ? next-- : 0;
}

void Gsc_Demo_CreateTransient()
{
    int id = transientDemoId();
    if (!id || !createDemo(id)) {
        stackPushUndefined();
        return;
    }
    stackPushInt(id);
}

// Called on the game thread: capture cannot append or rewind during this copy.
void Gsc_Demo_CopyHistory()
{
    int source;
    if (!stackGetParams("i", &source)) {
        stackPushUndefined();
        return;
    }
    sDemo_t *original = findDemoById(source);
    if (!original || original->size < 2 || original->releasePending) {
        stackPushUndefined();
        return;
    }
    int id = transientDemoId();
    sDemo_t *copy = id ? createDemo(id, original->size) : nullptr;
    if (!copy) {
        stackPushUndefined();
        return;
    }
    memcpy(copy->pDemoFrames, original->pDemoFrames, original->size * sizeof(sDemoFrame_t));
    copy->size = original->size;
    copy->currentFrame = copy->size - 1;
    copy->lastKeyFrame = original->lastKeyFrame;
    copy->isComplete = true;
    copy->isFirstFrameFilled = true;
    stackPushInt(id);
}

// [RPG shots, FPS category (-1=no airborne samples,0=125,1=mix,2=hax), elevation
// (-1=unknown,0=no,1=yes)] These result values are shared with GSC clip filters and range labels.
enum DemoFPSCategory {
    DEMO_FPS_UNKNOWN = -1,
    DEMO_FPS_125 = 0,
    DEMO_FPS_MIXED = 1,
    DEMO_FPS_OTHER = 2
};
enum DemoElevationStatus {
    DEMO_ELEVATION_UNKNOWN = -1,
    DEMO_ELEVATION_NONE = 0,
    DEMO_ELEVATION_USED = 1
};

void Gsc_Demo_RangeInfo() {
    int id;
    int first;
    int last;
    if (!stackGetParams("iii", &id, &first, &last)) {
        stackPushUndefined();
        return;
    }
    sDemo_t *demo = findDemoById(id);
    if (!demo || first < 0 || last < first || last >= demo->size) {
        stackPushUndefined();
        return;
    }
    int shotCount = 0;
    int fpsCategory = DEMO_FPS_UNKNOWN;
    bool elevationKnown = true;
    bool elevationUsed = false;
    for (int i = first; i <= last; ++i) {
        const sDemoFrame_t &frame = demo->pDemoFrames[i];
        shotCount += frame.rpgNow;
        elevationKnown = elevationKnown && frame.eleKnown;
        elevationUsed = elevationUsed || frame.eleUsed;
        if (!(frame.flags & DEMO_GROUNDED)) {
            if (frame.fps != 125 && frame.fps != 250 && frame.fps != 333) {
                fpsCategory = DEMO_FPS_OTHER;
            } else if (frame.fps != 125 && fpsCategory < DEMO_FPS_MIXED) {
                fpsCategory = DEMO_FPS_MIXED;
            } else if (fpsCategory < DEMO_FPS_125) {
                fpsCategory = DEMO_FPS_125;
            }
        }
    }
    int elevationStatus = DEMO_ELEVATION_UNKNOWN;
    if (elevationUsed) {
        elevationStatus = DEMO_ELEVATION_USED;
    } else if (elevationKnown) {
        elevationStatus = DEMO_ELEVATION_NONE;
    }
    stackMakeArray();
    stackPushInt(shotCount);
    stackPushArrayNext();
    stackPushInt(fpsCategory);
    stackPushArrayNext();
    stackPushInt(elevationStatus);
    stackPushArrayNext();
}

void Gsc_Demo_KeepLast() {
    int id;
    int count;
    if (!Base_Gsc_GetValidDemoId(&id, 2)) {
        return;
    }
    stackGetParamInt(1, &count);
    sDemo_t *demo = findDemoById(id);
    if (!demo || demo->isComplete || count < 1 || count > DEMO_MANUAL_HISTORY_LIMIT) {
        stackPushUndefined();
        return;
    }
    int removed = std::max(0, demo->size - count);
    if (removed) {
        memmove(demo->pDemoFrames, demo->pDemoFrames + removed, count * sizeof(sDemoFrame_t));
        demo->size = count;
        ++demo->editVersion;
        demo->currentFrame = count - 1;
        demo->lastKeyFrame = count - 1;
        // Manual clips preserve every take, so every frame stays playable.
        for (int i = 0; i < count; ++i) {
            auto &frame = demo->pDemoFrames[i];
            frame.isKeyFrame = true;
            frame.prevKeyFrame = std::max(0, i - 1);
            frame.nextKeyFrame = std::min(count - 1, i + 1);
        }
    }
    stackPushInt(removed);
}

constexpr int DEMO_TIMELINE_CELLS = 40;
enum DemoTimelineEvent {
    DEMO_TIMELINE_NO_EVENT = 0,
    DEMO_TIMELINE_SAVE = 1,
    DEMO_TIMELINE_LOAD = 2
};

// Preserve the script result order: pose, last load, then fixed-width event cells.
void Gsc_Demo_ClipInfo() {
    int id;
    int index;
    const int args = Scr_GetNumParam();
    if (args != 2 && args != 3) {
        stackPushUndefined();
        return;
    }
    if (!Base_Gsc_GetValidDemoId(&id, args)) {
        return;
    }
    stackGetParamInt(1, &index);
    const sDemo_t *demo = findDemoById(id);
    if (!demo || index < 0 || index >= demo->size) {
        stackPushUndefined();
        return;
    }
    int lastLoad = 0;
    for (int i = 0; i < demo->size; ++i) {
        if (demo->pDemoFrames[i].loadNow) {
            lastLoad = i;
        }
    }
    stackMakeArray();
    stackPushVector(demo->pDemoFrames[index].origin);
    stackPushArrayNext();
    stackPushVector(demo->pDemoFrames[index].angles);
    stackPushArrayNext();
    stackPushInt(lastLoad);
    stackPushArrayNext();
    // Timeline colors describe only events inside the inclusive trim range.
    int end = demo->size - 1;
    if (Scr_GetNumParam() > 2) {
        stackGetParamInt(2, &end);
    }
    if (end >= demo->size) {
        end = demo->size - 1;
    }
    int cells[DEMO_TIMELINE_CELLS] = {};
    const int cellCount = std::min(demo->size, DEMO_TIMELINE_CELLS);
    for (int i = index; i <= end; ++i) {
        const auto &frame = demo->pDemoFrames[i];
        int event = DEMO_TIMELINE_NO_EVENT;
        if (frame.loadNow) {
            event = DEMO_TIMELINE_LOAD;
        } else if (frame.saveNow) {
            event = DEMO_TIMELINE_SAVE;
        }
        int &cell = cells[i * cellCount / demo->size];
        if (event > cell) {
            cell = event;
        }
    }
    stackMakeArray();
    for (int event : cells) {
        stackPushInt(event);
        stackPushArrayNext();
    }
    stackPushArrayNext();
}

void Gsc_Demo_FPSReset(int client) {
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    demoFPSText[client].clear();
}

void Gsc_Demo_FPSStore(int client) {
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    int frame;
    char *text = nullptr;
    if (!stackGetParams("is", &frame, &text) || frame < 0 || strlen(text) > 1023) {
        stackPushUndefined();
        return;
    }
    demoFPSText[client].put(frame, text);
    stackPushBool(true);
}

void Gsc_Demo_FPSRead(int client) {
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    int frame;
    if (!stackGetParams("i", &frame)) {
        stackPushUndefined();
        return;
    }
    const char *text = demoFPSText[client].get(frame);
    if (text) {
        stackPushString(text);
    } else {
        stackPushUndefined();
    }
}

void Gsc_Demo_FPSStats(int client) {
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    stackMakeArray();
    stackPushInt(demoFPSText[client].changes.size());
    stackPushArrayNext();
    stackPushInt(demoFPSText[client].samples.size());
    stackPushArrayNext();
}

// All transfer bookkeeping is main-thread owned. SQL workers own only queries
// and MYSQL_RES until completion; binary payload bytes never enter GSC.
constexpr int DEMO_SQL_BATCH_CHUNKS = 32;
constexpr size_t DEMO_SQL_QUERY_BUFFER_BYTES = 256;
constexpr int DEMO_SQL_READ_WAIT_MS = 10000;
constexpr int DEMO_SQL_WRITE_WAIT_MS = 30000;
enum DemoSQLColumn { DEMO_SQL_CHUNK_NUMBER = 0, DEMO_SQL_PAYLOAD = 1, DEMO_SQL_COLUMN_COUNT = 2 };

struct DemoSQLRead {
    int nativeId;
    int nextChunk;
    int outcomeOverride;
    unsigned long long generation;
    bool done;
};
static std::map<int, DemoSQLRead> demoSQLReads;
long long OpenCJ_Demo_SQLClockMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// Keep compressed payloads native and limit each query to one bounded batch.
void Gsc_Demo_LoadChunks() {
    int nativeId;
    int storedId;
    int clip;
    int first;
    if (!stackGetParams("iiii", &nativeId, &storedId, &clip, &first) || storedId <= 0 ||
        first < 0 || (clip != 0 && clip != 1)) {
        stackPushInt(-SQL_INVALID);
        return;
    }
    sDemo_t *demo = findDemoById(nativeId);
    if (!demo || demo->isComplete) {
        stackPushInt(-SQL_INVALID);
        return;
    }
    char query[DEMO_SQL_QUERY_BUFFER_BYTES];
    snprintf(
        query, sizeof(query),
        "SELECT chunkNum,payload FROM %s WHERE %s=%d AND chunkNum>=%d ORDER BY chunkNum LIMIT %d",
        clip ? "demoClipChunks" : "demoChunks", clip ? "clipID" : "runID", storedId, first,
        DEMO_SQL_BATCH_CHUNKS);
    int id = sqlPoolSubmit(query, true, SQL_READ, "", "", DEMO_SQL_READ_WAIT_MS);
    if (id > 0) {
        demoSQLReads[id] = {nativeId, first, 0, demo->generation, false};
    }
    stackPushInt(id);
}

// Borrow the pool result across ticks and decode only within this frame's time budget.
static bool decodeCompletedDemoRows(sDemo_t &demo, DemoSQLRead &load, MYSQL_RES *result,
                                    long long deadlineMs) {
    if (!result || mysql_num_fields(result) != DEMO_SQL_COLUMN_COUNT || !mysql_num_rows(result) ||
        mysql_num_rows(result) > DEMO_SQL_BATCH_CHUNKS) {
        load.outcomeOverride = SQL_INVALID;
        load.done = true;
        return true;
    }
    // Limit main-thread decode time, not the number of concurrent viewers.
    while (OpenCJ_Demo_SQLClockMs() < deadlineMs) {
        MYSQL_ROW row = mysql_fetch_row(result);
        if (!row) {
            load.done = true;
            return true;
        }
        unsigned long *fieldLengths = mysql_fetch_lengths(result);
        char *numberEnd = nullptr;
        long chunkNumber =
            row[DEMO_SQL_CHUNK_NUMBER] ? strtol(row[DEMO_SQL_CHUNK_NUMBER], &numberEnd, 10) : -1;
        if (!row[DEMO_SQL_CHUNK_NUMBER] || !numberEnd || *numberEnd ||
            chunkNumber != load.nextChunk || !row[DEMO_SQL_PAYLOAD] || !fieldLengths ||
            !decodeDemoChunk(&demo, reinterpret_cast<unsigned char *>(row[DEMO_SQL_PAYLOAD]),
                             fieldLengths[DEMO_SQL_PAYLOAD])) {
            load.outcomeOverride = SQL_INVALID;
            load.done = true;
            return true;
        }
        ++load.nextChunk;
    }
    return false;
}

// Other SQL jobs are immediately publishable; demo jobs first consume their
// native payloads. Generation checks prevent reuse of a destroyed demo handle.
bool OpenCJ_Demo_SQLReady(int id, long long deadlineMs) {
    auto foundRead = demoSQLReads.find(id);
    if (foundRead == demoSQLReads.end()) {
        return true;
    }
    DemoSQLRead &load = foundRead->second;
    MYSQL_RES *result = nullptr;
    SqlCompletion completion;
    if (!sqlPoolPeek(id, &result, &completion)) {
        return false;
    }
    auto foundDemo = opencj_demoIdToIdx.find(load.nativeId);
    bool missing = foundDemo == opencj_demoIdToIdx.end() ||
                   opencj_demos[foundDemo->second].generation != load.generation;
    if (missing) {
        load.outcomeOverride = SQL_CANCELLED;
        load.done = true;
        return true;
    }
    if (load.done) {
        return true;
    }
    if (completion.outcome != SQL_OK) {
        load.done = true;
        return true;
    }
    sDemo_t &demo = opencj_demos[foundDemo->second];
    return decodeCompletedDemoRows(demo, load, result, deadlineMs);
}

void OpenCJ_Demo_SQLStatus(int id, SqlCompletion *completion) {
    auto foundRead = demoSQLReads.find(id);
    if (foundRead != demoSQLReads.end() && foundRead->second.outcomeOverride) {
        completion->outcome = foundRead->second.outcomeOverride;
    }
}

// Consume exactly one pool completion, free its result, and return the next chunk to GSC.
bool OpenCJ_Demo_SQLTake(int id) {
    auto foundRead = demoSQLReads.find(id);
    if (foundRead == demoSQLReads.end()) {
        return false;
    }
    MYSQL_RES *result = nullptr;
    SqlCompletion completion;
    if (!foundRead->second.done || !sqlPoolTake(id, &result, &completion)) {
        stackPushUndefined();
        return true;
    }
    if (result) {
        mysql_free_result(result);
    }
    if (completion.outcome != SQL_OK || foundRead->second.outcomeOverride) {
        stackPushUndefined();
    } else {
        stackMakeArray();
        stackMakeArray();
        stackPushInt(foundRead->second.nextChunk);
        stackPushArrayNext();
        stackPushArrayNext();
    }
    demoSQLReads.erase(foundRead);
    return true;
}

// A destroyed recording may still have a script waiter. Retain cancellation
// until that waiter consumes foundRead, and never decode into a reused native ID.
static void cancelDemoLoads(const sDemo_t &demo) {
    for (const auto &entry : demoSQLReads) {
        const DemoSQLRead &load = entry.second;
        if (load.nativeId == demo.id && load.generation == demo.generation) {
            sqlPoolCancelRead(entry.first, SqlCompletionHandling::Retain);
        }
    }
}

void OpenCJ_Demo_SQLNewMap() {
    // Map teardown has no remaining script waiters. The pool still owns active
    // connections until their workers finish; this main-thread bookkeeping can go now.
    for (const auto &entry : demoSQLReads) {
        sqlPoolCancelRead(entry.first, SqlCompletionHandling::Discard);
    }
    demoSQLReads.clear();
}

// Encode before admission. Once accepted, the pool owns the query through completion.
void Gsc_Demo_UploadChunk() {
    int nativeId;
    int storedId;
    int clip;
    int first;
    int count;
    int chunk;
    if (!stackGetParams("iiiiii", &nativeId, &storedId, &clip, &first, &count, &chunk) ||
        storedId <= 0 || chunk < 0 || (clip != 0 && clip != 1)) {
        stackPushInt(-SQL_INVALID);
        return;
    }
    std::string packed;
    if (!encodeDemoChunk(findDemoById(nativeId), first, count, packed)) {
        stackPushInt(-SQL_INVALID);
        return;
    }
    std::string key = (clip ? "clip:" : "demo:") + std::to_string(storedId);
    std::string query = "INSERT INTO " + std::string(clip ? "demoClipChunks" : "demoChunks") +
                        " VALUES(" + std::to_string(storedId) + "," + std::to_string(chunk) +
                        ",UNHEX('" + demoHex(packed) + "'))";
    stackPushInt(sqlPoolSubmit(query.c_str(), false, SQL_BACKGROUND, key.c_str(), "",
                               DEMO_SQL_WRITE_WAIT_MS));
}

// Pin ownership keeps source frames available while asynchronous users finish.
void Gsc_Demo_Pin() {
    int id;
    if (!stackGetParams("i", &id)) {
        stackPushBool(false);
        return;
    }
    sDemo_t *demo = findDemoById(id);
    if (!demo || demo->releasePending) {
        stackPushBool(false);
        return;
    }
    ++demo->pins;
    stackPushBool(true);
}

void Gsc_Demo_Unpin() {
    int id;
    if (!stackGetParams("i", &id)) {
        return;
    }
    auto foundRead = opencj_demoIdToIdx.find(id);
    if (foundRead == opencj_demoIdToIdx.end()) {
        return;
    }
    sDemo_t *demo = &opencj_demos[foundRead->second];
    if (demo->pins) {
        --demo->pins;
    }
    if (!demo->pins && demo->releasePending) {
        clearDemoById(id);
    }
}
