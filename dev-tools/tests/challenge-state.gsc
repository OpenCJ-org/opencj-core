// Exercise catalogue identities and pure rank/menu projections without a database.
main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.challengeChecks = 0;
    level.challengeFailures = 0;
    verifyDefinitions();
    verifyRankBoundaries();
    verifyProgressProjection();
    verifyModeIcons();
    printf("CHALLENGE STATE COMPLETE failures=" + level.challengeFailures +
           " checks=" + level.challengeChecks + "\n");
}

verifyDefinitions()
{
    openCJ\challenges::definitions();
    equal(level.challenges["to_the_moon.easy"].routeLabel, "Basic",
          "Basic label keeps its permanent easy key");
    equal(level.challenges["to_the_moon.inter"].routeLabel, "Intermediate",
          "Intermediate label keeps its permanent inter key");
    equal(level.challenges["to_the_moon.advanced"].routeLabel, "Advanced",
          "Advanced label keeps its permanent key");
    equal(level.challenges["blue2.inter"].routeLabel, "Intermediate",
          "Blue Intermediate keeps its permanent key");
    equal(level.challenges["dark.hard"].routeName, "hard", "explicit route hint stays distinct");

    millisecondsPerHour = 60 * 60 * 1000;
    equal(level.challenges["dark_final.hard.timed"].maxTime, millisecondsPerHour,
          "ordinary timed challenge allows one hour");
    equal(level.challenges["12.advanced.timed"].maxTime, 4 * millisecondsPerHour,
          "long Advanced challenge allows four hours");
    equal(level.challenges["12.challenge.timed"].maxTime, 8 * millisecondsPerHour,
          "long Challenge allows eight hours");
    equal(level.challenges["spectrum.beginner"].points, 10, "first-tier reward");
    equal(level.challenges["spectrum.beginner"].maxRPG, -1, "default RPG count is unrestricted");
}

verifyRankBoundaries()
{
    level.challengeTierPoints = [];
    for(tier = 1; tier <= 10; tier++)
    {
        level.challengeTierPoints[tier] = tier * 100;
    }
    equal(openCJ\challenges::rankForPoints(0), 1, "new player rank");
    equal(openCJ\challenges::rankForPoints(99), 1, "below first threshold");
    equal(openCJ\challenges::rankForPoints(100), 2, "exact first threshold");
    equal(openCJ\challenges::rankForPoints(299), 2, "below cumulative second threshold");
    equal(openCJ\challenges::rankForPoints(300), 3, "exact cumulative second threshold");
    equal(openCJ\challenges::rankForPoints(4499), 9, "below final threshold");
    equal(openCJ\challenges::rankForPoints(4500), 10, "exact final threshold");
    equal(openCJ\challenges::rankForPoints(9999), 10, "rank remains capped at ten");
}

verifyProgressProjection()
{
    progress = openCJ\challenges::progressForPoints(150);
    equal(progress["level"], "Level 2", "progress level label");
    equal(progress["points"], "150 points", "summary retains total points");
    equal(progress["next"], "Next: Level 3", "next level label");
    equal(progress["remaining"], "150 points to go", "remaining points use current tier");
    equal(progress["fraction"], .25, "bar covers current level only");

    progress = openCJ\challenges::progressForPoints(299);
    equal(progress["remaining"], "1 point to go", "single remaining point uses singular");
    progress = openCJ\challenges::progressForPoints(-10);
    equal(progress["points"], "0 points", "negative presentation clamps to zero");
    equal(progress["fraction"], 0, "negative progress cannot fill the bar");
    progress = openCJ\challenges::progressForPoints(4500);
    equal(progress["next"], "Maximum level", "final level has no next target");
    equal(progress["remaining"], "", "final level has no remaining-point label");
    equal(progress["fraction"], 1, "final level fills the bar");

    level.challengeTierPoints[1] = 0;
    equal(openCJ\challenges::rankForPoints(500), 1, "missing tier stops rank progression");
    progress = openCJ\challenges::progressForPoints(0);
    equal(progress["fraction"], 0, "empty tier avoids division by zero");
}

verifyModeIcons()
{
    icons = openCJ\challenges::allowedModeIcons("125,mix,hax", 15);
    equal(icons.size, 7, "all FPS and optional-mode icons");
    equal(icons[0], "opencj_icon_fps_classic", "classic FPS icon");
    equal(icons[1], "opencj_icon_fps_standard", "standard FPS icon");
    equal(icons[2], "opencj_icon_fps_any", "any FPS icon");
    equal(icons[3], "opencj_icon_anypct", "any-percent mode bit");
    equal(icons[4], "opencj_icon_ele", "elevator mode bit");
    equal(icons[5], "opencj_icon_halfbeat", "halfbeat mode bit");
    equal(icons[6], "opencj_icon_tas", "TAS mode bit");
    icons = openCJ\challenges::allowedModeIcons("", 0);
    equal(icons.size, 0, "empty rules have no icons");
    icons = openCJ\challenges::allowedModeIcons("hax,125", 0);
    equal(icons[0], "opencj_icon_fps_any", "FPS display preserves catalogue order");
}

equal(actual, expected, label)
{
    level.challengeChecks++;
    if(!isDefined(actual))
    {
        level.challengeFailures++;
        printf("CHALLENGE STATE FAIL " + label + " expected=" + expected + " actual=undefined\n");
        return;
    }
    if(actual != expected)
    {
        level.challengeFailures++;
        printf("CHALLENGE STATE FAIL " + label + " expected=" + expected + " actual=" + actual + "\n");
    }
}
