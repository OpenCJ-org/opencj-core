#include openCJ\util;

onInit()
{
    if(getCodVersion()==4)precacheMenu("opencj_demo");
    clearAllDemos();
    level.demoCache = [];
    openCJ\demoRecording::onInit();
    cmd = openCJ\commands_base::registerCommand("demo", "!demo [wt|sr|rpg|stop|pause|resume|speed <0.25|0.5|1|2|4>|forward|reverse|next|previous]", ::_onCommandPlayback, 0, 2, 0);
    openCJ\commands_base::addAlias(cmd,"playback");
    openCJ\commands_base::registerCommand("srdemo", "Watch the fastest compatible demo at your checkpoint or nearby area. Usage: !srdemo", ::_onCommandSpeedrun, 0, 0, 0);
    setting = openCJ\settings::addSettingBool("demoloop", true, "Loop demo playback");
    openCJ\commands_base::addAlias(setting,"loop");
}

_onCommandPlayback(args)
{
    if ((args.size && args[0]=="stop") || (!args.size && self isPlayingDemo()))
    {
        self cancelRequest();
        self thread doNextFrame(::stopDemo);
        return;
    }
    if(self isPlayingDemo() && args.size)
    {
        action=toLower(args[0]);
        if(action=="pause" || action=="resume" || action=="speed" || action=="forward" || action=="reverse" || action=="next" || action=="previous")
        {
            if(action=="pause")self.playbackPaused=true;
            if(action=="resume")self.playbackPaused=false;
            if(action=="speed" && args.size>1)
            {
                self setDemoSpeed(args[1]);
            }
            if(action=="forward" || action=="reverse")self setDemoDirection(action);
            if(action=="next")self.demoCheckpointRequest=1;
            if(action=="previous")self.demoCheckpointRequest=-1;
            return;
        }
    }
    kind="walkthrough";
    if (args.size) kind=toLower(args[0]);
    if(kind=="wt")kind="walkthrough";
    if(kind=="sr")kind="speedrun";
    if(kind=="rpg" || kind=="low")kind="lowrpg";
    if(kind!="walkthrough" && kind!="speedrun" && kind!="lowrpg")
    {
        self sendLocalChatMessage("Use !demo wt, !demo sr, !demo rpg, or !demo stop.",true);
        return;
    }
    self thread request(kind);
}

_onCommandSpeedrun(args)
{
    self thread request("speedrun");
}

request(kind)
{
    self cancelRequest();
    self endon("demo_request");
    self endon("disconnect");
    if (!self canWatch()) return;
    location=self selectionLocation();
    if(!location.checkpoints.size && kind!="speedrun")
    {
        self sendLocalChatMessage("Stand in a checkpoint to watch its demo.",true);
        return;
    }
    fps=self openCJ\fps::getCurrentFPSMode();
    mask=int(self openCJ\anyPct::hasAnyPct())+2*int(self openCJ\elevate::hasUsedEle())+4*int(self openCJ\halfBeat::isHalfBeatAllowed())+8*int(self openCJ\tas::hasHardTAS());
    rows=self openCJ\mySQL::mysqlAsyncRead(candidateQuery(location,kind,fps,mask,openCJ\mapID::getMapID()));
    if(!isDefined(rows))
    {
        self sendLocalChatMessage("Could not look up demos. Please try again.",true);
        return;
    }
    if(rows.size)self sendLocalChatMessage("Finding a demo for this location...");
    selected=self selectCandidate(rows,location,kind);
    if(!isDefined(selected))
    {
        self sendLocalChatMessage("No matching demo is available here for these modes.",true);
        return;
    }
    self playRun(selected.id,false,kind,selected.range);
    self releaseSelection();
}

candidateQuery(location,kind,fps,mask,mapID)
{
    if(kind=="walkthrough")
    {
        mask=0;
        if(fps=="hax")fps="mix";
        fpsFilter="("+dbStr(fps)+")";
    }
    else fpsFilter=openCJ\menus\board_base::getFPSModeStr(fps);
    routes=getArrayKeys(location.routes);
    routeFilter="";
    if(routes.size)
    {
        names="";
        for(i=0;i<routes.size;i++)
        {
            if(i)names+=",";
            names+=dbStr(routes[i]);
        }
        routeFilter=" AND w.routeName IN ("+names+")";
    }
    order="d.timePlayed,d.explosiveJumps";
    if(kind=="lowrpg")order="d.explosiveJumps,d.timePlayed";
    return "SELECT d.runID,d.modeMask,d.frameCount FROM demoWinners w JOIN demoRuns d ON d.runID=w.runID WHERE d.ready=1 AND w.mapID="+mapID+routeFilter+" AND w.kind="+dbStr(kind)+" AND (w.modeMask & "+mask+")=w.modeMask AND w.FPSMode IN "+fpsFilter+" ORDER BY "+order+",BIT_COUNT(d.modeMask),FIELD(d.FPSMode,'125','mix','hax'),d.runID";
}

// Capture physical context once. A finished run or a stale route after noclip
// must neither hide a valid shared-start demo nor select an unrelated lesson.
selectionLocation()
{
    location=spawnStruct();location.origin=self.origin;
    location.checkpoints=[];location.routes=[];
    groundEntity=self getGroundEntity();
    for(i=0;i<level.checkpoints_checkpoints.size;i++)
    {
        cp=level.checkpoints_checkpoints[i];
        if(!self openCJ\checkpoints::touchesArea(cp,true,groundEntity))continue;
        if(isDefined(cp.bigBrother))cp=cp.bigBrother;
        location.checkpoints[""+cp.id]=cp.id;
        ends=openCJ\checkpoints::getEndCheckpoints(cp);
        if(!isDefined(ends))continue;
        for(j=0;j<ends.size;j++)
            if(isDefined(ends[j].ender))location.routes[ends[j].ender]=true;
    }
    return location;
}

segmentAtLocation(id,any,skipFails,location)
{
    keys=getArrayKeys(location.checkpoints);
    best=undefined;
    for(i=0;i<keys.size;i++)
    {
        range=demoFindSegment(id,location.checkpoints[keys[i]],location.origin,any,skipFails,1);
        if(isDefined(range) && betterLesson(range,best))best=range;
    }
    if(keys.size)return best;
    // Only speedrun requests reach this spatial fallback. Strict matching
    // rejects the legacy Any% fallback to an unrelated complete recording.
    return demoFindSegment(id,0,location.origin,1,skipFails,1);
}

betterLesson(range,best)
{
    if(!isDefined(best))return true;
    if(range[2]!=best[2])return range[2]<best[2];
    return range[3]<best[3];
}

// The winner query is already ordered by full-run time/RPG policy. Walkthrough
// choices instead compare the actual matching jump, not the length of its route.
selectCandidate(rows,location,kind)
{
    best=undefined;
    for(i=0;i<rows.size;i++)
    {
        id=int(rows[i][0]);
        if(!self acquireCache(id,int(rows[i][2])))continue;
        range=segmentAtLocation(id,int(rows[i][1])&1,int(kind!="speedrun"),location);
        previousRange=undefined;
        if(isDefined(best))previousRange=best.range;
        if(isDefined(range) && (kind!="walkthrough" || betterLesson(range,previousRange)))
        {
            self releaseSelection();
            self.demoSelectionId=id;self.demoPendingId=undefined;
            best=spawnStruct();best.id=id;best.range=range;
            if(kind!="walkthrough")break;
        }
        else self releasePending();
    }
    return best;
}

acquireCache(id,expected)
{
    key=""+id;load=false;
    if(!isDefined(level.demoCache[key]))
    {
        cache=spawnStruct();cache.loading=true;cache.ready=false;cache.refs=0;
        level.demoCache[key]=cache;load=true;
    }
    cache=level.demoCache[key];cache.refs++;self.demoPendingId=id;
    if(load)level thread _loadCache(id,expected);
    while(cache.loading)wait 0.05;
    if(!cache.ready){self releasePending();return false;}
    return true;
}

releaseSelection()
{
    if(isDefined(self.demoSelectionId))
    {
        releaseCache(self.demoSelectionId);
        self.demoSelectionId=undefined;
    }
}

canWatch()
{
    if(!level.demoStorageReady)
    {
        self sendLocalChatMessage("Demo storage has not been initialized.",true);
        return false;
    }
    if(isDefined(self.playerRuns_runFinishing) && self.playerRuns_runFinishing)return false;
    if(self.sessionState!="playing" || self openCJ\checkpointCreation::isEditing() || self isPlayingDemo())
    {
        self sendLocalChatMessage("Spawn and leave CPC/current playback before watching a demo.",true);
        return false;
    }
    return true;
}

// Called by leaderboard row selection. Explicit rows always play the full run.
playRun(id,full,kind,selectedRange)
{
    self endon("disconnect");
    self endon("demo_request");
    if(!self canWatch())return;
    self sendLocalChatMessage("Loading demo...");
    if(!isDefined(full))full=true;
    meta=self openCJ\mySQL::mysqlAsyncRead("SELECT frameCount,modeMask,EXISTS(SELECT 1 FROM demoWinners w WHERE w.runID=demoRuns.runID AND w.kind='walkthrough'),(SELECT p.playerName FROM playerRuns r JOIN playerDisplayNames p ON p.playerID=r.playerID WHERE r.runID=demoRuns.runID) FROM demoRuns WHERE ready=1 AND mapID="+openCJ\mapID::getMapID()+" AND runID="+id);
    if(!isDefined(meta)||!meta.size)
    {
        self sendLocalChatMessage("This run has no retained demo.",true);
        return;
    }
    // Leaderboard rows can also be the walkthrough winner. Explicit requests
    // retain their requested style, even when the same recording wins both.
    if(!isDefined(kind))kind=leaderboardKind(int(meta[0][2])!=0);
    if(!self acquireCache(id,int(meta[0][0])))
    {
        self sendLocalChatMessage("The recording could not be loaded.",true);
        return;
    }
    if(!self canWatch()){self releasePending();return;}
    range=[];range[0]=0;range[1]=numberOfDemoFrames(id)-1;
    if(!full)
    {
        range=selectedRange;
        if(!isDefined(range))range=self segmentAtPosition(id,int(meta[0][1])&1,int(kind!="speedrun"));
        if(!isDefined(range))
        {
            self sendLocalChatMessage("No matching demo segment is available at this checkpoint.",true);
            self releasePending();
            return;
        }
    }
    // Start outside a client-command / movement callback.
    waittillframeend;
    if(!self canWatch()){self releasePending();return;}
    self.demoPendingId=undefined;
    self.demoAuthor=meta[0][3];
    if(!isDefined(self.demoAuthor) || self.demoAuthor=="")self.demoAuthor="Unknown player";
    self.demoStyle=0;
    if(kind=="lowrpg")self.demoStyle=1;
    else if(kind=="walkthrough")self.demoStyle=2;
    self.demoBegin=range[0];self.demoEnd=range[1];
    self.demoCheckpointed=(int(meta[0][1])&1)==0;
    self startDemo(id);
}

// Looking up a lesson must not depend on, or change, the viewer's run progress.
// Noclip and returning after a finish leave that progress at an unrelated CP.
segmentAtPosition(id,any,skipFails)
{
    current=self openCJ\checkpoints::getCurrentCheckpoint();
    groundEntity=self getGroundEntity();
    for(i=-1;i<level.checkpoints_checkpoints.size;i++)
    {
        cp=current;
        if(i>=0)cp=level.checkpoints_checkpoints[i];
        if(!isDefined(cp) || !self openCJ\checkpoints::touchesArea(cp,true,groundEntity))continue;
        if(isDefined(cp.bigBrother))cp=cp.bigBrother;
        range=demoFindSegment(id,cp.id,self.origin,any,skipFails);
        if(isDefined(range))return range;
    }
    cpID=0;
    if(isDefined(current))
    {
        if(isDefined(current.bigBrother))current=current.bigBrother;
        if(isDefined(current.id))cpID=current.id;
    }
    return demoFindSegment(id,cpID,self.origin,any,skipFails);
}

leaderboardKind(isWalkthrough)
{
    if(isWalkthrough)return "walkthrough";
    return "speedrun";
}

_loadCache(id,expected)
{
    cache=level.demoCache[""+id];
    created=createDemo(id);
    ok=created==id;
    if(ok)
    {
        // Bound result size while amortizing the 50ms async database poll.
        // Each query already yields; another wait after decoding doubles latency.
        chunk=0;
        while(ok && numberOfDemoFrames(id)<expected)
        {
            rows=openCJ\mySQL::awaitNative(demoLoadChunks(id,id,0,chunk));
            ok=isDefined(rows) && rows.size>0 && rows[0][0]>chunk;
            if(ok)chunk=rows[0][0];
        }
        if(ok)ok=numberOfDemoFrames(id)==expected;
        if(ok)completeDemo(id);
        else destroyDemo(id);
    }
    cache.ready=ok;cache.loading=false;
    if(!ok)printf("OpenCJ: failed to load demo "+id+".\n");
    if(cache.refs==0)releaseCache(id);
}

releaseCache(id)
{
    cache=level.demoCache[""+id];
    if(!isDefined(cache))return;
    if(cache.refs>0)cache.refs--;
    if(cache.refs==0 && !cache.loading)
    {
        if(cache.ready)destroyDemo(id);
        level.demoCache[""+id]=undefined;
    }
}

startDemo(demoID)
{
    self openCJ\mapBoost::cancel();
    self openCJ\shop::stopInspect();
    if (getCodVersion() == 4 && !(self demoBeginPresentation()))
    {
        releaseCache(demoID);
        self sendLocalChatMessage("Could not prepare demo playback", true);
        return;
    }
    state=spawnStruct();
    state.origin=self.origin;state.angles=self getPlayerAngles();state.velocity=self getVelocity();
    state.stance=self getStance();state.weapon=self getCurrentWeapon();state.health=self.health;
    state.paused=self.playerRuns_runPaused;state.time=self openCJ\playTime::getTimePlayed();
    state.timerRunning=!isDefined(self.stopTime);
    self openCJ\huds\hudFPSHistory::_flushPendingInput();
    state.fpshistory=self.fpshistory;state.fpsHistoryText=self.fpsHistoryText;
    state.fpsHistoryShortFPS=self.fpshistory["shortfps"];
    state.fpsHistoryEvents=self.fpsHistoryEvents;state.fpsHistoryTruncated=self.fpsHistoryTruncated;
    state.fpsHistoryStyle=self.fpsHistoryStyle;
    state.speed=self.currSpeed;state.maxSpeed=self.maxSpeed;
    state.started=getTime();
    self.demoReturn=state;
    self.checkpointContact=undefined;
    self openCJ\historySave::cancelPendingPage();
    self openCJ\notifications::onStartDemo();
    self.playingDemo=true;
    self openCJ\halfBeat::disableCorrection();
    self.demoExitRequested=false;
    self hide();
    // The local body is needed by the third-person camera. Native visibility
    // keeps this playback body hidden from unrelated players.
    if(getCodVersion()==4)self showToPlayer(self);
    self.playerRuns_runPaused=true;
    self openCJ\playTime::pauseTimer();
    self.eventQueue=[];
    self.demoID=demoID;self.playbackPaused=false;self.slowmoCount=0;
    self.demoPreviousStance=state.stance;self.demoPreviousState="none";
    self.demoPreviousFPS=undefined;self.demoPreviousOnGround=true;
    self.demoFirstFrame=true;self.demoLastPresentedFrame=undefined;self.demoLoopPending=false;
    self.demoFPSCacheKey=undefined;self demoFPSReset();self.demoFPSFloor=undefined;self.demoFPSWaiting=false;
    self.demoRate=1;self.demoStepRemainder=0;self.demoStepRate=1;self.demoMenuRate=undefined;self.demoControlButtons=0;self.demoCheckpointRequest=0;
    self.demoMenuOpened=false;
    self demoDisplayStart();
    self.maxSpeed=0;
    self openCJ\huds\hudSpeedometer::_hideSpeedometer();
    self selectPlaybackDemo(demoID);
    if(!isDefined(self.demoStyle))self.demoStyle=0;
    edited=self demoPlaybackStyle(self.demoStyle,self.demoBegin,self.demoEnd);
    if(isDefined(edited)){self.demoBegin=edited[0];self.demoEnd=edited[1];}
    current=self skipPlaybackFrames(0);
    self skipPlaybackFrames(self.demoBegin-current);
    self.demoLinker.origin=self.origin;
    self linkTo(self.demoLinker,"",(0,0,0),(0,0,0));
    self disableWeapons();
    self openCJ\showRecords::onStartDemo();
    self openCJ\checkpointPointers::onStartDemo();
    self openCJ\huds\hudStatistics::onStartDemo();
    self openCJ\huds\hudProgressBar::onStartDemo();
    self openCJ\buttonPress::resetButtons();
    if(getCodVersion()==4)
    {
        self setClientCvar("opencj_demo_checkpointed",int(isDefined(self.demoCheckpointed) && self.demoCheckpointed));
        menu="opencj_demo";
        if(isDefined(self.clipEdit))menu="opencj_clipedit";
        else if(isDefined(self.clipPreview))menu="opencj_clips";
        self closeInGameMenu();self closeMenu();
        self setClientCvar("g_scriptMainMenu",menu);
        self.demoStatusText=undefined;self.demoMenuPaused=undefined;self.demoClipCursor=undefined;
        self demoUpdateOverlay();
        self openMenu(menu);
    }
    self sendLocalChatMessage("Demo: use the playback bar. Escape or Exit returns to your run.");
}

isPlayingDemo()
{
    if (isDefined(self.playingDemo))
    {
        return self.playingDemo;
    }
    
    return false;
}

onPlayerConnect()
{
    self thread demoMenuResponses();
    self openCJ\clips::onConnect();
    self.playingDemo = false;
    self openCJ\demoRecording::onConnect();
    self.playbackPaused = false;
    self.demoLinker = spawn("script_origin", (0, 0, 0));
}

onPlayPauseDemo()
{
    self.playbackPaused = !self.playbackPaused;
    if(self.playbackPaused)
    {
        self iprintln("Playback paused");
    }
    else
    {
        self iprintln("Playback resumed");
    }
}

_getDemoFrame(nrFramesToSkip, shouldSkipFails)
{
    if(shouldSkipFails)
    {
        newFrame = self skipPlaybackKeyFrames(nrFramesToSkip);
    }
    else
    {
        newFrame = self skipPlaybackFrames(nrFramesToSkip);
    }

    if(newFrame<self.demoBegin)newFrame=self skipPlaybackFrames(self.demoBegin-newFrame);
    if(newFrame>self.demoEnd)newFrame=self skipPlaybackFrames(self.demoEnd-newFrame);

    frame = spawnStruct();
    frame.origin = self readPlaybackFrame_origin();
    frame.angles = self readPlaybackFrame_angles();
    frame.saveNow = self readPlaybackFrame_saveNow();
    frame.loadNow = self readPlaybackFrame_loadNow();
    frame.rpgNow = self readPlaybackFrame_rpgNow();
    flags = self readPlaybackFrame_flags();

    frame.left = (flags & 1) != 0;
    frame.right = (flags & 2) != 0;
    frame.forward = (flags & 4) != 0;
    frame.back = (flags & 8) != 0;
    frame.sprint = (flags & 16) != 0;
    frame.jump = (flags & 32) != 0;

    frame.state = "none";
    if((flags & 128) != 0)
    {
        frame.state = "mantling";
    }
    else if((flags & 256) != 0)
    {
        frame.state = "ladder";
    }
    else if((flags & 64) != 0)
    {
        frame.state = "sprinting";
    }

    frame.stance = "stand"; //512
    if((flags & 1024) != 0)
    {
        frame.stance = "crouch";
    }
    else if((flags & 2048) != 0)
    {
        frame.stance = "prone";
    }

    if((flags & 4096) != 0)
    {
        frame.weapon = "rpg";
    }
    else
    {
        frame.weapon = "default";
    }
    frame.onGround = (flags & 8192) != 0;
    frame.bounce = (flags & 16384) != 0;
    
    frame.FPS = self readPlaybackFrame_FPS();
    frame.number = newFrame;

    return frame;
}

whilePlayingDemo()
{
    if (isDefined(self.demoExitRequested) && self.demoExitRequested)
    {
        self stopDemo();
        return;
    }
    self demoControls();
    // Keep the final frame selected for the entire snapshot. Loop only on
    // the next tick, so pausing/marking an endpoint agrees with the picture.
    if(isDefined(self.demoLoopPending) && self.demoLoopPending && !self.playbackPaused)
    {
        if(self.demoRate>0 && isDefined(self.demoLoopAt) && getTime()<self.demoLoopAt)
        {
            self demoApplyPresentation();
            return;
        }
        self.demoLoopPending=false;
        if(self.demoRate>0)
        {
            if(!isDefined(self.clipPlayback) && !isDefined(self.clipEdit) && !self openCJ\settings::getSetting("demoloop"))
            {self stopDemo();return;}
            current=self skipPlaybackFrames(0);
            self skipPlaybackFrames(self.demoBegin-current);
            self.demoFirstFrame=true;self.demoLastPresentedFrame=undefined;
            self.maxSpeed=0;
        }
    }
    seek=false;
    if(self.demoCheckpointRequest!=0)
    {
        if(isDefined(self.demoCheckpointed) && self.demoCheckpointed)
        {
            target=self demoSeekCheckpoint(self.demoCheckpointRequest);
            if(isDefined(target))
            {
                self.demoBegin=0;self.demoEnd=numberOfDemoFrames(self.demoID)-1;
                current=self skipPlaybackFrames(0);
                self skipPlaybackFrames(target-current);
                self.demoFirstFrame=true;self.demoLastPresentedFrame=undefined;
                seek=true;
            }
        }
        self.demoCheckpointRequest=0;
    }
    self demoUpdateOverlay();
    if(self.playbackPaused && !seek && !self.demoFirstFrame)
    {
        self demoApplyPresentation();
        return;
    }
    currFrame=self advanceDemoFrame();
    isInterpolatedFrame=currFrame.interpolated;
    self syncDemoFPSHistory(currFrame.number);

    self.demoLinker.origin = currFrame.origin;
    self setPlayerAngles(currFrame.angles);
    if(currFrame.stance!=self.demoPreviousStance)self setStance(currFrame.stance);
    detailed = self demoApplyPresentation();
    if (!detailed)
    {
        self openCJ\weapons::switchToDemoWeapon(currFrame.weapon == "rpg");
        self openCJ\huds\hudSpeedometer::_hideSpeedometer();
    }
    else
    {
        if(isDefined(self.clipEdit))self openCJ\huds\hudSpeedometer::_hideSpeedometer();
        else self openCJ\huds\hudSpeedometer::whileAlive();
        sequential = !isDefined(self.demoLastPresentedFrame) || currFrame.number == self.demoLastPresentedFrame + 1;
        if (isDefined(self.demoLastPresentedFrame) && sequential && !isInterpolatedFrame && !currFrame.loadNow)
            self demoPlayLanding();
        if (currFrame.rpgNow && sequential && !isInterpolatedFrame)
        {
            sound = self readPlaybackFrame_rpgSound();
            if (isDefined(sound))self playLocalSound(sound);
        }
    }
    if (!isInterpolatedFrame)self.demoLastPresentedFrame = currFrame.number;
    if(!isDefined(self.clipEdit))
        self openCJ\huds\hudOnScreenKeyboard::showKeyboardDemo(currFrame.forward, currFrame.back, currFrame.left, currFrame.right, currFrame.jump, currFrame.sprint);
    if(currFrame.stance != self.demoPreviousStance)
    {
        //self iprintlnbold("stance changed to " + currFrame.stance);
        self.demoPreviousStance = currFrame.stance;
    }
    if(currFrame.state != self.demoPreviousState)
    {
        /*if((currFrame.state == "sprinting" && self.demoPreviousState == "none") || (currFrame.state == "none" && self.demoPreviousState == "sprinting"))
            self iprintln("state changed to " + currFrame.state);
        else
            self iprintlnbold("state changed to " + currFrame.state);*/
        self.demoPreviousState = currFrame.state;
    }

    
    // Check if demo ended.
    self demoUpdateOverlay();
    if(!self.playbackPaused && ((self.demoRate>0 && currFrame.number >= self.demoEnd) || (self.demoRate<0 && currFrame.number <= self.demoBegin)))
    {
        self _endOfDemo();
    }
}

_endOfDemo()
{
    if(self.demoRate<0)
    {
        self.playbackPaused=true;
        self.demoStepRemainder=0;
        self demoUpdateOverlay();
        return;
    }
    // Let the client render the terminal snapshot before looping or exiting.
    // This is presentation time only; no frames are added to the recording.
    self.demoLoopPending=true;
    self.demoLoopAt=getTime()+200;
}

stopDemo(loadClipSave)
{
    if(!self isPlayingDemo())return;
    if(getCodVersion()==4)
    {
        self closeInGameMenu();
        self closeMenu();
        self setClientCvar("g_scriptMainMenu",level.menu["ingame"]);
    }
    self.demoMenuOpened=false;
    self demoDisplayStop();
    state=self.demoReturn;
    returnToSave=(!isDefined(loadClipSave) || loadClipSave) && (isDefined(self.clipEdit) || isDefined(self.clipPlayback) || isDefined(self.clipPreview));
    id=self.demoID;
    self unlink();
    // Disable playback prediction/freeze before the normal teleport runs Pmove.
    self demoEndPresentation();
    self openCJ\mapBoost::cancel();
    self setoriginandangles(state.origin,state.angles);
    self setVelocity(state.velocity);
    self setStance(state.stance);
    self enableWeapons();
    if(state.weapon!="none" && state.weapon!="")self switchToWeapon(state.weapon);
    self.demoStyle=undefined;
    self.currSpeed=state.speed;self.maxSpeed=state.maxSpeed;
    self openCJ\huds\hudSpeedometer::whileAlive();
    self.health=state.health;
    self.playerRuns_runPaused=state.paused;
    self openCJ\playTime::setTimePlayed(state.time);
    self.demoExitRequested=false;
    self.playingDemo=false;
    self openCJ\clips::onPlaybackStopped();
    self show();
    openCJ\playerCollision::onFrame();
    if(state.timerRunning)self openCJ\playTime::startTimer();
    self.activelyPlayingOrigin=state.origin;
    self.activelyPlayingTimer=getTime()+5000;
    self.previousOrigin=state.origin;
    self.previousOnground=self isOnGround();
    elapsed=getTime()-state.started;
    timestamps=[];timestamps[0]=level.statisticsStrings_lastExplosiveFiredTime;timestamps[1]=level.statisticsStrings_lastJumpTime;
    for(i=0;i<timestamps.size;i++)
        if(isDefined(self.statistics[timestamps[i]]))self.statistics[timestamps[i]]+=elapsed;
    self.eventQueue=[];
    self openCJ\buttonPress::resetButtons();
    self openCJ\checkpointPointers::showCheckpointPointers();
    self openCJ\showRecords::onSpawnPlayer();
    self openCJ\huds\hudStatistics::onSpawnPlayer();
    self openCJ\huds\hudProgressBar::onSpawnPlayer();
    self openCJ\huds\hudRunInfo::onSpawnPlayer();
    self openCJ\huds\hudFPSHistory::restoreLiveHistory(state);
    self openCJ\halfBeat::syncPolicy();
    self.demoID=undefined;self.demoReturn=undefined;
    self.demoFPSCacheKey=undefined;self demoFPSReset();self.demoFPSFloor=undefined;self.demoFPSWaiting=false;
    releaseCache(id);
    if(returnToSave && isDefined(self openCJ\savePosition::getSavedPosition(0)))
    {
        self openCJ\savePosition::resetBackwardsCount();
        self openCJ\events\loadPosition::main(0);
        self sendLocalChatMessage("Clip stopped. Loaded your saved position.");
    }
    else self sendLocalChatMessage("Demo stopped. Returned to your previous position and run.");
}

onDisconnect()
{
    self demoEndPresentation();
    self.demoStyle=undefined;
    self releasePending();
    self releaseSelection();
    if(self isPlayingDemo())releaseCache(self.demoID);
    self demoFPSReset();
    if(isDefined(self.demoLinker))self.demoLinker delete();
}


releasePending()
{
    if(isDefined(self.demoPendingId))
    {
        releaseCache(self.demoPendingId);
        self.demoPendingId=undefined;
    }
}

cancelRequest()
{
    self notify("demo_request");
    self releasePending();
    self releaseSelection();
}

demoControls()
{
    buttons=int(self leftButtonPressed())+2*int(self rightButtonPressed())+4*int(self leanLeftButtonPressed())+8*int(self leanRightButtonPressed());
    pressed=buttons & ~self.demoControlButtons;
    self.demoControlButtons=buttons;
    rates=[];rates[0]=.25;rates[1]=.5;rates[2]=1;rates[3]=2;rates[4]=4;
    index=2;rate=abs(self.demoRate);
    for(i=0;i<rates.size;i++)if(rates[i]==rate)index=i;
    if((pressed&1) && index>0)index--;
    if((pressed&2) && index<4)index++;
    if(pressed&3)self setDemoSpeed(""+rates[index]);
    if(pressed&4)self.demoCheckpointRequest=-1;
    if(pressed&8)self.demoCheckpointRequest=1;
}

// Signed rate is kept internally; the menu controls direction and speed
// independently. Changing either leaves an explicitly paused demo paused.
setDemoSpeed(value)
{
    if(value!="0.25" && value!="0.5" && value!="1" && value!="2" && value!="4")return false;
    rate=float(value);
    if(self.demoRate<0)rate=0-rate;
    self.demoRate=rate;self.demoStepRemainder=0;self.demoStepRate=rate;
    return true;
}

setDemoDirection(direction)
{
    reverse=self.demoRate<0;
    if(direction=="toggle")reverse=!reverse;
    else if(direction=="reverse")reverse=true;
    else if(direction=="forward")reverse=false;
    else return false;
    rate=abs(self.demoRate);if(reverse)rate=0-rate;
    self.demoRate=rate;self.demoStepRemainder=0;self.demoStepRate=rate;
    self.demoLoopPending=false;
    return true;
}

advanceDemoFrame()
{
    if(self.demoFirstFrame)
    {
        self.demoFirstFrame=false;self.demoStepRemainder=0;
        frame=self _getDemoFrame(0,false);frame.interpolated=false;
        return frame;
    }
    step=self demoFrameStep();
    frame=self _getDemoFrame(step,self.demoStyle!=0);frame.interpolated=step==0;
    if(self.demoStepRemainder>0)
    {
        direction=1;if(self.demoRate<0)direction=-1;
        next=self _getDemoFrame(direction,self.demoStyle!=0);
        // Peeking must leave native presentation, events and time on the anchor.
        self skipPlaybackFrames(frame.number-next.number);
        if(canBlendDemoFrames(frame,next))
        {
            fraction=self.demoStepRemainder;
            frame.origin=frame.origin+(next.origin-frame.origin)*fraction;
            frame.angles=(blendDemoAngle(frame.angles[0],next.angles[0],fraction),
                blendDemoAngle(frame.angles[1],next.angles[1],fraction),
                blendDemoAngle(frame.angles[2],next.angles[2],fraction));
        }
    }
    return frame;
}

canBlendDemoFrames(a,b)
{
    if(abs(a.number-b.number)!=1)return false;
    later=b;if(a.number>b.number)later=a;
    if(later.loadNow)return false;
    // Legacy recordings have no explicit map-portal marker. Large single-sample
    // jumps stay discrete rather than drawing a path through the map.
    return distance(a.origin,b.origin)<=256;
}

blendDemoAngle(a,b,fraction)
{
    delta=b-a;
    if(delta>180)delta-=360;else if(delta<(-180))delta+=360;
    return a+delta*fraction;
}

// FPS history follows recorded chronology, independently of displayed rate.
// Cache rendered strings (not mutable event structs) for bounded reverse/seek
// reuse. The live event builder remains at demoFPSStateFrame.
syncDemoFPSHistory(target)
{
    mode=self.fpsHistoryMode;if(!isDefined(mode))mode="detailed";
    if(mode=="off")return;
    if(isDefined(self.demoFPSWaiting) && self.demoFPSWaiting)
    {
        ground=(self readPlaybackFrame_flags() & 8192)!=0;
        departed=isDefined(self.demoFPSWaitGround) && self.demoFPSWaitGround && !ground;
        self.demoFPSWaitGround=ground;
        if(!departed)return;
        self.demoFPSWaiting=false;self.demoFPSFloor=target;
    }
    key=self.demoID+":"+self.demoStyle+":"+self.demoBegin+":"+self.demoEnd+":"+mode;
    if(!isDefined(self.demoFPSCacheKey) || self.demoFPSCacheKey!=key)
    {
        self.demoFPSCacheKey=key;self demoFPSReset();
        self.demoFPSStateFrame=undefined;
    }
    text=self demoFPSRead(target);
    if(isDefined(text))
    {
        self showDemoFPSCache(target);
        return;
    }
    self.fpsHistoryBatch=true;
    if(isDefined(self.demoFPSStateFrame) && target>self.demoFPSStateFrame && target-self.demoFPSStateFrame<=4)
    {
        // Cached reverse display never changes the event builder. Restore its
        // current text from those events before processing new source samples.
        self openCJ\huds\hudFPSHistory::_refresh();
        self skipPlaybackFrames(self.demoFPSStateFrame-(self skipPlaybackFrames(0)));
        previous=self.demoFPSStateFrame;
    }
    else
    {
        self demoFPSReset();
        // Walk to the oldest relevant native sample, then process forward one
        // sample at a time. Never retain an array of 512 full GSC frame structs.
        frame=self _getDemoFrame(-511,self.demoStyle!=0);
        floor=self.demoBegin;
        if(isDefined(self.demoFPSFloor) && self.demoFPSFloor>floor)floor=self.demoFPSFloor;
        if(target<floor){self skipPlaybackFrames(target-(self skipPlaybackFrames(0)));self.fpsHistoryBatch=false;self openCJ\huds\hudFPSHistory::_hide();return;}
        if(frame.number<floor){self skipPlaybackFrames(floor-frame.number);frame=self _getDemoFrame(0,false);}
        self openCJ\huds\hudFPSHistory::onDemoFrame(frame,false,false);
        if(frame.number>floor && !frame.onGround)
        {
            self.fpsHistoryTruncated=true;
            self openCJ\huds\hudFPSHistory::_refresh();
        }
        self cacheDemoFPS(frame.number);previous=frame.number;
    }
    while(previous<target)
    {
        frame=self _getDemoFrame(1,self.demoStyle!=0);
        if(frame.number<=previous)break;
        self openCJ\huds\hudFPSHistory::onDemoFrame(frame,frame.number==previous+1,false);
        self cacheDemoFPS(frame.number);
        previous=frame.number;
    }
    self.demoFPSStateFrame=target;self.demoFPSFloor=undefined;
    self skipPlaybackFrames(target-(self skipPlaybackFrames(0)));
    self.fpsHistoryBatch=false;
    self showDemoFPSCache(target);
}

cacheDemoFPS(frame)
{
    text=self.fpsHistoryText;
    if(!isDefined(self.fpsHistoryMode) || self.fpsHistoryMode=="detailed")text=self.fpsHistoryDetailedText;
    self demoFPSStore(frame,text);
}

showDemoFPSCache(frame)
{
    text=self demoFPSRead(frame);if(!isDefined(text))return;
    if(!isDefined(self.fpsHistoryMode) || self.fpsHistoryMode=="detailed")self.fpsHistoryDetailedText=text;
    else self.fpsHistoryText=text;
    self openCJ\huds\hudFPSHistory::_publish();
}

demoFrameStep()
{
    if(!isDefined(self.demoStepRate) || self.demoStepRate!=self.demoRate || !isDefined(self.demoStepRemainder))
    {
        self.demoStepRate=self.demoRate;self.demoStepRemainder=0;
    }
    self.demoStepRemainder+=abs(self.demoRate);
    step=int(self.demoStepRemainder);
    self.demoStepRemainder-=step;
    if(self.demoRate<0)step=0-step;
    return step;
}

demoTime(frame)
{
    seconds=int(frame/20);minutes=int(seconds/60);seconds=seconds%60;
    prefix="";if(seconds<10)prefix="0";
    return minutes+":"+prefix+seconds;
}

demoUpdateOverlay()
{
    frame=self skipPlaybackFrames(0);
    status="PLAY";if(self.demoRate<0)status="REVERSE";
    if(self.playbackPaused)status="PAUSED";
    rate=self.demoRate;if(rate<0)rate=0-rate;
    if(!isDefined(self.demoMenuRate) || self.demoMenuRate!=self.demoRate)
    {
        self.demoMenuRate=self.demoRate;
        self setClientCvar("opencj_demo_reverse",int(self.demoRate<0));
        self setClientCvar("opencj_demo_speed",rate);
    }
    elapsed=frame-self.demoBegin;duration=self.demoEnd-self.demoBegin;
    timing=self demoPlaybackTime(self.demoBegin,self.demoEnd);
    if(isDefined(timing)){elapsed=timing[0];duration=timing[1];}
    text=demoTime(elapsed)+" / "+demoTime(duration);
    if(self.playbackPaused)text="Paused  "+text;
    if(isDefined(self.clipEdit))
    {
        count=numberOfDemoFrames(self.demoID);
        text=status+" "+rate+"x   Frame "+(frame+1)+" / "+count;
        if(!isDefined(self.demoClipCursor) || self.demoClipCursor!=frame)
        {
            self.demoClipCursor=frame;
            self setClientCvar("opencj_clip_cursor_x",20+frame*600/count);
        }
    }
    if(!isDefined(self.demoStatusText) || self.demoStatusText!=text)
    {
        self.demoStatusText=text;
        self setClientCvar("opencj_demo_status",text);
    }
    if(!isDefined(self.demoMenuPaused) || self.demoMenuPaused!=self.playbackPaused)
    {
        self.demoMenuPaused=self.playbackPaused;
        self setClientCvar("opencj_demo_paused",int(self.playbackPaused));
    }
}

demoMenuResponses()
{
    self endon("disconnect");
    for(;;)
    {
        self waittill("menuresponse",menu,response);
        if(menu!="opencj_demo" || !self isPlayingDemo())continue;
        if(response=="opened")self.demoMenuOpened=true;
        else if(response=="stop")self.demoExitRequested=true;
        else if(response=="pause")self.playbackPaused=true;
        else if(response=="resume")self.playbackPaused=false;
        else if(response=="previous")self.demoCheckpointRequest=-1;
        else if(response=="next")self.demoCheckpointRequest=1;
        else if(response=="direction")self setDemoDirection("toggle");
        else
        {
            args=strTok(response,"_");
            if(args.size==2 && args[0]=="speed")
            {
                self setDemoSpeed(args[1]);
            }
        }
    }
}

// Presentation only: do not alter spectator interpolation or recorded motion.
demoDisplayStart()
{
    self openCJ\huds\hudTimeLimit::onStartDemo();
    self demoMovementHudInMenu(isDefined(self.clipEdit) || isDefined(self.clipPreview));
    keys=getArrayKeys(self.hudSpeed);
    for(i=0;i<keys.size;i++)
    {
        self.hudSpeed[keys[i]].archived=true;
    }
    if(getCodVersion()!=4)return;
    self setClientCvar("cg_drawSpectatorMessages",0);
    self.demoCaption=[];
    for(i=0;i<2;i++)
    {
        hud=newClientHudElem(self);
        hud.archived=true;hud.foreground=true;hud.hideWhenInMenu=false;
        hud.horzAlign="center";hud.vertAlign="top";
        hud.alignX="center";hud.alignY="top";
        hud.x=0;hud.y=8+i*16;hud.font="objective";hud.fontScale=1.4;hud.alpha=1;
        self.demoCaption[i]=hud;
    }
    if(isDefined(self.clipEdit))
    {
        self.demoCaption[0] setText("EDITING CLIP");
        self.demoCaption[1] setText(self.name);
    }
    else if(isDefined(self.clipDescription))
    {
        self.demoCaption[0] setText("VIEWING CLIP");
        self.demoCaption[1] setText(self.clipDescription);
    }
    else
    {
        self.demoCaption[0] setText("VIEWING DEMO");
        author="Unknown player";
        if(isDefined(self.demoAuthor))author=self.demoAuthor;
        self.demoCaption[1] setText(author);
    }
}

demoDisplayStop()
{
    // Playback returns without spawning, so explicitly clear its input overlay.
    self openCJ\huds\hudOnScreenKeyboard::_hideKeyboard();
    self openCJ\huds\hudTimeLimit::onStopDemo();
    self demoMovementHudInMenu(true);
    keys=getArrayKeys(self.hudSpeed);
    for(i=0;i<keys.size;i++)
    {
        self.hudSpeed[keys[i]].archived=false;
    }
    if(getCodVersion()!=4)return;
    if(isDefined(self.demoCaption))
        for(i=0;i<self.demoCaption.size;i++)self.demoCaption[i] destroy();
    self.demoCaption=undefined;
    self.demoAuthor=undefined;
    self setClientCvar("cg_drawSpectatorMessages",1);
}

// Native HUD suppression follows all client menus, including stock menus.
// The playback toolbar is the only exception; its movement HUD is useful.
demoMovementHudInMenu(hide)
{
    keys=getArrayKeys(self.hudSpeed);
    for(i=0;i<keys.size;i++)self.hudSpeed[keys[i]].hideWhenInMenu=hide;
    keys=getArrayKeys(self.keyboard);
    for(i=0;i<keys.size;i++)self.keyboard[keys[i]].hideWhenInMenu=hide;
}

// Archived demo captions are inherited by followers. Suppress only the stock
// spectator label while following playback, restoring it when the target changes.
spectatorCaption()
{
    if(getCodVersion()!=4)return;
    playback=false;
    if(self.sessionState=="spectator" && self.spectatorClient>=0)
    {
        target=getEntByNum(self.spectatorClient);
        playback=isDefined(target) && target isPlayingDemo();
    }
    if(!isDefined(self.demoSpectatorCaption) || self.demoSpectatorCaption!=playback)
    {
        self.demoSpectatorCaption=playback;
        self setClientCvar("cg_drawSpectatorMessages",int(!playback));
    }
}
