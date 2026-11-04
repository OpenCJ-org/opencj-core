main()
{
    level.failures = 0;
    level.checks = 0;
    openCJ\huds\infiniteHuds::onInit();
    openCJ\huds\hudFPSHistory::onInit();
    wait 1;

    check(openCJ\huds\hudFPSHistory::appendFPSHistory("", "") == "", "empty history");
    check(openCJ\huds\hudFPSHistory::appendFPSHistory("14-2/", "3") == "14-2/3", "short history and separators unchanged");
    full = sequence(0, 512);
    check(sameText(openCJ\huds\hudFPSHistory::appendFPSHistory("", full), full), "exactly 512 characters unchanged");
    check(sameText(openCJ\huds\hudFPSHistory::appendFPSHistory(getSubStr(full, 0, 511), getSubStr(full, 511)), full), "append up to exact boundary");
    check(sameText(openCJ\huds\hudFPSHistory::appendFPSHistory(full, "X"), "..." + getSubStr(full, 4) + "X"), "first overflow retains newest 509 with marker");
    large = sequence(0, 1000);
    check(sameText(openCJ\huds\hudFPSHistory::appendFPSHistory("old", large), "..." + getSubStr(large, 491)), "large incoming chunk trimmed before concatenation");
    check(sameText(openCJ\huds\hudFPSHistory::appendFPSHistory(large, "X"), "..." + getSubStr(large, 492) + "X"), "oversized existing history recovered");
    check(sameText(openCJ\huds\hudFPSHistory::appendFPSHistory(full, getSubStr(full, 0, 509)), "..." + getSubStr(full, 0, 509)), "incoming chunk exactly fills retained payload");
    history = "";
    bounded = true;
    pattern = "142-/3065K";
    for (i = 0; i < 10000; i++)
    {
        history = openCJ\huds\hudFPSHistory::appendFPSHistory(history, pattern[i % pattern.size]);
        if (history.size > 512) bounded = false;
        if (i % 100 == 0) wait 0.05;
    }
    check(bounded && sameText(history, "..." + sequence(10000 - 509, 509)), "10000 appends preserve exact newest suffix within limit");

    player = addTestClient();
    viewer = addTestClient();
    check(isDefined(player) && isDefined(viewer), "two real test clients");
    if (!isDefined(player) || !isDefined(viewer))
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
    player openCJ\huds\hudFPSHistory::_setFPSHistory("14-2/3");
    check(viewer.hud[level.fpsHistoryHudName].lastText == "14-2/3", "live history delivered to spectator HUD");
    player openCJ\huds\hudFPSHistory::_setFPSHistory(large);
    check(sameText(player.fpsHistoryText, "..." + getSubStr(large, 491)), "direct live setter bounded");
    viewer openCJ\huds\hudFPSHistory::onSpectatorClientChanged(player);
    check(viewer.hud[level.fpsHistoryHudName].lastText == player.fpsHistoryText, "spectator switch receives bounded history and marker");
    viewer openCJ\huds\hudFPSHistory::onSpectatorClientChanged(undefined);
    check(viewer.fpsHistoryText == "" && viewer.hud[level.fpsHistoryHudName].alpha == 0, "leaving spectator target clears and hides HUD");

    viewer followPlayer(-1);
    player openCJ\huds\hudFPSHistory::_clearFPSHistory();
    viewer.playingDemo = true;
    viewer openCJ\huds\hudFPSHistory::clearAndSetDemoFPS("");
    bounded = true;
    for (i = 0; i < 3000; i++)
    {
        token = pattern[i % pattern.size];
        player openCJ\huds\hudFPSHistory::_addFPSHistory(token);
        viewer openCJ\huds\hudFPSHistory::addDemoFPSHistory(token);
        if (player.fpsHistoryText.size > 512 || !sameText(viewer.fpsHistoryText, player.fpsHistoryText)) bounded = false;
        if (i % 25 == 0) wait 0.05;
    }
    expected = "..." + sequence(3000 - 509, 509);
    check(bounded && sameText(player.fpsHistoryText, expected), "3000 live and 3000 demo appends agree at every step");
    check(sameText(viewer.hud[level.fpsHistoryHudName].lastText, expected), "demo HUD receives exact bounded suffix");
    viewer openCJ\huds\hudFPSHistory::addDemoFPSHistory("K");
    check(sameText(viewer.fpsHistoryText, expected), "demo duplicate FPS suppression preserved");
    viewer openCJ\huds\hudFPSHistory::_setDemoFPSHistory(large);
    check(sameText(viewer.fpsHistoryText, "..." + getSubStr(large, 491)), "direct demo setter bounded");
    viewer openCJ\huds\hudFPSHistory::onLoaded();
    check(viewer.fpsHistoryText != "", "live load event does not clear demo history");
    viewer openCJ\huds\hudFPSHistory::onDemoLeaveGround("1");
    check(viewer.fpsHistoryText == "1" && viewer.hud[level.fpsHistoryHudName].alpha == 0, "new demo jump removes truncation marker");
    viewer openCJ\huds\hudFPSHistory::addDemoFPSHistory("4");
    viewer openCJ\huds\hudFPSHistory::onDemoBounce("2");
    wait 0.2;
    check(viewer.fpsHistoryText == "14-2", "demo bounce separator preserved");
    player.FPS = 125;
    player openCJ\huds\hudFPSHistory::_setFPSHistory("14");
    player openCJ\huds\hudFPSHistory::onBounced();
    wait 0.2;
    check(player.fpsHistoryText == "14-1", "live bounce separator preserved");
    player thread openCJ\huds\hudFPSHistory::_onBhopThread();
    wait 0.2;
    check(player.fpsHistoryText == "14-1/1", "live bhop separator preserved");

    player openCJ\huds\hudFPSHistory::onLoaded();
    check(player.fpsHistoryText == "", "loading clears live history");
    player openCJ\huds\hudFPSHistory::_addFPSHistory("2");
    check(player.fpsHistoryText == "2", "new live history starts without truncation marker");
    player openCJ\huds\hudFPSHistory::onStartDemo();
    check(player.fpsHistoryText == "", "starting demo clears previous live history");
    player openCJ\huds\hudFPSHistory::_setFPSHistory("14");
    player openCJ\huds\hudFPSHistory::onSpawnPlayer();
    check(player.fpsHistoryText == "" && player.hud[level.fpsHistoryHudName].alpha == 0, "spawn clears and hides history");

    viewer.playingDemo = false;
    viewer followPlayer(player getEntityNumber());
    wait 0.1;
    player openCJ\huds\hudFPSHistory::_setFPSHistory(full);
    player openCJ\huds\hudFPSHistory::_addFPSHistory("2");
    check(viewer.hud[level.fpsHistoryHudName].lastText == player.fpsHistoryText, "spectator receives updated truncated history");
    player openCJ\huds\hudFPSHistory::onOnGround(true);
    wait 0.1;
    check(player.fpsHistoryText != "", "landing retains history during two-second grace period");
    wait 2;
    check(player.fpsHistoryText == "" && viewer.hud[level.fpsHistoryHudName].alpha == 0, "landing clears live history and spectator HUD");
    viewer followPlayer(-1);
    viewer.playingDemo = true;
    viewer openCJ\huds\hudFPSHistory::_setDemoFPSHistory(full);
    viewer openCJ\huds\hudFPSHistory::onDemoLand();
    wait 0.1;
    check(viewer.fpsHistoryText != "", "demo landing grace period preserved");
    wait 2;
    check(viewer.fpsHistoryText == "" && viewer.hud[level.fpsHistoryHudName].alpha == 0, "demo landing clears history and HUD");

    hud = viewer.hud[level.fpsHistoryHudName];
    prefix = "d " + hud.configstringIndex + " ";
    payload = sequence(0, 1023 - prefix.size);
    hud openCJ\huds\infiniteHuds::setInfiniteHudText(payload, viewer, false);
    check(sameText(hud.lastText, payload), "HUD payload exactly at command boundary unchanged");
    oversized = sequence(0, 1023);
    hud openCJ\huds\infiniteHuds::setInfiniteHudText(oversized, viewer, false);
    check(sameText(hud.lastText, payload) && prefix.size + hud.lastText.size == 1023, "HUD sender reserves prefix and null terminator");
    hud openCJ\huds\infiniteHuds::setInfiniteHudText(oversized, viewer, true);
    check(sameText(hud.lastText, payload), "repeated oversized input stays bounded");
    hud openCJ\huds\infiniteHuds::setInfiniteHudText("14", viewer, false);
    check(hud.lastText == "14", "short HUD update still works after truncation");
    finish();
}

setupPlayer(player)
{
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 200), (0, 0, 0));
    player.isFirstSpawn = false;
    player openCJ\huds\base::onPlayerConnect();
    player openCJ\huds\hudFPSHistory::onPlayerConnect();
}

sequence(start, count)
{
    pattern = "142-/3065K";
    result = "";
    for (j = 0; j < count; j++) result += pattern[(start + j) % pattern.size];
    return result;
}

check(ok, message)
{
    level.checks++;
    if (!ok) level.failures++;
    printf("FPS HISTORY SELFTEST " + message + ": " + ok + "\n");
}

finish()
{
    printf("FPS HISTORY SELFTEST COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}

// The VM compares interned IDs; long identical strings can have different IDs.
// Check each character so these tests validate the actual retained contents.
sameText(a, b)
{
    if (a.size != b.size) return false;
    for (k = 0; k < a.size; k++)
    {
        if (a[k] != b[k])
        {
            printf("FPS HISTORY SELFTEST DIAGNOSTIC mismatch index=" + k + " left=" + a[k] + " right=" + b[k] + "\n");
            return false;
        }
    }
    return true;
}
