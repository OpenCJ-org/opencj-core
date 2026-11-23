// Isolated test plugin: inspect demo presentation, animation and visibility masks.
#include "../../cod4x-server/src/opencj_main.hpp"
#include "../../server-ext/opencj_demo.hpp"
#include "../../server-ext/opencj_visibility.hpp"
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <climits>
#include <cstring>

extern "C"
{
void Plugin_Printf(const char *format, ...);
client_t *Plugin_GetClientForClientNum(int clientNumber);
int Plugin_Cvar_VariableIntegerValue(const char *name);
}

static int checks;
static int failures;
constexpr int OwnerClient = 0;
constexpr int ObserverClient = 1;
constexpr int DemoBodyHideFlag = 0x20;
constexpr int AnimationIndexMask = 511;
// The stock table is stored as raw bytes in bgs_s: 96-byte records, name first.
constexpr int AnimationRecordBytes = 96;
constexpr int AnimationNameBytes = 64;

// These probe values are shared with camera.gsc; other stages check an ordinary frame.
enum AnimationStage
{
    CaptureOriginal = 0,
    CaptureRunning = 3,
    RepeatRunning = 4,
    LeftStrafe = 7,
    RightStrafe = 8,
    CaptureLanding = 30,
    RepeatLanding = 31,
    VerifyRestored = 99
};

static playerState_t originalState;
static bgs_s *originalAnimationContext;
static int runningLegs;
static int runningTorso;
static int landingLegs;
static int landingTorso;

static void check(bool condition, const char *message)
{
    ++checks;
    if(!condition)
    {
        ++failures;
    }
    Plugin_Printf("CAMERA NATIVE %d: %s\n", condition, message);
}

static bool hiddenFromViewer(const gentity_t &actor, int viewerNumber)
{
    constexpr int MaskWordBits = sizeof(actor.r.clientMask[0]) * CHAR_BIT;
    int wordIndex = viewerNumber / MaskWordBits;
    unsigned int viewerBit = 1u << (viewerNumber % MaskWordBits);
    return (actor.r.clientMask[wordIndex] & viewerBit) != 0;
}

static bool animationRestored(const playerState_t &state)
{
    bool animationsMatch =
        state.legsAnim == originalState.legsAnim && state.torsoAnim == originalState.torsoAnim;
    bool timersMatch =
        state.legsTimer == originalState.legsTimer && state.torsoTimer == originalState.torsoTimer;
    bool durationsMatch = state.legsAnimDuration == originalState.legsAnimDuration &&
                          state.torsoAnimDuration == originalState.torsoAnimDuration;
    bool directionMatches = state.movementDir == originalState.movementDir;
    return animationsMatch && timersMatch && durationsMatch && directionMatches;
}

// Compare the presented player/entity state with the original simulation state.
static void checkPresentedFrame(gentity_t &actor, int stage, const char *expectedAnimation)
{
    const playerState_t &state = actor.client->ps;
    int animationIndex = state.legsAnim & AnimationIndexMask;
    const char *record =
        reinterpret_cast<const char *>(level_bgs.animScriptData) +
        animationIndex * AnimationRecordBytes;
    char animationName[AnimationNameBytes + 1];
    std::memcpy(animationName, record, AnimationNameBytes);
    animationName[AnimationNameBytes] = '\0';

    Plugin_Printf("CAMERA BODY stage=%d legs=%d torso=%d direction=%d name=%s\n",
                  stage, state.legsAnim, state.torsoAnim, state.movementDir, animationName);
    check(animationIndex > 0 && std::strstr(animationName, expectedAnimation),
          "recorded movement selects matching body animation");
    check(actor.s.legsAnim == state.legsAnim && actor.s.torsoAnim == state.torsoAnim &&
          actor.s.lerp.u.player.movementDir == state.movementDir,
          "body animation published to entity");

    bool weaponIdle = state.weaponDelay == 0 && state.weaponstate == 0;
    bool originUnchanged = state.origin[0] == originalState.origin[0] &&
                           state.origin[1] == originalState.origin[1] &&
                           state.origin[2] == originalState.origin[2];
    check(weaponIdle && originUnchanged, "animation cannot move player or replay weapon simulation");
    check(bgs == originalAnimationContext, "animation restores engine context");
}

static void animationProbe()
{
    if(Plugin_Cvar_VariableIntegerValue("opencj_isolated_camera_test") != 1)
    {
        return;
    }
    client_t *owner = Plugin_GetClientForClientNum(OwnerClient);
    if(!owner || !owner->gentity || !owner->gentity->client)
    {
        check(false, "animation owner is available");
        return;
    }
    gentity_t &actor = *owner->gentity;
    playerState_t &state = actor.client->ps;
    int stage = Scr_GetInt(0);
    if(stage == CaptureOriginal)
    {
        originalState = state;
        originalAnimationContext = bgs;
        return;
    }
    if(stage == VerifyRestored)
    {
        check(animationRestored(state), "original body animation restored");
        return;
    }

    checkPresentedFrame(actor, stage, Scr_GetString(1));
    if(stage == CaptureRunning)
    {
        runningLegs = state.legsAnim;
        runningTorso = state.torsoAnim;
    }
    if(stage == RepeatRunning)
    {
        check(state.legsAnim == runningLegs && state.torsoAnim == runningTorso,
              "reapplying paused frame does not restart animation");
    }
    if(stage == CaptureLanding)
    {
        landingLegs = state.legsAnim;
        landingTorso = state.torsoAnim;
    }
    if(stage == RepeatLanding)
    {
        check(state.legsAnim == landingLegs && state.torsoAnim == landingTorso,
              "repeated landing does not restart animation");
    }
    if(stage == LeftStrafe)
    {
        check(state.movementDir == 90, "left strafe body orientation");
    }
    if(stage == RightStrafe)
    {
        check(state.movementDir == -90, "right strafe body orientation");
    }
}

// Temporarily vary only the observer's role, then restore its exact session state.
static void verifyPresentationVisibility(gentity_t &actor, gclient_t &observer)
{
    check(OpenCJ_Demo_IsPresentationActive(OwnerClient), "presentation active");
    check(!(actor.s.lerp.eFlags & DemoBodyHideFlag) && !hiddenFromViewer(actor, OwnerClient),
          "demo body visible to owner");

    auto originalSessionState = observer.sess.sessionState;
    int originallyFollowedClient = observer.ps.clientNum;
    observer.sess.sessionState = SESS_STATE_PLAYING;
    Gsc_Vis_UpdatePlayerVisibility();
    check(hiddenFromViewer(actor, ObserverClient), "ordinary player cannot see playback body");

    observer.sess.sessionState = SESS_STATE_SPECTATOR;
    observer.ps.clientNum = ObserverClient;
    Gsc_Vis_UpdatePlayerVisibility();
    check(hiddenFromViewer(actor, ObserverClient), "unrelated spectator cannot see playback body");

    observer.ps.clientNum = OwnerClient;
    Gsc_Vis_UpdatePlayerVisibility();
    check(!hiddenFromViewer(actor, ObserverClient), "following spectator can see playback body");

    observer.sess.sessionState = originalSessionState;
    observer.ps.clientNum = originallyFollowedClient;
    Gsc_Vis_UpdatePlayerVisibility();
}

extern "C" int OnInit()
{
    Scr_AddFunction("cameraAnimationProbe", animationProbe, qfalse);
    return 0;
}

extern "C" void OnInfoRequest(pluginInfo_t *info)
{
    std::memset(info, 0, sizeof(*info));
    info->handlerVersion.major = PLUGIN_HANDLER_VERSION_MAJOR;
    std::strcpy(info->fullName, "OpenCJ isolated camera verification");
    info->pluginVersion.major = 1;
}

extern "C" void OnFrame()
{
    if(Plugin_Cvar_VariableIntegerValue("opencj_isolated_camera_test") != 1)
    {
        return;
    }

    static int previousStage;
    int stage = Plugin_Cvar_VariableIntegerValue("opencj_camera_test_stage");
    if(stage == previousStage || stage == 0)
    {
        return;
    }
    previousStage = stage;
    client_t *owner = Plugin_GetClientForClientNum(OwnerClient);
    client_t *observer = Plugin_GetClientForClientNum(ObserverClient);
    if(!owner || !owner->gentity || !owner->gentity->client)
    {
        check(false, "test owner is available");
        return;
    }
    if(!observer || !observer->gentity || !observer->gentity->client)
    {
        check(false, "test observer is available");
        return;
    }

    constexpr int PresentationStage = 1;
    constexpr int RestoredStage = 2;
    gentity_t &actor = *owner->gentity;
    if(stage == PresentationStage)
    {
        verifyPresentationVisibility(actor, *observer->gentity->client);
    }
    else if(stage == RestoredStage)
    {
        check(!OpenCJ_Demo_IsPresentationActive(OwnerClient), "presentation lifetime ends");
        Gsc_Vis_UpdatePlayerVisibility();
        check(!hiddenFromViewer(actor, ObserverClient), "normal visibility restored after playback");
        check(!OpenCJ_Demo_IsPresentationActive(-1) && !OpenCJ_Demo_IsPresentationActive(MAX_CLIENTS),
              "invalid presentation slots rejected");
        Plugin_Printf("CAMERA NATIVE COMPLETE failures=%d checks=%d\n", failures, checks);
    }
}
