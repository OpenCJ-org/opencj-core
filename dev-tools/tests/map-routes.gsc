main()
{
    level.routeTestChecks = 0;
    level.routeTestFailures = 0;
    openCJ\mySQL::onInit();
    wait 1;
    level.mapRoutes = [];
    level.mapRoutesReady = false;
    level.mapRoutesRequest = 0;
    level.routeTestOutcomes = [];
    level.routeTestRepliesReturned = [];
    level.routeTestQuerySleepSeconds = 0;

    verifySupersededQueuedRead();
    verifyBoundedRunningRead();
    verifyCompletedStaleReply();
    verifyPoolDrains();

    printf("MAP ROUTES COMPLETE failures=" + level.routeTestFailures +
           " checks=" + level.routeTestChecks + "\n");
}

// GET_LOCK records actual execution on a pool connection; fixture teardown releases it.
// The fourth column delays execution without changing the three route columns.
refreshQuery()
{
    lockName = getCvar("opencj_route_fixture") + ":" + level.routeTestDesiredName;
    return "/* map-route-fixture */ SELECT 'mp_killhouse', '" +
        level.routeTestDesiredName + "', 16777214 + GET_LOCK('" + lockName +
        "', 0), SLEEP(" + level.routeTestQuerySleepSeconds + ")";
}

startRefresh(routeName, querySleepSeconds)
{
    level.routeTestDesiredName = routeName;
    level.routeTestQuerySleepSeconds = querySleepSeconds;
    level thread openCJ\mapRoutes::refresh();
    return level.mapRoutesRequest;
}

occupyWorker()
{
    openCJ\mySQL::mysqlAsyncRead("SELECT SLEEP(1.5)");
}

waitForRunningJobs(expectedCount, timeoutSeconds)
{
    // SQL uses wall time. Round up because this clock reports whole seconds.
    deadlineSeconds = getRealTime() + timeoutSeconds + 1;
    while(getRealTime() < deadlineSeconds)
    {
        stats = mysql_async_stats();
        runningCount = stats[2];
        if(runningCount == expectedCount)
        {
            return true;
        }
        wait 0.05;
    }
    stats = mysql_async_stats();
    printf("MAP ROUTES WAIT running expected=" + expectedCount +
           " actual=" + stats[2] + " queued=" + stats[1] + "\n");
    return false;
}

waitForReply(requestVersion, timeoutSeconds)
{
    startedSeconds = getRealTime();
    deadlineSeconds = startedSeconds + timeoutSeconds + 1;
    while(getRealTime() < deadlineSeconds)
    {
        if(isDefined(level.routeTestRepliesReturned[requestVersion]))
        {
            return true;
        }
        wait 0.05;
    }
    printf("MAP ROUTES WAIT reply=" + requestVersion + " wallElapsedSeconds=" +
           (getRealTime() - startedSeconds) + "\n");
    return false;
}

// Occupied workers make queued cancellation observable before a query can execute.
verifySupersededQueuedRead()
{
    // The pool reserves one worker for progress writes; reads use the other three.
    progressWorkerCount = 1;
    readWorkerCount = level.sqlConstants.workerCount - progressWorkerCount;
    for(i = 0; i < readWorkerCount; i++)
    {
        level thread occupyWorker();
    }
    check(waitForRunningJobs(readWorkerCount, 1), "read workers occupied");

    obsoleteVersion = startRefresh("ObsoleteQueued", 0);
    stats = mysql_async_stats();
    check(stats[1] == 1, "first route read is queued behind occupied workers");
    latestVersion = startRefresh("LatestQueued", 0);
    check(waitForReply(obsoleteVersion, 1), "obsolete queued caller wakes promptly");
    check(isDefined(level.routeTestOutcomes[obsoleteVersion]) &&
              level.routeTestOutcomes[obsoleteVersion] == level.sqlConstants.outcomeCancelled,
          "obsolete queued read reports cancellation");

    check(waitForReply(latestVersion, 3), "latest queued refresh completes");
    check(isPublishedRoute("LatestQueued"), "latest queued refresh owns publication");

    lockName = getCvar("opencj_route_fixture") + ":ObsoleteQueued";
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT COALESCE(IS_USED_LOCK('" + lockName + "'), 0)");
    check(isDefined(rows) && rows.size == 1 && int(rows[0][0]) == 0,
          "obsolete queued query never executed");
    check(waitForRunningJobs(0, 3), "queued scenario releases read workers");
}

// The native API keeps a running connection owned until its bounded query settles.
verifyBoundedRunningRead()
{
    obsoleteVersion = startRefresh("ObsoleteRunning", 2);
    check(waitForRunningJobs(1, 1), "obsolete route read starts running");

    latestVersion = startRefresh("LatestRunning", 0);
    check(waitForReply(latestVersion, 1), "replacement publishes without waiting for obsolete query");
    check(isPublishedRoute("LatestRunning"), "replacement owns the visible snapshot");

    check(waitForReply(obsoleteVersion, 3), "cancelled running read settles within fixture deadline");
    check(isDefined(level.routeTestOutcomes[obsoleteVersion]) &&
              level.routeTestOutcomes[obsoleteVersion] == level.sqlConstants.outcomeCancelled,
          "settled obsolete read reports cancellation");
    check(isPublishedRoute("LatestRunning"), "settled obsolete result cannot replace newer snapshot");
    check(waitForRunningJobs(0, 1), "running scenario releases read workers");
}

// Cancellation can arrive after SQL completes; the request-version check still matters.
verifyCompletedStaleReply()
{
    level.routeTestHoldVersion = level.mapRoutesRequest + 1;
    level.routeTestHeldReplyReady = false;
    level.routeTestReleaseReply = false;
    obsoleteVersion = startRefresh("CompletedOld", 0);

    deadlineSeconds = getRealTime() + 4;
    while(!level.routeTestHeldReplyReady && getRealTime() < deadlineSeconds)
    {
        wait 0.05;
    }
    check(level.routeTestHeldReplyReady, "old SQL reply completes before replacement");

    latestVersion = startRefresh("CompletedLatest", 0);
    check(waitForReply(latestVersion, 3), "newer reply publishes while old reply is held");
    check(isPublishedRoute("CompletedLatest"), "newer completed result is visible");

    level.routeTestReleaseReply = true;
    check(waitForReply(obsoleteVersion, 1), "held old reply is released");
    check(isPublishedRoute("CompletedLatest"), "late completed reply cannot overwrite newer snapshot");
    level.routeTestHoldVersion = undefined;
}

isPublishedRoute(expectedRouteName)
{
    routes = level.mapRoutes["mp_killhouse"];
    if(!isDefined(routes) || routes.size != 1)
    {
        return false;
    }
    return routes[0].name == expectedRouteName;
}

verifyPoolDrains()
{
    deadlineSeconds = getRealTime() + 4;
    while(getRealTime() < deadlineSeconds)
    {
        stats = mysql_async_stats();
        queuedCount = stats[1];
        runningCount = stats[2];
        retainedCompletionCount = stats[3];
        outstandingCount = stats[4];
        if(queuedCount == 0 && runningCount == 0 &&
           retainedCompletionCount == 0 && outstandingCount == 0)
        {
            check(true, "SQL queue, workers and retained completions drain");
            return;
        }
        wait 0.05;
    }
    check(false, "SQL queue, workers and retained completions drain");
}

check(condition, message)
{
    level.routeTestChecks++;
    if(!condition)
    {
        level.routeTestFailures++;
    }
    printf("MAP ROUTES CHECK " + int(condition) + ": " + message + "\n");
}
