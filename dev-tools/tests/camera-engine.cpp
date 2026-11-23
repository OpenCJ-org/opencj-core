// Isolated test plugin: inspect demo presentation and visibility masks.
#include "../../cod4x-server/src/opencj_main.hpp"
#include "../../server-ext/opencj_demo.hpp"
#include "../../server-ext/opencj_visibility.hpp"
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <cstring>
#include <string>
extern "C"
{
    void Plugin_Printf(const char *, ...);
    client_t *Plugin_GetClientForClientNum(int);
    int Plugin_Cvar_VariableIntegerValue(const char *);
}
static int checks, failures;
static void check(bool ok, const char *label)
{
    ++checks;
    if(!ok)
    {
        ++failures;
    }
    Plugin_Printf("CAMERA NATIVE %d: %s\n", ok, label);
}
static bool hidden(const gentity_t *actor, int viewer)
{
    return (actor->r.clientMask[viewer / 32] & (1u << (viewer % 32))) != 0;
}
static void animationProbe()
{
    if(Plugin_Cvar_VariableIntegerValue("opencj_isolated_camera_test") != 1)
    {
        return;
    }
    auto &ent = *Plugin_GetClientForClientNum(0)->gentity;
    auto &ps = ent.client->ps;
    int stage = Scr_GetInt(0);
    static playerState_t before;
    static bgs_s *beforeContext;
    static int runLegs, runTorso, landLegs, landTorso;
    if(stage == 0)
    {
        before = ps;
        beforeContext = bgs;
        return;
    }
    if(stage == 99)
    {
        check(ps.legsAnim == before.legsAnim && ps.torsoAnim == before.torsoAnim &&
                  ps.legsTimer == before.legsTimer && ps.torsoTimer == before.torsoTimer &&
                  ps.legsAnimDuration == before.legsAnimDuration &&
                  ps.torsoAnimDuration == before.torsoAnimDuration &&
                  ps.movementDir == before.movementDir,
              "original body animation restored");
        return;
    }
    int legs = ps.legsAnim & 511;
    const char *name = reinterpret_cast<const char *>(&level_bgs) + legs * 96;
    Plugin_Printf("CAMERA BODY stage=%d legs=%d torso=%d direction=%d name=%.64s\n", stage,
                  ps.legsAnim, ps.torsoAnim, ps.movementDir, name);
    const char *expected = Scr_GetString(1);
    check(legs > 0 && std::strstr(name, expected),
          "recorded movement selects matching body animation");
    check(ent.s.legsAnim == ps.legsAnim && ent.s.torsoAnim == ps.torsoAnim &&
              ent.s.lerp.u.player.movementDir == ps.movementDir,
          "body animation published to entity");
    check(ps.weaponDelay == 0 && ps.weaponstate == 0 && ps.origin[0] == before.origin[0] &&
              ps.origin[1] == before.origin[1] && ps.origin[2] == before.origin[2],
          "animation cannot move player or replay weapon simulation");
    check(bgs == beforeContext, "animation restores engine context");
    if(stage == 3)
    {
        runLegs = ps.legsAnim;
        runTorso = ps.torsoAnim;
    }
    if(stage == 4)
    {
        check(ps.legsAnim == runLegs && ps.torsoAnim == runTorso,
              "reapplying paused frame does not restart animation");
    }
    if(stage == 30)
    {
        landLegs = ps.legsAnim;
        landTorso = ps.torsoAnim;
    }
    if(stage == 31)
    {
        check(ps.legsAnim == landLegs && ps.torsoAnim == landTorso,
              "repeated landing does not restart animation");
    }
    if(stage == 7)
    {
        check(ps.movementDir == 90, "left strafe body orientation");
    }
    if(stage == 8)
    {
        check(ps.movementDir == -90, "right strafe body orientation");
    }
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
    static int last = 0;
    int stage = Plugin_Cvar_VariableIntegerValue("opencj_camera_test_stage");
    if(stage == last || !stage)
    {
        return;
    }
    last = stage;
    client_t *owner = Plugin_GetClientForClientNum(0), *observer = Plugin_GetClientForClientNum(1);
    if(!owner || !observer || !owner->gentity || !observer->gentity)
    {
        check(false, "test clients available");
        return;
    }
    gentity_t *actor = owner->gentity;
    if(stage == 1)
    {
        check(OpenCJ_Demo_IsPresentationActive(0), "presentation active");
        check(!(actor->s.lerp.eFlags & 0x20) && !hidden(actor, 0), "demo body visible to owner");
        auto state = observer->gentity->client->sess.sessionState;
        int followed = observer->gentity->client->ps.clientNum;
        observer->gentity->client->sess.sessionState = SESS_STATE_PLAYING;
        Gsc_Vis_UpdatePlayerVisibility();
        check(hidden(actor, 1), "ordinary player cannot see playback body");
        observer->gentity->client->sess.sessionState = SESS_STATE_SPECTATOR;
        observer->gentity->client->ps.clientNum = 1;
        Gsc_Vis_UpdatePlayerVisibility();
        check(hidden(actor, 1), "unrelated spectator cannot see playback body");
        observer->gentity->client->ps.clientNum = 0;
        Gsc_Vis_UpdatePlayerVisibility();
        check(!hidden(actor, 1), "following spectator can see playback body");
        observer->gentity->client->sess.sessionState = state;
        observer->gentity->client->ps.clientNum = followed;
        Gsc_Vis_UpdatePlayerVisibility();
    }
    else if(stage == 2)
    {
        check(!OpenCJ_Demo_IsPresentationActive(0), "presentation lifetime ends");
        Gsc_Vis_UpdatePlayerVisibility();
        check(!hidden(actor, 1), "normal visibility restored after playback");
        check(!OpenCJ_Demo_IsPresentationActive(-1) &&
                  !OpenCJ_Demo_IsPresentationActive(MAX_CLIENTS),
              "invalid presentation slots rejected");
        Plugin_Printf("CAMERA NATIVE COMPLETE failures=%d checks=%d\n", failures, checks);
    }
}
