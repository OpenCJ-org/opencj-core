#include openCJ\util;

// Source histories are shared; display mode belongs to each spectator.
onInit()
{
    level.fpsHistoryHudName = "fpshistory";
    openCJ\huds\infiniteHuds::initInfiniteHud(level.fpsHistoryHudName);
    command=openCJ\settings::addSettingString("specfps",3,8,"detailed",
        "Spectator FPS mode: !specfps off, compact or detailed (default detailed)",::_onModeChanged);
    openCJ\commands_base::addAlias(command,"fpshistory");
}

onPlayerConnect()
{
    self.fpshistory=[];self.fpsHistoryText="";self.fpsHistoryDetailedText="";
    self.fpsHistoryEvents=[];self.fpsHistoryTruncated=false;self.fpsHistoryMode="detailed";
    self.fpsHistoryStyle=undefined;
    self.fpsHistoryForward=0;self.fpsHistoryRight=0;
    self.fpsHistoryAcceptedForward=0;self.fpsHistoryAcceptedRight=0;
    self.fpsHistoryPending=undefined;
    self.fpsHistoryAnchorForward=0;self.fpsHistoryAnchorRight=0;
    self openCJ\huds\base::initInfiniteHUD(level.fpsHistoryHudName,0,-85,"center","middle","center_safearea","center_safearea",
        true,"default",undefined,(1,1,1),undefined,undefined,1.5,false,0);

}

_onModeChanged(value)
{
    value=toLower(value);
    // Existing saved Live preferences use Detailed after retiring that renderer.
    if(value=="live")value="detailed";
    if(value!="off" && value!="compact" && value!="detailed")
    {
        self sendLocalChatMessage("Use !specfps off, compact or detailed",true);
        return false;
    }
    if(isDefined(self.fpsHistoryMode) && self.fpsHistoryMode==value)return true;
    self.fpsHistoryMode=value;
    self _hide();
    if(self openCJ\demos::isPlayingDemo())
    {
        self demoFPSReset();self.demoFPSCacheKey=undefined;
        self _clearDemoFPSHistory();
        self.demoFPSWaiting=value!="off";
        flags=self readPlaybackFrame_flags();
        self.demoFPSWaitGround=isDefined(flags) && (flags & 8192)!=0;
    }
    else
    {
        self.fpsHistoryWaitSource=self.fpsHistorySource;
        self.fpsHistoryWaitJump=0;
        if(isDefined(self.fpsHistorySource) && isDefined(self.fpsHistorySource.fpsHistoryJumpSerial))
            self.fpsHistoryWaitJump=self.fpsHistorySource.fpsHistoryJumpSerial;
    }
    return true;
}

_hide()
{
    if(!isDefined(self.hud))return;
    if(isDefined(self.hud[level.fpsHistoryHudName]))self openCJ\huds\base::disableHUD(level.fpsHistoryHudName);
}

onSpectatorClientChanged(newClient)
{
    if(!isDefined(newClient) || newClient openCJ\demos::isPlayingDemo())
    {
        self.fpsHistorySource=undefined;
        self hideAndClearFPSHistory();
        return;
    }
    self _render(newClient);
}
onSpawnSpectator(){self hideAndClearFPSHistory();}
onSpawnPlayer(){self hideAndClearFPSHistory();}
hideAndClearFPSHistory()
{
    self.fpsHistorySource=undefined;
    self _hide();
    self _clearFPSHistory();
}

inputLabel(forward,right)
{
    label="";
    if(forward>0)label="W";else if(forward<0)label="S";
    if(right<0)label+="A";else if(right>0)label+="D";
    if(label=="")label="None";
    return label;
}

// Native callback supplies complete held input, including releases.
onMovementState(forward,right,time,onGround)
{
    if(self openCJ\demos::isPlayingDemo())return;
    self _movement(forward,right,time,onGround);
}

_movement(forward,right,time,onGround,incomingFPS)
{
    // Confirm the previous held input before processing its release. Demo time
    // advances by recorded samples; live input also has a cancellable timer.
    if(isDefined(self.fpsHistoryPending) && time-self.fpsHistoryPending.time>=150)
        self _confirmPendingInput();
    wasGround=self.fpsHistoryInputGround;
    self.fpsHistoryForward=forward;self.fpsHistoryRight=right;self.fpsHistoryInputGround=onGround;
    if(onGround || !isDefined(wasGround) || wasGround)
    {
        self _flushPendingInput();
        self.fpsHistoryAcceptedForward=forward;self.fpsHistoryAcceptedRight=right;
        self.fpsHistoryAnchorForward=forward;self.fpsHistoryAnchorRight=right;
        return;
    }
    if(!isDefined(self.fpsHistoryText) || self.fpsHistoryText=="")return;
    if(isDefined(self.fpsHistoryPending))
    {
        if(self.fpsHistoryPending.forward==forward && self.fpsHistoryPending.right==right)return;
        self _flushPendingInput();
    }
    if(self.fpsHistoryAcceptedForward==forward && self.fpsHistoryAcceptedRight==right)return;
    fps=incomingFPS;
    if(!isDefined(fps))fps=self.fpshistory["shortfps"];
    if(!isDefined(fps))fps=openCJ\fps::getShortFPS(self openCJ\fps::getCurrentFPS());
    self notify("fpshistory_pending");
    pending=spawnStruct();pending.forward=forward;pending.right=right;
    pending.time=time;pending.fps=fps;self.fpsHistoryPending=pending;
    if(!self openCJ\demos::isPlayingDemo())self thread _waitPendingInput();
}

_waitPendingInput()
{
    self endon("disconnect");self endon("fpshistory_clear");self endon("fpshistory_pending");
    wait .15;
    if(!isDefined(self.fpsHistoryPending) || self.fpsHistoryInputGround || self openCJ\demos::isPlayingDemo())return;
    self _confirmPendingInput();
}

_cancelPendingInput()
{
    self notify("fpshistory_pending");
    self.fpsHistoryPending=undefined;
}

_flushPendingInput()
{
    if(!isDefined(self.fpsHistoryPending))return;
    fps=self.fpsHistoryPending.fps;
    self _cancelPendingInput();
    // A rejected short tap keeps its FPS changes, without a new strafe.
    self _appendRecordedFPS(fps);
}

_confirmPendingInput()
{
    if(!isDefined(self.fpsHistoryPending))return;
    pending=self.fpsHistoryPending;
    // Do not notify here: this can be called by the waiting thread itself.
    self.fpsHistoryPending=undefined;
    forward=pending.forward;right=pending.right;
    self.fpsHistoryAcceptedForward=forward;self.fpsHistoryAcceptedRight=right;
    flags=strafeTransition(self.fpsHistoryAnchorForward,self.fpsHistoryAnchorRight,forward,right);
    if((flags&1) || (forward!=0 && right!=0) || (self.fpsHistoryAnchorForward==0 && self.fpsHistoryAnchorRight==0))
    {
        self.fpsHistoryAnchorForward=forward;self.fpsHistoryAnchorRight=right;
    }
    self _action("move",pending.fps,(flags&1)!=0,pending.time,pending.firstFPSChange);
}

onFPSChanged(newFPS)
{
    if(self openCJ\demos::isPlayingDemo())return;
    self notify("fpshistory_fpschanged");
    fps=openCJ\fps::getShortFPS(newFPS);
    self.fpshistory["shortfps"]=fps;
    if(!self isOnGround())self _recordFPS(fps);
}

_beginHistory(fps)
{
    self markNextJump();
    self _resetHistory();
    self.fpshistory["shortfps"]=fps;
    self.fpsHistoryAnchorForward=self.fpsHistoryForward;
    self.fpsHistoryAnchorRight=self.fpsHistoryRight;
    self _action("move",fps,false);
}

_action(kind,fps,switched,inputTime,firstFPSChange)
{
    if(kind!="move" && isDefined(self.fpsHistoryPending))
    {
        // Split FPS at the marker, but keep timing the held input. Native input
        // callbacks only report changes, so dropping this candidate would lose
        // a continuing strafe when no further key event arrives after a bounce.
        self _appendRecordedFPS(self.fpsHistoryPending.fps);
        self.fpsHistoryPending.fps=self.fpshistory["shortfps"];
        self.fpsHistoryPending.firstFPSChange=undefined;
    }
    if(!isDefined(self.fpsHistoryEvents))self.fpsHistoryEvents=[];
    count=self.fpsHistoryEvents.size;
    now=self historyTime();
    if(count>0)self.fpsHistoryEvents[count-1].ended=now;
    event=spawnStruct();event.kind=kind;event.fps=fps;
    event.keys=inputLabel(self.fpsHistoryAcceptedForward,self.fpsHistoryAcceptedRight);
    event.forward=self.fpsHistoryAcceptedForward;event.right=self.fpsHistoryAcceptedRight;
    event.switched=switched;event.started=now;
    event.inputTime=now;if(isDefined(inputTime))event.inputTime=inputTime;
    event.firstFPSChange=firstFPSChange;
    if(self openCJ\demos::isPlayingDemo() && isDefined(self.fpsHistoryViewPhase))
        event.viewPhase=self.fpsHistoryViewPhase;
    if(kind=="bounce")
    {
        event.incomingFPS=self.fpshistory["shortfps"];
        self.fpsHistoryBounceDisplayAt=now+150;
        if(!self openCJ\demos::isPlayingDemo())self thread _waitBounceDisplay();
    }
    self.fpsHistoryEvents[count]=event;
    if(self.fpsHistoryEvents.size>64)
    {
        kept=[];for(i=1;i<self.fpsHistoryEvents.size;i++)kept[kept.size]=self.fpsHistoryEvents[i];
        self.fpsHistoryEvents=kept;self.fpsHistoryTruncated=true;
    }
    self _refresh();
}

historyTime()
{
    if(self openCJ\demos::isPlayingDemo() && isDefined(self.fpsHistoryDemoTime))return self.fpsHistoryDemoTime;
    return getTime();
}

_recordFPS(fps)
{
    self.fpshistory["shortfps"]=fps;
    if(isDefined(self.fpsHistoryPending))
    {
        previous=self.fpsHistoryPending.fps;
        self.fpsHistoryPending.fps=mergeActionFPS(previous,fps);
        if(previous.size==1 && self.fpsHistoryPending.fps.size>1)
            self.fpsHistoryPending.firstFPSChange=self historyTime();
        return;
    }
    self _appendRecordedFPS(fps);
}

_appendRecordedFPS(fps)
{
    if(!isDefined(self.fpsHistoryEvents) || self.fpsHistoryEvents.size==0)
    {
        self _action("move",fps,false);
        return;
    }
    event=self.fpsHistoryEvents[self.fpsHistoryEvents.size-1];
    if(event.kind!="move"){self _action("move",fps,false);return;}
    merged=mergeActionFPS(event.fps,fps);
    if(merged==event.fps)return;
    if(event.fps.size==1 && merged.size>1)event.firstFPSChange=self historyTime();
    event.fps=merged;
    self _refresh();
}

mergeActionFPS(history,part)
{
    merged=mergePhaseFPS(history,part);
    if(merged.size>480)merged="..."+getSubStr(merged,merged.size-477);
    return merged;
}

renderHistory(events,detailed,truncated)
{
    if(detailed)return renderDetailed(phaseActions(events),truncated);
    parts=[];previousFPS="";previousKind="";
    for(i=0;i<events.size;i++)
    {
        event=events[i];part="";
        if(event.kind=="bounce")part="-";
        else if(event.kind=="bhop")part="/";
        else
        {
            fps=event.fps;
            // Compact describes FPS transitions, independent of strafe phases.
            if(previousKind=="move" && fps.size>0 && previousFPS==fps[0])fps=getSubStr(fps,1);
            part+=fps;
        }
        parts[parts.size]=part;
        if(event.fps.size>0)previousFPS=event.fps[event.fps.size-1];
        previousKind=event.kind;
    }
    result="";cut=truncated;
    for(i=parts.size-1;i>=0;i--)
    {
        // Reserve the visible marker while selecting complete newest entries.
        if(result.size+parts[i].size>509){cut=true;break;}
        result=parts[i]+result;
    }
    if(cut)result="..."+result;
    return result;
}

// Six recent, whole phases; explicit labels survive color-blind viewing.
// CoD's inline text palette uses cyan/gold for bounce/bhop.
renderDetailed(actions,truncated)
{
    start=int(max(0,actions.size-6));result="";
    if(start>0 || truncated)result="^7... > ";
    for(i=start;i<actions.size;i++)
    {
        event=actions[i];
        if(i>start)result+=" ^7> ";
        if(event.kind=="bounce")result+="^5BOUNCE^7";
        else if(event.kind=="bhop")result+="^3BHOP^7";
        else
        {
            color="^7";
            if(isSubStr(event.keys,"A"))color="^6";
            else if(isSubStr(event.keys,"D"))color="^2";
            fps=event.fps;
            if(fps.size>8)fps="..."+getSubStr(fps,fps.size-5);
            result+=color+event.keys+" ^7"+fps;
        }
    }
    return result;
}

// Only the first 150 ms after a bounce may be attached to the new strafe.
// Keep raw source actions intact: this is a shared display projection, not a
// sampling blackout. Every distinct FPS change remains in the projected string.
bounceDisplayEvents(events,now,pending)
{
    result=[];
    for(i=0;i<events.size;i++)
    {
        event=events[i];
        if(event.kind!="bounce"){result[result.size]=event;continue;}
        result[result.size]=event;
        if(i+1>=events.size || events[i+1].kind!="move")continue;
        first=events[i+1];
        // Briefly buffer the bounce exit. A candidate beginning in the window
        // must still pass the existing 150 ms input-duration test before grouping.
        waiting=now<event.started+150 && (!isDefined(event.displayReady) || !event.displayReady);
        if(isDefined(pending) && pending.time<=event.started+150)waiting=true;
        if(waiting)break;
        copy=spawnStruct();copy.kind="move";copy.fps=first.fps;
        copy.keys=first.keys;copy.forward=first.forward;copy.right=first.right;
        copy.switched=first.switched;copy.started=first.started;copy.viewPhase=first.viewPhase;
        // A carry-over value already shown before the bounce is not a new FPS
        // step. Remove only that leading value, only when its first change is
        // inside the window. Rapid changes after it (e.g. 3->2->3) all survive.
        if(isDefined(event.incomingFPS) && copy.fps.size>1 && copy.fps[0]==event.incomingFPS &&
           isDefined(first.firstFPSChange) && first.firstFPSChange<=event.started+150)
            copy.fps=getSubStr(copy.fps,1);
        i++;
        if(i+1<events.size && events[i+1].kind=="move")
        {
            next=events[i+1];
            if(isDefined(next.inputTime) && next.inputTime<=event.started+150 && next.switched)
            {
                copy.fps=mergePhaseFPS(copy.fps,next.fps);
                copy.keys=next.keys;copy.forward=next.forward;copy.right=next.right;
                copy.viewPhase=next.viewPhase;copy.switched=false;i++;
            }
        }
        result[result.size]=copy;
    }
    return result;
}

_waitBounceDisplay()
{
    self endon("disconnect");self endon("fpshistory_clear");
    wait .15;
    self.fpsHistoryBounceDisplayAt=undefined;
    self _refresh();
}

_refresh()
{
    displayed=bounceDisplayEvents(self.fpsHistoryEvents,self historyTime(),self.fpsHistoryPending);
    self.fpsHistoryText=renderHistory(displayed,false,self.fpsHistoryTruncated);
    if(!isDefined(self.fpsHistoryStyle))self.fpsHistoryStyle=inferStrafeStyle(displayed);
    self.fpsHistoryDetailedText=renderDetailed(phaseActions(displayed,self.fpsHistoryStyle),self.fpsHistoryTruncated);
    self _publish();
}

_publish()
{
    if(isDefined(self.fpsHistoryBatch) && self.fpsHistoryBatch)return;
    if(self openCJ\demos::isPlayingDemo()){self _render(self);return;}
    if(self.sessionState!="playing")return;
    spectators=self getSpectatorList(false);
    for(i=0;i<spectators.size;i++)spectators[i] _render(self);
}

_render(source)
{
    if(!self openCJ\demos::isPlayingDemo() && isDefined(self.fpsHistoryWaitJump))
    {
        serial=0;if(isDefined(source.fpsHistoryJumpSerial))serial=source.fpsHistoryJumpSerial;
        if((!isDefined(self.fpsHistoryWaitSource) || self.fpsHistoryWaitSource==source) && serial==self.fpsHistoryWaitJump)
        {self _hide();return;}
        self.fpsHistoryWaitJump=undefined;self.fpsHistoryWaitSource=undefined;
    }
    self.fpsHistorySource=source;
    mode=self.fpsHistoryMode;if(!isDefined(mode))mode="detailed";
    text=source.fpsHistoryText;
    if(mode=="detailed" && isDefined(source.fpsHistoryDetailedText))text=source.fpsHistoryDetailedText;
    if(mode=="off" || !isDefined(text) || text==""){self _hide();return;}
    self.hud[level.fpsHistoryHudName] openCJ\huds\infiniteHuds::setInfiniteHudText(text,self,false);
    self openCJ\huds\base::enableHUD(level.fpsHistoryHudName);
}

// A single A/D tap cannot establish halfbeat. Lock the first confirmed
// fullbeat pair or halfbeat return pattern for this airborne history.
inferStrafeStyle(events)
{
    diagonal=undefined;previous=undefined;before=undefined;
    for(j=0;j<events.size;j++)
    {
        event=events[j];
        if(event.kind!="move" || event.right==0)continue;
        if(event.forward!=0)
        {
            if(isDefined(diagonal) && diagonal.forward==event.forward && diagonal.right==(0-event.right))
                return makeStrafeStyle("fullbeat",event.forward,event.right);
            diagonal=event;
        }
        if(isDefined(previous) && previous.forward==event.forward && previous.right==event.right)continue;
        if(isDefined(before) && before.forward==event.forward && before.right==event.right)
        {
            if(event.forward!=0 && previous.forward==0 && previous.right==(0-event.right))
                return makeStrafeStyle("halfbeat",event.forward,event.right);
            if(event.forward==0 && previous.forward!=0 && previous.right==(0-event.right))
                return makeStrafeStyle("halfbeat",previous.forward,previous.right);
        }
        before=previous;previous=event;
    }
    return undefined;
}

makeStrafeStyle(kind,forward,right)
{
    style=spawnStruct();style.kind=kind;style.forward=forward;style.right=right;
    return style;
}

phaseActions(events,style)
{
    if(!isDefined(style))style=inferStrafeStyle(events);
    inferred=style;
    phases=[];phaseForward=0;phaseRight=0;pendingFPS="";pendingStart=undefined;
    for(j=0;j<events.size;j++)
    {
        event=events[j];current=undefined;
        if(phases.size>0)current=phases[phases.size-1];
        if(event.kind=="move")
        {
            style=inferred;
            if(isDefined(event.viewPhase) && event.viewPhase!=0)
            {
                kind="fullbeat";if((event.viewPhase & 48)==32)kind="halfbeat";
                else if((event.viewPhase & 48)==48)kind="invert";
                f=1;if(event.viewPhase & 8)f=-1;
                r=1;if(event.viewPhase & 1)r=-1;
                style=makeStrafeStyle(kind,f,r);
            }
            forward=event.forward;right=event.right;
            hasPhase=phaseForward!=0 || phaseRight!=0;
            neutral=forward==0 && right==0;
            if(!hasPhase && neutral)continue;
            accepted=false;
            if(isDefined(style) && style.kind=="invert")
                accepted=forward==0 && right!=0;
            else if(isDefined(style) && style.kind=="halfbeat")
                accepted=(forward==style.forward && right==style.right) || (forward==0 && right==(0-style.right));
            else
                accepted=forward!=0 && right!=0 && (!isDefined(style) || forward==style.forward);

            if(!hasPhase && isDefined(style) && !accepted)
            {
                // The bounded raw history may begin with a release. Do not
                // resurrect that release as the established style's first row.
                pendingFPS=mergePhaseFPS(pendingFPS,event.fps);
                if(!isDefined(pendingStart))pendingStart=event.started;
                continue;
            }
            switched=false;upgrade=false;
            if(!hasPhase)
            {
                // Keep the takeoff input until a strafe style is established.
                phaseForward=forward;phaseRight=right;
            }
            else if(accepted)
            {
                upgrade=phaseForward==0 || phaseRight==0;
                if(isDefined(style) && style.kind=="halfbeat")
                    upgrade=!((phaseForward==style.forward && phaseRight==style.right) || (phaseForward==0 && phaseRight==(0-style.right)));
                // Converted samples carry an already confirmed native phase.
                // A preserved takeoff must remain its own row when HB begins.
                if(isDefined(event.viewPhase) && event.viewPhase!=0)upgrade=false;
                switched=!upgrade && (phaseForward!=forward || phaseRight!=right);
                phaseForward=forward;phaseRight=right;
            }
            if(isDefined(current) && current.kind=="move" && !switched)
            {
                if(upgrade)current.keys=inputLabel(phaseForward,phaseRight);
                current.fps=mergePhaseFPS(current.fps,event.fps);
                continue;
            }
            next=spawnStruct();next.kind="move";
            next.keys=inputLabel(phaseForward,phaseRight);next.fps=mergePhaseFPS(pendingFPS,event.fps);
            next.started=event.started;
            if(isDefined(pendingStart))next.started=pendingStart;
            pendingFPS="";pendingStart=undefined;
        }
        else
        {
            next=spawnStruct();next.kind=event.kind;next.keys="";next.fps="";
            next.started=event.started;
        }
        if(isDefined(current))current.ended=next.started;
        phases[phases.size]=next;
    }
    return phases;
}

mergePhaseFPS(history,part)
{
    if(history.size>0 && part.size>0 && history[history.size-1]==part[0])part=getSubStr(part,1);
    return appendFPSHistory(history,part);
}

onBounced()
{
    if(self openCJ\demos::isPlayingDemo())return;
    self resetStrafeTracking();
    self thread _separator("bounce");
}
_separator(kind)
{
    self endon("disconnect");self endon("fpshistory_clear");
    if(self.fpsHistoryText=="")return;
    self _action(kind,"",false);
    self endon("fpshistory_fpschanged");
    wait 0.15;
    self _recordFPS(openCJ\fps::getShortFPS(self openCJ\fps::getCurrentFPS()));
}
onLoaded()
{
    if(self openCJ\demos::isPlayingDemo())return;
    self resetStrafeTracking();
    self _clearFPSHistory();
}
onOnGround(onGround)
{
    if(self openCJ\demos::isPlayingDemo())return;
    self thread _onOnGroundThread(onGround);
}
_onOnGroundThread(onGround)
{
    self endon("disconnect");self notify("fpshistory_ongroundchange");self endon("fpshistory_ongroundchange");
    if(onGround)
    {
        self _flushPendingInput();
        wait 2;
        self _clearFPSHistory();
    }
    else if(self openCJ\events\onGroundChanged::getLastGroundEnterTime()>=getTime()-250 && self.fpsHistoryText!="")
        self _onBhopThread();
    else self _beginHistory(openCJ\fps::getShortFPS(self openCJ\fps::getCurrentFPS()));
}
_onBhopThread(){self markNextJump();self _separator("bhop");}

_resetHistory()
{
    self notify("fpshistory_clear");
    self.fpsHistoryBounceDisplayAt=undefined;
    self _cancelPendingInput();
    self.fpsHistoryAcceptedForward=self.fpsHistoryForward;self.fpsHistoryAcceptedRight=self.fpsHistoryRight;
    self.fpsHistoryEvents=[];self.fpsHistoryTruncated=false;
    self.fpsHistoryStyle=undefined;
    self.fpsHistoryText="";self.fpsHistoryDetailedText="";
    self.fpsHistoryAnchorForward=0;self.fpsHistoryAnchorRight=0;
}
_clearFPSHistory()
{
    self _resetHistory();
    spectators=self getSpectatorList(false);
    for(i=0;i<spectators.size;i++)spectators[i] _hide();
}

// Keep the bounded raw-string helpers for callers restoring older history.
appendFPSHistory(history,text)
{
    limit=512;marker="...";
    if(history.size+text.size<=limit)return history+text;
    remaining=limit-marker.size;
    if(text.size>=remaining)return marker+getSubStr(text,text.size-remaining);
    remaining-=text.size;
    return marker+getSubStr(history,history.size-remaining)+text;
}
_setFPSHistory(text)
{
    if(self openCJ\demos::isPlayingDemo())return;
    self _cancelPendingInput();
    self.fpsHistoryEvents=[];
    self.fpsHistoryText=appendFPSHistory("",text);self.fpsHistoryDetailedText=self.fpsHistoryText;
    self _publish();
}
_addFPSHistory(text){self _setFPSHistory(appendFPSHistory(self.fpsHistoryText,text));}
_clearDemoFPSHistory()
{
    self _resetHistory();
    if(!isDefined(self.fpsHistoryBatch) || !self.fpsHistoryBatch)self _hide();
}
// Process recorded time, not wall time: slow motion, seeks and reverse use this same path.
applyRecordedFrame(frame,sequential,interpolated)
{
    if(interpolated)return;
    self.fpsHistoryViewPhase=frame.techniquePhase;
    f=int(frame.forward)-int(frame.back);r=int(frame.right)-int(frame.left);
    fps=openCJ\fps::getShortFPS(frame.FPS);
    if(!sequential || frame.loadNow)
    {
        self notify("fpshistory_ongroundchange");
        self _clearDemoFPSHistory();
        self.fpsHistoryForward=f;self.fpsHistoryRight=r;self.fpsHistoryInputGround=frame.onGround;
        self.fpsHistoryDemoTime=0;self.fpsHistoryDemoLandTime=undefined;
        if(!frame.onGround)self _beginHistory(fps);
    }
    else
    {
        // OpenCJ recordings contain one sample per 50 ms, not per client FPS.
        self.fpsHistoryDemoTime+=50;
        wasGround=self.fpsHistoryInputGround;
        self _movement(f,r,self.fpsHistoryDemoTime,frame.onGround,fps);
        if(wasGround && !frame.onGround)
        {
            self notify("fpshistory_ongroundchange");
            if(isDefined(self.fpsHistoryDemoLandTime) && self.fpsHistoryDemoTime-self.fpsHistoryDemoLandTime<250 && self.fpsHistoryText!="")
                self _action("bhop","",false);
            else self _beginHistory(fps);
        }
        else if(!wasGround && frame.onGround)
        {
            self.fpsHistoryDemoLandTime=self.fpsHistoryDemoTime;
        }
        if(frame.onGround && isDefined(self.fpsHistoryDemoLandTime) &&
            self.fpsHistoryDemoTime-self.fpsHistoryDemoLandTime>=2000 && self.fpsHistoryText!="")
            self _clearDemoFPSHistory();
        if(frame.bounce && !frame.onGround)self _action("bounce","",false);
        if(!frame.onGround)
        {
            if(self.fpshistory["shortfps"]!=fps)self notify("fpshistory_fpschanged");
            self _recordFPS(fps);
        }
    }
    if(isDefined(self.fpsHistoryBounceDisplayAt) && self.fpsHistoryDemoTime>=self.fpsHistoryBounceDisplayAt)
    {
        self.fpsHistoryBounceDisplayAt=undefined;
        self _refresh();
    }
    self.demoPreviousOnGround=frame.onGround;self.demoPreviousFPS=frame.FPS;
}

restoreLiveHistory(state)
{
    self notify("fpshistory_ongroundchange");
    self.fpshistory=state.fpshistory;self.fpsHistoryText=state.fpsHistoryText;
    self.fpshistory["shortfps"]=state.fpsHistoryShortFPS;
    self.fpsHistoryEvents=state.fpsHistoryEvents;
    self.fpsHistoryTruncated=state.fpsHistoryTruncated;
    self.fpsHistoryStyle=state.fpsHistoryStyle;
    self _cancelPendingInput();
    self.fpsHistoryAcceptedForward=0;self.fpsHistoryAcceptedRight=0;
    if(self.fpsHistoryEvents.size>0)
    {
        last=self.fpsHistoryEvents[self.fpsHistoryEvents.size-1];
        self.fpsHistoryAcceptedForward=last.forward;self.fpsHistoryAcceptedRight=last.right;
    }
    self.fpsHistoryForward=self.fpsHistoryAcceptedForward;self.fpsHistoryRight=self.fpsHistoryAcceptedRight;
    self.fpsHistoryInputGround=undefined;
    self.fpsHistoryAnchorForward=0;self.fpsHistoryAnchorRight=0;
    self resetStrafeTracking();
    self _hide();
    if(self.fpsHistoryEvents.size>0)self _refresh();
    else
    {
        self.fpsHistoryDetailedText=self.fpsHistoryText;
        self _publish();
    }
}

markNextJump()
{
    if(!isDefined(self.fpsHistoryJumpSerial))self.fpsHistoryJumpSerial=0;
    self.fpsHistoryJumpSerial++;
}
