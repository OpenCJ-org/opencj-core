#include openCJ\util;

onInit()
{
    level.saveError_none = 0;
    level.saveError_notPlaying = 1;
    level.saveError_airborne = 2;
    level.saveError_loading = 4;
    level.saveError_tutorialSkip = 5;

    // The first three load results match the native save-selection interface.
    level.loadError_none = 0;
    level.loadError_empty = 1;
    level.loadError_unavailable = 2;
    level.loadError_loading = 3;
    level.loadError_demoPlaying = 998;
    level.loadError_invalidSession = 999;

    level.saveFlagName_cheating = "cheating";
    level.saveFlagName_speedModeNow = "speedModeNow";
    level.saveFlagName_speedModeEver = "speedModeEver";
    level.saveFlagName_hasRPG = "rpg";
    level.saveFlagName_usedEle = "usedEle";
    level.saveFlagName_anyPct = "anyPct";
    level.saveFlagName_allowHalfBeat = "halfBeat";
    level.saveFlagName_hardTAS = "hardTAS";
    level.saveFlagName_tutorial = "tutorial";

    level.saveFlags = [];

    // Flags are present in database as well as hardcoded in database function(s) right now, so do
    // NOT modify existing ones.
    level.saveFlags[level.saveFlagName_cheating] = 1;
    level.saveFlags[level.saveFlagName_speedModeNow] = 2;
    level.saveFlags[level.saveFlagName_speedModeEver] = 4;
    level.saveFlags[level.saveFlagName_hasRPG] = 8;
    // 16 can be re-used, but it was eleNow
    level.saveFlags[level.saveFlagName_usedEle] = 32;
    level.saveFlags[level.saveFlagName_anyPct] = 64;
    level.saveFlags[level.saveFlagName_allowHalfBeat] = 128;
    level.saveFlags[level.saveFlagName_hardTAS] = 256;
    level.saveFlags[level.saveFlagName_tutorial] = 512;
}

getFlagUsedEle(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_usedEle]) != 0;
}

getFlagAllowHalfBeat(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_allowHalfBeat]) != 0;
}

getUsedAnyPct(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_anyPct]) != 0;
}

getUsedHardTAS(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_hardTAS]) != 0;
}

isTutorialRun(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_tutorial]) != 0;
}

isCheating(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_cheating]) != 0;
}

hasSpeedModeNow(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_speedModeNow]) != 0;
}

hasSpeedModeEver(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_speedModeEver]) != 0;
}

hasRPG(save)
{
    return (save.flags & level.saveFlags[level.saveFlagName_hasRPG]) != 0;
}

createFlags()
{
    flags = 0;
    if(self openCJ\cheating::isCheating())
    {
        flags |= level.saveFlags[level.saveFlagName_cheating];
    }
    if(self openCJ\speedMode::hasSpeedMode())
    {
        flags |= level.saveFlags[level.saveFlagName_speedModeNow];
    }
    if(self openCJ\speedMode::hasSpeedModeEver())
    {
        flags |= level.saveFlags[level.saveFlagName_speedModeEver];
    }
    if(openCJ\weapons::isRPG(self getCurrentWeapon()))
    {
        flags |= level.saveFlags[level.saveFlagName_hasRPG];
    }
    if(self openCJ\elevate::hasUsedEle())
    {
        flags |= level.saveFlags[level.saveFlagName_usedEle];
    }
    if(self openCJ\anyPct::hasAnyPct())
    {
        flags |= level.saveFlags[level.saveFlagName_anyPct];
    }
    if(self openCJ\halfBeat::isHalfBeatAllowed())
    {
        flags |= level.saveFlags[level.saveFlagName_allowHalfBeat];
    }
    if(self openCJ\tas::hasHardTAS())
    {
        flags |= level.saveFlags[level.saveFlagName_hardTAS];
    }
    if(self openCJ\tutorial::isTutorialRun())
    {
        flags |= level.saveFlags[level.saveFlagName_tutorial];
    }

    return flags;
}

onRunCreated()
{
    self openCJ\notifications::cancelCheckpoint();
    self openCJ\notifications::cancelFlash();
    self openCJ\notifications::cancelResults();
    self openCJ\historySave::cancelPendingPage();
    self.historySaves = undefined;
    self savePosition_initClient();
    self resetBackwardsCount();
}

// Return a save restriction without changing the player's current save.
canSaveError()
{
    if(self openCJ\historySave::isLoadingInitial())
    {
        return level.saveError_loading;
    }
    if(self.sessionState != "playing")
    {
        return level.saveError_notPlaying;
    }
    if(!self isOnGround())
    {
        return level.saveError_airborne;
    }

    // Tutorial runs must follow the route instead of saving beyond a skipped checkpoint.
    isTutorialRun = self openCJ\tutorial::isTutorialRun();
    if(isTutorialRun && (self openCJ\tutorial::isSkipLoadPending() ||
                         self openCJ\checkpoints::touchesRouteSkippingCheckpoint()))
    {
        return level.saveError_tutorialSkip;
    }
    return level.saveError_none;
}

printCanSaveError(error)
{
    if(error == level.saveError_loading)
    {
        self iprintln("Wait until your run has loaded.");
    }
    else if(error == level.saveError_airborne)
    {
        self iprintln("^1Cannot save in air");
    }
    else if(error == level.saveError_tutorialSkip)
    {
        self iprintln("^1Cannot save here: tutorial runs follow the route");
    }
}

printSaveSuccess()
{
    self openCJ\notifications::action("save", "^2Saved");
}

printLoadSuccess()
{
    self openCJ\notifications::action("load", "^2Loaded");
}

onSpawnPlayer()
{
    self resetBackwardsCount();
}

// Select a retained save when requested, and start an older page read if needed.
// An undefined offset checks only whether loading is allowed.
canLoadError(backwardsCount)
{
    if(self.sessionState != "playing" && self.sessionState != "spectator")
    {
        return level.loadError_invalidSession;
    }
    if(self openCJ\demos::isPlayingDemo())
    {
        return level.loadError_demoPlaying;
    }
    if(self openCJ\historySave::isLoadingInitial())
    {
        return level.loadError_loading;
    }
    if(!isDefined(backwardsCount))
    {
        return level.loadError_none;
    }

    selectionError = self savePosition_selectSave(backwardsCount);
    loadingOlderSaves = self openCJ\historySave::maybePrefetch(backwardsCount);
    if(loadingOlderSaves && selectionError != level.loadError_none)
    {
        return level.loadError_loading;
    }
    return selectionError;
}

// Explain unavailable history and keep the selection inside the retained page.
printCanLoadError(error)
{
    if(error == level.loadError_empty)
    {
        self iprintln("^1No save available");
        return;
    }
    if(error != level.loadError_loading && error != level.loadError_unavailable)
    {
        return;
    }

    historyInfo = self savePosition_historyInfo();
    retainedCount = historyInfo[0];
    historyCapacity = historyInfo[3];
    if(error == level.loadError_loading)
    {
        self iprintln("Loading older saves...");
    }
    else if(retainedCount >= historyCapacity)
    {
        self iprintln("Only the " + historyCapacity + " most recent saves are available.");
    }
    else if(isDefined(self.historySaves) && self.historySaves.failed)
    {
        self iprintln("^1Could not read older saves. Try again.");
    }
    else
    {
        self iprintln("No older saved position available.");
    }

    if(retainedCount > 0 && self.savePosition_backwardsCount >= retainedCount)
    {
        self.savePosition_backwardsCount = retainedCount - 1;
    }
}

// Target names can be shared; persistence identifies the platform by its sibling index.
_findEntitySiblingIndex(entity)
{
    siblings = getEntArray(entity.targetName, "targetname");
    for(i = 0; i < siblings.size; i++)
    {
        if(siblings[i] == entity)
        {
            return i;
        }
    }
    return undefined;
}

// Store platform-relative coordinates, then publish the accepted save to persistence and demos.
setSavedPosition()
{
    groundEntity = self getGroundEntity();
    origin = self getOrigin();
    angles = self getPlayerAngles();
    if(isDefined(groundEntity) && isDefined(groundEntity.targetName))
    {
        positionOffset = origin - groundEntity.origin;
        x = vectorDot(anglesToForward(groundEntity.angles), positionOffset);
        y = vectorDot(anglesToRight(groundEntity.angles), positionOffset);
        z = vectorDot(anglesToUp(groundEntity.angles), positionOffset);
        origin = (x, y, z);
        angles = angles - (0, groundEntity.angles[1], 0);
        entityNumber = groundEntity getEntityNumber();
        entityTargetName = groundEntity.targetName;
        entitySiblingIndex = _findEntitySiblingIndex(groundEntity);
    }
    else
    {
        entityNumber = undefined;
        entityTargetName = undefined;
        entitySiblingIndex = undefined;
    }
    flags = self createFlags();
    fpsModeName = self openCJ\fps::getCurrentFPSMode();
    fpsModeNumber = self openCJ\fps::FPSModeToInt(fpsModeName);
    previousSaveCount = self openCJ\statistics::getSaveCount();
    saveNumber = self openCJ\statistics::increaseAndGetSaveCount();

    // Native validation can reject a position. Publish it only after local storage
    // accepts it, so a failed save cannot advance progress or add a demo marker.
    nativeSaveResult = self savePosition_save(
        origin, angles, entityNumber, self openCJ\statistics::getExplosiveJumps(),
        self openCJ\statistics::getDoubleExplosives(),
        self openCJ\checkpoints::getCurrentCheckpointID(), fpsModeNumber, flags, saveNumber);
    if(!isDefined(nativeSaveResult))
    {
        self openCJ\statistics::setSaveCount(previousSaveCount);
        self iprintln("^1Could not save this position.");
        return undefined;
    }

    self thread openCJ\historySave::saveToDatabase(
        origin, angles, entityTargetName, entitySiblingIndex, self openCJ\statistics::getExplosiveJumps(),
        self openCJ\statistics::getDoubleExplosives(),
        self openCJ\checkpoints::getCurrentCheckpointID(), fpsModeName, flags);
    self openCJ\demoRecording::onSaved(saveNumber);
    return saveNumber;
}

// Read the selected native save and convert a moving-platform offset back to world space.
getSavedPosition(backwardsCount)
{
    selectionError = self savePosition_selectSave(backwardsCount);
    self openCJ\historySave::maybePrefetch(backwardsCount);
    if(selectionError == level.loadError_none)
    {
        save = spawnStruct();
        save.origin = self savePosition_getOrigin();
        save.angles = self savePosition_getAngles();
        save.explosiveJumps = self savePosition_getExplosiveJumps();
        save.doubleExplosives = self savePosition_getDoubleExplosives();
        save.checkpointID = self savePosition_getCheckpointID();
        save.flags = self savePosition_getFlags();
        save.FPSMode = self openCJ\fps::FPSModeToString(self savePosition_getFPSMode());
        save.saveNum = self savePosition_getSaveNum();

        groundEntity = self savePosition_getGroundEntity();

        if(isDefined(groundEntity))
        {
            forwardOffset = vectorScale(anglesToForward(groundEntity.angles), save.origin[0]);
            rightOffset = vectorScale(anglesToRight(groundEntity.angles), save.origin[1]);
            upOffset = vectorScale(anglesToUp(groundEntity.angles), save.origin[2]);
            save.origin = groundEntity.origin + forwardOffset + rightOffset + upOffset;
            save.angles = (save.angles[0], save.angles[1] + groundEntity.angles[1], save.angles[2]);
        }

        return save;
    }

    return undefined;
}

incrementBackwardsCount(amount)
{
    if(amount == 0)
    {
        return self resetBackwardsCount();
    }
    else
    {
        self.savePosition_backwardsCount += amount;
        historyInfo = self savePosition_historyInfo();
        historyCapacity = historyInfo[3];
        if(self.savePosition_backwardsCount > historyCapacity)
        {
            self.savePosition_backwardsCount = historyCapacity;
        }
        if(self.savePosition_backwardsCount < 0)
        {
            self.savePosition_backwardsCount = 0;
        }
    }
    return self.savePosition_backwardsCount;
}

resetBackwardsCount()
{
    self.savePosition_backwardsCount = 0;
    return 0;
}

getBackwardsCount()
{
    return self.savePosition_backwardsCount;
}

onPlayerCommand(args)
{
    switch(args[0])
    {
    case "save":
    {
        self openCJ\events\eventHandler::onSavePositionRequest();
        return true;
    }
    case "load":
    {
        self openCJ\events\eventHandler::onLoadPositionRequest(0);
        return true;
    }
    case "loadsecondary":
    {
        self openCJ\events\eventHandler::onLoadPositionRequest(1);
        return true;
    }
    case "mr":
    {
        if(isDefined(args[3]))
        {
            if(args[3] == "load")
            {
                self openCJ\events\eventHandler::onLoadPositionRequest(0);
                return true;
            }
            else if(args[3] == "save")
            {
                self openCJ\events\eventHandler::onSavePositionRequest();
                return true;
            }
            else if(args[3] == "loadsecondary")
            {
                self openCJ\events\eventHandler::onLoadPositionRequest(1);
                return true;
            }
        }
    }
    }
    return false;
}