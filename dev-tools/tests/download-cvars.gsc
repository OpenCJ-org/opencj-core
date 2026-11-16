// #200: test production initialization and the initial client systeminfo.
main()
{
    level.downloadChecks = 0;
    level.downloadFailures = 0;
    wait 1;
    check(level.downloadInitRan, "production initialization ran before accepting players");
    check(level.downloadConnections == 0, "settings available before any player connects");
    verify();
    check(getCvarInt("sv_allowDownload") == 0, "server file delivery remains disabled");
    check(getCvarInt("sv_wwwDownload") == 0, "server HTTP delivery remains disabled");
    check(getCvar("sv_wwwBaseURL") == "", "no HTTP URL configured");
    if(getCvarInt("opencj_download_test_stage") == 0 && !level.downloadFailures)
    {
        printf("DOWNLOAD TEST STAGE COMPLETE 0 checks=" + level.downloadChecks + "\n");
        setCvar("opencj_download_test_stage", 1);
        exec("map_restart");
        return;
    }
    printf("DOWNLOAD TEST COMPLETE failures=" + level.downloadFailures + " checks=" + level.downloadChecks + "\n");
}

verify()
{
    check(getCvarInt("cl_allowDownload") == 1, "disabled allowDownload overridden");
    check(getCvarInt("cl_wwwDownload") == 1, "disabled wwwDownload overridden");
    // Publication runs in SV_PreFrame, outside the script catch-up loop.
    info = "";
    for(attempt = 0; attempt < 100; attempt++)
    {
        info = getConfigStringByIndex(1);
        if(value(info, "cl_allowdownload") == "1" &&
           value(info, "cl_wwwdownload") == "1") break;
        wait 0.05;
    }
    check(value(info, "cl_allowdownload") == "1", "initial systeminfo enables downloads");
    check(value(info, "cl_wwwdownload") == "1", "initial systeminfo enables HTTP");
}

value(info, key)
{
    if(!isDefined(info)) return "";
    parts = strTok(info, "\\");
    for(i = 0; i + 1 < parts.size; i += 2)
        if(toLower(parts[i]) == key) return parts[i + 1];
    return "";
}

check(ok, label)
{
    level.downloadChecks++;
    if(!ok) level.downloadFailures++;
    printf("DOWNLOAD TEST " + ok + ": " + label + "\n");
}
