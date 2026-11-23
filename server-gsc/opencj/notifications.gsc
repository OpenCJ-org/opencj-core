#include openCJ\util;

// Modes: 0 off, 1 text (default), 2 flash, 3 both.
onInit()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    precacheShader("white");
    precacheShader("opencj_notify_glow_left");
    precacheShader("opencj_notify_glow_right");
    events = actionEvents();
    for(i = 0; i < events.size; i++)
    {
        openCJ\settings::addSettingInt(
            "notify_" + events[i], modeValue("off"), modeValue("both"), modeValue("text"),
            "Action feedback: 0 off, 1 text, 2 flash, 3 both. See !notifications.",
            ::_settingChanged);
    }
    openCJ\settings::addSettingInt("notify_results", modeValue("text"), modeValue("both"), modeValue("text"),
                                   "Finish/record/challenge feedback: 1 text, 3 text plus flash.",
                                   ::_settingChanged);
    openCJ\settings::addSettingInt("notify_strength", 1, 3, 1,
                                   "Flash strength: 1 low, 2 medium, 3 high.", ::_settingChanged);
    openCJ\commands_base::registerCommand(
        "notifications",
        "Feedback: !notifications [all|checkpoint|save|load] <text|flash|both|off>; results <text|both>; strength <low|medium|high>.",
        ::command, 0, 2, 0);
}

mode(event)
{
    feedbackMode = self openCJ\settings::getSetting("notify_" + event);
    if(!isDefined(feedbackMode))
    {
        return modeValue("text");
    }
    return int(feedbackMode);
}

wantsText(event)
{
    feedbackMode = self mode(event);
    return feedbackMode == modeValue("text") || feedbackMode == modeValue("both");
}

wantsFlash(event)
{
    feedbackMode = self mode(event);
    return feedbackMode == modeValue("flash") || feedbackMode == modeValue("both");
}

modeValue(name)
{
    switch(toLower(name))
    {
    case "off":
        return 0;
    case "text":
        return 1;
    case "flash":
        return 2;
    case "both":
        return 3;
    }
    return undefined;
}

modeName(value)
{
    names = [];
    names[0] = "off";
    names[1] = "text";
    names[2] = "flash";
    names[3] = "both";
    return names[value];
}
// Apply one command choice; result messages remain mandatory even when actions are off.
command(args)
{
    if(!self openCJ\settings::areSettingsLoaded())
    {
        return;
    }
    if(!args.size)
    {
        self printPreferences();
        return;
    }

    targetEvent = "all";
    choiceName = toLower(args[0]);
    if(args.size == 2)
    {
        targetEvent = choiceName;
        choiceName = toLower(args[1]);
    }
    if(targetEvent == "strength")
    {
        self setStrengthChoice(choiceName);
        return;
    }
    if(targetEvent == "results")
    {
        self setResultChoice(choiceName);
        return;
    }

    feedbackMode = modeValue(choiceName);
    validEvent = targetEvent == "all" || targetEvent == "checkpoint" ||
                 targetEvent == "save" || targetEvent == "load";
    if(!isDefined(feedbackMode) || !validEvent)
    {
        self iprintln("Use !notifications [all|checkpoint|save|load] <text|flash|both|off>.");
        return;
    }
    self setActionChoices(targetEvent, feedbackMode);
    self iprintln("Notifications (" + targetEvent + "): " + choiceName);
    if(targetEvent == "all")
    {
        self iprintln("Finish, record and challenge messages always stay on.");
    }
}

printPreferences()
{
    self iprintln("Notifications: checkpoint " + modeName(self mode("checkpoint")) +
                  ", save " + modeName(self mode("save")) +
                  ", load " + modeName(self mode("load")));
    resultName = "text";
    if(self wantsFlash("results"))
    {
        resultName = "both";
    }
    self iprintln("Results: " + resultName +
                  ". !notifications results <text|both>; strength <low|medium|high>");
}

setStrengthChoice(choiceName)
{
    strength = undefined;
    if(choiceName == "low")
    {
        strength = 1;
    }
    if(choiceName == "medium")
    {
        strength = 2;
    }
    if(choiceName == "high")
    {
        strength = 3;
    }
    if(!isDefined(strength))
    {
        self iprintln("Use strength low, medium or high.");
        return;
    }
    self openCJ\settings::setSettingByScript("notify_strength", strength);
    self iprintln("Notification flash strength: " + choiceName);
}

setResultChoice(choiceName)
{
    if(choiceName != "text" && choiceName != "both")
    {
        self iprintln("Use !notifications results <text|both>. Result messages always stay on.");
        return;
    }
    self openCJ\settings::setSettingByScript("notify_results", modeValue(choiceName));
    self iprintln("Finish, record and challenge feedback: " + choiceName);
}

actionEvents()
{
    events = [];
    events[0] = "checkpoint";
    events[1] = "save";
    events[2] = "load";
    return events;
}

setActionChoices(targetEvent, feedbackMode)
{
    events = actionEvents();
    for(i = 0; i < events.size; i++)
    {
        if(targetEvent == "all" || targetEvent == events[i])
        {
            self openCJ\settings::setSettingByScript("notify_" + events[i], feedbackMode);
        }
    }
    if(targetEvent == "all")
    {
        resultMode = modeValue("text");
        if(feedbackMode == modeValue("flash") || feedbackMode == modeValue("both"))
        {
            resultMode = modeValue("both");
        }
        self openCJ\settings::setSettingByScript("notify_results", resultMode);
    }
}

_settingChanged(value)
{
    self cancelFlash();
    self cancelCheckpoint();
    self cancelResults();
}

action(event, text)
{
    if(self.sessionState != "playing" || self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    self cancelResults();
    if(isDefined(self.notificationFlashResult) && self.notificationFlashResult)
    {
        self cancelFlash();
    }
    if(event == "load")
    {
        self cancelCheckpoint();
    }
    if(isDefined(text) && self wantsText(event))
    {
        self iprintln(text);
    }
    if(self wantsFlash(event))
    {
        self flash(event);
    }
}

color(event)
{
    if(event == "checkpoint" || event == "record")
    {
        return (.05, 1, .10);
    }
    if(event == "save" || event == "finish")
    {
        return (.05, .25, 1);
    }
    if(event == "challenge")
    {
        return (1, .65, .05);
    }
    return (1, .05, .05); // Load: red, clearly separate from save's blue.
}

beginResults(runID)
{
    self cancelResults();
    if(!self wantsFlash("results"))
    {
        return;
    }
    self.notificationResultRun = runID;
    self.notificationResultInstance = self openCJ\playerRuns::getRunInstanceNumber();
    // Give asynchronous record and challenge replies a short shared celebration window.
    resultWindowMs = 2000;
    self.notificationResultUntil = getTime() + resultWindowMs;
    self.notificationResultPriority = 0;
    self result("finish", runID);
}
// Upgrade the same finish overlay only while that run's celebration is still current.
result(event, runID)
{
    if(!isDefined(self.notificationResultRun) || self.notificationResultRun != runID)
    {
        return;
    }
    currentRun = self openCJ\playerRuns::getRunID() == runID &&
                 self openCJ\playerRuns::getRunInstanceNumber() == self.notificationResultInstance;
    if(!currentRun || !self openCJ\playerRuns::isRunFinished())
    {
        return;
    }
    if(getTime() > self.notificationResultUntil || self.sessionState != "playing" ||
       self openCJ\demos::isPlayingDemo() || !self wantsFlash("results"))
    {
        return;
    }

    priority = resultPriority(event);
    if(priority <= self.notificationResultPriority)
    {
        return;
    }
    self.notificationResultPriority = priority;
    self flash(event, true);
}

resultPriority(event)
{
    // Record emphasis wins over a challenge, which wins over the ordinary finish.
    if(event == "record")
    {
        return 3;
    }
    if(event == "challenge")
    {
        return 2;
    }
    return 1;
}

cancelResults()
{
    self.notificationResultRun = undefined;
    self.notificationResultInstance = undefined;
    self.notificationResultUntil = undefined;
    self.notificationResultPriority = undefined;
}

_createOverlay(x, width, shader)
{
    hud = newClientHudElem(self);
    // Foreground draws independently of the stock HUD visibility gate.
    hud.archived = false;
    hud.hideWhenInMenu = true;
    hud.foreground = true;
    hud.horzAlign = "fullscreen";
    hud.vertAlign = "fullscreen";
    hud.alignX = "left";
    hud.alignY = "top";
    hud.x = x;
    hud.y = 0;
    // Draw below ordinary HUD content while keeping the foreground visibility behavior.
    overlaySort = -1000;
    hud.sort = overlaySort;
    hud.alpha = 0;
    screenHeight = 480;
    hud setShader(shader, width, screenHeight);
    return hud;
}
// Own one edge pair or result overlay. A burst recolors it without extending its lifetime.
flash(event, isResult)
{
    if(getCodVersion() != 4)
    {
        return;
    }
    if(!isDefined(isResult))
    {
        isResult = false;
    }
    if(isDefined(self.notificationFlash) && self.notificationFlashResult != isResult)
    {
        self cancelFlash();
    }
    flashColor = color(event);
    if(isDefined(self.notificationFlash))
    {
        self.notificationFlash.color = flashColor;
        if(isDefined(self.notificationFlashRight))
        {
            self.notificationFlashRight.color = flashColor;
        }
        return;
    }

    style = flashStyle(isResult);
    overlay = self _createOverlay(0, style.width, style.shader);
    self.notificationFlash = overlay;
    self.notificationFlashResult = isResult;
    rightOverlay = undefined;
    if(!isResult)
    {
        rightOverlay = self _createOverlay(style.rightX, style.width, "opencj_notify_glow_right");
        self.notificationFlashRight = rightOverlay;
        rightOverlay.color = flashColor;
    }
    overlay.color = flashColor;
    strength = self openCJ\settings::getSetting("notify_strength");
    if(!isDefined(strength))
    {
        strength = 1;
    }

    // The network drops the low three alpha bits. These steps survive that encoding.
    strengthStepByte = 16;
    maxAlphaByte = 255.0;
    peakAlpha = (style.baseAlphaByte + strengthStepByte * strength) / maxAlphaByte;
    self thread _fade(overlay, rightOverlay, peakAlpha,
                      style.fadeInSeconds, style.holdSeconds, style.fadeOutSeconds);
}

// Keep the established 640x480 HUD geometry and fade timings together.
flashStyle(isResult)
{
    screenWidth = 640;
    edgeWidth = 64;
    style = spawnStruct();
    style.width = edgeWidth;
    style.rightX = screenWidth - edgeWidth;
    style.shader = "opencj_notify_glow_left";
    style.baseAlphaByte = 40;
    style.fadeInSeconds = .05;
    style.holdSeconds = .15;
    style.fadeOutSeconds = .15;
    if(isResult)
    {
        style.width = screenWidth;
        style.shader = "white";
        style.baseAlphaByte = 56;
        style.fadeInSeconds = .10;
        style.holdSeconds = .30;
        style.fadeOutSeconds = .35;
    }
    return style;
}

_fade(overlay, rightOverlay, peakAlpha, fadeInSeconds, holdSeconds, fadeOutSeconds)
{
    self endon("disconnect");
    self endon("notificationFlashStop");
    overlay fadeOverTime(fadeInSeconds);
    overlay.alpha = peakAlpha;
    if(isDefined(rightOverlay))
    {
        rightOverlay fadeOverTime(fadeInSeconds);
        rightOverlay.alpha = peakAlpha;
    }
    wait holdSeconds; // Includes fade-in, then a short peak hold.
    overlay fadeOverTime(fadeOutSeconds);
    overlay.alpha = 0;
    if(isDefined(rightOverlay))
    {
        rightOverlay fadeOverTime(fadeOutSeconds);
        rightOverlay.alpha = 0;
    }
    wait fadeOutSeconds;
    self.notificationFlash = undefined;
    self.notificationFlashRight = undefined;
    self.notificationFlashResult = undefined;
    overlay destroy();
    if(isDefined(rightOverlay))
    {
        rightOverlay destroy();
    }
}

cancelFlash()
{
    // Stop the fade thread before destroying the HUD elements it owns.
    self notify("notificationFlashStop");
    if(isDefined(self.notificationFlash))
    {
        self.notificationFlash destroy();
    }
    if(isDefined(self.notificationFlashRight))
    {
        self.notificationFlashRight destroy();
    }
    self.notificationFlash = undefined;
    self.notificationFlashRight = undefined;
    self.notificationFlashResult = undefined;
}

cancelCheckpoint()
{
    self notify("notificationCheckpointStop");
}

onDisconnect()
{
    self cancelAll();
}

cancelAll()
{
    self cancelFlash();
    self cancelCheckpoint();
    self cancelResults();
}
