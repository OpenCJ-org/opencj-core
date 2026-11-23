#include openCJ\huds\hudFPSHistory;

// Import the production HUD functions once. Repeating the module on every call
// fills the engine's precache list before this large fixture can start.
main()
{
    openCJ\demoRecording::_initConstants();
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    level.failures = 0;
    level.checks = 0;
    openCJ\huds\infiniteHuds::onInit();
    onInit();
    openCJ\huds\infiniteHuds::initInfiniteHud("fps");
    wait 1;
    setCvar("opencj_test_movement", 1);

    verifyStringBounds();
    player = addTestClient();
    viewer = addTestClient();
    check(isDefined(player) && isDefined(viewer), "two real test clients");
    if(!isDefined(player) || !isDefined(viewer))
    {
        finish();
        return;
    }
    wait 0.2;
    setupPlayer(player);
    setupPlayer(viewer);
    viewer.sessionTeam = "spectator";
    viewer.sessionState = "spectator";
    viewer.pers["team"] = "spectator";
    viewer followPlayer(player getEntityNumber());
    wait 0.1;
    followers = player getSpectatorList(false);
    check(followers.size == 1 && followers[0] == viewer, "native spectator following configured");
    startMovement(player, 1, -1);
    setCvar("opencj_test_movement", 2);
    wait .1;
    check(player.fpsHistoryForward == 0 && player.fpsHistoryRight == 1 &&
              player.fpsHistoryEvents.size == 1,
          "native complete-input callback reports releases without publishing sub-150 ms phases");
    strafeHistory(player, viewer);
    phaseGrouping(player, viewer);
    heldDuration(player, viewer);
    bounceBoundaries(viewer);
    compactFPSChanges(viewer);
    detailedWindow(viewer);
    playbackControls(player);
    playbackSampling(player);
    verifyLiveSpectatorDisplay(player, viewer);
    verifyRecordedHistoryBounds(player, viewer);
    verifyLiveHistoryEvents(player);
    verifyLandingExpiry(player, viewer);
    verifyHUDCommandLimits(viewer);
    finish();
}

// Include the command prefix when testing the engine's reliable-message limit.
verifyHUDCommandLimits(viewer)
{
    maximumCommandCharacters = 1023; // Native 1024-byte command buffer includes its terminator.
    hud = viewer.hud[level.fpsHistoryHudName];
    prefix = "d " + hud.configstringIndex + " ";
    payload = sequence(0, maximumCommandCharacters - prefix.size);
    hud openCJ\huds\infiniteHuds::setInfiniteHudText(payload, viewer, false);
    check(sameText(hud.lastText, payload), "HUD payload exactly at command boundary unchanged");
    oversized = sequence(0, maximumCommandCharacters);
    hud openCJ\huds\infiniteHuds::setInfiniteHudText(oversized, viewer, false);
    check(sameText(hud.lastText, payload) &&
              prefix.size + hud.lastText.size == maximumCommandCharacters,
          "HUD sender reserves prefix and null terminator");
    hud openCJ\huds\infiniteHuds::setInfiniteHudText(oversized, viewer, true);
    check(sameText(hud.lastText, payload), "repeated oversized input stays bounded");
    hud openCJ\huds\infiniteHuds::setInfiniteHudText("14", viewer, false);
    check(hud.lastText == "14", "short HUD update still works after truncation");
}

// Live timers and recorded samples must expire the same history after two seconds.
verifyLandingExpiry(player, viewer)
{
    fullHistory = sequence(0, 512);
    viewer.playingDemo = false;
    viewer followPlayer(player getEntityNumber());
    wait 0.1;
    player _setFPSHistory(fullHistory);
    player _addFPSHistory("2");
    check(viewer.hud[level.fpsHistoryHudName].lastText == player.fpsHistoryText,
          "spectator receives updated truncated history");
    player onOnGround(true);
    wait 0.1;
    check(player.fpsHistoryText != "", "landing retains history during two-second grace period");
    wait 2;
    check(player.fpsHistoryText == "" && viewer.hud[level.fpsHistoryHudName].alpha == 0,
          "landing clears live history and spectator HUD");
    viewer followPlayer(-1);
    viewer.playingDemo = true;
    viewer applyRecordedFrame(demoFrame(1, -1, false, 333, false), false, false);
    viewer applyRecordedFrame(demoFrame(1, -1, true, 333, false), true, false);
    for(i = 0; i < 39; i++)
    {
        viewer applyRecordedFrame(demoFrame(1, -1, true, 333, false), true, false);
    }
    check(viewer.fpsHistoryText != "", "recorded landing grace period lasts 1950 ms");
    viewer applyRecordedFrame(demoFrame(1, -1, true, 333, false), true, false);
    check(viewer.fpsHistoryText == "" && viewer.hud[level.fpsHistoryHudName].alpha == 0,
          "recorded landing clears history at 2000 ms");
}

verifyLiveHistoryEvents(player)
{
    player.FPS = 125;
    setSequence(player, "14");
    player onBounced();
    wait 0.2;
    check(player.fpsHistoryText == "14-1", "live bounce separator preserved");
    player thread _onBhopThread();
    wait 0.2;
    check(player.fpsHistoryText == "14-1/1", "live bhop separator preserved");

    player onLoaded();
    check(player.fpsHistoryText == "", "loading clears live history");
    player _addFPSHistory("2");
    check(player.fpsHistoryText == "2", "new live history starts without truncation marker");
    player _clearFPSHistory();
    check(player.fpsHistoryText == "", "explicit history clear removes previous live history");
    setSequence(player, "14");
    player onSpawnPlayer();
    check(player.fpsHistoryText == "" && player.hud[level.fpsHistoryHudName].alpha == 0,
          "spawn clears and hides history");
}

// A long recording must retain exactly the newest visible FPS changes.
verifyRecordedHistoryBounds(player, viewer)
{
    viewer followPlayer(-1);
    player _clearFPSHistory();
    viewer.playingDemo = true;
    // Drive the actual recording consumer instead of the retired event helpers.
    viewer applyRecordedFrame(demoFrame(1, -1, false, 333, false), false, false);
    stayedWithinLimit = true;
    expectedText = "3";
    for(i = 0; i < 3000; i++)
    {
        fps = 250;
        fpsToken = "2";
        if(i % 2)
        {
            fps = 333;
            fpsToken = "3";
        }
        viewer applyRecordedFrame(demoFrame(1, -1, false, fps, false), true, false);
        expectedText += fpsToken;
        if(expectedText.size > 480)
        {
            expectedText = "..." + getSubStr(expectedText, expectedText.size - 477);
        }
        if(viewer.fpsHistoryText.size > 512 || !sameText(viewer.fpsHistoryText, expectedText))
        {
            stayedWithinLimit = false;
        }
        if(i % 25 == 0)
        {
            wait .05;
        }
    }
    check(stayedWithinLimit, "3000 recorded FPS changes retain the exact bounded newest suffix");
    check(sameText(viewer.hud[level.fpsHistoryHudName].lastText, expectedText),
          "recorded-frame HUD receives bounded suffix");
    viewer applyRecordedFrame(demoFrame(1, -1, false, 333, false), true, false);
    check(sameText(viewer.fpsHistoryText, expectedText),
          "recorded duplicate FPS suppression preserved");
    viewer onLoaded();
    check(viewer.fpsHistoryText != "", "live load event does not clear demo history");
    viewer applyRecordedFrame(demoFrame(1, -1, false, 125, false), false, false);
    check(viewer.fpsHistoryText == "1" && viewer.hud[level.fpsHistoryHudName].alpha == 1,
          "new recorded jump removes truncation marker");
    viewer applyRecordedFrame(demoFrame(1, -1, false, 142, false), true, false);
    viewer applyRecordedFrame(demoFrame(1, -1, false, 250, true), true, false);
    for(i = 0; i < 3; i++)
    {
        viewer applyRecordedFrame(demoFrame(1, -1, false, 250, false), true, false);
    }
    check(viewer.fpsHistoryText == "14-2", "recorded bounce separator preserved");
}

verifyLiveSpectatorDisplay(player, viewer)
{
    oversizedHistory = sequence(0, 1000);
    player _setFPSHistory("14-2/3");
    check(viewer.hud[level.fpsHistoryHudName].lastText == "14-2/3",
          "live history delivered to spectator HUD");
    player _setFPSHistory(oversizedHistory);
    check(sameText(player.fpsHistoryText, "..." + getSubStr(oversizedHistory, 491)),
          "direct live setter bounded");
    viewer onSpectatorClientChanged(player);
    check(viewer.hud[level.fpsHistoryHudName].lastText == player.fpsHistoryText,
          "spectator switch receives bounded history and marker");
    viewer onSpectatorClientChanged(undefined);
    check(viewer.fpsHistoryText == "" && viewer.hud[level.fpsHistoryHudName].alpha == 0,
          "leaving spectator target clears and hides HUD");
}

// Use fixed boundary expectations so a change to production limits cannot silently pass.
verifyStringBounds()
{
    check(appendFPSHistory("", "") == "", "empty history");
    check(appendFPSHistory("14-2/", "3") == "14-2/3", "short history and separators unchanged");
    fullHistory = sequence(0, 512);
    check(sameText(appendFPSHistory("", fullHistory), fullHistory),
          "exactly 512 characters unchanged");
    check(sameText(appendFPSHistory(getSubStr(fullHistory, 0, 511), getSubStr(fullHistory, 511)),
                   fullHistory),
          "append up to exact boundary");
    check(sameText(appendFPSHistory(fullHistory, "X"), "..." + getSubStr(fullHistory, 4) + "X"),
          "first overflow retains newest 509 with marker");
    oversizedHistory = sequence(0, 1000);
    check(sameText(appendFPSHistory("old", oversizedHistory),
                   "..." + getSubStr(oversizedHistory, 491)),
          "large incoming chunk trimmed before concatenation");
    check(sameText(appendFPSHistory(oversizedHistory, "X"),
                   "..." + getSubStr(oversizedHistory, 492) + "X"),
          "oversized existing history recovered");
    check(sameText(appendFPSHistory(fullHistory, getSubStr(fullHistory, 0, 509)),
                   "..." + getSubStr(fullHistory, 0, 509)),
          "incoming chunk exactly fills retained payload");
    history = "";
    stayedWithinLimit = true;
    pattern = "142-/3065K";
    for(i = 0; i < 10000; i++)
    {
        history = appendFPSHistory(history, pattern[i % pattern.size]);
        if(history.size > 512)
        {
            stayedWithinLimit = false;
        }
        if(i % 100 == 0)
        {
            wait 0.05;
        }
    }
    check(stayedWithinLimit && sameText(history, "..." + sequence(10000 - 509, 509)),
          "10000 appends preserve exact newest suffix within limit");
}

setupPlayer(player)
{
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 200), (0, 0, 0));
    player.isFirstSpawn = false;
    player openCJ\huds\base::onPlayerConnect();
    player onPlayerConnect();
    player openCJ\huds\hudFPS::onPlayerConnect();
    player.fpsHistoryMode = "compact";
}

sequence(start, count)
{
    pattern = "142-/3065K";
    result = "";
    for(j = 0; j < count; j++)
    {
        result += pattern[(start + j) % pattern.size];
    }
    return result;
}

check(ok, message)
{
    level.checks++;
    if(!ok)
    {
        level.failures++;
    }
    printf("FPS HISTORY SELFTEST " + message + ": " + ok + "\n");
}

finish()
{
    printf("FPS HISTORY SELFTEST COMPLETE failures=" + level.failures + " checks=" + level.checks +
           "\n");
}

// The VM compares interned IDs; long identical strings can have different IDs.
// Check each character so these tests validate the actual retained contents.
sameText(actualText, expectedText)
{
    if(actualText.size != expectedText.size)
    {
        return false;
    }
    for(k = 0; k < actualText.size; k++)
    {
        if(actualText[k] != expectedText[k])
        {
            printf("FPS HISTORY SELFTEST DIAGNOSTIC mismatch index=" + k +
                   " left=" + actualText[k] + " right=" + expectedText[k] + "\n");
            return false;
        }
    }
    return true;
}

setSequence(player, text)
{
    player _beginHistory(text[0]);
    for(j = 1; j < text.size; j++)
    {
        player _recordFPS(text[j]);
    }
}
startMovement(player, forward, right)
{
    player.FPS = 333;
    player.fpsTestTime = 200;
    player _clearFPSHistory();
    player onMovementState(forward, right, 100, true);
    player onMovementState(forward, right, 103, false);
    player.lastGroundEnterTime = getTime() - 1000;
    player onOnGround(false);
}
demoFrame(forward, right, onGround, fps, bounce)
{
    frame = spawnStruct();
    frame.forward = forward > 0;
    frame.back = forward < 0;
    frame.right = right > 0;
    frame.left = right < 0;
    frame.onGround = onGround;
    frame.FPS = fps;
    frame.bounce = bounce;
    frame.loadNow = false;
    return frame;
}
strafeHistory(player, viewer)
{
    verifyLiveModeSwitching(player, viewer);
    verifyLiveStrafeLabels(player, viewer);
    verifyStructuredHistoryBounds(player, viewer);
    verifyRecordedStrafeLabels(player, viewer);
}

verifyLiveModeSwitching(player, viewer)
{
    check(level.settings["specfps"].defaultVal == "detailed",
          "Detailed is the persistent setting default");
    check(isDefined(level.commands["specfps"]) &&
              level.commands["fpshistory"].cmd.name == "specfps",
          "mode command and alias registered for help");
    player setOrigin((0, 0, 5000));
    player setVelocity((0, 0, 0));
    wait .1;
    viewer _onModeChanged("detailed");
    startMovement(player, 1, -1);
    check(player.fpsHistoryText == "3" &&
              viewer.hud[level.fpsHistoryHudName].lastText == "^6WA ^73",
          "detailed takeoff labels held input");
    heldInput(player, 1, 1);
    player openCJ\fps::onFPSChange(250);
    check(player.fpsHistoryText == "32",
          "Compact parastrafe includes only the actual 333->250 change");
    check(viewer.hud[level.fpsHistoryHudName].lastText == "^6WA ^73 ^7> ^2WD ^732",
          "detailed fullbeat and FPS changes grouped");
    heldInput(player, 0, 1);
    check(player.fpsHistoryText == "32" &&
              player.fpsHistoryDetailedText == "^6WA ^73 ^7> ^2WD ^732",
          "Detailed groups landing adjustment within its strafe phase");
    viewer _onModeChanged("compact");
    check(viewer.hud[level.fpsHistoryHudName].alpha == 0,
          "switching live spectator mode hides the current jump");
    startMovement(player, 1, -1);
    player openCJ\fps::onFPSChange(250);
    check(viewer.hud[level.fpsHistoryHudName].lastText == "32",
          "Compact starts on the next jump without key labels");
    viewer _onModeChanged("off");
    player openCJ\fps::onFPSChange(333);
    check(viewer.hud[level.fpsHistoryHudName].alpha == 0, "Off stays hidden while source updates");
    viewer _onModeChanged("detailed");
}

verifyLiveStrafeLabels(player, viewer)
{
    viewer _onModeChanged("detailed");
    startMovement(player, 1, -1);
    heldInput(player, 1, 0);
    heldInput(player, 1, 1);
    check(player.fpsHistoryText == "3",
          "fullbeat switch through W does not repeat unchanged Compact FPS");
    startMovement(player, 1, -1);
    heldInput(player, 0, 1);
    player openCJ\fps::onFPSChange(250);
    check(player.fpsHistoryText == "32" && player.fpsHistoryDetailedText == "^6WA ^732",
          "unconfirmed halfbeat stays in the current Detailed phase");
    heldInput(player, 1, -1);
    check(player.fpsHistoryDetailedText == "^6WA ^73 ^7> ^2D ^732 ^7> ^6WA ^72",
          "confirmed left halfbeat has colored phases");
    startMovement(player, 1, 1);
    heldInput(player, 0, -1);
    heldInput(player, 1, 1);
    check(player.fpsHistoryDetailedText == "^2WD ^73 ^7> ^6A ^73 ^7> ^2WD ^73",
          "confirmed right halfbeat uses A label");
    startMovement(player, -1, -1);
    heldInput(player, -1, 1);
    check(player.fpsHistoryDetailedText == "^6SA ^73 ^7> ^2SD ^73",
          "backward fullbeat labels supported");
    check(inputLabel(0, 0) == "None" && inputLabel(-1, 0) == "S",
          "neutral and S-only actions labelled");
}

verifyStructuredHistoryBounds(player, viewer)
{
    for(j = 0; j < 150; j++)
    {
        heldInput(player, 1, 1 - 2 * (j % 2));
        if(j % 20 == 0)
        {
            wait .05;
        }
    }
    check(player.fpsHistoryEvents.size <= 64 && player.fpsHistoryText.size <= 512 &&
              player.fpsHistoryDetailedText.size <= 512,
          "structured history and both renderings bounded");
    check(getSubStr(player.fpsHistoryDetailedText, 0, 5) == "^7...",
          "detailed history visibly marks truncation");
    viewer onSpectatorClientChanged(player);
    check(viewer.hud[level.fpsHistoryHudName].lastText == player.fpsHistoryDetailedText,
          "new spectator receives current detailed history");
    viewer _onModeChanged("off");
}

verifyRecordedStrafeLabels(player, viewer)
{
    viewer.playingDemo = true;
    viewer _onModeChanged("detailed");
    viewer applyRecordedFrame(demoFrame(1, -1, true, 333, false), false, false);
    viewer applyRecordedFrame(demoFrame(1, -1, false, 333, false), true, false);
    viewer applyRecordedFrame(demoFrame(1, 1, false, 333, false), true, false);
    viewer applyRecordedFrame(demoFrame(1, 1, false, 250, false), true, false);
    repeatDemo(viewer, 1, 1, 250, 2);
    check(viewer.fpsHistoryText == "32" &&
              viewer.fpsHistoryDetailedText == "^6WA ^73 ^7> ^2WD ^732",
          "demo frames share detailed parastrafe history");
    viewer applyRecordedFrame(demoFrame(1, -1, true, 333, false), false, false);
    viewer applyRecordedFrame(demoFrame(1, -1, false, 333, false), true, false);
    viewer applyRecordedFrame(demoFrame(1, 1, false, 250, false), true, false);
    repeatDemo(viewer, 1, 1, 250, 3);
    check(viewer.fpsHistoryText == "32", "same-frame FPS/key change does not invent an extra 333");
    viewer applyRecordedFrame(demoFrame(1, 1, true, 250, false), true, false);
    viewer applyRecordedFrame(demoFrame(1, 1, false, 250, false), true, false);
    check(viewer.fpsHistoryText == "32/2", "demo bhop retains history with matching separator");
    viewer applyRecordedFrame(demoFrame(1, 1, true, 333, false), true, false);
    for(j = 0; j < 5; j++)
    {
        viewer applyRecordedFrame(demoFrame(1, 1, true, 333, false), true, false);
    }
    viewer applyRecordedFrame(demoFrame(1, 1, false, 333, false), true, false);
    check(viewer.fpsHistoryText == "3",
          "300 ms demo ground contact is not misclassified using recorded client FPS");
    viewer applyRecordedFrame(demoFrame(0, -1, false, 250, false), false, false);
    check(viewer.fpsHistoryText == "2" && viewer.fpsHistoryDetailedText == "^6A ^72",
          "seek or reversed playback starts fresh history");
    viewer applyRecordedFrame(demoFrame(1, 1, false, 333, false), true, true);
    check(viewer.fpsHistoryText == "2", "interpolation creates no phantom input actions");
    saved = spawnStruct();
    saved.fpshistory = player.fpshistory;
    saved.fpsHistoryText = player.fpsHistoryText;
    saved.fpsHistoryEvents = player.fpsHistoryEvents;
    saved.fpsHistoryTruncated = player.fpsHistoryTruncated;
    saved.fpsHistoryShortFPS = player.fpshistory["shortfps"];
    saved.fpsHistoryStyle = player.fpsHistoryStyle;
    viewer restoreLiveHistory(saved);
    check(viewer.fpsHistoryText == saved.fpsHistoryText &&
              viewer.fpshistory["shortfps"] == saved.fpsHistoryShortFPS,
          "return from demo restores structured history and original FPS");
    viewer notify("fpshistory_ongroundchange");
    viewer _clearDemoFPSHistory();
    viewer.playingDemo = false;
    viewer _onModeChanged("compact");
    player onLoaded();
}

// Regression for noisy real-demo input: adjustments stay within a Detailed phase.
phaseGrouping(player, viewer)
{
    verifyFullbeatReleaseGrouping(player, viewer);
    verifyHalfbeatReleaseGrouping(player);
    verifyEstablishedStyleGrouping(player, viewer);
}

verifyFullbeatReleaseGrouping(player, viewer)
{
    viewer _onModeChanged("detailed");
    startMovement(player, 1, -1);
    heldInput(player, 1, 0);
    heldInput(player, 1, 1);
    player _recordFPS("2");
    heldInput(player, 0, 1);
    heldInput(player, 0, 0);
    player _recordFPS("3");
    heldInput(player, 1, 1);
    groups = phaseActions(player.fpsHistoryEvents);
    check(groups.size == 2 && groups[0].keys == "WA" && groups[1].keys == "WD",
          "Detailed fullbeat suppresses W/D/neutral release rows");
    check(groups[1].fps == "323", "Detailed retains FPS transitions across ignored releases");
}

verifyHalfbeatReleaseGrouping(player)
{
    // A lone opposite key is not enough to call a landing adjustment halfbeat.
    startMovement(player, 1, -1);
    heldInput(player, 0, 1);

    heldInput(player, 1, -1);
    groups = phaseActions(player.fpsHistoryEvents, player.fpsHistoryStyle);
    check(groups.size == 3 && groups[0].keys == "WA" && groups[1].keys == "D" &&
              groups[2].keys == "WA" && player.fpsHistoryStyle.kind == "halfbeat",
          "WA D WA confirms halfbeat and recovers the first D in its trail");
    heldInput(player, 1, 1);
    heldInput(player, 1, 0);
    heldInput(player, 0, 0);
    player _recordFPS("2");
    heldInput(player, 0, 1);
    heldInput(player, 1, -1);
    groups = phaseActions(player.fpsHistoryEvents, player.fpsHistoryStyle);
    check(groups.size == 5 && groups[2].keys == "WA" && groups[2].fps == "32" &&
              groups[3].keys == "D",
          "confirmed halfbeat ignores WD W and neutral adjustments while retaining FPS");

    startMovement(player, 1, 1);
    heldInput(player, 0, -1);
    heldInput(player, 1, 1);
    heldInput(player, 1, -1);
    heldInput(player, 1, 1);
    groups = phaseActions(player.fpsHistoryEvents, player.fpsHistoryStyle);
    check(groups.size == 3 && groups[1].keys == "A" && groups[2].keys == "WD",
          "confirmed WD A WD halfbeat suppresses WA air-control input");
}

verifyEstablishedStyleGrouping(player, viewer)
{
    startMovement(player, 1, -1);
    heldInput(player, 1, 1);
    heldInput(player, 0, 1);
    heldInput(player, 1, 1);
    heldInput(player, 0, 0);
    heldInput(player, 0, -1);
    heldInput(player, -1, 0);
    heldInput(player, 0, 1);
    groups = phaseActions(player.fpsHistoryEvents, player.fpsHistoryStyle);
    check(groups.size == 2 && groups[1].keys == "WD" && player.fpsHistoryStyle.kind == "fullbeat",
          "recorded Moon fullbeat landing A S D taps never change the established style");
    heldInput(player, 1, 1);
    heldInput(player, 0, -1);
    heldInput(player, 1, 1);
    check(player.fpsHistoryStyle.kind == "fullbeat",
          "later braking alternation does not reclassify an established fullbeat jump");
    startMovement(player, 1, 0);
    heldInput(player, 0, 0);
    heldInput(player, -1, 0);
    player _recordFPS("2");
    heldInput(player, 0, -1);
    heldInput(player, 0, 1);
    groups = phaseActions(player.fpsHistoryEvents, player.fpsHistoryStyle);
    check(groups.size == 1 && groups[0].keys == "W" && groups[0].fps == "32",
          "straight W jump keeps its label through S braking and A D landing steering");
    startMovement(player, -1, -1);
    heldInput(player, -1, 1);
    heldInput(player, -1, 0);
    heldInput(player, 0, 1);
    groups = phaseActions(player.fpsHistoryEvents);
    check(groups.size == 2 && groups[1].keys == "SD",
          "backward fullbeat release adjustments stay in their phase");

    viewer notify("fpshistory_ongroundchange");
    viewer _clearDemoFPSHistory();
    viewer.playingDemo = false;
    viewer _onModeChanged("compact");
    player onLoaded();
}

// Advance input-command time without sleeping; production still owns the gate.
heldInput(player, forward, right)
{
    player.fpsTestTime += 200;
    player onMovementState(forward, right, player.fpsTestTime, false);
    player onMovementState(forward, right, player.fpsTestTime + 150, false);
}

repeatDemo(player, forward, right, fps, count)
{
    for(k = 0; k < count; k++)
    {
        player applyRecordedFrame(demoFrame(forward, right, false, fps, false), true, false);
    }
}

heldDuration(player, viewer)
{
    verifyInputDurationThreshold(player, viewer);
    verifyLiveInputConfirmation(player);
    verifyPendingMarkerFPS(player);
    verifyReplacementInputTimer(player);
    verifyRecordedInputDuration(player, viewer);
}

verifyInputDurationThreshold(player, viewer)
{
    player setOrigin((0, 0, 5000));
    player setVelocity((0, 0, 0));
    viewer _onModeChanged("detailed");
    startMovement(player, 1, -1);
    player onMovementState(1, 1, 200, false);
    player _recordFPS("2");
    player onMovementState(1, 1, 349, false);

    check(player.fpsHistoryEvents.size == 1 && player.fpsHistoryText == "3" &&
              viewer.hud[level.fpsHistoryHudName].lastText == "^6WA ^73",
          "149 ms remains pending in Compact and Detailed");
    player onMovementState(1, 1, 350, false);
    check(player.fpsHistoryText == "32" &&
              viewer.hud[level.fpsHistoryHudName].lastText == "^6WA ^73 ^7> ^2WD ^732",
          "confirmed phase keeps its opening FPS in Detailed and deduplicates Compact");

    startMovement(player, 1, -1);
    for(k = 0; k < 20; k++)
    {
        player onMovementState(1, 1, 200 + k * 200, false);
        player _recordFPS("2");
        player _recordFPS("3");
        player onMovementState(1, -1, 349 + k * 200, false);
    }

    check(player.fpsHistoryEvents.size == 1 && !isDefined(player.fpsHistoryStyle) &&
              !isSubStr(player.fpsHistoryText, "|") &&
              !isSubStr(player.fpsHistoryDetailedText, "WD"),
          "rapid alternation creates neither a strafe entry nor a style");
    check(player.fpsHistoryEvents[0].fps.size == 41 &&
              getSubStr(player.fpsHistoryEvents[0].fps, 0, 5) == "32323",
          "rejected taps merge every FPS transition into the existing phase");
    check(player.fpsHistoryDetailedText == "^6WA ^7...32323",
          "Detailed abbreviates long FPS runs with a visible marker");

    startMovement(player, 1, -1);
    player onMovementState(1, 1, 200, false);
    player _recordFPS("2");
    player onMovementState(1, -1, 350, false);
    check(player.fpsHistoryText == "32",
          "release exactly at the threshold retains the held strafe");
    player onMovementState(1, -1, 500, false);
    check(player.fpsHistoryText == "32", "confirmed return phase adds no unchanged Compact FPS");
}

// Exercise real timers: no second input callback, then cancellation by load and landing.
verifyLiveInputConfirmation(player)
{
    startMovement(player, 1, -1);
    player onMovementState(1, 1, 200, false);
    wait .2;
    check(player.fpsHistoryText == "3", "live hold confirms without another input-change callback");

    startMovement(player, 1, -1);
    player onMovementState(1, 1, 200, false);
    player onLoaded();
    wait .2;
    check(player.fpsHistoryText == "" && !isDefined(player.fpsHistoryPending),
          "load cancels a waiting confirmation");

    startMovement(player, 1, -1);
    player onMovementState(1, 1, 200, false);
    player _recordFPS("2");
    player onMovementState(1, 1, 300, true);
    wait .2;
    check(player.fpsHistoryText == "32" && !isDefined(player.fpsHistoryPending),
          "landing rejects a short phase without losing its FPS");
}

verifyPendingMarkerFPS(player)
{
    startMovement(player, 1, -1);
    player onMovementState(1, 1, 200, false);
    player _recordFPS("2");
    player _action("bounce", "", false);
    player _recordFPS("3");
    check(player.fpsHistoryText == "32-" && player.fpsHistoryPending.fps == "23",
          "pending FPS is split at the bounce while the held input keeps its duration");
    wait .2;

    player _action("bhop", "", false);
    player _recordFPS("2");
    check(player.fpsHistoryDetailedText ==
              "^6WA ^732 ^7> ^5BOUNCE^7 ^7> ^2WD ^73 ^7> ^3BHOP^7 ^7> ^2WD ^72",
          "Detailed preserves named markers alongside recent phases");
}

// Replacing a candidate must stop its old timer before the new hold can be accepted.
verifyReplacementInputTimer(player)
{
    startMovement(player, 1, -1);
    player onMovementState(0, 1, 200, false);
    player onMovementState(1, -1, 349, false);
    check(!isDefined(player.fpsHistoryStyle) && player.fpsHistoryEvents.size == 1,
          "short halfbeat taps cannot confirm a repeating pattern");

    startMovement(player, 1, -1);
    player onMovementState(1, 1, 200, false);
    player onMovementState(0, -1, 300, false);
    wait .1;
    check(player.fpsHistoryEvents.size == 1,
          "replacement candidate is not confirmed by the previous timer");
    wait .1;
    check(player.fpsHistoryEvents.size == 2 && player.fpsHistoryEvents[1].keys == "A",
          "replacement candidate gets its own complete hold");
}

// Wall time cannot confirm recorded input; only new samples advance its duration.
verifyRecordedInputDuration(player, viewer)
{
    viewer.playingDemo = true;
    viewer applyRecordedFrame(demoFrame(1, -1, false, 333, false), false, false);
    repeatDemo(viewer, 1, 1, 333, 1);
    wait .2;
    check(viewer.fpsHistoryText == "3" && isDefined(viewer.fpsHistoryPending),
          "wall time during a paused demo never confirms a strafe");
    repeatDemo(viewer, 1, 1, 250, 2);
    check(viewer.fpsHistoryText == "3", "100 ms recorded duration stays pending");
    repeatDemo(viewer, 1, 1, 250, 1);
    check(viewer.fpsHistoryText == "32",
          "150 ms of recorded samples confirms the phase without repeating Compact FPS");
    repeatDemo(viewer, 1, -1, 333, 1);
    viewer applyRecordedFrame(demoFrame(-1, 1, false, 250, false), false, false);
    wait .2;
    check(viewer.fpsHistoryText == "2" && !isDefined(viewer.fpsHistoryPending) &&
              viewer.fpsHistoryDetailedText == "^2SD ^72",
          "demo seek discards previous pending input");

    viewer notify("fpshistory_ongroundchange");
    viewer _clearDemoFPSHistory();
    viewer.playingDemo = false;
    viewer _onModeChanged("compact");
    player onLoaded();
}

detailedWindow(viewer)
{
    check(viewer _onModeChanged("live") && viewer.fpsHistoryMode == "detailed",
          "retired saved Live preference falls back to Detailed");
    actions = [];
    for(i = 0; i < 7; i++)
    {
        event = spawnStruct();
        event.kind = "move";
        event.keys = "WA";
        event.fps = "" + i;
        actions[i] = event;
        if(i == 5)
        {
            check(renderDetailed(actions, false) ==
                      "^6WA ^70 ^7> ^6WA ^71 ^7> ^6WA ^72 ^7> ^6WA ^73 ^7> ^6WA ^74 ^7> ^6WA ^75",
                  "Detailed keeps six whole recent actions without truncation");
        }
    }
    check(renderDetailed(actions, false) ==
              "^7... > ^6WA ^71 ^7> ^6WA ^72 ^7> ^6WA ^73 ^7> ^6WA ^74 ^7> ^6WA ^75 ^7> ^6WA ^76",
          "seventh action truncates the oldest with a visible marker");
    viewer _onModeChanged("compact");
}

playbackControls(player)
{
    player.demoRate = 1;
    player.playbackPaused = true;
    rates = playbackRates();
    for(direction = 0; direction < 2; direction++)
    {
        directionName = "forward";
        directionSign = 1;
        if(direction)
        {
            directionName = "reverse";
            directionSign = -1;
        }
        player openCJ\demos::setDemoDirection(directionName);
        for(i = 0; i < rates.size; i++)
        {
            accepted = player openCJ\demos::setDemoSpeed(rates[i]);
            check(accepted && player.demoRate == directionSign * float(rates[i]) &&
                      player.playbackPaused,
                  "speed choice preserves direction and pause " + directionName + " " + rates[i]);
            advancedFrameCount = 0;
            for(tick = 0; tick < 20; tick++)
            {
                advancedFrameCount += player openCJ\demos::demoFrameStep();
            }
            check(advancedFrameCount == directionSign * 20 * float(rates[i]),
                  "one second advances the correct recorded frames " + directionName + " " +
                      rates[i]);
        }
    }
    player openCJ\demos::setDemoSpeed("0.25");
    check(player openCJ\demos::demoFrameStep() == 0,
          "quarter speed holds the current frame initially");
    player openCJ\demos::setDemoDirection("toggle");
    check(player.demoRate == .25 && player.demoStepRemainder == 0 && player.playbackPaused,
          "direction toggle preserves speed and clears fractional remainder");
    acceptedZero = player openCJ\demos::setDemoSpeed("0");
    acceptedUnsupportedRate = player openCJ\demos::setDemoSpeed("0.75");
    acceptedText = player openCJ\demos::setDemoSpeed("bad");
    check(!acceptedZero && !acceptedUnsupportedRate && !acceptedText && player.demoRate == .25,
          "invalid speed responses leave playback unchanged");

    // Exercise the actual menu notification consumer, including pause/resume.
    player.playingDemo = true;
    player thread openCJ\demos::demoMenuResponses();
    player notify("menuresponse", "opencj_demo", "speed_0.5");
    wait .05;
    check(player.demoRate == .5 && player.playbackPaused, "menu speed selection does not unpause");
    player notify("menuresponse", "opencj_demo", "direction");
    wait .05;
    check(player.demoRate == -.5 && player.playbackPaused,
          "menu direction toggle is independent of speed");
    player notify("menuresponse", "opencj_demo", "resume");
    wait .05;
    check(!player.playbackPaused && player.demoRate == -.5, "resume retains reverse half speed");
    player notify("menuresponse", "opencj_demo", "pause");
    wait .05;
    check(player.playbackPaused, "menu pause is independent of selected speed");
    player.playingDemo = false;
}

// Exercise the actual native cursor and production history pipeline at every
// supported rate, including reverse/seek, fractional camera poses and markers.
playbackSampling(player)
{
    demoID = createSamplingRecording(player);
    if(!isDefined(demoID))
    {
        return;
    }
    reference = buildSamplingReference(player);
    verifySamplingRates(player, reference);
    verifySamplingSeeks(player, reference);
    verifySamplingModeChanges(player);
    verifyInterpolationBoundaries();
    player.demoBegin = 0;
    player.demoEnd = 699;
    player.playingDemo = false;
    player onLoaded();
    destroyDemo(demoID);
}

// Include a long landing, a bounce, and a bhop in one deterministic native recording.
createSamplingRecording(player)
{
    demoID = 1800000092;
    if(!isDefined(createDemo(demoID)))
    {
        check(false, "sampling demo allocation succeeds");
        return undefined;
    }
    for(i = 0; i < 700; i++)
    {
        flags = level.demoFlags.forward | level.demoFlags.left;
        if(i >= 2)
        {
            flags = level.demoFlags.forward | level.demoFlags.right;
        }
        fps = 333;
        if(i >= 3)
        {
            fps = 250;
        }
        if(i >= 40 && i < 100)
        {
            flags |= level.demoFlags.onGround;
        }
        if(i == 110)
        {
            flags |= level.demoFlags.bounce;
        }
        if(i == 120)
        {
            flags |= level.demoFlags.onGround;
        }
        addFrameToDemo(demoID, (i, 0, 5000), (0, 0, 0), 1, flags, 0, 0, 0, fps, 0);
    }
    player selectPlaybackDemo(demoID);
    player.demoID = demoID;
    player.demoBegin = 0;
    player.demoEnd = 699;
    player.demoStyle = 0;
    player.playingDemo = true;
    return demoID;
}

// Derive expected history by consuming every source sample in chronological order.
buildSamplingReference(player)
{
    // Establish the independent, sequential per-source-frame reference.
    detailedText = [];
    compactText = [];
    for(i = 0; i < 160; i++)
    {
        skipFrames = 1;
        if(i == 0)
        {
            skipFrames = 0;
        }
        frame = player openCJ\demos::_getDemoFrame(skipFrames, false);
        player applyRecordedFrame(frame, i > 0, false);
        detailedText[i] = player.fpsHistoryDetailedText;
        compactText[i] = player.fpsHistoryText;
    }
    check(compactText[6] == "32", "source reference contains only actual parastrafe FPS changes");
    check(compactText[79] != "" && compactText[80] == "",
          "landing expiry follows two seconds of recorded time");
    check(isSubStr(detailedText[110], "BOUNCE") && isSubStr(detailedText[121], "BHOP"),
          "source reference includes bounce and bhop markers");
    reference = spawnStruct();
    reference.detailed = detailedText;
    reference.compact = compactText;
    return reference;
}

verifySamplingRates(player, reference)
{
    rates = playbackRates();
    for(modeIndex = 0; modeIndex < 2; modeIndex++)
    {
        player.fpsHistoryMode = "detailed";
        if(modeIndex)
        {
            player.fpsHistoryMode = "compact";
        }
        for(i = 0; i < rates.size; i++)
        {
            verifySampledDirection(player, reference, rates[i], "forward");
            verifySampledDirection(player, reference, rates[i], "reverse");
            accepted = player openCJ\demos::setDemoSpeed("" + float(rates[i]));
            check(accepted, "keyboard speed formatting remains accepted " + rates[i]);
        }
    }
}

// Both directions must show source-time history, a smooth camera and an unchanged read cursor.
verifySampledDirection(player, reference, rate, direction)
{
    sampledFrameCount = 128;
    player openCJ\demos::setDemoDirection(direction);
    if(direction == "forward")
    {
        player openCJ\demos::setDemoSpeed(rate);
        seekSamplingFrame(player, 0);
        player.demoFPSCacheKey = undefined;
    }
    // Reverse intentionally retains the completed cache for backwards lookup.
    player.demoFirstFrame = true;
    frame = player openCJ\demos::advanceDemoFrame();
    player openCJ\demos::syncDemoFPSHistory(frame.number);
    historyMatched = true;
    cameraWasSmooth = true;
    cursorWasPreserved = true;
    tickCount = int(sampledFrameCount / float(rate));
    for(tick = 1; tick <= tickCount; tick++)
    {
        frame = player openCJ\demos::advanceDemoFrame();
        player openCJ\demos::syncDemoFPSHistory(frame.number);
        if(player.fpsHistoryMode == "detailed" &&
           !sameText(player.fpsHistoryDetailedText, reference.detailed[frame.number]))
        {
            historyMatched = false;
        }
        if(player.fpsHistoryMode == "compact" &&
           !sameText(player.fpsHistoryText, reference.compact[frame.number]))
        {
            historyMatched = false;
        }
        expectedOriginX = tick * float(rate);
        if(direction == "reverse")
        {
            expectedOriginX = sampledFrameCount - expectedOriginX;
        }
        if(abs(frame.origin[0] - expectedOriginX) > .001)
        {
            cameraWasSmooth = false;
        }
        if(player skipPlaybackFrames(0) != frame.number)
        {
            cursorWasPreserved = false;
        }
        if(tick % 40 == 0)
        {
            wait .05;
        }
    }
    check(historyMatched, direction + " history matches source chronology at speed " + rate);
    check(cameraWasSmooth && cursorWasPreserved,
          direction + " camera interpolation preserves the source cursor " + rate);
}

verifySamplingSeeks(player, reference)
{
    player.fpsHistoryMode = "detailed";
    // Fresh seeks must rebuild without feeding backwards samples into the HUD.
    player.demoFPSCacheKey = undefined;
    seekSamplingFrame(player, 121);
    player openCJ\demos::syncDemoFPSHistory(121);
    check(sameText(player.fpsHistoryDetailedText, reference.detailed[121]) &&
              player skipPlaybackFrames(0) == 121,
          "uncached seek rebuilds complete chronological history and restores presentation cursor");
    player openCJ\demos::syncDemoFPSHistory(80);
    check(player.fpsHistoryDetailedText == "", "cached grounded frame shows expired history");
    seekSamplingFrame(player, 122);
    player openCJ\demos::syncDemoFPSHistory(122);
    check(sameText(player.fpsHistoryDetailedText, reference.detailed[122]),
          "resuming forward after cached rewind restores the event builder text");
    player.demoFPSCacheKey = undefined;
    seekSamplingFrame(player, 699);
    player openCJ\demos::syncDemoFPSHistory(699);
    check(cachedHistoryFrameCount(player) == 512 && player skipPlaybackFrames(0) == 699 &&
              getSubStr(player.fpsHistoryDetailedText, 0, 6) == "^7... ",
          "far airborne seek bounds rebuild and displays truncation");
    player.demoBegin = 690;
    player openCJ\demos::syncDemoFPSHistory(699);
    check(cachedHistoryFrameCount(player) == 10 && !player.fpsHistoryTruncated,
          "clip range change invalidates the cached chronology");
}

verifySamplingModeChanges(player)
{
    player.demoBegin = 0;
    player _onModeChanged("compact");
    check(cachedHistoryFrameCount(player) == 0, "changing mode discards all previous mode text");
    player openCJ\demos::syncDemoFPSHistory(699);
    check(player.demoFPSWaiting && cachedHistoryFrameCount(player) == 0,
          "mode switch waits through the current airborne jump");
    seekSamplingFrame(player, 40);
    player openCJ\demos::syncDemoFPSHistory(40);
    seekSamplingFrame(player, 100);
    player openCJ\demos::syncDemoFPSHistory(100);
    check(!player.demoFPSWaiting && cachedHistoryFrameCount(player) == 1 &&
              player.fpsHistoryText == "2",
          "selected mode begins afresh on the next takeoff");
    seekSamplingFrame(player, 16);
    player openCJ\demos::syncDemoFPSHistory(16);
    check(player skipPlaybackFrames(0) == 16 && isDefined(player demoFPSRead(16)),
          "after the new jump starts the selected mode can seek earlier normally");
    player _onModeChanged("off");
    player openCJ\demos::syncDemoFPSHistory(100);
    check(cachedHistoryFrameCount(player) == 0 && player.fpsHistoryEvents.size == 0,
          "Off retains no demo FPS display history");
    player.fpsHistoryMode = "detailed";
    player.demoFPSFloor = undefined;
    player.demoFPSWaiting = false;
}

verifyInterpolationBoundaries()
{
    previousFrame = spawnStruct();
    nextFrame = spawnStruct();
    previousFrame.number = 0;
    nextFrame.number = 1;
    previousFrame.origin = (0, 0, 0);
    nextFrame.origin = (10, 0, 0);
    previousFrame.loadNow = false;
    nextFrame.loadNow = false;
    check(openCJ\demos::canBlendDemoFrames(previousFrame, nextFrame) &&
              openCJ\demos::canBlendDemoFrames(nextFrame, previousFrame),
          "adjacent movement can interpolate in both directions");
    nextFrame.loadNow = true;
    check(!openCJ\demos::canBlendDemoFrames(previousFrame, nextFrame) &&
              !openCJ\demos::canBlendDemoFrames(nextFrame, previousFrame),
          "load boundaries never interpolate in either direction");
    nextFrame.loadNow = false;
    nextFrame.number = 3;
    check(!openCJ\demos::canBlendDemoFrames(previousFrame, nextFrame),
          "edited timeline cuts never interpolate");
    nextFrame.number = 1;
    nextFrame.origin = (1000, 0, 0);
    check(!openCJ\demos::canBlendDemoFrames(previousFrame, nextFrame),
          "legacy teleports do not blend through the map");
    check(openCJ\demos::blendDemoAngle(179, -179, .5) == 180 &&
              openCJ\demos::blendDemoAngle(-179, 179, .5) == -180,
          "view rotation crosses wrap by the shortest arc");
}

// Express an absolute seek using the native cursor's relative movement interface.
seekSamplingFrame(player, frameIndex)
{
    currentFrame = player skipPlaybackFrames(0);
    player skipPlaybackFrames(frameIndex - currentFrame);
}

cachedHistoryFrameCount(player)
{
    stats = player demoFPSStats();
    cachedFrameCountIndex = 1;
    return stats[cachedFrameCountIndex];
}

playbackRates()
{
    rates = [];
    rates[0] = "0.25";
    rates[1] = "0.5";
    rates[2] = "1";
    rates[3] = "2";
    rates[4] = "4";
    return rates;
}

// A bounce window groups its setup without blacking out actual FPS switches.
bounceBoundaries(player)
{
    player.playingDemo = true;
    player applyRecordedFrame(demoFrame(1, -1, false, 333, false), false, false);
    repeatDemo(player, 1, -1, 250, 1);
    player applyRecordedFrame(demoFrame(1, -1, false, 250, true), true, false);
    repeatDemo(player, 1, -1, 333, 1);
    repeatDemo(player, 1, 1, 333, 1);
    check(player.fpsHistoryText == "32-",
          "bounce setup waits instead of flashing the approach strafe");
    repeatDemo(player, 1, 1, 333, 2);
    check(player.fpsHistoryText == "32-", "bounce exit input still needs its full 150 ms");
    repeatDemo(player, 1, 1, 333, 1);
    check(player.fpsHistoryText == "32-3" &&
              player.fpsHistoryDetailedText == "^6WA ^732 ^7> ^5BOUNCE^7 ^7> ^2WD ^73",
          "Moon bounce exit groups 250->333 then WA->WD into the confirmed exit phase");
    check(player.fpsHistoryEvents[2].fps == "23", "raw bounce samples remain intact");
    repeatDemo(player, 1, 1, 250, 1);
    check(player.fpsHistoryText == "32-32", "post-bounce FPS change remains visible");
    player applyRecordedFrame(demoFrame(1, 1, true, 333, false), true, false);
    check(player.fpsHistoryText == "32-32", "FPS switch first recorded on ground is excluded");

    player applyRecordedFrame(demoFrame(1, -1, false, 250, false), false, false);
    player applyRecordedFrame(demoFrame(1, -1, false, 250, true), true, false);
    repeatDemo(player, 1, -1, 333, 1);
    repeatDemo(player, 1, -1, 250, 1);
    repeatDemo(player, 1, -1, 333, 1);
    check(player.fpsHistoryText == "2-323",
          "all rapid 333->250->333 changes inside the bounce window survive");
    repeatDemo(player, 1, -1, 333, 1);
    check(player.fpsHistoryText == "2-323", "unchanged FPS does not add another digit");

    player applyRecordedFrame(demoFrame(1, -1, false, 250, false), false, false);
    player applyRecordedFrame(demoFrame(1, -1, false, 333, true), true, false);
    repeatDemo(player, 1, -1, 250, 1);
    repeatDemo(player, 1, -1, 333, 2);
    check(player.fpsHistoryText == "2-323",
          "FPS already changed in the bounce sample is not mistaken for carried input");

    player applyRecordedFrame(demoFrame(1, -1, false, 250, false), false, false);
    player applyRecordedFrame(demoFrame(1, -1, false, 250, true), true, false);
    repeatDemo(player, 1, -1, 250, 3);
    check(player.fpsHistoryText == "2-2",
          "unchanged bounce exit FPS is published after the window");
    repeatDemo(player, 1, -1, 333, 1);
    check(player.fpsHistoryText == "2-23", "later FPS change keeps the established exit FPS");
    repeatDemo(player, 1, 1, 333, 4);
    check(player.fpsHistoryDetailedText == "^6WA ^72 ^7> ^5BOUNCE^7 ^7> ^6WA ^723 ^7> ^2WD ^73",
          "strafe beginning after the bounce window stays a separate phase");

    player applyRecordedFrame(demoFrame(1, -1, false, 250, false), false, false);
    player applyRecordedFrame(demoFrame(1, -1, false, 250, true), true, false);
    repeatDemo(player, 1, 1, 333, 1);
    repeatDemo(player, 1, -1, 250, 1);
    repeatDemo(player, 1, -1, 333, 1);
    check(player.fpsHistoryText == "2-323" && !isSubStr(player.fpsHistoryDetailedText, "WD"),
          "rejected short exit tap retains its FPS without creating a strafe");

    player applyRecordedFrame(demoFrame(1, 1, false, 250, false), false, false);
    repeatDemo(player, 1, 1, 333, 4);
    player applyRecordedFrame(demoFrame(1, 1, true, 333, false), true, false);
    check(player.fpsHistoryText == "23", "genuine 333 change 200 ms before landing stays visible");

    player _clearDemoFPSHistory();
    player.playingDemo = false;
}

compactFPSChanges(player)
{
    player.playingDemo = true;
    player applyRecordedFrame(demoFrame(1, -1, false, 333, false), false, false);
    repeatDemo(player, 1, 1, 333, 4);
    repeatDemo(player, 1, -1, 333, 4);
    check(player.fpsHistoryText == "3" &&
              player.fpsHistoryDetailedText == "^6WA ^73 ^7> ^2WD ^73 ^7> ^6WA ^73",
          "constant FPS across fullbeat switches stays one digit only in Compact");
    repeatDemo(player, 1, -1, 250, 1);
    repeatDemo(player, 1, 1, 250, 4);
    repeatDemo(player, 1, 1, 333, 1);
    check(player.fpsHistoryText == "323",
          "real FPS changes survive independently of strafe boundaries");

    player applyRecordedFrame(demoFrame(1, -1, false, 333, false), false, false);
    repeatDemo(player, 0, 1, 333, 4);
    repeatDemo(player, 1, -1, 333, 4);
    check(player.fpsHistoryText == "3" &&
              player.fpsHistoryDetailedText == "^6WA ^73 ^7> ^2D ^73 ^7> ^6WA ^73",
          "confirmed halfbeat retains Detailed phases without duplicate Compact FPS");

    player applyRecordedFrame(demoFrame(1, -1, false, 333, false), false, false);
    repeatDemo(player, 1, -1, 250, 1);
    player applyRecordedFrame(demoFrame(1, -1, false, 250, true), true, false);
    repeatDemo(player, 1, -1, 333, 1);
    repeatDemo(player, 1, 1, 333, 4);
    repeatDemo(player, 1, 1, 250, 1);
    repeatDemo(player, 1, -1, 250, 4);
    repeatDemo(player, 1, 1, 250, 2);
    repeatDemo(player, 1, 1, 333, 2);
    check(player.fpsHistoryText == "32-323",
          "Basic skip Compact collapses repeated 250 at each strafe");
    check(player.fpsHistoryDetailedText ==
              "^6WA ^732 ^7> ^5BOUNCE^7 ^7> ^2WD ^732 ^7> ^6WA ^72 ^7> ^2WD ^723",
          "Basic skip Detailed retains the accepted strafe breakdown");
    player _clearDemoFPSHistory();
    player.playingDemo = false;
}
