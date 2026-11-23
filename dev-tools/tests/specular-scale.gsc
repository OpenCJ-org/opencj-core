// Check map defaults and replicated specular strength without account/database state.
main()
{
    level.specularFailures = 0;
    level.specularChecks = 0;
    // CoD4 stores 128 replicated names followed by their corresponding values.
    level.codinfoFirstNameIndex = 20;
    level.codinfoSlotCount = 128;
    level.specularTolerance = 0.0001;
    stage = getCvarInt("opencj_specular_test_stage");
    wait 1;
    check(getCvarInt("sv_cheats") == 0, "normal server keeps cheats disabled");
    if(stage == 0)
    {
        verifySpecularStrength(9, "map script override");
        setDvar("r_specularColorScale", "2.5");
        verifySpecularStrength(2.5, "runtime script change");
        setDvar("r_specularColorScale", "0");
        verifySpecularStrength(0, "zero strength");
        setDvar("r_specularColorScale", "100");
        verifySpecularStrength(100, "client range upper boundary");
        setDvar("r_specularColorScale", "9");
        verifySpecularStrength(9, "override before restart");
        advanceMapStage(1, "map_restart");
    }
    else if(stage == 1)
    {
        verifySpecularStrength(1, "map restart without override resets to default");
        advanceMapStage(2, "map mp_crash");
    }
    else if(stage == 2)
    {
        verifySpecularStrength(0.1, "new map fractional override");
        advanceMapStage(3, "map mp_killhouse");
    }
    else
    {
        verifySpecularStrength(1, "map change without override resets to default");
        check(getCvar("mapname") == "mp_killhouse", "map transition completed");
        printf("SPECULAR TEST COMPLETE failures=" + level.specularFailures +
               " checks=" + level.specularChecks + "\n");
    }
}

verifySpecularStrength(expected, label)
{
    check(abs(getCvarFloat("r_specularColorScale") - expected) < level.specularTolerance,
          label + " server value");
    // SV_PreFrame publishes changes outside G_RunFrame's catch-up loop.
    // Wait for that asynchronous publication instead of assuming one script wait.
    maximumPublicationChecks = 100;
    publicationPollSeconds = 0.05;
    for(attempt = 0; attempt < maximumPublicationChecks; attempt++)
    {
        if(replicaMatches(expected))
        {
            break;
        }
        wait publicationPollSeconds;
    }
    matchingEntries = 0;
    namesEndIndex = level.codinfoFirstNameIndex + level.codinfoSlotCount;
    for(configstringIndex = level.codinfoFirstNameIndex; configstringIndex < namesEndIndex;
        configstringIndex++)
    {
        name = getConfigStringByIndex(configstringIndex);
        if(isDefined(name) && toLower(name) == "r_specularcolorscale")
        {
            matchingEntries++;
            value = getConfigStringByIndex(configstringIndex + level.codinfoSlotCount);
            printf("SPECULAR OBSERVED " + label + " slot=" + configstringIndex + " value=" + value +
                   "\n");
            check(isDefined(value) && abs(float(value) - expected) < level.specularTolerance,
                  label + " replicated value for current and joining clients");
        }
    }
    check(matchingEntries == 1, label + " has exactly one codinfo entry");
}

advanceMapStage(stage, command)
{
    if(level.specularFailures)
    {
        return;
    }
    printf("SPECULAR TEST STAGE COMPLETE " + getCvarInt("opencj_specular_test_stage") +
           " checks=" + level.specularChecks + "\n");
    setCvar("opencj_specular_test_stage", stage);
    exec(command);
}

check(passed, label)
{
    level.specularChecks++;
    if(!passed)
    {
        level.specularFailures++;
    }
    printf("SPECULAR TEST " + passed + ": " + label + "\n");
}

replicaMatches(expected)
{
    namesEndIndex = level.codinfoFirstNameIndex + level.codinfoSlotCount;
    for(configstringIndex = level.codinfoFirstNameIndex; configstringIndex < namesEndIndex;
        configstringIndex++)
    {
        name = getConfigStringByIndex(configstringIndex);
        if(!isDefined(name) || toLower(name) != "r_specularcolorscale")
        {
            continue;
        }
        value = getConfigStringByIndex(configstringIndex + level.codinfoSlotCount);
        return isDefined(value) && abs(float(value) - expected) < level.specularTolerance;
    }
    return false;
}
