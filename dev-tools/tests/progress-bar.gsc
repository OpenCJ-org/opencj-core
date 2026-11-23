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
    p = addTestClient();
    wait .2;
    check(isDefined(p), "test client available");
    if(!isDefined(p))
    {
        return;
    }
    p.sessionTeam = "allies";
    p.sessionState = "playing";
    p.pers["team"] = "allies";
    p spawn((0, 0, 700), (0, 0, 0));
    p freezeControls(true);
    p.playerRuns_runID = 1;
    p.runInstanceNumber = 1;
    p.playerRuns_runPaused = false;
    p.playerRuns_runFinished = false;
    p.cheating = false;
    p.anyPct = false;
    p.playingDemo = false;
    p openCJ\huds\hudProgressBar::onPlayerConnect();
    track = p.progressBarTrack;
    fill = p.progressBar;
    check(track.alpha == 0 && fill.alpha == 0, "both layers start hidden");
    check(track.sort < fill.sort, "gray track is behind completed fill");
    check(track.hideWhenInMenu && fill.hideWhenInMenu, "both layers hide in menus");

    p openCJ\huds\hudProgressBar::onRunRestored();
    check(near(track.alpha, 112 / 255.0) && fill.alpha == 0 && p.prevProgress == 0,
          "zero progress shows only full gray track");
    check(gray(track.color), "remaining track is neutral gray");
    cp = spawnStruct();
    cp.id = 1;
    cp.ender = "test route";
    cp.checkpointsFromStart = 2;
    cp.checkpointsTillEnd = 8;
    p.checkpoints_checkpoint = cp;
    p openCJ\huds\hudProgressBar::onRunRestored();
    check(p.prevProgress == 128, "two of ten checkpoints occupies twenty percent");
    check(near(fill.alpha, 216 / 255.0) && near(track.alpha, 112 / 255.0),
          "restored run uses steady fill and track opacity");
    check(green(fill.color), "completed section is green");
    cp.checkpointsFromStart = 4;
    cp.checkpointsTillEnd = 6;
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    check(p.prevProgress == 256, "checkpoint advances fill fraction");
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
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    check(near(fill.alpha, 216 / 255.0), "unchanged checkpoint does not flash");

    cp.checkpointsFromStart = 5;
    cp.checkpointsTillEnd = 5;
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    wait .05;
    cp.checkpointsFromStart = 6;
    cp.checkpointsTillEnd = 4;
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    wait .25;
    check(p.prevProgress == 384 && near(fill.alpha, 216 / 255.0),
          "rapid checkpoint events settle to latest progress");
    check(p.progressBarTrack == track && p.progressBar == fill, "pulses reuse the same two HUDs");

    cp.checkpointsFromStart = 7;
    cp.checkpointsTillEnd = 3;
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    wait .05;
    p.playerRuns_runPaused = true;
    p openCJ\huds\hudProgressBar::onRunPaused();
    wait .25;
    check(track.alpha == 0 && fill.color[0] > fill.color[1],
          "pause cancels pulse and retains red status");
    p.playerRuns_runPaused = false;
    p openCJ\huds\hudProgressBar::onRunResumed();
    check(p.prevProgress == 448 && green(fill.color) && near(track.alpha, 112 / 255.0),
          "resume restores split progress");
    p.cheating = true;
    p openCJ\huds\hudProgressBar::onSpawnPlayer();
    check(track.alpha == 0 && fill.color[0] > fill.color[1], "invalid run keeps red status");
    p.cheating = false;
    p.cpc = spawnStruct();
    p openCJ\huds\hudProgressBar::onRunStopped();
    check(track.alpha == 0 && near(fill.alpha, .4) && fill.color[2] > fill.color[0],
          "checkpoint editor keeps cyan status");
    p.cpc = undefined;
    p.playerRuns_runFinished = true;
    p openCJ\huds\hudProgressBar::onRunFinished(cp);
    check(p.prevProgress == 640, "finished route fills the full bar");
    check(near(fill.alpha, 248 / 255.0) && green(fill.color),
          "finish receives stronger green pulse");
    wait .25;
    check(near(fill.alpha, 216 / 255.0), "finish settles to full green");
    p openCJ\huds\hudProgressBar::onRunRestored();
    check(near(fill.alpha, 216 / 255.0), "restoring a finished run does not pulse");

    p.playerRuns_runFinished = false;
    p.anyPct = true;
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(false);
    check(track.alpha == 0 && fill.alpha == 0, "Any percent hides both layers");
    p.anyPct = false;
    p openCJ\huds\hudProgressBar::onSpawnPlayer();
    p openCJ\huds\hudProgressBar::onSpawnSpectator();
    wait .25;
    check(track.alpha == 0 && fill.alpha == 0, "spectating hides both layers");
    p openCJ\huds\hudProgressBar::onSpawnPlayer();
    p openCJ\huds\hudProgressBar::onPlayerKilled();
    wait .25;
    check(track.alpha == 0 && fill.alpha == 0, "death hides both layers");
    p.playingDemo = true;
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    check(track.alpha == 0 && fill.alpha == 0, "demo updates cannot reveal live progress");
    p.playingDemo = false;
    cp.checkpointsFromStart = 8;
    cp.checkpointsTillEnd = 2;
    p openCJ\huds\hudProgressBar::onCheckpointsChanged(true);
    p openCJ\huds\hudProgressBar::_hideProgressBar();
    wait .25;
    check(track.alpha == 0 && fill.alpha == 0, "hiding during a pulse prevents resurrection");
    p.runInstanceNumber = undefined;
    p openCJ\huds\hudProgressBar::onRunStopped();
    check(track.alpha == 0 && fill.color[0] > fill.color[1], "stopped run retains red status");
    printf("PROGRESS BAR COMPLETE failures=" + level.progressFailures +
           " checks=" + level.progressChecks + "\n");
}
near(actual, expected)
{
    return abs(actual - expected) < .008;
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
