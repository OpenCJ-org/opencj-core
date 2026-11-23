main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    precacheShader("opencj_notify_glow_left");
    precacheShader("opencj_notify_glow_right");
    precacheShader("white");
    level.opacityChecks = 0;
    level.opacityFailures = 0;
    wait 1;
    player = addTestClient();
    wait .2;
    check(isDefined(player), "real client available");
    if(!isDefined(player))
    {
        return;
    }
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 700), (0, 0, 0));
    player freezeControls(true);
    player.settingValues = [];
    for(strength = 1; strength <= 3; strength++)
    {
        player.settingValues["notify_strength"] = strength;
        player openCJ\notifications::flash("save", false);
        left = player.notificationFlash;
        right = player.notificationFlashRight;
        wait .05;
        check(isDefined(left) && isDefined(right), "edge pair created " + strength);
        check(abs(left.alpha - (40 + 16 * strength) / 255.0) < .005, "edge opacity " + strength);
        check(abs(right.alpha - left.alpha) < .005, "matching side opacity " + strength);
        check(left.x == 0 && right.x == 576, "outer edges retain clear center " + strength);
        player openCJ\notifications::flash("load", false);
        check(player.notificationFlash == left && player.notificationFlashRight == right,
              "rapid actions reuse pair " + strength);
        check(left.color[0] > .99 && left.color[1] < .06 && left.color[2] < .06,
              "load retains red");
        wait .3;
        check(!isDefined(player.notificationFlash) && !isDefined(player.notificationFlashRight),
              "edge pair cleaned up " + strength);
        player openCJ\notifications::flash("record", true);
        wait .05;
        check(isDefined(player.notificationFlash) && !isDefined(player.notificationFlashRight),
              "single result overlay " + strength);
        check(abs(player.notificationFlash.alpha - (56 + 16 * strength) / 255.0) < .005,
              "result opacity " + strength);
        wait .65;
        check(!isDefined(player.notificationFlash), "result cleanup " + strength);
    }
    player openCJ\notifications::flash("save", false);
    player openCJ\notifications::cancelAll();
    check(!isDefined(player.notificationFlash) && !isDefined(player.notificationFlashRight),
          "explicit cancellation cleanup");
    printf("NOTIFICATION OPACITY COMPLETE failures=" + level.opacityFailures +
           " checks=" + level.opacityChecks + "\n");
}
check(ok, label)
{
    level.opacityChecks++;
    if(!ok)
    {
        level.opacityFailures++;
        printf("NOTIFICATION OPACITY FAIL: " + label + "\n");
    }
}
