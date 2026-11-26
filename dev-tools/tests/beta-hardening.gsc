#include openCJ\util;

// Beta hardening: credential random numbers, CoD4 grenade cleanup, the account
// lookup without a database, run restarts that reuse unstored runs, speedometer
// hiding for spectators, archived progress-bar layers and the chat server ID.
main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.hardeningChecks = 0;
    level.hardeningFailures = 0;
    // Shaders must be precached before the first wait.
    openCJ\huds\hudProgressBar::onInit();
    openCJ\mySQL::_initConstants();

    checkCredentialRandomNumbers();
    checkChatServerID();

    wait 1;
    player = addTestClient();
    wait .2;
    check(isDefined(player), "test client available");
    if(isDefined(player))
    {
        player.sessionTeam = "allies";
        player.sessionState = "playing";
        player.pers["team"] = "allies";
        player spawn((0, 0, 700), (0, 0, 0));
        player freezeControls(true);
        checkGrenadeCleanup(player);
        checkAccountLookupWithoutDatabase(player);
        checkRunRestartDecision(player);
        checkSpeedometerHiding(player);
        checkProgressBarLayers(player);
    }
    printf("BETA HARDENING COMPLETE failures=" + level.hardeningFailures +
           " checks=" + level.hardeningChecks + "\n");
}

// Account credentials need defined values from the secure source, and they must vary.
checkCredentialRandomNumbers()
{
    sampleCount = 16;
    firstValue = createRandomInt();
    check(isDefined(firstValue), "secure random source supplies a value");
    sawDifferentValue = false;
    for(i = 0; i < sampleCount; i++)
    {
        value = createRandomInt();
        check(isDefined(value), "secure random value " + i + " is defined");
        if(isDefined(value) && isDefined(firstValue) && value != firstValue)
        {
            sawDifferentValue = true;
        }
    }
    check(sawDifferentValue, "credential random values vary");
}

checkChatServerID()
{
    setCvar("opencj_server_id", "main-eu");
    check(openCJ\chat::getServerName() == "main-eu", "configured server ID names chat messages");
    setCvar("opencj_server_id", "");
    check(openCJ\chat::getServerName() == "cod4 " + getCvarInt("net_port"),
          "installations without an ID keep their previous chat name");
}

// Before this fix CoD4 reported every entity as thinking, so grenades were never removed.
checkGrenadeCleanup(player)
{
    olderGrenade = spawn("script_origin", player.origin);
    newerGrenade = spawn("script_origin", player.origin);
    check(!olderGrenade isThinking(), "an idle entity is not reported as thinking");
    newerGrenade.prevNade = olderGrenade;
    player.weapons_prevNade = newerGrenade;
    player openCJ\weapons::onRunCreated();
    check(!isDefined(olderGrenade) && !isDefined(newerGrenade),
          "a new run deletes the player's idle grenades");
    check(!isDefined(player.weapons_prevNade), "the grenade list is cleared");
}

// No database answer must never be treated as an unknown credential.
checkAccountLookupWithoutDatabase(player)
{
    storedCredential = [];
    storedCredential[0] = 1;
    storedCredential[1] = 2;
    storedCredential[2] = 3;
    storedCredential[3] = 4;
    lookup = player openCJ\login::_getPlayerInformation(storedCredential);
    check(lookup == "unavailable", "a lookup without a database is unavailable, got " + lookup);
    check(!player openCJ\login::isLoggedIn(), "an unavailable lookup logs nobody in");
}

checkRunRestartDecision(player)
{
    player.playerRuns_runID = 7;
    player.runInstanceNumber = 1;
    player.playerRuns_runFinished = false;
    player.cpc = undefined;

    player.playerRuns_progressStored = undefined;
    check(!player openCJ\playerRuns::_canRestartInPlace(),
          "a run with unknown storage state is archived");
    player.playerRuns_progressStored = false;
    check(player openCJ\playerRuns::_canRestartInPlace(),
          "a new run without stored data restarts in place");
    player openCJ\playerRuns::onProgressStored();
    check(!player openCJ\playerRuns::_canRestartInPlace(), "a run with stored data is archived");

    player.playerRuns_progressStored = false;
    player.cpc = spawnStruct();
    check(!player openCJ\playerRuns::_canRestartInPlace(), "the checkpoint editor keeps its path");
    player.cpc = undefined;
    player.playerRuns_runFinished = true;
    check(!player openCJ\playerRuns::_canRestartInPlace(), "a finished run is archived");
    player.playerRuns_runFinished = false;
    player.playerRuns_runID = undefined;
    check(!player openCJ\playerRuns::_canRestartInPlace(), "no run means nothing to reuse");
    player.runInstanceNumber = undefined;
}

checkSpeedometerHiding(player)
{
    player openCJ\huds\hudSpeedometer::onPlayerConnect();
    showSpeedometerHud(player);
    player.showSpeedometer = true;
    player openCJ\huds\hudSpeedometer::_onCommandSpeedometer(false);
    check(!player.showSpeedometer && speedometerHidden(player),
          "turning the setting off hides the speedometer at once");

    followedPlayer = spawnStruct();
    followedPlayer.showSpeedometer = false;
    showSpeedometerHud(player);
    player openCJ\huds\hudSpeedometer::onSpectatorClientChanged(followedPlayer);
    check(speedometerHidden(player), "following a player without speedometer hides it");

    followedPlayer.showSpeedometer = true;
    showSpeedometerHud(player);
    player openCJ\huds\hudSpeedometer::onSpectatorClientChanged(followedPlayer);
    check(!speedometerHidden(player), "following a player with speedometer leaves it to them");

    player openCJ\huds\hudSpeedometer::onSpectatorClientChanged(undefined);
    check(speedometerHidden(player), "free spectating hides the speedometer");
}

showSpeedometerHud(player)
{
    player.hudSpeed["curr"].alpha = 1;
    player.hudSpeed["max"].alpha = 1;
}

speedometerHidden(player)
{
    return player.hudSpeed["curr"].alpha == 0 && player.hudSpeed["max"].alpha == 0;
}

// Spectators following a player receive that player's archived HUD elements from
// the engine; a free spectator only has their own, which spectating hides.
checkProgressBarLayers(player)
{
    player openCJ\huds\hudProgressBar::onPlayerConnect();
    check(player.progressBarTrack.archived && player.progressBar.archived,
          "both progress-bar layers are archived for followers");
    player.progressBarTrack.alpha = 1;
    player.progressBar.alpha = 1;
    player openCJ\huds\hudProgressBar::onSpawnSpectator();
    check(player.progressBarTrack.alpha == 0 && player.progressBar.alpha == 0,
          "a spectator's own progress bar is hidden");
}

check(condition, description)
{
    level.hardeningChecks++;
    if(!condition)
    {
        level.hardeningFailures++;
        printf("BETA HARDENING FAILURE: " + description + "\n");
    }
}

