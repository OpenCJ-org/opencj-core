main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.progressChecks = 0;
    level.progressFailures = 0;
    openCJ\huds\hudProgressBar::onInit();
    wait 1;
    player = addTestClient();
    wait .2;
    check(isDefined(player), "test client available");
    if(!isDefined(player))
    {
        return;
    }
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 700), (0, 0, 0));
    player freezeControls(true);
    player.playerRuns_runID = 1;
    player.runInstanceNumber = 1;
    player.playerRuns_runPaused = false;
    player.playerRuns_runFinished = false;
    player.cheating = false;
    player.anyPct = false;
    player.playingDemo = false;
    player openCJ\huds\hudProgressBar::onPlayerConnect();
    checkpoint = verifyCheckpointPulses(player);
    verifyOverlappingPulses(player, checkpoint);
    verifyPausedAndInvalidRuns(player, checkpoint);
    verifyFinishedRun(player, checkpoint);
    verifyHiddenStates(player, checkpoint);
    printf("PROGRESS BAR COMPLETE failures=" + level.progressFailures +
           " checks=" + level.progressChecks + "\n");
}

// Check the initial track, checkpoint width and pulse settling.
verifyCheckpointPulses(player)
{
    track = player.progressBarTrack;
    fill = player.progressBar;
    check(track.alpha == 0 && fill.alpha == 0, "both layers start hidden");
    check(track.sort < fill.sort, "gray track is behind completed fill");
    check(track.hideWhenInMenu && fill.hideWhenInMenu, "both layers hide in menus");

    player openCJ\huds\hudProgressBar::onRunRestored();
    check(near(track.alpha, 112 / 255.0) && fill.alpha == 0 && player.previousProgressWidth == 0,
          "zero progress shows only full gray track");
    check(gray(track.color), "remaining track is neutral gray");
    checkpoint = spawnStruct();
    checkpoint.id = 1;
    checkpoint.ender = "test route";
    checkpoint.checkpointsFromStart = 2;
    checkpoint.checkpointsTillEnd = 8;
    player.checkpoints_checkpoint = checkpoint;
    player openCJ\huds\hudProgressBar::onRunRestored();
    check(player.previousProgressWidth == 128, "two of ten checkpoints occupies twenty percent");
    check(near(fill.alpha, 216 / 255.0) && near(track.alpha, 112 / 255.0),
          "restored run uses steady fill and track opacity");
    check(green(fill.color), "completed section is green");
    checkpoint.checkpointsFromStart = 4;
    checkpoint.checkpointsTillEnd = 6;
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    check(player.previousProgressWidth == 256, "checkpoint advances fill fraction");
    check(near(fill.alpha, 232 / 255.0) && near(track.alpha, 232 / 255.0),
          "checkpoint pulse brightens both sections");
    check(green(fill.color) && green(track.color) && near(track.color[0], .1),
          "whole bar flashes green");
    wait .05;
    check(near(fill.alpha, 232 / 255.0) && near(track.alpha, 232 / 255.0),
          "green peak remains visible across a server tick");
    wait .20;
    check(near(fill.alpha, 216 / 255.0) && near(track.alpha, 112 / 255.0),
          "pulse restores steady opacity");
    check(near(track.color[0], .5) && near(fill.color[1], .8), "pulse restores steady colors");
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    check(near(fill.alpha, 216 / 255.0), "unchanged checkpoint does not flash");

    return checkpoint;
}

// A new checkpoint replaces the old pulse without allocating another HUD pair.
verifyOverlappingPulses(player, checkpoint)
{
    track = player.progressBarTrack;
    fill = player.progressBar;
    checkpoint.checkpointsFromStart = 5;
    checkpoint.checkpointsTillEnd = 5;
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    wait .05;
    checkpoint.checkpointsFromStart = 6;
    checkpoint.checkpointsTillEnd = 4;
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    wait .25;
    check(player.previousProgressWidth == 384 && near(fill.alpha, 216 / 255.0),
          "rapid checkpoint events settle to latest progress");
    check(player.progressBarTrack == track && player.progressBar == fill, "pulses reuse the same two HUDs");
}

// Run-state changes cancel pulses and replace progress with the right status color.
verifyPausedAndInvalidRuns(player, checkpoint)
{
    track = player.progressBarTrack;
    fill = player.progressBar;
    checkpoint.checkpointsFromStart = 7;
    checkpoint.checkpointsTillEnd = 3;
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    wait .05;
    player.playerRuns_runPaused = true;
    player openCJ\huds\hudProgressBar::onRunPaused();
    wait .25;
    check(track.alpha == 0 && fill.color[0] > fill.color[1],
          "pause cancels pulse and retains red status");
    player.playerRuns_runPaused = false;
    player openCJ\huds\hudProgressBar::onRunResumed();
    check(player.previousProgressWidth == 448 && green(fill.color) && near(track.alpha, 112 / 255.0),
          "resume restores split progress");
    player.cheating = true;
    player openCJ\huds\hudProgressBar::onSpawnPlayer();
    check(track.alpha == 0 && fill.color[0] > fill.color[1], "invalid run keeps red status");
    player.cheating = false;
    player.cpc = spawnStruct();
    player openCJ\huds\hudProgressBar::onRunStopped();
    check(track.alpha == 0 && near(fill.alpha, .4) && fill.color[2] > fill.color[0],
          "checkpoint editor keeps cyan status");
    player.cpc = undefined;
}

// Only the original finish event receives the stronger pulse.
verifyFinishedRun(player, checkpoint)
{
    track = player.progressBarTrack;
    fill = player.progressBar;
    player.playerRuns_runFinished = true;
    player openCJ\huds\hudProgressBar::onRunFinished(checkpoint);
    check(player.previousProgressWidth == 640, "finished route fills the full bar");
    check(near(fill.alpha, 248 / 255.0) && green(fill.color),
          "finish receives stronger green pulse");
    wait .25;
    check(near(fill.alpha, 216 / 255.0), "finish settles to full green");
    player openCJ\huds\hudProgressBar::onRunRestored();
    check(near(fill.alpha, 216 / 255.0), "restoring a finished run does not pulse");
}

// Spectating, death and explicit hiding must outlive any pending pulse.
verifyHiddenStates(player, checkpoint)
{
    track = player.progressBarTrack;
    fill = player.progressBar;
    player.playerRuns_runFinished = false;
    player.anyPct = true;
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(false);
    check(track.alpha == 0 && fill.alpha == 0, "Any percent hides both layers");
    player.anyPct = false;
    player openCJ\huds\hudProgressBar::onSpawnPlayer();
    player openCJ\huds\hudProgressBar::onSpawnSpectator();
    wait .25;
    check(track.alpha == 0 && fill.alpha == 0, "spectating hides both layers");
    player openCJ\huds\hudProgressBar::onSpawnPlayer();
    player openCJ\huds\hudProgressBar::onPlayerKilled();
    wait .25;
    check(track.alpha == 0 && fill.alpha == 0, "death hides both layers");
    player.playingDemo = true;
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    check(track.alpha == 0 && fill.alpha == 0, "demo updates cannot reveal live progress");
    player.playingDemo = false;
    checkpoint.checkpointsFromStart = 8;
    checkpoint.checkpointsTillEnd = 2;
    player openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    player openCJ\huds\hudProgressBar::_hideProgressBar();
    wait .25;
    check(track.alpha == 0 && fill.alpha == 0, "hiding during a pulse prevents resurrection");
    player.runInstanceNumber = undefined;
    player openCJ\huds\hudProgressBar::onRunStopped();
    check(track.alpha == 0 && fill.color[0] > fill.color[1], "stopped run retains red status");
}

near(actual, expected)
{
    colorTolerance = .008;
    return abs(actual - expected) < colorTolerance;
}

gray(color)
{
    return near(color[0], color[1]) && near(color[1], color[2]);
}

green(color)
{
    return color[1] > color[0] && color[1] > color[2];
}

check(ok, label)
{
    level.progressChecks++;
    if(!isDefined(ok) || !ok)
    {
        level.progressFailures++;
        printf("PROGRESS BAR FAIL: " + label + "\n");
    }
}
