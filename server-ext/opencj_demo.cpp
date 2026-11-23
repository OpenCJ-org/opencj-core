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
#ifdef COD4
#include "../cod4x-server/src/zlib/zlib.h"
#else
#include <zlib.h>
#endif

/**************************************************************************
 * Defines                                                                *
 **************************************************************************/

// Max number of demos per map that are available for playback
#define MAX_NR_DEMOS_PER_MAP            128

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

static DemoVisual captureDemoVisual(const playerState_t &ps, bool rpg, int previousEventSequence)
{
    DemoVisual v = {};
    v.valid = true;
    v.weapon = ps.weapon;
    v.weaponTime = demoU16(ps.weaponTime);
    v.weaponDelay = demoU16(ps.weaponDelay);
    v.animation = ps.weapAnim;
    v.weaponState = ps.weaponstate;
    v.bobCycle = ps.bobCycle;
    v.viewHeight = ps.viewHeightCurrent;
    v.ads = ps.fWeaponPosFrac;
    for (int i = 0; i < 3; ++i)
    {
        v.velocity[i] = std::max(-32767, std::min(32767, int(ps.velocity[i] * 4)));
        v.ladder[i] = std::max(-32767, std::min(32767, int(ps.vLadderVec[i] * 32767)));
    }
    v.sprintElapsed = demoU16(ps.commandTime - ps.sprintState.lastSprintStart);
    v.mantleTimer = demoU16(ps.mantleState.timer);
    v.mantleYaw = uint16_t(int(ps.mantleState.yaw * 65536.0f / 360.0f));
    v.mantleTransition = ps.mantleState.transIndex;
    v.mantleFlags = ps.mantleState.flags;
    // Only new engine events since the preceding recorded frame. The ring and
    // sequence wrap at 4 and 256 respectively. Never replay fall damage.
    int count = std::min(4, (ps.eventSequence - previousEventSequence) & 255);
    for (int i = count; i > 0; --i)
    {
        int slot = (ps.eventSequence - i) & 3;
        int event = ps.events[slot];
        int impact = ps.eventParms[slot];
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
            v.landingEvent = event;
            v.landingImpact = std::min(24, impact);
        }
    }
    // WEAPON_FIRING is 5. Do not retain ordinary gun/pistol firing animations.
    if (!rpg && ps.weaponstate == 5)
    {
        v.weaponState = 0;
        v.weaponTime = 0;
        v.weaponDelay = 0;
        v.animation = 0;
    }
    return v;
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
    bool valid;
    bool fallback;
    sDemoFrame_t frame;
    CJ_DemoSection section;
    unsigned long long sectionGeneration;
    int sectionSize;
};
static DemoTechniqueState demoTechnique[MAX_CLIENTS];
static sDemoFrame_t &techniqueFrame(int client, const sDemo_t &demo, int index)
{
    DemoTechniqueState &state = demoTechnique[client];
    if (state.valid && state.generation == demo.generation && state.index == index)
    {
        return state.frame;
    }
    state.frame = demo.pDemoFrames[index];
    state.generation = demo.generation;
    state.index = index;
    state.valid = true;
    state.fallback = false;
    if (!state.mode)
    {
        return state.frame;
    }
    auto read = [&](int i) {
        const sDemoFrame_t &f = demo.pDemoFrames[i];
        bool excluded = (f.flags & (128 | 256)) != 0;
        return CJ_DemoInput{int(bool(f.flags & 4)) - int(bool(f.flags & 8)),
                            int(bool(f.flags & 2)) - int(bool(f.flags & 1)),
                            bool(f.flags & 8192),
                            f.loadNow,
                            excluded,
                            f.rpgNow};
    };
    if (state.sectionGeneration != demo.generation || state.sectionSize != demo.size ||
        index < state.section.beginFrame || index >= state.section.endFrame)
    {
        state.section = CJ_AnalyzeDemoTechnique(demo.size, index, read);
        state.sectionGeneration = demo.generation;
        state.sectionSize = demo.size;
    }
    CJ_DemoTechnique result = CJ_ApplyDemoTechnique(index, state.mode, read(index), state.section);
    state.fallback = result.fallback;
    state.frame.flags = (state.frame.flags & ~15) |
                        (result.forward > 0   ? 4
                         : result.forward < 0 ? 8
                                              : 0) |
                        (result.right > 0   ? 2
                         : result.right < 0 ? 1
                                            : 0);
    auto camera = [&](int i) {
        const CJ_DemoInput input = read(i);
        const bool outside = i < state.section.beginFrame || i >= state.section.endFrame;
        CJ_DemoTechnique view = CJ_ApplyDemoTechnique(i, state.mode, input, state.section);
        // Shot aiming is a short camera-only flick, independent of the general
        // strafe smoothing and the converted keys.
        const bool locked = outside || input.ground || input.excluded || view.fallback;
        return CJ_DemoCameraSample{demo.pDemoFrames[i].angles[1], locked ? 0 : view.yawOffset,
                                   input.cut, locked, input.shot};
    };
    state.frame.angles[1] = std::remainder(CJ_SmoothDemoYaw(demo.size, index, camera), 360.0f);
    return state.frame;
}

void Gsc_Demo_SetTechnique(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    int mode;
    if (!stackGetParams("i", &mode) || mode < 0 || mode > 3) {
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
    const sDemoPlayback_t &play = opencj_playback[client];
    if (!hasSelectedDemoFrame(play)) {
        stackPushBool(false);
        return;
    }
    techniqueFrame(client, *play.pDemo, play.selectedFrame);
    stackPushBool(demoTechnique[client].fallback);
}


void Gsc_Demo_TechniquePhase(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    const sDemoPlayback_t &play = opencj_playback[client];
    if (!hasSelectedDemoFrame(play)) {
        stackPushInt(0);
        return;
    }
    techniqueFrame(client, *play.pDemo, play.selectedFrame);
    const auto &state = demoTechnique[client];
    const auto &section = state.section;
    if (!state.mode || state.fallback || !section.style) {
        stackPushInt(0);
        return;
    }
    int mode = state.mode;
    if ((mode == 2 || mode == 3) && play.selectedFrame < section.takeoffEndFrame) {
        mode = 1;
    }
    stackPushInt((mode << 4) | (section.anchorForward > 0 ? 4 : 8) |
                 (section.anchorRight > 0 ? 2 : 1));
}

void Gsc_Demo_ReadFrame_Checkpoint(int client)
{
    if (rejectInvalidDemoClient(client)) {
        return;
    }
    const sDemoPlayback_t &play = opencj_playback[client];
    if (!hasSelectedDemoFrame(play)) {
        stackPushUndefined();
        return;
    }
    stackPushInt(play.pDemo->pDemoFrames[play.selectedFrame].checkpointId);
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

static sDemo_t *createDemo(int demoId, int capacity = 1024)
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
    if (!pDemoId) return false;

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
    if (!Base_Gsc_GetValidDemoId(&demoId, 1)) return;

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
    if (!Base_Gsc_GetValidDemoId(&demoId, 1)) return;

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
    if (!Base_Gsc_GetValidDemoId(&demoId, 1)) return;

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
    if (!Base_Gsc_GetValidDemoId(&demoId, 1)) return;

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
        const playerState_t &ps = *SV_GameClientNum(client);
        bool continuous = pDemo->size && ps.commandTime >= pDemo->captureTime &&
                          ps.commandTime - pDemo->captureTime <= 100;
        if (continuous && (ps.eFlags & 2) != pDemo->captureTeleportBit)
        {
            frame.loadNow = true;
        }
        frame.visual = captureDemoVisual(ps, (flags & 4096) != 0,
                                         continuous && !frame.loadNow ? pDemo->captureEventSequence
                                                                      : ps.eventSequence);
        capturedPlayer = &ps;
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
            pDemo->captureTeleportBit = capturedPlayer->eFlags & 2;
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
    if (!Base_Gsc_GetValidDemoId(&demoId, 1)) return;

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
static void putDemoInt(unsigned char *p, uint32_t n, int bytes)
{
    for (int i = 0; i < bytes; ++i)
    {
        p[i] = (n >> (8 * i)) & 255;
    }
}

static uint32_t getDemoInt(const unsigned char *p, int bytes)
{
    uint32_t n = 0;
    for (int i = 0; i < bytes; ++i)
    {
        n |= uint32_t(p[i]) << (8 * i);
    }
    return n;
}

static const int demoChunkFrames = 64;
static const int demoWireFrameSize = 27;
static const int demoVisualWireSize = 31;
static const int demoChunkBufferSize = 8192;

static bool encodeDemoChunk(sDemo_t *demo, int first, int count, std::string &output)
{
    if (!demo || first < 0 || count < 1 || count > demoChunkFrames || first > demo->size - count)
    {
        return false;
    }
    unsigned char raw[demoChunkBufferSize] = {'O', 'C', 'J', '5'};
    size_t used = 8;
    uint16_t previousWeapon = 0;
    bool haveWeapon = false;
    putDemoInt(raw + 4, count, 4);
    for (int i = 0; i < count; ++i)
    {
        const sDemoFrame_t &frame = demo->pDemoFrames[first + i];
        unsigned char *p = raw + used;
        used += demoWireFrameSize;
        for (int axis = 0; axis < 3; ++axis)
        {
            uint32_t bits;
            memcpy(&bits, &frame.origin[axis], 4);
            putDemoInt(p + axis * 4, bits, 4);
            putDemoInt(p + 12 + axis * 2, uint16_t(int(frame.angles[axis] * 65536.0f / 360.0f)), 2);
        }
        putDemoInt(p + 18, uint16_t(frame.flags), 2);
        putDemoInt(p + 20, uint16_t(frame.fps), 2);
        putDemoInt(p + 22, frame.checkpointId, 4);
        p[26] = (frame.saveNow ? 1 : 0) | (frame.loadNow ? 2 : 0) | (frame.rpgNow ? 4 : 0) |
                (frame.isKeyFrame ? 0 : 32) | (frame.eleKnown ? 64 : 0) | (frame.eleUsed ? 128 : 0);
#ifdef COD4
        if (frame.visual.valid)
        {
            p[26] |= 8;
            const DemoVisual &v = frame.visual;
            unsigned char *q = raw + used;
            used += demoVisualWireSize;
            putDemoInt(q, v.weaponTime, 2);
            putDemoInt(q + 2, v.weaponDelay, 2);
            putDemoInt(q + 4, v.animation, 2);
            q[6] = v.weaponState;
            q[7] = v.bobCycle;
            putDemoInt(q + 8, int(v.viewHeight * 256), 2);
            q[10] = std::max(0, std::min(255, int(std::lround(v.ads * 255))));
            for (int a = 0; a < 3; ++a)
            {
                putDemoInt(q + 11 + a * 2, uint16_t(v.velocity[a]), 2);
                putDemoInt(q + 17 + a * 2, uint16_t(v.ladder[a]), 2);
            }
            putDemoInt(q + 23, v.sprintElapsed, 2);
            putDemoInt(q + 25, v.mantleTimer, 2);
            putDemoInt(q + 27, v.mantleYaw, 2);
            q[29] = v.mantleTransition;
            q[30] = v.mantleFlags;
            const char *name =
                (!haveWeapon || previousWeapon != v.weapon) ? demoWeaponName(v.weapon) : "";
            size_t length = strlen(name);
            if (length > 63 || used + 1 + length > sizeof(raw))
            {
                return false;
            }
            raw[used++] = length;
            memcpy(raw + used, name, length);
            used += length;
            previousWeapon = v.weapon;
            haveWeapon = true;
            if (v.landingEvent)
            {
                p[26] |= 16;
                raw[used++] = v.landingEvent;
                raw[used++] = v.landingImpact;
            }
        }
#endif
    }
    unsigned char packed[demoChunkBufferSize];
    uLongf size = sizeof(packed);
    if (compress2(packed, &size, raw, used, 6) != Z_OK)
    {
        return false;
    }
    output.assign(reinterpret_cast<const char *>(packed), size);
    return true;
}

static std::string demoHex(const std::string &packed) {
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

static int decodeDemoChunk(sDemo_t *demo, const unsigned char *packed, size_t length)
{
    if (!demo || demo->isComplete || !length || length > demoChunkBufferSize)
    {
        return 0;
    }
    unsigned char raw[demoChunkBufferSize];
    uLongf size = sizeof(raw);
    if (uncompress(raw, &size, packed, length) != Z_OK || size < 8 ||
        (memcmp(raw, "OCJ1", 4) && memcmp(raw, "OCJ2", 4) && memcmp(raw, "OCJ3", 4) &&
         memcmp(raw, "OCJ4", 4) && memcmp(raw, "OCJ5", 4)))
    {
        return 0;
    }
    uint32_t count = getDemoInt(raw + 4, 4);
    bool modern = raw[3] != '1';
    size_t used = 8;
    uint16_t weapon = 0;
    bool haveWeapon = false;
    if (!count || count > demoChunkFrames || (!modern && size != 8 + count * demoWireFrameSize))
    {
        return 0;
    }
    sDemoFrame_t frames[demoChunkFrames] = {};
    for (uint32_t i = 0; i < count; ++i)
    {
        if (used + demoWireFrameSize > size)
        {
            return 0;
        }
        unsigned char *p = raw + used;
        used += demoWireFrameSize;
        sDemoFrame_t &frame = frames[i];
        for (int axis = 0; axis < 3; ++axis)
        {
            uint32_t bits = getDemoInt(p + axis * 4, 4);
            memcpy(&frame.origin[axis], &bits, 4);
            if (!std::isfinite(frame.origin[axis]) || fabs(frame.origin[axis]) > 131072)
            {
                return 0;
            }
            frame.angles[axis] = getDemoInt(p + 12 + axis * 2, 2) * 360.0f / 65536.0f;
        }
        frame.flags = getDemoInt(p + 18, 2);
        frame.fps = getDemoInt(p + 20, 2);
        frame.checkpointId = getDemoInt(p + 22, 4);
        frame.saveNow = p[26] & 1;
        frame.loadNow = p[26] & 2;
        frame.rpgNow = p[26] & 4;
        frame.isKeyFrame = raw[3] < '4' || !(p[26] & 32);
        frame.eleKnown = raw[3] >= '5' && (p[26] & 64);
        frame.eleUsed = frame.eleKnown && (p[26] & 128);
        if (modern && (p[26] & 8))
        {
            if (used + demoVisualWireSize + 1 > size)
            {
                return 0;
            }
            unsigned char *q = raw + used;
            used += demoVisualWireSize;
            DemoVisual &v = frame.visual;
            v.valid = true;
            v.weaponTime = getDemoInt(q, 2);
            v.weaponDelay = getDemoInt(q + 2, 2);
            v.animation = getDemoInt(q + 4, 2);
            v.weaponState = q[6];
            v.bobCycle = q[7];
            v.viewHeight = int16_t(getDemoInt(q + 8, 2)) / 256.0f;
            v.ads = q[10] / 255.0f;
            for (int a = 0; a < 3; ++a)
            {
                v.velocity[a] = getDemoInt(q + 11 + a * 2, 2);
                v.ladder[a] = getDemoInt(q + 17 + a * 2, 2);
            }
            v.sprintElapsed = getDemoInt(q + 23, 2);
            v.mantleTimer = getDemoInt(q + 25, 2);
            v.mantleYaw = getDemoInt(q + 27, 2);
            v.mantleTransition = q[29];
            v.mantleFlags = q[30];
            unsigned length = raw[used++];
            if (length > 63 || used + length > size || (!length && !haveWeapon) ||
                v.viewHeight < 0 || v.viewHeight > 100 || v.weaponState > 32)
            {
                return 0;
            }
#ifdef COD4
            if (length)
            {
                char name[64];
                memcpy(name, raw + used, length);
                name[length] = 0;
                if (strlen(name) != length)
                {
                    return 0;
                }
                weapon = !strcmp(name, "none") ? 0 : G_GetWeaponIndexForName(name);
                haveWeapon = true;
            }
#endif
            used += length;
            v.weapon = weapon;
            if (raw[3] >= '3' && (p[26] & 16))
            {
                if (used + 2 > size)
                {
                    return 0;
                }
                v.landingEvent = raw[used++];
                v.landingImpact = raw[used++];
                if (v.landingEvent < 77 || v.landingEvent > 105 || !v.landingImpact ||
                    v.landingImpact > 24)
                {
                    return 0;
                }
            }
        }
    }
    if (used != size)
    {
        return 0;
    }
    if (!reserveDemoFrames(demo, size_t(demo->size) + count))
    {
        return 0;
    }
    for (uint32_t i = 0; i < count; ++i)
    {
        if (!appendDemoFrame(demo, frames[i]))
        {
            return 0;
        }
    }
    return count;
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
    if (!length || length > demoChunkBufferSize * 2 || length % 2) {
        stackPushUndefined();
        return;
    }
    unsigned char packed[demoChunkBufferSize];
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
    stackPushInt(demo->size);
}

// Idle means grounded with an unchanged position AND view. Do not remove
// aiming, stance changes, reloads, RPG shots, or transitions across a load.
static bool demoIdleTogether(const sDemoFrame_t &a, const sDemoFrame_t &b)
{
    if (!(a.flags & 8192) || a.flags != b.flags || (a.flags & 511) ||
        a.checkpointId != b.checkpointId || a.loadNow || b.loadNow || a.saveNow || b.saveNow ||
        a.rpgNow || b.rpgNow)
    {
        return false;
    }
    for (int axis = 0; axis < 3; ++axis)
    {
        if (fabs(a.origin[axis] - b.origin[axis]) > 0.01f ||
            fabs(std::remainder(a.angles[axis] - b.angles[axis], 360.0f)) > 0.01f)
        {
            return false;
        }
    }
    const auto &x = a.visual;
    const auto &y = b.visual;
    if (x.valid != y.valid)
    {
        return false;
    }
    if (x.valid &&
        (x.weapon != y.weapon || x.weaponState || y.weaponState || x.weaponTime || y.weaponTime ||
         x.weaponDelay || y.weaponDelay || x.landingEvent || y.landingEvent ||
         fabs(x.ads - y.ads) > 0.001f || fabs(x.viewHeight - y.viewHeight) > 0.01f))
    {
        return false;
    }
    return true;
}

// 0: complete speedrun/leaderboard; 1: successful low-RPG path;
// 2: successful walkthrough. Preserve positioning and shorten only true idle pauses.
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
    if (!demo || style < 0 || style > 2 || begin < 0 || end >= demo->size || begin > end)
    {
        stackPushUndefined();
        return;
    }
    auto &timeline = demoPlaybackTimeline[client];
    std::vector<int>().swap(timeline);
    if (style == 0)
    {
        opencj_playback[client].selectedFrame = begin;
        stackMakeArray();
        stackPushInt(begin);
        stackPushArrayNext();
        stackPushInt(end);
        stackPushArrayNext();
        return;
    }
    for (int i = 0; i < demo->size; ++i)
    {
        if (style == 0 || demo->pDemoFrames[i].isKeyFrame)
        {
            timeline.push_back(i);
        }
    }
    if (style == 2)
    {
        // 20 Hz capture: shorten pauses of at least a second to 0.2 seconds.
        // Keep both ends so movement starts/ends at its original recorded pose.
        size_t write = 0;
        for (size_t first = 0; first < timeline.size();)
        {
            size_t last = first + 1;
            while (last < timeline.size() && timeline[last] == timeline[last - 1] + 1 &&
                   timeline[last] != begin && timeline[last - 1] != end &&
                   demoIdleTogether(demo->pDemoFrames[timeline[first]],
                                    demo->pDemoFrames[timeline[last]]))
            {
                ++last;
            }
            for (size_t i = first; i < last; ++i)
            {
                if (last - first < 20 || i < first + 2 || i >= last - 2)
                {
                    timeline[write++] = timeline[i];
                }
            }
            first = last;
        }
        timeline.resize(write);
    }
    auto a = std::lower_bound(timeline.begin(), timeline.end(), begin);
    auto b = std::upper_bound(timeline.begin(), timeline.end(), end);
    if (a == b)
    {
        stackPushUndefined();
        return;
    }
    opencj_playback[client].selectedFrame = *a;
    stackMakeArray();
    stackPushInt(*a);
    stackPushArrayNext();
    stackPushInt(*(b - 1));
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
    const auto &timeline = demoPlaybackTimeline[client];
    int frame = opencj_playback[client].selectedFrame;
    if (timeline.empty()) {
        const sDemo_t *demo = opencj_playback[client].pDemo;
        if (!demo || begin < 0 || end < begin || end >= demo->size) {
            stackPushUndefined();
            return;
        }
        stackMakeArray();
        stackPushInt(std::max(0, std::min(end, frame) - begin));
        stackPushArrayNext();
        stackPushInt(end - begin);
        stackPushArrayNext();
        return;
    }
    auto a = std::lower_bound(timeline.begin(), timeline.end(), begin);
    auto b = std::upper_bound(timeline.begin(), timeline.end(), end);
    auto c = std::lower_bound(a, b, frame);
    stackMakeArray();
    stackPushInt(int(c - a));
    stackPushArrayNext();
    stackPushInt(std::max(0, int(b - a) - 1));
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
        sDemoFrame_t &f = demo->pDemoFrames[i];
        f.isKeyFrame = true;
        f.prevKeyFrame = i ? i - 1 : 0;
        f.nextKeyFrame = i + 1 < count ? i + 1 : i;
        demo->lastKeyFrame = i;
    }
    stackPushInt(count);
}

void Gsc_Demo_FindSegment()
{
    int id;
    int cp;
    int any;
    vec3_t origin;
    int args = Scr_GetNumParam();
    if (args != 4 && args != 5 && args != 6)
    {
        stackPushUndefined();
        return;
    }
    if (!Base_Gsc_GetValidDemoId(&id, args))
    {
        return;
    }
    stackGetParamInt(1, &cp);
    stackGetParamVector(2, origin);
    stackGetParamInt(3, &any);
    sDemo_t *demo = findDemoById(id);
    if (!demo || demo->size < 2)
    {
        stackPushUndefined();
        return;
    }
    int skipFails = 0;
    int strict = 0;
    if (args > 4)
    {
        stackGetParamInt(4, &skipFails);
    }
    if (args > 5)
    {
        stackGetParamInt(5, &strict);
    }
    int first = -1;
    int last = -1;
    float nearest = 256.0f * 256.0f;
    if (!any)
    {
        for (int i = 0; i < demo->size; ++i)
        {
            if (skipFails && !demo->pDemoFrames[i].isKeyFrame)
            {
                continue;
            }
            if (demo->pDemoFrames[i].checkpointId == cp)
            {
                if (first < 0)
                {
                    first = i;
                }
                last = i;
            }
            else if (first >= 0)
            {
                last = i;
                // Show the landing for up to half a second, stopping before
                // another takeoff, load, or checkpoint transition.
                int destination = demo->pDemoFrames[i].checkpointId;
                int grounded = (demo->pDemoFrames[i].flags & 8192) ? 1 : 0;
                for (int j = i + 1; grounded > 0 && grounded < 10 && j < demo->size; ++j)
                {
                    const auto &f = demo->pDemoFrames[j];
                    if (!f.isKeyFrame && skipFails)
                    {
                        break;
                    }
                    if (f.loadNow || f.checkpointId != destination || !(f.flags & 8192))
                    {
                        break;
                    }
                    last = j;
                    ++grounded;
                }
                break;
            }
        }
        // Compare the viewer with the recorded setup across this checkpoint,
        // not just its arrival frame (large platforms can span hundreds of units).
        // Airborne travel toward the next platform is not a matching setup.
        if (first >= 0)
        {
            bool nearby = false;
            bool hasGround = false;
            for (int i = first; i <= last; ++i)
            {
                if (demo->pDemoFrames[i].checkpointId == cp &&
                    (!skipFails || demo->pDemoFrames[i].isKeyFrame) &&
                    (demo->pDemoFrames[i].flags & 8192))
                {
                    hasGround = true;
                }
            }
            for (int i = first; i <= last; ++i)
            {
                const auto &f = demo->pDemoFrames[i];
                if (f.checkpointId != cp || (skipFails && !f.isKeyFrame) ||
                    (hasGround && !(f.flags & 8192)))
                {
                    continue;
                }
                float d = 0;
                for (int a = 0; a < 3; ++a)
                {
                    float x = f.origin[a] - origin[a];
                    d += x * x;
                }
                if (d <= nearest)
                {
                    nearby = true;
                    break;
                }
            }
            if (!nearby)
            {
                first = -1;
            }
        }
    }
    else
    {
        int begin = 0;
        int grounded = 0;
        bool airborne = false;
        float distance = nearest;
        for (int i = 0; i < demo->size; ++i)
        {
            const sDemoFrame_t &f = demo->pDemoFrames[i];
            if (skipFails && !f.isKeyFrame)
            {
                continue;
            }
            float d = 0;
            for (int a = 0; a < 3; ++a)
            {
                float x = f.origin[a] - origin[a];
                d += x * x;
            }
            if (d < distance)
            {
                distance = d;
            }
            if (f.flags & 8192)
            {
                ++grounded;
            }
            else
            {
                grounded = 0;
                airborne = true;
            }
            if ((airborne && grounded >= 10) || i == demo->size - 1)
            {
                if (distance < nearest)
                {
                    first = begin;
                    last = i;
                    nearest = distance;
                }
                begin = i;
                grounded = 0;
                airborne = false;
                distance = 256.0f * 256.0f;
            }
        }
        // Older explicit callers retain their whole-route fallback. Automatic
        // location selection must reject a recording with no nearby passage.
        if (first < 0 && !strict)
        {
            first = 0;
            last = demo->size - 1;
        }
    }
    if (first < 0 || last <= first)
    {
        stackPushUndefined();
        return;
    }
    // Keep the original range fields; append local RPG usage and successful
    // sample count so shared-route choices compare this jump, not whole runs.
    int shots = 0;
    int frames = 0;
    for (int i = first; i <= last; ++i)
    {
        const auto &f = demo->pDemoFrames[i];
        if (skipFails && !f.isKeyFrame)
        {
            continue;
        }
        ++frames;
        if (f.rpgNow)
        {
            ++shots;
        }
    }
    stackMakeArray();
    stackPushInt(first);
    stackPushArrayNext();
    stackPushInt(last);
    stackPushArrayNext();
    stackPushInt(shots);
    stackPushArrayNext();
    stackPushInt(frames);
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
    playerState_t &ps = *SV_GameClientNum(client);
    ps.legsAnim = body.legs;
    ps.torsoAnim = body.torso;
    ps.legsTimer = 0;
    ps.torsoTimer = 0;
    ps.legsAnimDuration = body.legsDuration;
    ps.torsoAnimDuration = body.torsoDuration;
    ps.movementDir = body.direction;
    g_entities[client].s.legsAnim = body.legs;
    g_entities[client].s.torsoAnim = body.torso;
    g_entities[client].s.lerp.u.player.movementDir = body.direction;
#endif
}

#ifdef COD4
static void applyDemoBodyEvent(DemoBody &body, playerState_t &pose, int event, int frame,
                               int elapsed)
{
    if (body.event != event || body.eventFrame != frame || body.eventWeapon != int(pose.weapon))
    {
        playerState_t transition = pose;
        int duration = BG_AnimScriptEvent(&transition, event, 0, 1);
        // Some stock weapon sets omit direct stand/prone transitions.
        // Their crouch/prone transition still supplies the raising/lowering motion.
        if (duration <= 0 && (event == 15 || event == 16))
        {
            duration = BG_AnimScriptEvent(&transition, event == 15 ? 11 : 12, 0, 1);
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

static void applyDemoBody(int client, const sDemo_t &demo, int index)
{
    const sDemoFrame_t &frame = techniqueFrame(client, demo, index);
    playerState_t &ps = *SV_GameClientNum(client);
    DemoBody &body = demoPresentedBody[client];
    // Older demos never stored body animation indices. Select stock locomotion
    // from recorded motion, stance and keys, independently of the frozen viewer.
    // Retain the animation toggle bits across ticks so loops do not restart.
    playerState_t pose = ps;
    pose.clientNum = client;
    pose.pm_type = 0;
    pose.legsAnim = body.legs;
    pose.torsoAnim = body.torso;
    pose.legsTimer = 0;
    pose.torsoTimer = 0;
    pose.legsAnimDuration = body.legsDuration;
    pose.torsoAnimDuration = body.torsoDuration;
    pose.pm_flags = (frame.flags & 2048) ? 1 : (frame.flags & 1024) ? 2 : 0;
    if (frame.flags & 256)
    {
        pose.pm_flags |= 8;
    }
    pose.eFlags &= ~0x300; // Never inherit the viewer's mounted-weapon state.
    float vx = 0;
    float vy = 0;
    float vz = 0;
    if (frame.visual.valid)
    {
        vx = frame.visual.velocity[0] / 4.0f;
        vy = frame.visual.velocity[1] / 4.0f;
        vz = frame.visual.velocity[2] / 4.0f;
    }
    else if (index > 0 && !frame.loadNow)
    {
        const sDemoFrame_t &before = demo.pDemoFrames[index - 1];
        float dx = frame.origin[0] - before.origin[0];
        float dy = frame.origin[1] - before.origin[1];
        if (dx * dx + dy * dy < 256 * 256)
        {
            vx = dx * 20;
            vy = dy * 20;
            vz = (frame.origin[2] - before.origin[2]) * 20;
        }
    }
    const float speed = std::sqrt(vx * vx + vy * vy);
    const int forward = ((frame.flags & 4) ? 1 : 0) - ((frame.flags & 8) ? 1 : 0);
    const int right = ((frame.flags & 2) ? 1 : 0) - ((frame.flags & 1) ? 1 : 0);
    const bool backward = forward < 0;
    const bool grounded = frame.flags & 8192;
    const bool moving = speed > 5 && (forward || right);
    const bool crouch = frame.flags & 1024;
    const bool prone = frame.flags & 2048;
    // Values are the stock animMoveTypesStr order in _bg_animation_mp.asm.
    int movement = prone ? 3 : crouch ? 2 : 1; // idle, idlecr, idleprone
    if (frame.flags & 256)
    {
        movement = vz < 0 ? 19 : 18; // climb down/up
    }
    else if (frame.flags & 128)
    {
        movement = 21; // mantle root
    }
    else if (moving)
    {
        bool walk = speed < std::max(1, ps.speed) * 0.6f || frame.visual.ads > 0;
        movement = prone ? 8 : crouch ? (walk ? 6 : 12) : (walk ? 4 : 10);
        if (backward)
        {
            ++movement;
        }
        if (!prone && !crouch && (frame.flags & 64))
        {
            movement = 20;
        }
    }
    pmove_t pm = {};
    pm.ps = &pose;
    bgs_s *previousBgs = bgs;
    bgs = &level_bgs;
    BG_AnimUpdatePlayerStateConditions(&pm);
    BG_SetConditionValue(client, 8, forward == 0 ? (right < 0 ? 1 : right > 0 ? 2 : 0) : 0);
    BG_AnimScriptAnimation(&pose, 0, movement, 0);
    if (!grounded && !(frame.flags & (128 | 256)))
    {
        applyDemoBodyEvent(body, pose, backward ? 4 : 3, -1,
                           0); // Pose only; no jump/physics event.
    }
    else if (grounded && !(frame.flags & (128 | 256)))
    {
        // Reconstruct short landing/stance transitions by source-frame time,
        // including when seeking or reversing. Never carry one across a load.
        for (int i = index; i > 0 && index - i < 80; --i)
        {
            const auto &now = demo.pDemoFrames[i];
            const auto &before = demo.pDemoFrames[i - 1];
            if (now.loadNow)
            {
                break;
            }
            int event = -1;
            if ((now.flags & 8192) && !(before.flags & (8192 | 128 | 256)))
            {
                event = 5; // land
            }
            int stance = now.flags & (1024 | 2048);
            int oldStance = before.flags & (1024 | 2048);
            if (stance != oldStance)
            {
                if (stance == 2048)
                {
                    event = oldStance == 1024 ? 11 : 15;
                }
                else if (oldStance == 2048)
                {
                    event = stance == 1024 ? 12 : 16;
                }
                else
                {
                    event = stance == 1024 ? 13 : 14;
                }
            }
            if (event >= 0)
            {
                applyDemoBodyEvent(body, pose, event, i, (index - i) * 50);
                break;
            }
        }
    }
    bgs = previousBgs;
    // Temporary locomotion selection before a jump/landing must not flip the
    // restart bit on every tick. Only a real final-animation change toggles it.
    int legs = pose.legsAnim & 511;
    int torso = pose.torsoAnim & 511;
    body.legs = legs == (body.legs & 511) ? body.legs : legs | ((body.legs ^ 512) & 512);
    body.torso = torso == (body.torso & 511) ? body.torso : torso | ((body.torso ^ 512) & 512);
    body.valid = true;
    body.legsDuration = pose.legsAnimDuration;
    body.torsoDuration = pose.torsoAnimDuration;
    float direction = 0;
    if (grounded && moving)
    {
        direction = std::remainder(std::atan2(vy, vx) * 180.0f / 3.14159265f - frame.angles[1] +
                                       (backward ? 180 : 0),
                                   360.0f);
    }
    body.direction = std::max(-90, std::min(90, int(direction)));
    // Publish now and reapply at the player-to-entity copy after linked Pmove.
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
    delete demoReturnVisual[client];
    demoReturnVisual[client] = new (std::nothrow) playerState_t(*SV_GameClientNum(client));
    demoPresentedWeapon[client] = -1;
    demoPresentedFrame[client] = -1;
    demoPresentedBody[client] = {};
    demoReturnFrozen[client] = g_entities[client].client->bFrozen;
    stackPushBool(demoReturnVisual[client] != nullptr);
#else
    stackPushBool(false);
#endif
}

void Gsc_Demo_ApplyPresentation(int client)
{
#ifdef COD4
    if (rejectInvalidDemoClient(client))
    {
        return;
    }
    sDemoPlayback_t &play = opencj_playback[client];
    if (!demoReturnVisual[client] || !hasSelectedDemoFrame(play))
    {
        stackPushBool(false);
        return;
    }
    const sDemoFrame_t &frame = play.pDemo->pDemoFrames[play.selectedFrame];
    const DemoVisual &v = frame.visual;
    if (!v.valid)
    {
        applyDemoBody(client, *play.pDemo, play.selectedFrame);
        stackPushBool(false);
        return;
    }
    playerState_t &ps = *SV_GameClientNum(client);
    if (v.weapon >= 128)
    {
        stackPushBool(false);
        return;
    }
    if (demoPresentedFrame[client] != play.selectedFrame)
    {
        bool cut = frame.loadNow || (demoPresentedFrame[client] >= 0 &&
                                     std::abs(play.selectedFrame - demoPresentedFrame[client]) > 4);
        int previous = demoPresentedFrame[client];
        if (previous >= 0 && previous < play.pDemo->size)
        {
            const sDemoFrame_t &before = play.pDemo->pDemoFrames[previous];
            float distance = 0;
            float speed = 0;
            for (int i = 0; i < 3; ++i)
            {
                float delta = frame.origin[i] - before.origin[i];
                distance += delta * delta;
                float velocity = v.velocity[i] / 4.0f;
                speed += velocity * velocity;
            }
            // Older recordings lack teleport markers. Do not blend map portals
            // across the map; allow for genuine high-speed movement.
            cut |= distance > std::max(256.0f * 256.0f, speed * 0.01f);
        }
        if (cut)
        {
            ps.eFlags ^= 2; // EF_TELEPORT_BIT: discard interpolation across a cut.
        }
        demoPresentedFrame[client] = play.selectedFrame;
    }
    // Match the existing seamless-switch protocol so client prediction does not
    // keep re-equipping the viewer's own weapon. Restore inventory on exit.
    if (v.weapon)
    {
        ps.weapons[v.weapon / 32] |= 1u << (v.weapon % 32);
    }
    if (demoPresentedWeapon[client] != v.weapon)
    {
        SV_GameSendServerCommand(client, 1, va("a %u", unsigned(v.weapon)));
        demoPresentedWeapon[client] = v.weapon;
    }
    // disableWeapons makes PM_Weapon lower the weapon to "none". Freeze
    // live input instead, and drive the animation directly from the recording.
    // Never feed recorded fire delays/states back into weapon simulation:
    // a delayed RPG shot could otherwise spawn a real missile.
    g_entities[client].client->bFrozen = qtrue;
    ps.pm_flags |= 0x800;
    // Use the client's spectator interpolation path. Local prediction would
    // zero velocity for frozen controls, suppressing recorded weapon bob/sway.
    ps.otherFlags |= 2;
    ps.weapFlags &= ~0x80;
    // Viewmodel rocket tags depend on clip ammo even when animation is driven
    // directly. Supply presentation ammo; the saved inventory is restored on exit.
    const WeaponDef *weapon = BG_GetWeaponDef(v.weapon);
    if (weapon)
    {
        if (weapon->iClipIndex >= 0 &&
            weapon->iClipIndex < int(sizeof(ps.ammoclip) / sizeof(ps.ammoclip[0])))
        {
            ps.ammoclip[weapon->iClipIndex] = 1;
        }
        if (weapon->iAmmoIndex >= 0 &&
            weapon->iAmmoIndex < int(sizeof(ps.ammo) / sizeof(ps.ammo[0])))
        {
            ps.ammo[weapon->iAmmoIndex] = 1;
        }
    }
    ps.weapon = v.weapon;
    ps.weaponTime = 1000;
    ps.weaponDelay = 0;
    ps.weapAnim = v.animation;
    ps.weaponstate = 0;
    ps.bobCycle = v.bobCycle;
    ps.viewHeightCurrent = v.viewHeight;
    ps.viewHeightTarget = int(v.viewHeight);
    ps.viewHeightLerpTime = 0;
    ps.fWeaponPosFrac = v.ads;
    if (!(frame.flags & 8192) && ps.groundEntityNum != ENTITYNUM_NONE)
    {
        ps.jumpTime = ps.commandTime;
        ps.jumpOriginZ = frame.origin[2];
    }
    ps.groundEntityNum = (frame.flags & 8192) ? ENTITYNUM_WORLD : ENTITYNUM_NONE;
    ps.pm_flags =
        (ps.pm_flags & ~12) | ((frame.flags & 128) ? 4 : 0) | ((frame.flags & 256) ? 8 : 0);
    for (int i = 0; i < 3; ++i)
    {
        ps.velocity[i] = v.velocity[i] / 4.0f;
        ps.vLadderVec[i] = v.ladder[i] / 32767.0f;
    }
    ps.sprintState.lastSprintStart = ps.commandTime - v.sprintElapsed;
    ps.sprintState.lastSprintEnd =
        (frame.flags & 64) ? ps.sprintState.lastSprintStart - 1 : ps.commandTime;
    ps.mantleState.timer = v.mantleTimer;
    ps.mantleState.yaw = v.mantleYaw * 360.0f / 65536;
    ps.mantleState.transIndex = v.mantleTransition;
    ps.mantleState.flags = v.mantleFlags;
    applyDemoBody(client, *play.pDemo, play.selectedFrame);
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
    const sDemoPlayback_t &play = opencj_playback[client];
    if (!play.pDemo)
    {
        stackPushUndefined();
        return;
    }
    const auto &timeline = demoPlaybackTimeline[client];
    const sDemoFrame_t *frames = play.pDemo->pDemoFrames;
    if (timeline.empty())
    {
        int current = play.selectedFrame;
        int target = current;
        if (direction > 0)
        {
            while (target + 1 < play.pDemo->size &&
                   frames[target + 1].checkpointId == frames[current].checkpointId)
            {
                ++target;
            }
            if (target + 1 < play.pDemo->size)
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
    int current = int(std::lower_bound(timeline.begin(), timeline.end(), play.selectedFrame) -
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
    const sDemoPlayback_t &play = opencj_playback[client];
    if (demoReturnVisual[client] && hasSelectedDemoFrame(play))
    {
        const sDemoFrame_t &frame = play.pDemo->pDemoFrames[play.selectedFrame];
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
    playerState_t &ps = *SV_GameClientNum(client);
    g_entities[client].client->bFrozen = demoReturnFrozen[client];
    ps.otherFlags = (ps.otherFlags & ~2) | (saved->otherFlags & 2);
    ps.pm_flags = (ps.pm_flags & ~0x800) | (saved->pm_flags & 0x800);
    ps.weapFlags = (ps.weapFlags & ~0x80) | (saved->weapFlags & 0x80);
    memcpy(ps.weapons, saved->weapons, sizeof(ps.weapons));
    memcpy(ps.weaponold, saved->weaponold, sizeof(ps.weaponold));
    memcpy(ps.weaponrechamber, saved->weaponrechamber, sizeof(ps.weaponrechamber));
    memcpy(ps.ammo, saved->ammo, sizeof(ps.ammo));
    memcpy(ps.ammoclip, saved->ammoclip, sizeof(ps.ammoclip));
    ps.weapon = saved->weapon;
    ps.weaponTime = saved->weaponTime;
    ps.weaponDelay = saved->weaponDelay;
    SV_GameSendServerCommand(client, 1, va("a %u", saved->weapon));
    ps.weapAnim = saved->weapAnim;
    ps.weaponstate = saved->weaponstate;
    ps.bobCycle = saved->bobCycle;
    ps.viewHeightCurrent = saved->viewHeightCurrent;
    ps.viewHeightTarget = saved->viewHeightTarget;
    ps.viewHeightLerpTime = saved->viewHeightLerpTime;
    ps.viewHeightLerpTarget = saved->viewHeightLerpTarget;
    ps.viewHeightLerpDown = saved->viewHeightLerpDown;
    ps.fWeaponPosFrac = saved->fWeaponPosFrac;
    ps.pm_flags = (ps.pm_flags & ~12) | (saved->pm_flags & 12);
    memcpy(ps.velocity, saved->velocity, sizeof(ps.velocity));
    memcpy(ps.vLadderVec, saved->vLadderVec, sizeof(ps.vLadderVec));
    int elapsed = ps.commandTime - saved->commandTime;
    ps.groundEntityNum = saved->groundEntityNum;
    ps.jumpTime = saved->jumpTime + elapsed;
    ps.jumpOriginZ = saved->jumpOriginZ;
    ps.sprintState = saved->sprintState;
    ps.sprintState.lastSprintStart += elapsed;
    ps.sprintState.lastSprintEnd += elapsed;
    ps.mantleState = saved->mantleState;
    ps.legsAnim = saved->legsAnim;
    ps.torsoAnim = saved->torsoAnim;
    ps.legsTimer = saved->legsTimer;
    ps.torsoTimer = saved->torsoTimer;
    ps.legsAnimDuration = saved->legsAnimDuration;
    ps.torsoAnimDuration = saved->torsoAnimDuration;
    ps.movementDir = saved->movementDir;
    g_entities[client].s.legsAnim = ps.legsAnim;
    g_entities[client].s.torsoAnim = ps.torsoAnim;
    g_entities[client].s.lerp.u.player.movementDir = ps.movementDir;
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
    const sDemoPlayback_t &play = opencj_playback[client];
    if (hasSelectedDemoFrame(play)) {
        const DemoVisual &v = play.pDemo->pDemoFrames[play.selectedFrame].visual;
        if (v.valid) {
            stackPushString(demoWeaponName(v.weapon));
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
    const sDemoPlayback_t &play = opencj_playback[client];
    if (hasSelectedDemoFrame(play))
    {
        const sDemoFrame_t &f = play.pDemo->pDemoFrames[play.selectedFrame];
        if (f.visual.valid && f.rpgNow && (f.flags & 4096))
        {
            const char *sound = demoFireSound(f.visual.weapon);
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

// [RPG shots, FPS category (-1=no airborne samples,0=125,1=mix,2=hax), elevation (-1=unknown,0=no,1=yes)]
void Gsc_Demo_RangeInfo()
{
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
    int shots = 0;
    int fps = -1;
    bool known = true;
    bool ele = false;
    for (int i = first; i <= last; ++i) {
        const sDemoFrame_t &f = demo->pDemoFrames[i];
        shots += f.rpgNow;
        known = known && f.eleKnown;
        ele = ele || f.eleUsed;
        if (!(f.flags & 8192)) {
            if (f.fps != 125 && f.fps != 250 && f.fps != 333) {
                fps = 2;
            } else if (f.fps != 125 && fps < 1) {
                fps = 1;
            } else if (fps < 0) {
                fps = 0;
            }
        }
    }
    stackMakeArray();
    stackPushInt(shots);
    stackPushArrayNext();
    stackPushInt(fps);
    stackPushArrayNext();
    stackPushInt(ele ? 1 : known ? 0 : -1);
    stackPushArrayNext();
}

void Gsc_Demo_KeepLast()
{
    int id;
    int count;
    if (!Base_Gsc_GetValidDemoId(&id, 2))
    {
        return;
    }
    stackGetParamInt(1, &count);
    sDemo_t *demo = findDemoById(id);
    if (!demo || demo->isComplete || count < 1 || count > 1200)
    {
        stackPushUndefined();
        return;
    }
    int removed = std::max(0, demo->size - count);
    if (removed)
    {
        memmove(demo->pDemoFrames, demo->pDemoFrames + removed, count * sizeof(sDemoFrame_t));
        demo->size = count;
        demo->currentFrame = count - 1;
        demo->lastKeyFrame = count - 1;
        // Manual clips preserve every take, so every frame stays playable.
        for (int i = 0; i < count; ++i)
        {
            auto &f = demo->pDemoFrames[i];
            f.isKeyFrame = true;
            f.prevKeyFrame = std::max(0, i - 1);
            f.nextKeyFrame = std::min(count - 1, i + 1);
        }
    }
    stackPushInt(removed);
}

void Gsc_Demo_ClipInfo()
{
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
    int cells[40] = {};
    const int cellCount = demo->size < 40 ? demo->size : 40;
    for (int i = index; i <= end; ++i) {
        const auto &frame = demo->pDemoFrames[i];
        const int event = frame.loadNow ? 2 : (frame.saveNow ? 1 : 0);
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
struct DemoSQLRead {
    int nativeId;
    int nextChunk;
    int error;
    unsigned long long generation;
    bool done;
    bool abandoned;
};
static std::map<int,DemoSQLRead> demoSQLReads;
long long OpenCJ_Demo_SQLClock() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
               std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

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
    char query[256];
    snprintf(
        query, sizeof(query),
        "SELECT chunkNum,payload FROM %s WHERE %s=%d AND chunkNum>=%d ORDER BY chunkNum LIMIT 32",
        clip ? "demoClipChunks" : "demoChunks", clip ? "clipID" : "runID", storedId, first);
    int id = sqlPoolSubmit(query, true, SQL_READ, "", "", 10000);
    if (id > 0) {
        demoSQLReads[id] = {nativeId, first, 0, demo->generation, false, false};
    }
    stackPushInt(id);
}

bool OpenCJ_Demo_SQLReady(int id, long long deadline) {
    auto it = demoSQLReads.find(id);
    if (it == demoSQLReads.end()) {
        return true;
    }
    DemoSQLRead &read = it->second;
    MYSQL_RES *result = nullptr;
    SqlCompletion c;
    if (!sqlPoolPeek(id, &result, &c)) {
        return false;
    }
    auto d = opencj_demoIdToIdx.find(read.nativeId);
    bool missing =
        d == opencj_demoIdToIdx.end() || opencj_demos[d->second].generation != read.generation;
    if (read.abandoned) {
        sqlPoolTake(id, &result, &c);
        if (result) {
            mysql_free_result(result);
        }
        demoSQLReads.erase(it);
        return false;
    }
    if (missing) {
        read.error = SQL_CANCELLED;
        read.done = true;
        return true;
    }
    if (read.done) {
        return true;
    }
    if (c.outcome != SQL_OK) {
        read.done = true;
        return true;
    }
    if (!result || mysql_num_fields(result) != 2 || !mysql_num_rows(result) ||
        mysql_num_rows(result) > 32) {
        read.error = SQL_INVALID;
        read.done = true;
        return true;
    }
    sDemo_t *demo = &opencj_demos[d->second];
    // Limit main-thread decode time, not the number of concurrent viewers.
    while (OpenCJ_Demo_SQLClock() < deadline) {
        MYSQL_ROW row = mysql_fetch_row(result);
        if (!row) {
            read.done = true;
            return true;
        }
        unsigned long *lengths = mysql_fetch_lengths(result);
        char *end = nullptr;
        long chunk = row[0] ? strtol(row[0], &end, 10) : -1;
        if (!row[0] || !end || *end || chunk != read.nextChunk || !row[1] || !lengths ||
            !decodeDemoChunk(demo, reinterpret_cast<unsigned char *>(row[1]), lengths[1])) {
            read.error = SQL_INVALID;
            read.done = true;
            return true;
        }
        ++read.nextChunk;
    }
    return false;
}

void OpenCJ_Demo_SQLStatus(int id, SqlCompletion *c) {
    auto it = demoSQLReads.find(id);
    if (it != demoSQLReads.end() && it->second.error) {
        c->outcome = it->second.error;
    }
}

bool OpenCJ_Demo_SQLTake(int id) {
    auto it = demoSQLReads.find(id);
    if (it == demoSQLReads.end()) {
        return false;
    }
    MYSQL_RES *result = nullptr;
    SqlCompletion c;
    if (!it->second.done || !sqlPoolTake(id, &result, &c)) {
        stackPushUndefined();
        return true;
    }
    if (result) {
        mysql_free_result(result);
    }
    if (c.outcome != SQL_OK || it->second.error) {
        stackPushUndefined();
    } else {
        stackMakeArray();
        stackMakeArray();
        stackPushInt(it->second.nextChunk);
        stackPushArrayNext();
        stackPushArrayNext();
    }
    demoSQLReads.erase(it);
    return true;
}

void OpenCJ_Demo_SQLNewMap() {
    // Old loaders have no remaining GSC waiter. Drain their native results as
    // they finish, without decoding into a reused demo ID on the next map.
    for (auto &entry : demoSQLReads) {
        entry.second.abandoned = true;
    }
}

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
    stackPushInt(sqlPoolSubmit(query.c_str(), false, SQL_BACKGROUND, key.c_str(), "", 30000));
}

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
    auto it = opencj_demoIdToIdx.find(id);
    if (it == opencj_demoIdToIdx.end()) {
        return;
    }
    sDemo_t *demo = &opencj_demos[it->second];
    if (demo->pins) {
        --demo->pins;
    }
    if (!demo->pins && demo->releasePending) {
        clearDemoById(id);
    }
}
