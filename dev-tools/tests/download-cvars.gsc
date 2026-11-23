// Exercise production initialization and the initial client systeminfo.
main()
{
    level.downloadChecks = 0;
    level.downloadFailures = 0;
    wait 1;
    check(level.downloadInitRan, "production initialization ran before accepting players");
    check(level.downloadConnections == 0, "settings available before any player connects");
    verifyPublishedSettings();
    check(getCvarInt("sv_allowDownload") == 0, "server file delivery remains disabled");
    check(getCvarInt("sv_wwwDownload") == 0, "server HTTP delivery remains disabled");
    check(getCvar("sv_wwwBaseURL") == "", "no HTTP URL configured");

    initialStage = 0;
    restartedStage = 1;
    if(getCvarInt("opencj_download_test_stage") == initialStage && !level.downloadFailures)
    {
        printf("DOWNLOAD TEST STAGE COMPLETE 0 failures=0 checks=" + level.downloadChecks + "\n");
        setCvar("opencj_download_test_stage", restartedStage);
        exec("map_restart");
        return;
    }
    printf("DOWNLOAD TEST COMPLETE failures=" + level.downloadFailures +
           " checks=" + level.downloadChecks + "\n");
}

// Configstring publication happens outside the script catch-up loop; wait for it.
verifyPublishedSettings()
{
    check(getCvarInt("cl_allowDownload") == 1, "disabled allowDownload overridden");
    check(getCvarInt("cl_wwwDownload") == 1, "disabled wwwDownload overridden");
    systeminfoConfigstring = 1;
    maxPublicationAttempts = 100;
    publicationPollSeconds = 0.05;
    systeminfo = "";
    for(attempt = 0; attempt < maxPublicationAttempts; attempt++)
    {
        systeminfo = getConfigStringByIndex(systeminfoConfigstring);
        if(systeminfoValue(systeminfo, "cl_allowdownload") == "1" &&
           systeminfoValue(systeminfo, "cl_wwwdownload") == "1")
        {
            break;
        }
        wait publicationPollSeconds;
    }
    check(systeminfoValue(systeminfo, "cl_allowdownload") == "1", "initial systeminfo enables downloads");
    check(systeminfoValue(systeminfo, "cl_wwwdownload") == "1", "initial systeminfo enables HTTP");
}

systeminfoValue(systeminfo, key)
{
    if(!isDefined(systeminfo))
    {
        return "";
    }
    fields = strTok(systeminfo, "\\");
    // Systeminfo stores alternating key/value fields; a trailing key has no value.
    for(i = 0; i + 1 < fields.size; i += 2)
    {
        if(toLower(fields[i]) == key)
        {
            return fields[i + 1];
        }
    }
    return "";
}

check(condition, message)
{
    level.downloadChecks++;
    if(!condition)
    {
        level.downloadFailures++;
    }
    printf("DOWNLOAD TEST " + condition + ": " + message + "\n");
}
