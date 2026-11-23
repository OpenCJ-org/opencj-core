// These choices and query builders are pure; no database or player is needed.
main()
{
    level.finishSoundChecks = 0;
    level.finishSoundFailures = 0;
    check(openCJ\finishSounds::soundForResult(undefined) == "opencj_route_complete",
          "query failure fallback");
    rankingRows = [];
    check(openCJ\finishSounds::soundForResult(rankingRows) == "opencj_route_complete",
          "empty result fallback");
    rankingRows[0] = [];
    rankingRows[0][0] = undefined;
    check(openCJ\finishSounds::soundForResult(rankingRows) == "opencj_route_complete",
          "null result fallback");
    rankingRows[0][0] = "0";
    check(openCJ\finishSounds::soundForResult(rankingRows) == "opencj_route_complete",
          "ordinary finish");
    rankingRows[0][0] = "1";
    check(openCJ\finishSounds::soundForResult(rankingRows) == "opencj_route_record",
          "top three finish");

    firstRunQuery = openCJ\finishSounds::podiumQuery(100);
    secondRunQuery = openCJ\finishSounds::podiumQuery(101);
    check(isDefined(firstRunQuery) && firstRunQuery.size > 0 && firstRunQuery != secondRunQuery,
          "ranking query uses requested run");
    printf("FINISH SOUND SELFTEST COMPLETE failures=" + level.finishSoundFailures +
           " checks=" + level.finishSoundChecks + "\n");
}

check(value, label)
{
    level.finishSoundChecks++;
    if(!value)
    {
        level.finishSoundFailures++;
        printf("FINISH SOUND SELFTEST FAIL " + label + "\n");
    }
}
