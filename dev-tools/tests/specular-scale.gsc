// #201: actual map initialization and replicated codinfo, without DB/player state.
main()
{
    level.specularFailures = 0;
    level.specularChecks = 0;
    stage = getCvarInt("opencj_specular_test_stage");
    wait 1;
    check(getCvarInt("sv_cheats") == 0, "normal server keeps cheats disabled");
    if(stage == 0)
    {
        verify(9, "map script override");
        setDvar("r_specularColorScale", "2.5");
        verify(2.5, "runtime script change");
        setDvar("r_specularColorScale", "0");
        verify(0, "zero strength");
        setDvar("r_specularColorScale", "100");
        verify(100, "client range upper boundary");
        setDvar("r_specularColorScale", "9");
        verify(9, "override before restart");
        next(1, "map_restart");
    }
    else if(stage == 1)
    {
        verify(1, "map restart without override resets to default");
        next(2, "map mp_crash");
    }
    else if(stage == 2)
    {
        verify(0.1, "new map fractional override");
        next(3, "map mp_killhouse");
    }
    else
    {
        verify(1, "map change without override resets to default");
        check(getCvar("mapname") == "mp_killhouse", "map transition completed");
        printf("SPECULAR TEST COMPLETE failures=" + level.specularFailures + " checks=" + level.specularChecks + "\n");
    }
}

verify(expected, label)
{
    check(abs(getCvarFloat("r_specularColorScale") - expected) < 0.0001, label + " server value");
    // SV_PreFrame publishes changes outside G_RunFrame's catch-up loop.
    // Wait for that asynchronous publication instead of assuming one script wait.
    for(attempt = 0; attempt < 100; attempt++)
    {
        if(replicaMatches(expected)) break;
        wait 0.05;
    }
    count = 0;
    for(i = 20; i < 148; i++)
    {
        name = getConfigStringByIndex(i);
        if(isDefined(name) && toLower(name) == "r_specularcolorscale")
        {
            count++;
            value = getConfigStringByIndex(i + 128);
            printf("SPECULAR OBSERVED " + label + " slot=" + i + " value=" + value + "\n");
            check(isDefined(value) && abs(float(value) - expected) < 0.0001,
                  label + " replicated value for current and joining clients");
        }
    }
    check(count == 1, label + " has exactly one codinfo entry");
}

next(stage, command)
{
    if(level.specularFailures) return;
    printf("SPECULAR TEST STAGE COMPLETE " + getCvarInt("opencj_specular_test_stage") + " checks=" + level.specularChecks + "\n");
    setCvar("opencj_specular_test_stage", stage);
    exec(command);
}

check(ok, label)
{
    level.specularChecks++;
    if(!ok) level.specularFailures++;
    printf("SPECULAR TEST " + ok + ": " + label + "\n");
}

replicaMatches(expected)
{
    for(i = 20; i < 148; i++)
    {
        name = getConfigStringByIndex(i);
        if(!isDefined(name) || toLower(name) != "r_specularcolorscale") continue;
        value = getConfigStringByIndex(i + 128);
        return isDefined(value) && abs(float(value) - expected) < 0.0001;
    }
    return false;
}
