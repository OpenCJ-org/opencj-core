#include openCJ\util;

// Source histories are shared; display mode belongs to each spectator.
onInit()
{
    level.fpsHistoryHudName = "fpshistory";
    initializeHistoryLimits();
    openCJ\huds\infiniteHuds::initInfiniteHud(level.fpsHistoryHudName);
    minimumModeLength = 3;
    maximumModeLength = 8;
    command = openCJ\settings::addSettingString(
        "specfps", minimumModeLength, maximumModeLength, "detailed",
        "Spectator FPS mode: !specfps off, compact or detailed (default detailed)",
        ::_onModeChanged);
    openCJ\commands_base::addAlias(command, "fpshistory");
}

// Keep live timers and recorded-time comparisons on the same policy.
initializeHistoryLimits()
{
    limits = spawnStruct();
    limits.inputConfirmationMs = 150;
    limits.bounceGroupingMs = 150;
    limits.separatorFPSDelayMs = 150;
    limits.bhopWindowMs = 250;
    limits.landingExpiryMs = 2000;
    limits.sampleIntervalMs = 50; // Stored demos contain 20 samples per second.
    limits.maxEvents = 64;
    limits.historyCharacters = 512;
    limits.actionCharacters = 480; // Leave space for other actions and separators.
    limits.detailedPhases = 6;
    limits.detailedFPSCharacters = 8;
    limits.truncationMarker = "...";
    level.fpsHistoryLimits = limits;
}

onPlayerConnect()
{
    self.fpshistory = [];
    self.fpsHistoryText = "";
    self.fpsHistoryDetailedText = "";
    self.fpsHistoryEvents = [];
    self.fpsHistoryTruncated = false;
    self.fpsHistoryMode = "detailed";
    self.fpsHistoryStyle = undefined;
    self.fpsHistoryForward = 0;
    self.fpsHistoryRight = 0;
    self.fpsHistoryAcceptedForward = 0;
    self.fpsHistoryAcceptedRight = 0;
    self.fpsHistoryPending = undefined;
    self.fpsHistoryAnchorForward = 0;
    self.fpsHistoryAnchorRight = 0;
    self openCJ\huds\base::initInfiniteHUD(
        level.fpsHistoryHudName, 0, -85, "center", "middle", "center_safearea", "center_safearea",
        true, "default", undefined, (1, 1, 1), undefined, undefined, 1.5, false, 0);
}

_onModeChanged(value)
{
    value = toLower(value);
    // Existing saved Live preferences use Detailed after retiring that renderer.
    if(value == "live")
    {
        value = "detailed";
    }
    if(value != "off" && value != "compact" && value != "detailed")
    {
        self sendLocalChatMessage("Use !specfps off, compact or detailed", true);
        return false;
    }
    if(isDefined(self.fpsHistoryMode) && self.fpsHistoryMode == value)
    {
        return true;
    }
    self.fpsHistoryMode = value;
    self _hide();
    if(self openCJ\demos::isPlayingDemo())
    {
        self demoFPSReset();
        self.demoFPSCacheKey = undefined;
        self _clearDemoFPSHistory();
        self.demoFPSWaiting = value != "off";
        flags = self readPlaybackFrame_flags();
        self.demoFPSWaitGround = isDefined(flags) && (flags & level.demoFlags.onGround) != 0;
    }
    else
    {
        self.fpsHistoryWaitSource = self.fpsHistorySource;
        self.fpsHistoryWaitJump = 0;
        if(isDefined(self.fpsHistorySource) &&
           isDefined(self.fpsHistorySource.fpsHistoryJumpSerial))
        {
            self.fpsHistoryWaitJump = self.fpsHistorySource.fpsHistoryJumpSerial;
        }
    }
    return true;
}

_hide()
{
    if(!isDefined(self.hud))
    {
        return;
    }
    if(isDefined(self.hud[level.fpsHistoryHudName]))
    {
        self openCJ\huds\base::disableHUD(level.fpsHistoryHudName);
    }
}

onSpectatorClientChanged(newClient)
{
    if(!isDefined(newClient) || newClient openCJ\demos::isPlayingDemo())
    {
        self.fpsHistorySource = undefined;
        self hideAndClearFPSHistory();
        return;
    }
    self _render(newClient);
}

onSpawnSpectator()
{
    self hideAndClearFPSHistory();
}

onSpawnPlayer()
{
    self hideAndClearFPSHistory();
}

hideAndClearFPSHistory()
{
    self.fpsHistorySource = undefined;
    self _hide();
    self _clearFPSHistory();
}

inputLabel(forward, right)
{
    label = "";
    if(forward > 0)
    {
        label = "W";
    }
    else if(forward < 0)
    {
        label = "S";
    }
    if(right < 0)
    {
        label += "A";
    }
    else if(right > 0)
    {
        label += "D";
    }
    if(label == "")
    {
        label = "None";
    }
    return label;
}

// Native callback supplies complete held input, including releases.
onMovementState(forward, right, sampleTimeMs, onGround)
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self _movement(forward, right, sampleTimeMs, onGround);
}

// Debounce short airborne taps while retaining their FPS changes.
_movement(forward, right, sampleTimeMs, onGround, incomingFPS)
{
    // Confirm the previous held input before processing its release. Demo time
    // advances by recorded samples; live input also has a cancellable timer.
    if(isDefined(self.fpsHistoryPending) &&
       sampleTimeMs - self.fpsHistoryPending.time >= level.fpsHistoryLimits.inputConfirmationMs)
    {
        self _confirmPendingInput();
    }
    wasOnGround = self.fpsHistoryInputGround;
    self.fpsHistoryForward = forward;
    self.fpsHistoryRight = right;
    self.fpsHistoryInputGround = onGround;
    if(onGround || !isDefined(wasOnGround) || wasOnGround)
    {
        self _flushPendingInput();
        self.fpsHistoryAcceptedForward = forward;
        self.fpsHistoryAcceptedRight = right;
        self.fpsHistoryAnchorForward = forward;
        self.fpsHistoryAnchorRight = right;
        return;
    }
    if(!isDefined(self.fpsHistoryText) || self.fpsHistoryText == "")
    {
        return;
    }
    if(isDefined(self.fpsHistoryPending))
    {
        if(self.fpsHistoryPending.forward == forward && self.fpsHistoryPending.right == right)
        {
            return;
        }
        self _flushPendingInput();
    }
    if(self.fpsHistoryAcceptedForward == forward && self.fpsHistoryAcceptedRight == right)
    {
        return;
    }
    fps = incomingFPS;
    if(!isDefined(fps))
    {
        fps = self.fpshistory["shortfps"];
    }
    if(!isDefined(fps))
    {
        fps = openCJ\fps::getShortFPS(self openCJ\fps::getCurrentFPS());
    }
    self notify("fpshistory_pending");
    pending = spawnStruct();
    pending.forward = forward;
    pending.right = right;
    pending.time = sampleTimeMs;
    pending.fps = fps;
    self.fpsHistoryPending = pending;
    if(!self openCJ\demos::isPlayingDemo())
    {
        self thread _waitPendingInput();
    }
}

_waitPendingInput()
{
    self endon("disconnect");
    self endon("fpshistory_clear");
    self endon("fpshistory_pending");
    wait level.fpsHistoryLimits.inputConfirmationMs / 1000.0;
    if(!isDefined(self.fpsHistoryPending) || self.fpsHistoryInputGround ||
       self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self _confirmPendingInput();
}

_cancelPendingInput()
{
    self notify("fpshistory_pending");
    self.fpsHistoryPending = undefined;
}

_flushPendingInput()
{
    if(!isDefined(self.fpsHistoryPending))
    {
        return;
    }
    fps = self.fpsHistoryPending.fps;
    self _cancelPendingInput();
    // A rejected short tap keeps its FPS changes, without a new strafe.
    self _appendRecordedFPS(fps);
}

_confirmPendingInput()
{
    if(!isDefined(self.fpsHistoryPending))
    {
        return;
    }
    pending = self.fpsHistoryPending;
    // Do not notify here: this can be called by the waiting thread itself.
    self.fpsHistoryPending = undefined;
    forward = pending.forward;
    right = pending.right;
    self.fpsHistoryAcceptedForward = forward;
    self.fpsHistoryAcceptedRight = right;
    transitionFlags =
        strafeTransition(self.fpsHistoryAnchorForward, self.fpsHistoryAnchorRight, forward, right);
    phaseSwitchFlag = 1; // Native strafeTransition result: the held input changed phase.
    switchedPhase = (transitionFlags & phaseSwitchFlag) != 0;
    diagonalInput = forward != 0 && right != 0;
    noAnchor = self.fpsHistoryAnchorForward == 0 && self.fpsHistoryAnchorRight == 0;
    if(switchedPhase || diagonalInput || noAnchor)
    {
        self.fpsHistoryAnchorForward = forward;
        self.fpsHistoryAnchorRight = right;
    }
    self _action("move", pending.fps, switchedPhase, pending.time, pending.firstFPSChange);
}

onFPSChanged(newFPS)
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self notify("fpshistory_fpschanged");
    fps = openCJ\fps::getShortFPS(newFPS);
    self.fpshistory["shortfps"] = fps;
    if(!self isOnGround())
    {
        self _recordFPS(fps);
    }
}

_beginHistory(fps)
{
    self markNextJump();
    self _resetHistory();
    self.fpshistory["shortfps"] = fps;
    self.fpsHistoryAnchorForward = self.fpsHistoryForward;
    self.fpsHistoryAnchorRight = self.fpsHistoryRight;
    self _action("move", fps, false);
}

// Record one input action; rendering groups these actions into strafe phases.
_action(kind, fps, switched, inputTime, firstFPSChange)
{
    if(kind != "move" && isDefined(self.fpsHistoryPending))
    {
        // Split FPS at the marker, but keep timing the held input. Native input
        // callbacks only report changes, so dropping this candidate would lose
        // a continuing strafe when no further key event arrives after a bounce.
        self _appendRecordedFPS(self.fpsHistoryPending.fps);
        self.fpsHistoryPending.fps = self.fpshistory["shortfps"];
        self.fpsHistoryPending.firstFPSChange = undefined;
    }
    if(!isDefined(self.fpsHistoryEvents))
    {
        self.fpsHistoryEvents = [];
    }
    eventCount = self.fpsHistoryEvents.size;
    eventTimeMs = self historyTime();
    if(eventCount > 0)
    {
        self.fpsHistoryEvents[eventCount - 1].ended = eventTimeMs;
    }
    event = spawnStruct();
    event.kind = kind;
    event.fps = fps;
    event.keys = inputLabel(self.fpsHistoryAcceptedForward, self.fpsHistoryAcceptedRight);
    event.forward = self.fpsHistoryAcceptedForward;
    event.right = self.fpsHistoryAcceptedRight;
    event.switched = switched;
    event.started = eventTimeMs;
    event.inputTime = eventTimeMs;
    if(isDefined(inputTime))
    {
        event.inputTime = inputTime;
    }
    event.firstFPSChange = firstFPSChange;
    if(self openCJ\demos::isPlayingDemo() && isDefined(self.fpsHistoryViewPhase))
    {
        event.viewPhase = self.fpsHistoryViewPhase;
    }
    if(kind == "bounce")
    {
        event.incomingFPS = self.fpshistory["shortfps"];
        self.fpsHistoryBounceDisplayAt = eventTimeMs + level.fpsHistoryLimits.bounceGroupingMs;
        if(!self openCJ\demos::isPlayingDemo())
        {
            self thread _waitBounceDisplay();
        }
    }
    self.fpsHistoryEvents[eventCount] = event;
    if(self.fpsHistoryEvents.size > level.fpsHistoryLimits.maxEvents)
    {
        retainedEvents = [];
        for(i = 1; i < self.fpsHistoryEvents.size; i++)
        {
            retainedEvents[retainedEvents.size] = self.fpsHistoryEvents[i];
        }
        self.fpsHistoryEvents = retainedEvents;
        self.fpsHistoryTruncated = true;
    }
    self _refresh();
}

historyTime()
{
    if(self openCJ\demos::isPlayingDemo() && isDefined(self.fpsHistoryDemoTime))
    {
        return self.fpsHistoryDemoTime;
    }
    return getTime();
}

_recordFPS(fps)
{
    self.fpshistory["shortfps"] = fps;
    if(isDefined(self.fpsHistoryPending))
    {
        previous = self.fpsHistoryPending.fps;
        self.fpsHistoryPending.fps = mergeActionFPS(previous, fps);
        if(previous.size == 1 && self.fpsHistoryPending.fps.size > 1)
        {
            self.fpsHistoryPending.firstFPSChange = self historyTime();
        }
        return;
    }
    self _appendRecordedFPS(fps);
}

_appendRecordedFPS(fps)
{
    if(!isDefined(self.fpsHistoryEvents) || self.fpsHistoryEvents.size == 0)
    {
        self _action("move", fps, false);
        return;
    }
    event = self.fpsHistoryEvents[self.fpsHistoryEvents.size - 1];
    if(event.kind != "move")
    {
        self _action("move", fps, false);
        return;
    }
    merged = mergeActionFPS(event.fps, fps);
    if(merged == event.fps)
    {
        return;
    }
    if(event.fps.size == 1 && merged.size > 1)
    {
        event.firstFPSChange = self historyTime();
    }
    event.fps = merged;
    self _refresh();
}

// Bound a single action without discarding its newest distinct FPS changes.
mergeActionFPS(history, part)
{
    merged = mergePhaseFPS(history, part);
    characterLimit = level.fpsHistoryLimits.actionCharacters;
    marker = level.fpsHistoryLimits.truncationMarker;
    if(merged.size > characterLimit)
    {
        merged = marker + getSubStr(merged, merged.size - (characterLimit - marker.size));
    }
    return merged;
}

// Build compact history from whole newest actions, reserving room for truncation.
renderHistory(events, detailed, truncated)
{
    if(detailed)
    {
        return renderDetailed(phaseActions(events), truncated);
    }
    parts = [];
    previousFPS = "";
    previousKind = "";
    for(i = 0; i < events.size; i++)
    {
        event = events[i];
        part = "";
        if(event.kind == "bounce")
        {
            part = "-";
        }
        else if(event.kind == "bhop")
        {
            part = "/";
        }
        else
        {
            fps = event.fps;
            // Compact describes FPS transitions, independent of strafe phases.
            if(previousKind == "move" && fps.size > 0 && previousFPS == fps[0])
            {
                fps = getSubStr(fps, 1);
            }
            part += fps;
        }
        parts[parts.size] = part;
        if(event.fps.size > 0)
        {
            previousFPS = event.fps[event.fps.size - 1];
        }
        previousKind = event.kind;
    }
    result = "";
    marker = level.fpsHistoryLimits.truncationMarker;
    contentLimit = level.fpsHistoryLimits.historyCharacters - marker.size;
    cut = truncated;
    for(i = parts.size - 1; i >= 0; i--)
    {
        // Reserve the visible marker while selecting complete newest entries.
        if(result.size + parts[i].size > contentLimit)
        {
            cut = true;
            break;
        }
        result = parts[i] + result;
    }
    if(cut)
    {
        result = marker + result;
    }
    return result;
}

// Six recent, whole phases; explicit labels survive color-blind viewing.
// CoD's inline text palette uses cyan/gold for bounce/bhop.
renderDetailed(actions, truncated)
{
    firstVisiblePhase = int(max(0, actions.size - level.fpsHistoryLimits.detailedPhases));
    marker = level.fpsHistoryLimits.truncationMarker;
    fpsCharacterLimit = level.fpsHistoryLimits.detailedFPSCharacters;
    result = "";
    if(firstVisiblePhase > 0 || truncated)
    {
        result = "^7... > ";
    }
    for(i = firstVisiblePhase; i < actions.size; i++)
    {
        event = actions[i];
        if(i > firstVisiblePhase)
        {
            result += " ^7> ";
        }
        if(event.kind == "bounce")
        {
            result += "^5BOUNCE^7";
        }
        else if(event.kind == "bhop")
        {
            result += "^3BHOP^7";
        }
        else
        {
            color = "^7";
            if(isSubStr(event.keys, "A"))
            {
                color = "^6";
            }
            else if(isSubStr(event.keys, "D"))
            {
                color = "^2";
            }
            fps = event.fps;
            if(fps.size > fpsCharacterLimit)
            {
                fps = marker + getSubStr(fps, fps.size - (fpsCharacterLimit - marker.size));
            }
            result += color + event.keys + " ^7" + fps;
        }
    }
    return result;
}

// Only the first 150 ms after a bounce may be attached to the new strafe.
// Keep the recorded actions intact; only the display groups them. Every distinct
// FPS change remains visible after grouping.
bounceDisplayEvents(events, displayTimeMs, pending)
{
    result = [];
    groupingWindowMs = level.fpsHistoryLimits.bounceGroupingMs;
    for(i = 0; i < events.size; i++)
    {
        event = events[i];
        if(event.kind != "bounce")
        {
            result[result.size] = event;
            continue;
        }
        result[result.size] = event;
        if(i + 1 >= events.size || events[i + 1].kind != "move")
        {
            continue;
        }
        bounceExit = events[i + 1];
        // Briefly buffer the bounce exit. A candidate beginning in the window
        // must still pass the existing 150 ms input-duration test before grouping.
        waitingForInput = displayTimeMs < event.started + groupingWindowMs &&
                          (!isDefined(event.displayReady) || !event.displayReady);
        if(isDefined(pending) && pending.time <= event.started + groupingWindowMs)
        {
            waitingForInput = true;
        }
        if(waitingForInput)
        {
            break;
        }
        displayMove = spawnStruct();
        displayMove.kind = "move";
        displayMove.fps = bounceExit.fps;
        displayMove.keys = bounceExit.keys;
        displayMove.forward = bounceExit.forward;
        displayMove.right = bounceExit.right;
        displayMove.switched = bounceExit.switched;
        displayMove.started = bounceExit.started;
        displayMove.viewPhase = bounceExit.viewPhase;
        // A carry-over value already shown before the bounce is not a new FPS
        // step. Remove only that leading value, only when its first change is
        // inside the window. Rapid changes after it (e.g. 3->2->3) all survive.
        if(isDefined(event.incomingFPS) && displayMove.fps.size > 1 &&
           displayMove.fps[0] == event.incomingFPS && isDefined(bounceExit.firstFPSChange) &&
           bounceExit.firstFPSChange <= event.started + groupingWindowMs)
        {
            displayMove.fps = getSubStr(displayMove.fps, 1);
        }
        i++;
        if(i + 1 < events.size && events[i + 1].kind == "move")
        {
            nextMove = events[i + 1];
            if(isDefined(nextMove.inputTime) &&
               nextMove.inputTime <= event.started + groupingWindowMs && nextMove.switched)
            {
                displayMove.fps = mergePhaseFPS(displayMove.fps, nextMove.fps);
                displayMove.keys = nextMove.keys;
                displayMove.forward = nextMove.forward;
                displayMove.right = nextMove.right;
                displayMove.viewPhase = nextMove.viewPhase;
                displayMove.switched = false;
                i++;
            }
        }
        result[result.size] = displayMove;
    }
    return result;
}

_waitBounceDisplay()
{
    self endon("disconnect");
    self endon("fpshistory_clear");
    wait level.fpsHistoryLimits.bounceGroupingMs / 1000.0;
    self.fpsHistoryBounceDisplayAt = undefined;
    self _refresh();
}

_refresh()
{
    displayed =
        bounceDisplayEvents(self.fpsHistoryEvents, self historyTime(), self.fpsHistoryPending);
    self.fpsHistoryText = renderHistory(displayed, false, self.fpsHistoryTruncated);
    if(!isDefined(self.fpsHistoryStyle))
    {
        self.fpsHistoryStyle = inferStrafeStyle(displayed);
    }
    self.fpsHistoryDetailedText =
        renderDetailed(phaseActions(displayed, self.fpsHistoryStyle), self.fpsHistoryTruncated);
    self _publish();
}

_publish()
{
    if(isDefined(self.fpsHistoryBatch) && self.fpsHistoryBatch)
    {
        return;
    }
    if(self openCJ\demos::isPlayingDemo())
    {
        self _render(self);
        return;
    }
    if(self.sessionState != "playing")
    {
        return;
    }
    spectators = self getSpectatorList(false);
    for(i = 0; i < spectators.size; i++)
    {
        spectators[i] _render(self);
    }
}

_render(sourcePlayer)
{
    if(!self openCJ\demos::isPlayingDemo() && isDefined(self.fpsHistoryWaitJump))
    {
        jumpSerial = 0;
        if(isDefined(sourcePlayer.fpsHistoryJumpSerial))
        {
            jumpSerial = sourcePlayer.fpsHistoryJumpSerial;
        }
        if((!isDefined(self.fpsHistoryWaitSource) || self.fpsHistoryWaitSource == sourcePlayer) &&
           jumpSerial == self.fpsHistoryWaitJump)
        {
            self _hide();
            return;
        }
        self.fpsHistoryWaitJump = undefined;
        self.fpsHistoryWaitSource = undefined;
    }
    self.fpsHistorySource = sourcePlayer;
    displayMode = self.fpsHistoryMode;
    if(!isDefined(displayMode))
    {
        displayMode = "detailed";
    }
    displayText = sourcePlayer.fpsHistoryText;
    if(displayMode == "detailed" && isDefined(sourcePlayer.fpsHistoryDetailedText))
    {
        displayText = sourcePlayer.fpsHistoryDetailedText;
    }
    if(displayMode == "off" || !isDefined(displayText) || displayText == "")
    {
        self _hide();
        return;
    }
    self.hud[level.fpsHistoryHudName] openCJ\huds\infiniteHuds::setInfiniteHudText(displayText,
                                                                                   self, false);
    self openCJ\huds\base::enableHUD(level.fpsHistoryHudName);
}

// A single A/D tap cannot establish halfbeat. Lock the first confirmed
// fullbeat pair or halfbeat return pattern for this airborne history.
inferStrafeStyle(events)
{
    previousDiagonal = undefined;
    previous = undefined;
    beforePrevious = undefined;
    for(j = 0; j < events.size; j++)
    {
        event = events[j];
        if(event.kind != "move" || event.right == 0)
        {
            continue;
        }
        if(event.forward != 0)
        {
            if(isDefined(previousDiagonal) && previousDiagonal.forward == event.forward &&
               previousDiagonal.right == (0 - event.right))
            {
                return makeStrafeStyle("fullbeat", event.forward, event.right);
            }
            previousDiagonal = event;
        }
        if(isDefined(previous) && previous.forward == event.forward &&
           previous.right == event.right)
        {
            continue;
        }
        if(isDefined(beforePrevious) && beforePrevious.forward == event.forward &&
           beforePrevious.right == event.right)
        {
            if(event.forward != 0 && previous.forward == 0 && previous.right == (0 - event.right))
            {
                return makeStrafeStyle("halfbeat", event.forward, event.right);
            }
            if(event.forward == 0 && previous.forward != 0 && previous.right == (0 - event.right))
            {
                return makeStrafeStyle("halfbeat", previous.forward, previous.right);
            }
        }
        beforePrevious = previous;
        previous = event;
    }
    return undefined;
}

makeStrafeStyle(kind, forward, right)
{
    style = spawnStruct();
    style.kind = kind;
    style.forward = forward;
    style.right = right;
    return style;
}

// Group accepted held input into display phases, preserving takeoff and marker timing.
phaseActions(events, style)
{
    if(!isDefined(style))
    {
        style = inferStrafeStyle(events);
    }
    inferredStyle = style;
    phases = [];
    phaseForward = 0;
    phaseRight = 0;
    pendingFPS = "";
    pendingStartMs = undefined;
    for(j = 0; j < events.size; j++)
    {
        event = events[j];
        currentPhase = undefined;
        if(phases.size > 0)
        {
            currentPhase = phases[phases.size - 1];
        }
        if(event.kind == "move")
        {
            style = inferredStyle;
            if(isDefined(event.viewPhase) && event.viewPhase != 0)
            {
                style = recordedStrafeStyle(event.viewPhase);
            }
            forward = event.forward;
            right = event.right;
            hasPhase = phaseForward != 0 || phaseRight != 0;
            neutral = forward == 0 && right == 0;
            if(!hasPhase && neutral)
            {
                continue;
            }
            accepted = isStrafeInput(style, forward, right);

            if(!hasPhase && isDefined(style) && !accepted)
            {
                // The bounded raw history may begin with a release. Do not
                // resurrect that release as the established style's first row.
                pendingFPS = mergePhaseFPS(pendingFPS, event.fps);
                if(!isDefined(pendingStartMs))
                {
                    pendingStartMs = event.started;
                }
                continue;
            }
            switched = false;
            completesTakeoffInput = false;
            if(!hasPhase)
            {
                // Keep the takeoff input until a strafe style is established.
                phaseForward = forward;
                phaseRight = right;
            }
            else if(accepted)
            {
                completesTakeoffInput = phaseForward == 0 || phaseRight == 0;
                if(isDefined(style) && style.kind == "halfbeat")
                {
                    completesTakeoffInput = !isStrafeInput(style, phaseForward, phaseRight);
                }
                // Converted samples carry an already confirmed native phase.
                // A preserved takeoff must remain its own row when HB begins.
                if(isDefined(event.viewPhase) && event.viewPhase != 0)
                {
                    completesTakeoffInput = false;
                }
                switched =
                    !completesTakeoffInput && (phaseForward != forward || phaseRight != right);
                phaseForward = forward;
                phaseRight = right;
            }
            if(isDefined(currentPhase) && currentPhase.kind == "move" && !switched)
            {
                if(completesTakeoffInput)
                {
                    currentPhase.keys = inputLabel(phaseForward, phaseRight);
                }
                currentPhase.fps = mergePhaseFPS(currentPhase.fps, event.fps);
                continue;
            }
            nextPhase = spawnStruct();
            nextPhase.kind = "move";
            nextPhase.keys = inputLabel(phaseForward, phaseRight);
            nextPhase.fps = mergePhaseFPS(pendingFPS, event.fps);
            nextPhase.started = event.started;
            if(isDefined(pendingStartMs))
            {
                nextPhase.started = pendingStartMs;
            }
            pendingFPS = "";
            pendingStartMs = undefined;
        }
        else
        {
            nextPhase = spawnStruct();
            nextPhase.kind = event.kind;
            nextPhase.keys = "";
            nextPhase.fps = "";
            nextPhase.started = event.started;
        }
        if(isDefined(currentPhase))
        {
            currentPhase.ended = nextPhase.started;
        }
        phases[phases.size] = nextPhase;
    }
    return phases;
}

// Native technique conversion packs style and input signs into each recorded phase.
recordedStrafeStyle(viewPhase)
{
    kindMask = 48;
    halfbeatBits = 32;
    invertBits = 48;
    backwardBit = 8;
    leftBit = 1;
    kind = "fullbeat";
    if((viewPhase & kindMask) == halfbeatBits)
    {
        kind = "halfbeat";
    }
    else if((viewPhase & kindMask) == invertBits)
    {
        kind = "invert";
    }
    forwardInput = 1;
    if(viewPhase & backwardBit)
    {
        forwardInput = -1;
    }
    rightInput = 1;
    if(viewPhase & leftBit)
    {
        rightInput = -1;
    }
    return makeStrafeStyle(kind, forwardInput, rightInput);
}

// Accept the two held-input shapes belonging to the established strafe style.
isStrafeInput(style, forward, right)
{
    if(isDefined(style) && style.kind == "invert")
    {
        return forward == 0 && right != 0;
    }
    if(isDefined(style) && style.kind == "halfbeat")
    {
        diagonalInput = forward == style.forward && right == style.right;
        oppositeSideOnly = forward == 0 && right == (0 - style.right);
        return diagonalInput || oppositeSideOnly;
    }
    return forward != 0 && right != 0 && (!isDefined(style) || forward == style.forward);
}

mergePhaseFPS(history, part)
{
    if(history.size > 0 && part.size > 0 && history[history.size - 1] == part[0])
    {
        part = getSubStr(part, 1);
    }
    return appendFPSHistory(history, part);
}

onBounced()
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self resetStrafeTracking();
    self thread _separator("bounce");
}

_separator(kind)
{
    self endon("disconnect");
    self endon("fpshistory_clear");
    if(self.fpsHistoryText == "")
    {
        return;
    }
    self _action(kind, "", false);
    self endon("fpshistory_fpschanged");
    wait level.fpsHistoryLimits.separatorFPSDelayMs / 1000.0;
    self _recordFPS(openCJ\fps::getShortFPS(self openCJ\fps::getCurrentFPS()));
}

onLoaded()
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self resetStrafeTracking();
    self _clearFPSHistory();
}

onOnGround(onGround)
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self thread _onOnGroundThread(onGround);
}
// A new ground transition cancels the previous landing-expiry timer.
_onOnGroundThread(onGround)
{
    self endon("disconnect");
    self notify("fpshistory_ongroundchange");
    self endon("fpshistory_ongroundchange");
    if(onGround)
    {
        self _flushPendingInput();
        wait level.fpsHistoryLimits.landingExpiryMs / 1000.0;
        self _clearFPSHistory();
    }
    else if(self openCJ\events\onGroundChanged::getLastGroundEnterTime() >=
                getTime() - level.fpsHistoryLimits.bhopWindowMs &&
            self.fpsHistoryText != "")
    {
        self _onBhopThread();
    }
    else
    {
        self _beginHistory(openCJ\fps::getShortFPS(self openCJ\fps::getCurrentFPS()));
    }
}

_onBhopThread()
{
    self markNextJump();
    self _separator("bhop");
}

// Cancel pending input and bounce work before discarding the history it belongs to.
_resetHistory()
{
    self notify("fpshistory_clear");
    self.fpsHistoryBounceDisplayAt = undefined;
    self _cancelPendingInput();
    self.fpsHistoryAcceptedForward = self.fpsHistoryForward;
    self.fpsHistoryAcceptedRight = self.fpsHistoryRight;
    self.fpsHistoryEvents = [];
    self.fpsHistoryTruncated = false;
    self.fpsHistoryStyle = undefined;
    self.fpsHistoryText = "";
    self.fpsHistoryDetailedText = "";
    self.fpsHistoryAnchorForward = 0;
    self.fpsHistoryAnchorRight = 0;
}

_clearFPSHistory()
{
    self _resetHistory();
    spectators = self getSpectatorList(false);
    for(i = 0; i < spectators.size; i++)
    {
        spectators[i] _hide();
    }
}

// Keep the bounded raw-string helpers for callers restoring older history.
appendFPSHistory(history, text)
{
    characterLimit = level.fpsHistoryLimits.historyCharacters;
    marker = level.fpsHistoryLimits.truncationMarker;
    if(history.size + text.size <= characterLimit)
    {
        return history + text;
    }
    retainedCharacters = characterLimit - marker.size;
    if(text.size >= retainedCharacters)
    {
        return marker + getSubStr(text, text.size - retainedCharacters);
    }
    retainedCharacters -= text.size;
    return marker + getSubStr(history, history.size - retainedCharacters) + text;
}

_setFPSHistory(text)
{
    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self _cancelPendingInput();
    self.fpsHistoryEvents = [];
    self.fpsHistoryText = appendFPSHistory("", text);
    self.fpsHistoryDetailedText = self.fpsHistoryText;
    self _publish();
}

_addFPSHistory(text)
{
    self _setFPSHistory(appendFPSHistory(self.fpsHistoryText, text));
}

_clearDemoFPSHistory()
{
    self _resetHistory();
    if(!isDefined(self.fpsHistoryBatch) || !self.fpsHistoryBatch)
    {
        self _hide();
    }
}
// Process recorded time, not wall time: slow motion, seeks and reverse use this same path.
applyRecordedFrame(frame, sequential, interpolated)
{
    if(interpolated)
    {
        return;
    }
    self.fpsHistoryViewPhase = frame.techniquePhase;
    forwardInput = int(frame.forward) - int(frame.back);
    rightInput = int(frame.right) - int(frame.left);
    fps = openCJ\fps::getShortFPS(frame.FPS);
    if(!sequential || frame.loadNow)
    {
        self notify("fpshistory_ongroundchange");
        self _clearDemoFPSHistory();
        self.fpsHistoryForward = forwardInput;
        self.fpsHistoryRight = rightInput;
        self.fpsHistoryInputGround = frame.onGround;
        self.fpsHistoryDemoTime = 0;
        self.fpsHistoryDemoLandTime = undefined;
        if(!frame.onGround)
        {
            self _beginHistory(fps);
        }
    }
    else
    {
        self advanceRecordedHistory(frame, forwardInput, rightInput, fps);
    }
    if(isDefined(self.fpsHistoryBounceDisplayAt) &&
       self.fpsHistoryDemoTime >= self.fpsHistoryBounceDisplayAt)
    {
        self.fpsHistoryBounceDisplayAt = undefined;
        self _refresh();
    }
    self.demoPreviousOnGround = frame.onGround;
    self.demoPreviousFPS = frame.FPS;
}

// Advance ground, bounce and FPS state using recording time rather than playback speed.
advanceRecordedHistory(frame, forwardInput, rightInput, fps)
{
    // OpenCJ recordings contain one sample per 50 ms, not per client FPS.
    self.fpsHistoryDemoTime += level.fpsHistoryLimits.sampleIntervalMs;
    wasOnGround = self.fpsHistoryInputGround;
    self _movement(forwardInput, rightInput, self.fpsHistoryDemoTime, frame.onGround, fps);
    if(wasOnGround && !frame.onGround)
    {
        self notify("fpshistory_ongroundchange");
        if(isDefined(self.fpsHistoryDemoLandTime) &&
           self.fpsHistoryDemoTime - self.fpsHistoryDemoLandTime <
               level.fpsHistoryLimits.bhopWindowMs &&
           self.fpsHistoryText != "")
        {
            self _action("bhop", "", false);
        }
        else
        {
            self _beginHistory(fps);
        }
    }
    else if(!wasOnGround && frame.onGround)
    {
        self.fpsHistoryDemoLandTime = self.fpsHistoryDemoTime;
    }
    if(frame.onGround && isDefined(self.fpsHistoryDemoLandTime) &&
       self.fpsHistoryDemoTime - self.fpsHistoryDemoLandTime >=
           level.fpsHistoryLimits.landingExpiryMs &&
       self.fpsHistoryText != "")
    {
        self _clearDemoFPSHistory();
    }
    if(frame.bounce && !frame.onGround)
    {
        self _action("bounce", "", false);
    }
    if(!frame.onGround)
    {
        if(self.fpshistory["shortfps"] != fps)
        {
            self notify("fpshistory_fpschanged");
        }
        self _recordFPS(fps);
    }
}

// Restore the saved live history after demo viewing without resuming old input timers.
restoreLiveHistory(savedHistory)
{
    self notify("fpshistory_ongroundchange");
    self.fpshistory = savedHistory.fpshistory;
    self.fpsHistoryText = savedHistory.fpsHistoryText;
    self.fpshistory["shortfps"] = savedHistory.fpsHistoryShortFPS;
    self.fpsHistoryEvents = savedHistory.fpsHistoryEvents;
    self.fpsHistoryTruncated = savedHistory.fpsHistoryTruncated;
    self.fpsHistoryStyle = savedHistory.fpsHistoryStyle;
    self _cancelPendingInput();
    self.fpsHistoryAcceptedForward = 0;
    self.fpsHistoryAcceptedRight = 0;
    if(self.fpsHistoryEvents.size > 0)
    {
        lastEvent = self.fpsHistoryEvents[self.fpsHistoryEvents.size - 1];
        self.fpsHistoryAcceptedForward = lastEvent.forward;
        self.fpsHistoryAcceptedRight = lastEvent.right;
    }
    self.fpsHistoryForward = self.fpsHistoryAcceptedForward;
    self.fpsHistoryRight = self.fpsHistoryAcceptedRight;
    self.fpsHistoryInputGround = undefined;
    self.fpsHistoryAnchorForward = 0;
    self.fpsHistoryAnchorRight = 0;
    self resetStrafeTracking();
    self _hide();
    if(self.fpsHistoryEvents.size > 0)
    {
        self _refresh();
    }
    else
    {
        self.fpsHistoryDetailedText = self.fpsHistoryText;
        self _publish();
    }
}

markNextJump()
{
    if(!isDefined(self.fpsHistoryJumpSerial))
    {
        self.fpsHistoryJumpSerial = 0;
    }
    self.fpsHistoryJumpSerial++;
}
