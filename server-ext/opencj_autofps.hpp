#ifndef OPENCJ_AUTOFPS_HPP
#define OPENCJ_AUTOFPS_HPP
#ifdef COD4
#include "shared.hpp"

// Tutorial-mode automatic FPS. While enabled for a client, each movement command
// may send that client a new com_maxfps (333, 250 or 125). Disabled by default.
extern "C"
{
// Clears a client slot: disabled, nothing sent. Call on connect and init.
void opencj_autoFpsInitClient(int clientNum);

// Called after the engine has moved the player for this command.
void opencj_autoFpsObserve(const playerState_t *ps, const usercmd_t *cmd);

// True when a command ended rising, at least 50 units/s faster upward than the
// previous command ended. Such a gain is a bounce or a push.
bool opencj_autoFpsIsUpwardGain(float previousEndVerticalSpeed, float endVerticalSpeed);

// True when two server times are close enough (500 ms) to link an upward gain
// to an RPG shot.
bool opencj_autoFpsIsWithinRPGWindow(int firstTime, int secondTime);

// True when 333 makes the difference: flying the current way, the airborne
// player would reach the target (x, y, z) horizontally below its height at
// 250/125 FPS but at or above it at 333; or, climbing, its peak at 250/125
// would stay less than 48 units above the target while its peak at 333 reaches
// it. False when not heading towards it, already over it, or 333 cannot help.
bool opencj_autoFpsNeedsHeight(const playerState_t *ps, const float *target);

// True when the player, switching to 250/125 now and gaining horizontal speed at
// horizontalAcceleration (units/s^2), would reach the target horizontally at
// least 32 units above its height. Ends the 333 kept for height.
bool opencj_autoFpsArrivesHighEnoughAt250(const playerState_t *ps, const float *target,
                                          float horizontalAcceleration);

// GSC: self setAutoFPSTarget(x, y, z) / self clearAutoFPSTarget().
// The position of the player's next checkpoint, used by opencj_autoFpsNeedsHeight.
void Gsc_AutoFps_SetTarget(int clientNum);
void Gsc_AutoFps_ClearTarget(int clientNum);

// GSC: self notifyAutoFPSRPGFired(). Reports an RPG shot; an upward gain within
// 500 ms before or after it is treated as an RPG push (333 for height).
void Gsc_AutoFps_NotifyRPGFired(int clientNum);

// The speed and RPG parts of the rule: returns 333, 250 or 125 for this player
// state and command, and updates *inPushRise (true from an RPG push until
// shortly before the following peak). switchLeadMs moves that switch earlier,
// to cover network delay. The height check is opencj_autoFpsNeedsHeight.
int opencj_autoFpsChooseFrameRate(bool *inPushRise, const playerState_t *ps,
                                  const usercmd_t *cmd, int switchLeadMs);

// GSC: self setAutoFPSEnabled(enabled). Returns true for a valid client.
void Gsc_AutoFps_SetEnabled(int clientNum);

// GSC: self getAutoFPS(). The last com_maxfps sent, or 0 when none is active.
void Gsc_AutoFps_GetCurrent(int clientNum);
}

#endif
#endif
