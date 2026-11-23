#include openCJ\util;

// Load equipment before spawning, then initialize the run and its displays in order.
main(atLastSavedPosition)
{
    self endon("disconnect");
    self cancelPendingSpawn();
    requestVersion = self.spawnRequestVersion;
    self openCJ\mapBoost::cancel();
    if(!self openCJ\login::isLoggedIn())
    {
        return;
    }

    if(!self openCJ\fpsRegistration::canStart())
    {
        self openCJ\events\spawnSpectator::main();
        // Arm after the temporary spectator transition, which cancels older spawn requests.
        self.fpsRegistrationSpawnPending = true;
        self.fpsRegistrationSpawnAtSave = atLastSavedPosition;
        self openCJ\fpsRegistration::explainBlocked();
        return;
    }

    self openCJ\shop::stopInspect();
    loadForSpawn = true;
    if(!self openCJ\shop::loadEquipment(loadForSpawn))
    {
        return;
    }
    if(requestVersion != self.spawnRequestVersion)
    {
        return;
    }

    self openCJ\demos::cancelRequest();
    if(self openCJ\demos::isPlayingDemo())
    {
        self openCJ\demos::stopDemo();
    }

    self openCJ\noclip::disableNoclip();

    self.demoSpectatorCaption = undefined;
    self setClientCvar("cg_drawSpectatorMessages", 1);
    self notify("spawned");

    resetTimeout();
    self.sessionTeam = "allies";
    self.sessionState = "playing";
    if(self.spectatorClient != -1)
    {
        self openCJ\events\spectatorClientChanged::main(getEntByNum(self.spectatorClient),
                                                        undefined);
        self.spectatorClient = -1;
    }
    self.archiveTime = 0;
    self.psOffsetTime = 0;
    self.pers["team"] = "allies";
    spawnPoint = self openCJ\spawnpoints::getPlayerSpawnpoint();
    self unlink(); // Player may be attached to something
    self openCJ\mapBoost::cancel();
    self spawn(spawnPoint.origin, spawnPoint.angles);

    self openCJ\savePosition::onSpawnPlayer();
    self openCJ\playerRuns::onSpawnPlayer();
    self openCJ\checkpoints::onSpawnPlayer();
    self openCJ\showRecords::onSpawnPlayer();
    self openCJ\huds\hudOnScreenKeyboard::onSpawnPlayer();
    self openCJ\huds\hudJumpSlowdown::onSpawnPlayer();
    self openCJ\huds\hudProgressBar::onSpawnPlayer();
    self openCJ\huds\hudSpeedometer::onSpawnPlayer();
    self openCJ\huds\hudGrenadeTimers::onSpawnPlayer();
    self openCJ\huds\hudFpsHistory::onSpawnPlayer();
    self openCJ\huds\hudFps::onSpawnPlayer();
    self openCJ\huds\hudPosition::onSpawnPlayer();
    self openCJ\huds\hudRunInfo::onSpawnPlayer();
    self openCJ\huds\hudSpectatorList::onSpawnPlayer();
    self openCJ\events\eventHandler::onSpawnPlayer();
    self openCJ\statistics::onSpawnPlayer();
    self openCJ\huds\hudStatistics::onSpawnPlayer();
    self openCJ\playTime::onSpawnPlayer();
    self openCJ\fps::onSpawnPlayer();
    self openCJ\tutorial::onSpawnPlayer();
    self openCJ\elevate::_updateAllowEle();

    self setSharedSpawnVars(false, true);
    self thread openCJ\events\whileAlive::main();
    self thread _notifySpawnedAfterFrame();

    self openCJ\checkpointCreation::onSpawnPlayer();

    // Set player at last saved position if requested
    if(isDefined(atLastSavedPosition) && atLastSavedPosition &&
       !self openCJ\checkpointCreation::isEditing())
    {
        self openCJ\events\eventHandler::onLoadPositionRequest(0);
    }

    // Keep this as last
    self.isFirstSpawn = false;
}

// A later spectator, demo, spawn, or disconnect request owns the player's next state.
cancelPendingSpawn()
{
    self.fpsRegistrationSpawnPending = false;
    if(!isDefined(self.spawnRequestVersion))
    {
        self.spawnRequestVersion = 0;
    }
    self.spawnRequestVersion++;
    if(isDefined(self.shopEquipmentForSpawn) && self.shopEquipmentForSpawn)
    {
        self openCJ\shop::cancelEquipmentRead();
    }
}

setSharedSpawnVars(giveRPG, isSpawn)
{
    self openCJ\healthRegen::resetHealthRegen();
    self openCJ\weapons::giveWeapons(giveRPG, isSpawn);
    self openCJ\weapons::setWeaponSpread();
    self openCJ\shellShock::resetShellShock();
    self openCJ\huds\hudGrenadeTimers::removeNadeTimers();
    self openCJ\buttonPress::resetButtons();

    self openCJ\playerModels::setPlayerModel();

    self openCJ\checkpointPointers::showCheckpointPointers();

    if(getCodVersion() == 2)
        self setContents(256);
    else
    {
        self setperk("specialty_fastreload");
        self setPerk("specialty_longersprint");
    }
    self jumpClearStateExtended();
    self openCJ\speedMode::applySpeedMode();
    self openCJ\huds\hudFpsHistory::hideAndClearFPSHistory();
}

// Send the deferred spawn event only while the player still exists.
_notifySpawnedAfterFrame()
{
    waittillframeend;
    if(isDefined(self))
    {
        self notify("spawned_player");
    }
}

setDemoSpawnVars(giveRPG)
{
    self openCJ\weapons::giveWeapons(giveRPG);
    self openCJ\shellShock::resetShellShock();

    self openCJ\playerModels::setPlayerModel();

    if(getCodVersion() == 2)
        self setContents(256);
    else
    {
        self setperk("specialty_fastreload");
        self setPerk("specialty_longersprint");
    }
    self jumpClearStateExtended();
}