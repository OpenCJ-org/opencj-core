#include openCJ\util;

onInit()
{
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

    // Flags are present in database as well as hardcoded in database function(s) right now, so do NOT modify existing ones.
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
    self.historySaves=undefined;
    self savePosition_initClient();
    self resetBackwardsCount();
}

canSaveError()
{
    if(self openCJ\historySave::isLoadingInitial())return 4;
    if(self.sessionState != "playing")
    {
        return 1;
    }

    if(!self isOnGround())
    {
        return 2;
    }

    // Tutorial runs follow their route: no saving where a skip was triggered
    isTutorialRun = self openCJ\tutorial::isTutorialRun();
    if(isTutorialRun && (self openCJ\tutorial::isSkipLoadPending() || self openCJ\checkpoints::touchesRouteSkippingCheckpoint()))
    {
        return 5;
    }

    groundEntity = self getGroundEntity();

    if(isDefined(groundEntity) && !isDefined(groundEntity.canSaveOn) && false)
    {
        return 3;
    }

    return 0;
}

printCanSaveError(error)
{
    switch(error)
    {
        case 4:
        {
            self iprintln("Wait until your run has loaded.");
            break;
        }
        case 2:
        {
            self iprintln("^1Cannot save in air");
            break;
        }
        case 3:
        {
            self iprintln("^1Cannot save on this object");
            break;
        }
        case 5:
        {
            self iprintln("^1Cannot save here: tutorial runs follow the route");
            break;
        }
    }
}

printSaveSuccess()
{
    self openCJ\notifications::action("save","^2Saved");
}

printLoadSuccess()
{
    self openCJ\notifications::action("load","^2Loaded");
}

onSpawnPlayer()
{
    self resetBackwardsCount();
}

canLoadError(backwardsCount)
{
    error = 0; // No error by default
    if((self.sessionState != "playing") && (self.sessionState != "spectator"))
    {
        error = 999;
    }
    else if(self openCJ\demos::isPlayingDemo())
    {
        error = 998;
    }
    else if(self openCJ\historySave::isLoadingInitial())
    {
        error = 3;
    }
    else if (isDefined(backwardsCount)) // Sometimes we don't want to select any save
    {
        error = self savePosition_selectSave(backwardsCount);
        if(self openCJ\historySave::maybePrefetch(backwardsCount) && error!=0)error=3;
    }

    if (error != 0) // Useful for debugging
    {
        //self iprintln("canLoadError: " + error);
    }
    return error;
}

printCanLoadError(error)
{
    switch(error)
    {
        case 1:
        {
            self iprintln("^1No save available");
            break;
        }
        case 3:
        {
            self iprintln("Loading older saves...");
            info=self savePosition_historyInfo();
            if(info[0]>0 && self.savePosition_backwardsCount>=info[0])
                self.savePosition_backwardsCount=info[0]-1;
            break;
        }
        case 2:
        {
            info=self savePosition_historyInfo();
            if(info[0]>=info[3])self iprintln("Only the "+info[3]+" most recent saves are available.");
            else if(isDefined(self.historySaves) && self.historySaves.failed)
                self iprintln("^1Could not read older saves. Try again.");
            else self iprintln("No older saved position available.");
            if(self.savePosition_backwardsCount>=info[0] && info[0]>0)
                self.savePosition_backwardsCount=info[0]-1;
            break;
        }
    }
}

_findNumOfEnt(ent)
{
    ents = getEntArray(ent.targetName, "targetname");
    for(i = 0; i < ents.size; i++)
    {
        if(ents[i] == ent)
        {
            return i;
        }
    }
    return undefined;
}

setSavedPosition()
{
    groundEntity = self getGroundEntity();
    origin = self getOrigin();
    angles = self getPlayerAngles();
    if(isDefined(groundEntity) && isDefined(groundEntity.targetName))
    {
        diff = origin - groundEntity.origin;
        x = vectorDot(anglesToForward(groundEntity.angles), diff);
        y = vectorDot(anglesToRight(groundEntity.angles), diff);
        z = vectorDot(anglesToUp(groundEntity.angles), diff);
        origin = (x, y, z);
        angles = angles - (0, groundEntity.angles[1], 0);
        entNum = groundEntity getEntityNumber();
        entTargetName = groundEntity.targetName;
        numOfEnt = _findNumOfEnt(groundEntity);
    }
    else
    {
        entNum = undefined;
        entTargetName = undefined;
        numOfEnt = undefined;
    }
    flags = self createFlags();
    FPSModeStr = self openCJ\fps::getCurrentFPSMode();
    FPSModeNum = self openCJ\fps::FPSModeToInt(FPSModeStr);
    previousSaveCount = self openCJ\statistics::getSaveCount();
    saveNum = self openCJ\statistics::increaseAndGetSaveCount();

    // Native validation can reject a position. Publish it only after local storage
    // accepts it, so a failed save cannot advance progress or add a demo marker.
    saved = self savePosition_save(origin, angles, entNum,
        self openCJ\statistics::getExplosiveJumps(),
        self openCJ\statistics::getDoubleExplosives(),
        self openCJ\checkpoints::getCurrentCheckpointID(), FPSModeNum, flags, saveNum);
    if (!isDefined(saved))
    {
        self openCJ\statistics::setSaveCount(previousSaveCount);
        self iprintln("^1Could not save this position.");
        return undefined;
    }

    self thread openCJ\historySave::saveToDatabase(origin, angles, entTargetName, numOfEnt,
        self openCJ\statistics::getExplosiveJumps(),
        self openCJ\statistics::getDoubleExplosives(),
        self openCJ\checkpoints::getCurrentCheckpointID(), FPSModeStr, flags);
    self openCJ\demoRecording::onSaved(saveNum);
    return saveNum;
}

getSavedPosition(backwardsCount)
{
    error = self savePosition_selectSave(backwardsCount);
    self openCJ\historySave::maybePrefetch(backwardsCount);
    if (error == 0) // No error
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
            x = vectorScale(anglesToForward(groundEntity.angles), save.origin[0]);
            y = vectorScale(anglesToRight(groundEntity.angles), save.origin[1]);
            z = vectorScale(anglesToUp(groundEntity.angles), save.origin[2]);
            save.origin = groundEntity.origin + x + y + z;
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
        info=self savePosition_historyInfo();
        if(self.savePosition_backwardsCount>info[3])self.savePosition_backwardsCount=info[3];
        if(self.savePosition_backwardsCount<0)self.savePosition_backwardsCount=0;
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