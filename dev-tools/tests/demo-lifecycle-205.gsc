#include openCJ\util;
// Isolated synthetic clients and in-memory demos. No database initialization.
main()
{
    level.lifecycleChecks=0;level.lifecycleFailures=0;
    openCJ\settings::onInit();openCJ\commands_base::onInit();
    openCJ\huds\infiniteHuds::onInit();openCJ\huds\hudFPSHistory::onInit();
    openCJ\huds\infiniteHuds::initInfiniteHud("fps");
    openCJ\statistics::onInit();openCJ\showRecords::onInit();
    openCJ\huds\hudProgressBar::onInit();openCJ\huds\hudRunInfo::onInit();
    openCJ\huds\hudOnScreenKeyboard::onInit();openCJ\checkpointPointers::onInit();
    openCJ\notifications::onInit();
    precacheMenu("opencj_demo");precacheMenu("opencj_clipedit");precacheMenu("opencj_clips");
    precacheItem("rpg_mp");
    level.demoCache=[];level.menu["ingame"]="opencj_ingame";
    cacheOwnershipChecks();
    wait 1;
    p=addTestClient();follower=addTestClient();wait .2;
    check(isDefined(p) && isDefined(follower),"two isolated clients");
    if(!isDefined(p) || !isDefined(follower))return;
    setup(p);setup(follower);
    follower.sessionState="spectator";follower.sessionTeam="spectator";
    follower followPlayer(p getEntityNumber());wait .1;
    for(pass=0;pass<3;pass++)
    {
        // Normal demo, clip editor and browser preview use the same lifecycle.
        p.clipEdit=undefined;p.clipPreview=undefined;
        if(pass==1)p.clipEdit=spawnStruct();
        if(pass==2)p.clipPreview=true;
        p.playerRuns_runPaused=pass==1;
        p.startTime=getTime()-5000;p.stopTime=undefined;
        if(pass==1)p.stopTime=getTime();
        p.playerRuns_runID=17205;p.runInstanceNumber=3;p.playerRuns_runStarted=false;
        p.playerRuns_runFinished=false;p.playerRuns_runFinishing=false;
        cp=spawnStruct();cp.id=205;cp.childs=[];cp.checkpointsFromStart=0;cp.checkpointsTillEnd=0;cp.enders=[];
        p.checkpoints_checkpoint=cp;
        p openCJ\huds\hudFPSHistory::_setFPSHistory("32-323");
        p.fpshistory["shortfps"]="3";
        p.statistics[level.statisticsStrings_saveCount]=7;p.statistics[level.statisticsStrings_loadCount]=4;
        p.statistics[level.statisticsStrings_explosiveJumps]=2;
        p.currSpeed=123;p.maxSpeed=456;p.health=75;
        p setVelocity((12,34,0));p setStance("stand");
        p.notificationFlash=p openCJ\notifications::_createOverlay(0,64,"white");
        p.notificationResultRun=17205;p.notificationResultUntil=getTime()+5000;
        p.statisticsHudString="old";follower.statisticsHudString="old";
        p.showRecords_nameString="old";follower.showRecords_nameString="old";
        p.progressBar.alpha=1;
        id=demoCreateTransient();
        for(i=0;i<8;i++)addFrameToDemo(id,(i,0,100),(0,90,0),1,8192,0,0,0,333,0,p getEntityNumber());
        cache=spawnStruct();cache.refs=1;cache.loading=false;cache.ready=true;level.demoCache[""+id]=cache;
        p.demoBegin=0;p.demoEnd=7;p.demoStyle=0;
        origin=p.origin;angles=p getPlayerAngles();velocity=p getVelocity();
        time=p openCJ\playTime::getTimePlayed();paused=p.playerRuns_runPaused;
        p openCJ\demos::startDemo(id);
        check(p openCJ\demos::isPlayingDemo(),"entered playback "+pass);
        check(p.playerRuns_runPaused && isDefined(p.stopTime),"run timer paused "+pass);
        check(!isDefined(p.notificationFlash) && !isDefined(p.notificationResultUntil),"pending feedback cancelled "+pass);
        check(p.statisticsHudString=="" && follower.statisticsHudString=="","statistics hidden for player and spectator "+pass);
        check(p.showRecords_nameString=="" && follower.showRecords_nameString=="","records hidden for player and spectator "+pass);
        check(p.progressBar.alpha==0 && p.hudSpeed["curr"].alpha==0,"live progress and speed hidden "+pass);
        check(p.hudTimeLimit.x==-8 && p.hudTimeLimit.y==-74 && p.hudTimeLimit.alignX=="right","timer clear of toolbar "+pass);
        check(p.hudSpeed["curr"].hideWhenInMenu==(pass!=0) && p.keyboard["forward"].hideWhenInMenu==(pass!=0),"menu overlay policy "+pass);
        p openCJ\events\eventHandler::onSavePositionRequest();
        check(!isDefined(p.eventQueue["save"]),"watching cannot enqueue a save "+pass);
        p openCJ\events\eventHandler::onLoadPositionRequest(1);
        check(p.demoExitRequested && !isDefined(p.eventQueue["load"]),"load requests exit without changing run "+pass);
        check(p.checkpoints_checkpoint==cp && p.playerRuns_runID==17205 && p.runInstanceNumber==3,"checkpoint and run unchanged during playback "+pass);
        // Exercise the actual exit with a changed playback pose and health.
        p unlink();p setOrigin((400,500,600));p.health=99;
        wait .1;
        p openCJ\demos::stopDemo(false);
        check(!p openCJ\demos::isPlayingDemo() && !isDefined(p.demoReturn) && !isDefined(p.demoID),"exit clears playback state "+pass);
        check(distanceSquared(p.origin,origin)<.01 && distanceSquared(p getVelocity(),velocity)<.01,"position and velocity restored "+pass);
        check(distanceSquared(p getPlayerAngles(),angles)<.01 && p.health==75,"view and health restored "+pass);
        check(p.playerRuns_runPaused==paused && isDefined(p.stopTime)==paused,"original paused/running state restored "+pass);
        check(abs((p openCJ\playTime::getTimePlayed())-time)<51,"watching does not advance run time "+pass);
        check(p.checkpoints_checkpoint==cp && p.playerRuns_runID==17205 && p.runInstanceNumber==3,"checkpoint and run survive exit "+pass);
        check(p openCJ\statistics::getSaveCount()==7 && p openCJ\statistics::getLoadCount()==4 && p openCJ\statistics::getExplosiveJumps()==2,"run counters unchanged "+pass);
        check(p.fpsHistoryText=="32-323" && p.maxSpeed==456,"live FPS history and maximum speed restored "+pass);
        check(p.hudTimeLimit.x==0 && p.hudTimeLimit.y==-12 && p.hudTimeLimit.alignX=="center","normal timer layout restored "+pass);
        check(!isDefined(p.demoCaption) && p.hudSpeed["curr"].hideWhenInMenu && !p.hudSpeed["curr"].archived,"temporary HUDs removed and menu policy restored "+pass);
        check(!isDefined(level.demoCache[""+id]) && !isDefined(p.clipEdit) && !isDefined(p.clipPreview),"cache and clip state released "+pass);
        p openCJ\demos::stopDemo(false);
        check(p.checkpoints_checkpoint==cp,"repeated stop is harmless "+pass);
    }
    // Other events retain the shared cleanup for the watched player too.
    p.statisticsHudString="old";follower.statisticsHudString="old";
    p openCJ\huds\hudStatistics::onRunCreated();
    check(p.statisticsHudString=="" && follower.statisticsHudString=="","new run shares statistics cleanup");
    p.statisticsHudString="old";follower.statisticsHudString="old";
    p openCJ\huds\hudStatistics::onRunStopped();
    check(p.statisticsHudString=="" && follower.statisticsHudString=="","stopped run shares statistics cleanup");
    p.showRecords_nameString="old";follower.showRecords_nameString="old";
    p openCJ\showRecords::onRunStopped();
    check(p.showRecords_nameString=="" && follower.showRecords_nameString=="","stopped run shares records cleanup");
    p.notificationFlash=p openCJ\notifications::_createOverlay(0,64,"white");
    p.notificationResultUntil=getTime()+5000;
    p openCJ\notifications::onDisconnect();
    check(!isDefined(p.notificationFlash) && !isDefined(p.notificationResultUntil),"disconnect shares feedback cleanup");
    printf("DEMO LIFECYCLE COMPLETE failures="+level.lifecycleFailures+" checks="+level.lifecycleChecks+"\n");
}
setup(p)
{
    p.sessionState="playing";p.sessionTeam="allies";p.pers["team"]="allies";
    p spawn((0,0,300),(0,0,0));p freezeControls(true);p.isFirstSpawn=false;
    p openCJ\settings::onPlayerConnect();
    p openCJ\huds\base::onPlayerConnect();
    p openCJ\huds\hudFPSHistory::onPlayerConnect();p.fpsHistoryMode="compact";
    p openCJ\huds\hudSpeedometer::onPlayerConnect();
    p openCJ\huds\hudOnScreenKeyboard::onPlayerConnect();
    p openCJ\huds\hudProgressBar::onPlayerConnect();
    p openCJ\huds\hudRunInfo::onPlayerConnect();
    p openCJ\huds\hudTimeLimit::onPlayerConnect();
    p openCJ\showRecords::onPlayerConnect();
    p openCJ\checkpointPointers::onPlayerConnect();
    p openCJ\statistics::onPlayerConnect();
    p openCJ\playerCollision::onPlayerConnect();
    p.demoLinker=spawn("script_origin",(0,0,0));p.playingDemo=false;
    p.cheating=false;p.allowHalfBeat=false;
    p giveWeapon("rpg_mp");p setSpawnWeapon("rpg_mp");
}
check(ok,label)
{
    level.lifecycleChecks++;
    if(!isDefined(ok) || !ok){level.lifecycleFailures++;printf("DEMO LIFECYCLE FAIL "+label+"\n");}
}


// Releasing one viewer must preserve shared work; the final release cancels its native owner.
cacheOwnershipChecks()
{
    demoID = 205001;
    key = "" + demoID;
    oldEntry = spawnStruct();
    oldEntry.refs = 2;
    oldEntry.loading = true;
    oldEntry.ready = false;
    oldEntry.cancelled = false;
    oldEntry.nativeCreated = true;
    level.demoCache[key] = oldEntry;
    check(createDemo(demoID) == demoID, "cache cancellation fixture owns a native recording");

    openCJ\demos::releaseCache(demoID);
    check(oldEntry.refs == 1 && !oldEntry.cancelled
          && isDefined(numberOfDemoFrames(demoID)), "another viewer preserves a shared load");
    openCJ\demos::releaseCache(demoID);
    cancelled = oldEntry.cancelled;
    check(cancelled, "last viewer cancels the loading cache entry");
    check(!isDefined(level.demoCache[key]) && !isDefined(numberOfDemoFrames(demoID)),
          "last viewer releases cache and native ownership");

    check(createDemo(demoID) == demoID, "replacement native recording can reuse the ID");
    addFrameToDemo(demoID, (1, 2, 3), (0, 0, 0), 1, 0, 0, 0, 0, 333);
    replacement = spawnStruct();
    replacement.refs = 1;
    replacement.loading = false;
    replacement.ready = true;
    level.demoCache[key] = replacement;
    openCJ\demos::_loadCache(demoID, 2, oldEntry);
    check(numberOfDemoFrames(demoID) == 1 && level.demoCache[key] == replacement,
          "obsolete loader cannot replace a newer recording with the same ID");
    openCJ\demos::releaseCache(demoID, oldEntry);
    check(replacement.refs == 1 && numberOfDemoFrames(demoID) == 1,
          "late cache release cannot affect a replacement entry");

    owner = spawnStruct();
    owner.demoPendingId = demoID;
    owner.demoPendingCache = replacement;
    owner openCJ\demos::releasePending(oldEntry);
    check(isDefined(owner.demoPendingId) && owner.demoPendingCache == replacement
          && replacement.refs == 1, "late cleanup cannot release a newer pending request");

    openCJ\demos::releaseCache(demoID);
    destroyDemo(demoID);
    level.demoCache[key] = undefined;
}
