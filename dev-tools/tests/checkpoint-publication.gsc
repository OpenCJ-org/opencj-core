// Run real publication transactions against the runner's empty, restricted schema.
main()
{
    level.publicationChecks = 0;
    level.publicationFailures = 0;
    openCJ\mySQL::onInit();
    level.mapid_mapID = 1;
    wait 1;
    editor = addTestClient();
    wait .2;
    editor.login_playerID = 1;
    editor.cpc = routeDraft("fixture_route");
    checkInitialPublication(editor);
    checkBackupCapacity(editor);
    checkRouteMigration(editor);
    checkPartialWriteRollback(editor);
    checkInsertedCheckpoint(editor);
    checkUnusedRouteReplacement(editor);
    checkSharedBranches(editor);
    checkLoadedMetadata();
    checkGraphReload();
    checkLostCommitReply(editor);
    checkFinalizationRun(editor);
    printf("PUBLICATION SELFTEST COMPLETE failures=" + level.publicationFailures +
           " checks=" + level.publicationChecks + "\n");
}

routeDraft(routeName)
{
    draft = spawnStruct();
    draft.route = routeName;
    draft.path = "checkpoint-publication/" + routeName;
    draft.routeHex = "#123456";
    draft.revision = 0;
    draft.rows = [];
    draft.rows[0] = row(0, false, false);
    draft.rows[1] = row(200, false, true);
    draft.rows[2] = row(400, true, false);
    draft.selected = draft.rows.size;
    draft.draft = openCJ\checkpointCreation::_empty();
    return draft;
}

row(offsetX, finish, alternative)
{
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points = rectangle(offsetX, 0);
    checkpoint.finish = finish;
    if (alternative)
    {
        checkpoint.alternatives[0] = rectangle(offsetX, 200);
    }
    return openCJ\checkpointCreation::_encode(checkpoint);
}

rectangle(offsetX, offsetY)
{
    points = [];
    points[0] = (offsetX, offsetY, 0);
    points[1] = (offsetX + 100, offsetY, 0);
    points[2] = (offsetX + 100, offsetY + 100, 0);
    points[3] = (offsetX, offsetY + 100, 0);
    return points;
}

checkInitialPublication(editor)
{
    if (!check(editor openCJ\checkpointPublish::publish(), "new route publishes"))
    {
        return;
    }
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 4, "primary and alternative areas persist");
    checkScalar("SELECT COUNT(*) FROM checkpointBrothers", 1, "alternative has one leader");
    checkScalar("SELECT COUNT(*) FROM checkpointConnections", 4,
                "both alternatives connect to the preceding and following groups");
    checkScalar("SELECT COUNT(*) FROM checkpointRoutes", 4, "route memberships reach every area");
    checkScalar("SELECT colorRGB FROM routes WHERE routeName='fixture_route'", 1193046,
                "route color stores RGB bytes");
    publishedRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT cpID FROM checkpointAreas ORDER BY ordinal");
    level.publicationOriginalIds = [];
    for (i = 0; i < publishedRows.size; i++)
    {
        level.publicationOriginalIds[i] = int(publishedRows[i][0]);
    }
    check(editor openCJ\checkpointPublish::publish(), "unchanged publication succeeds");
    checkScalar("SELECT COUNT(*) FROM checkpoints", 4, "repeated publication does not duplicate IDs");
    checkScalar("SELECT COUNT(*) FROM checkpointConnections", 4,
                "repeated publication does not duplicate connections");

    editor.cpc.routeHex = "#654321";
    check(editor openCJ\checkpointPublish::publish(), "color-only publication succeeds");
    checkScalar("SELECT colorRGB FROM routes WHERE routeName='fixture_route'", 6636321,
                "color-only edit reaches the published route");
    checkScalar("SELECT COUNT(*) FROM checkpoints", 4, "color-only edit keeps checkpoint IDs");
    editor.cpc.routeHex = "invalid";
    check(!editor openCJ\checkpointPublish::publish(), "invalid color is rejected on an unchanged route");
    checkScalar("SELECT colorRGB FROM routes WHERE routeName='fixture_route'", 6636321,
                "rejected color keeps the previously published value");
    editor.cpc.routeHex = "#654321";
}

// Completed results retain their references; interrupted runs are archived after graph edits.
checkRouteMigration(editor)
{
    if (!isDefined(level.publicationOriginalIds))
    {
        check(false, "migration needs a successfully published route");
        return;
    }
    startId = level.publicationOriginalIds[0];
    middleId = level.publicationOriginalIds[1];
    alternativeId = level.publicationOriginalIds[2];
    finishId = level.publicationOriginalIds[3];
    check(isDefined(openCJ\mySQL::mysqlSyncQuery(
              "INSERT INTO playerRuns(runID,playerID,mapID,finishcpID,finishTimeStamp) VALUES" +
              "(1,1,1," + finishId + ",CURRENT_TIMESTAMP),(2,1,1,NULL,NULL)")),
          "seed completed and interrupted synthetic runs");
    check(isDefined(openCJ\mySQL::mysqlSyncQuery(
              "INSERT INTO checkpointStatistics" +
              "(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives)" +
              " VALUES(1," + middleId + ",1000,0,0,0,0,0),(2," + middleId + ",1000,0,0,0,0,0)")),
          "seed historical checkpoint references");
    editor.cpc.rows[1] = row(250, false, true);
    check(editor openCJ\checkpointPublish::publish(), "one changed checkpoint publishes with history");
    checkScalar("SELECT cpID FROM checkpointAreas WHERE ordinal=1", middleId,
                "geometry replacement retains checkpoint identity");
    checkScalar("SELECT COUNT(*) FROM checkpointStatistics", 2, "migration preserves statistics");
    checkScalar("SELECT archived+0 FROM playerRuns WHERE runID=1", 0, "completed result stays active");
    checkScalar("SELECT archived+0 FROM playerRuns WHERE runID=2", 1, "interrupted run is archived");

    changedCheckpoint = openCJ\checkpointCreation::_decode(editor.cpc.rows[1]);
    changedCheckpoint.allowEle = true;
    editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(changedCheckpoint);
    check(!editor openCJ\checkpointPublish::publish(), "historical requirement change is rejected");
    checkScalar("SELECT elevate FROM checkpoints WHERE cpID=" + middleId, 0,
                "rejected edit leaves published requirements intact");
    checkScalar("SELECT COUNT(*) FROM checkpointConnections", 4,
                "rejected edit leaves published graph intact");

    reducedRows = [];
    reducedRows[0] = editor.cpc.rows[0];
    reducedRows[1] = editor.cpc.rows[2];
    editor.cpc.rows = reducedRows;
    editor.cpc.selected = reducedRows.size;
    check(editor openCJ\checkpointPublish::publish(), "middle group can be retired with history");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 2, "retired group leaves active layout");
    checkScalar("SELECT COUNT(*) FROM checkpoints WHERE retired=1", 2,
                "retired primary and alternative remain addressable");
    checkScalar("SELECT COUNT(*) FROM checkpointStatistics WHERE cpID=" + middleId, 2,
                "retired checkpoint keeps historical statistics");
    checkScalar("SELECT cpID FROM checkpointAreas WHERE ordinal=0", startId, "start ID survives deletion");
    checkScalar("SELECT cpID FROM checkpointAreas WHERE ordinal=1", finishId, "finish ID survives deletion");
    checkScalar("SELECT retired FROM checkpoints WHERE cpID=" + alternativeId, 1,
                "alternative retires with its group");
}

// Fail after earlier inserts, then verify the owner rolls back the complete transaction.
checkPartialWriteRollback(editor)
{
    editor.cpc = routeDraft("rejected_route");
    if (!check(isDefined(openCJ\mySQL::mysqlSyncQuery(
                   "CREATE TRIGGER fixture_reject_area BEFORE INSERT ON checkpointAreas " +
                   "FOR EACH ROW BEGIN IF NEW.ordinal=2 THEN " +
                   "SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='synthetic area failure'; END IF; END")),
               "install fixture-only failure trigger"))
    {
        return;
    }
    check(!editor openCJ\checkpointPublish::publish(), "partial publication reports failure");
    checkScalar("SELECT COUNT(*) FROM routes WHERE routeName='rejected_route'", 0,
                "failed transaction removes its route identity");
    checkScalar("SELECT COUNT(*) FROM checkpoints", 4, "failed transaction removes inserted checkpoints");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 2, "failed transaction preserves old areas");
    check(isDefined(openCJ\mySQL::mysqlSyncQuery("DROP TRIGGER fixture_reject_area")),
          "remove synthetic failure trigger");
}

checkScalar(query, expected, label)
{
    rows = openCJ\mySQL::mysqlSyncQuery(query);
    if (!isDefined(rows) || rows.size != 1 || !isDefined(rows[0][0]))
    {
        return check(false, label + " (expected one SQL value)");
    }
    actual = int(rows[0][0]);
    return check(actual == expected, label + " expected=" + expected + " actual=" + actual);
}

check(condition, label)
{
    level.publicationChecks++;
    if (!condition)
    {
        level.publicationFailures++;
    }
    printf("PUBLICATION CHECK " + condition + ": " + label + "\n");
    return condition;
}

// Simulate filename collisions without creating thousands of files or touching live drafts.
checkBackupCapacity(editor)
{
    originalPath = editor.cpc.path;
    originalRevision = editor.cpc.revision;
    level.forceMigrationBackupCollision = true;
    level.migrationBackupLookups = 0;
    saved = editor openCJ\checkpointMigration::backUpPublishedDraft(editor.cpc.route, editor.cpc.rows);
    level.forceMigrationBackupCollision = false;
    maximumBackupNames = 10000;
    check(!saved, "exhausted recovery names reject migration");
    check(level.migrationBackupLookups == maximumBackupNames, "recovery filename search is bounded");
    check(editor.cpc.path == originalPath && editor.cpc.revision == originalRevision,
          "exhausted backup names preserve the active draft");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 4,
                "exhausted backup names preserve published geometry");
}

migrationBackupExists(path)
{
    if(isDefined(level.forceMigrationBackupCollision) && level.forceMigrationBackupCollision)
    {
        level.migrationBackupLookups++;
        return true;
    }
    return FS_TestFile(path);
}

// Either branch may publish first; the shared opening keeps one set of checkpoint IDs.
checkSharedBranches(editor)
{
    editor.cpc = routeDraft("branch_a");
    editor.cpc.sharedRoute = "shared_opening";
    editor.cpc.sharedHex = "#abcdef";
    editor.cpc.sharedCount = 2;
    check(editor openCJ\checkpointPublish::publish(), "first branch publishes its shared opening");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE draftName='shared_opening'", 3,
                "shared opening includes primary and alternative areas");
    firstBranch = editor.cpc;
    editor.cpc = routeDraft("branch_b");
    editor.cpc.rows[2] = row(600, true, false);
    editor.cpc.sharedRoute = "shared_opening";
    editor.cpc.sharedHex = "#abcdef";
    editor.cpc.sharedCount = 2;
    check(editor openCJ\checkpointPublish::publish(), "second branch reuses the shared opening");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE draftName='shared_opening'", 3,
                "second branch does not duplicate shared checkpoints");
    checkScalar(
        "SELECT COUNT(*) FROM checkpointConnections e " +
        "JOIN checkpointAreas p ON p.cpID=e.cpID JOIN checkpointAreas c ON c.cpID=e.childcpID " +
        "WHERE p.draftName='shared_opening' AND c.draftName IN ('branch_a','branch_b')",
        4, "both shared alternatives connect to both branch finishes");
    checkScalar(
        "SELECT COUNT(*) FROM checkpointRoutes cr " +
        "JOIN checkpointAreas a ON a.cpID=cr.cpID WHERE a.draftName='shared_opening'",
        6, "shared checkpoints belong to both reachable routes");
    check(editor openCJ\checkpointPublish::publish(), "repeated branch publication succeeds");
    checkScalar(
        "SELECT COUNT(*) FROM checkpointConnections e " +
        "JOIN checkpointAreas p ON p.cpID=e.cpID JOIN checkpointAreas c ON c.cpID=e.childcpID " +
        "WHERE p.draftName='shared_opening' AND c.draftName IN ('branch_a','branch_b')",
        4, "repeated branch publication does not duplicate shared connections");
    editor.cpc.rows[0] = row(50, false, false);
    check(!editor openCJ\checkpointPublish::publish(), "changed shared opening is rejected");
    checkScalar(
        "SELECT c.x FROM checkpoints c JOIN checkpointAreas a ON a.cpID=c.cpID " +
        "WHERE a.draftName='shared_opening' AND a.ordinal=0",
        50, "rejected shared edit leaves the original opening center");
    editor.cpc = firstBranch;
}

checkInsertedCheckpoint(editor)
{
    editor.cpc = routeDraft("fixture_route");
    editor.cpc.rows[1] = row(300, false, false);
    check(editor openCJ\checkpointPublish::publish(), "insertion allocates only the new checkpoint");
    checkScalar("SELECT COUNT(*) FROM checkpoints", 5, "insertion keeps retired checkpoints and adds one");
    checkScalar("SELECT cpID FROM checkpointAreas WHERE draftName='fixture_route' AND ordinal=0",
                level.publicationOriginalIds[0], "insertion keeps original start ID");
    checkScalar("SELECT cpID FROM checkpointAreas WHERE draftName='fixture_route' AND ordinal=2",
                level.publicationOriginalIds[3], "insertion keeps original finish ID");
    checkScalar("SELECT COUNT(*) FROM checkpointStatistics", 2, "insertion preserves historical statistics");
}

checkUnusedRouteReplacement(editor)
{
    editor.cpc = routeDraft("unused_route");
    check(editor openCJ\checkpointPublish::publish(), "unused route baseline publishes");
    firstRows = openCJ\mySQL::mysqlSyncQuery(
        "SELECT cpID FROM checkpointAreas WHERE draftName='unused_route' ORDER BY ordinal");
    if (!check(isDefined(firstRows) && firstRows.size == 4, "unused route has four initial area IDs"))
    {
        return;
    }
    firstCheckpointId = int(firstRows[0][0]);
    editor.cpc.rows[0] = row(100, false, false);
    editor.cpc.rows[2] = row(700, true, false);
    checkpoint = openCJ\checkpointCreation::_decode(editor.cpc.rows[1]);
    checkpoint.allowEle = true;
    editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(checkpoint);
    check(editor openCJ\checkpointPublish::publish(), "route without history permits endpoint and requirement changes");
    checkScalar("SELECT cpID FROM checkpointAreas WHERE draftName='unused_route' AND ordinal=0",
                firstCheckpointId, "unused route replacement preserves start identity");
    checkScalar("SELECT x FROM checkpoints WHERE cpID=" + firstCheckpointId, 150,
                "unused route replacement publishes the changed start");
}

// Metadata loading updates the runtime graph without changing its checkpoint identities.
checkLoadedMetadata()
{
    areaIds = openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas ORDER BY cpID");
    if (!check(isDefined(areaIds) && areaIds.size > 0, "published metadata has checkpoint IDs"))
    {
        return;
    }
    level.checkpoints_checkpoints = [];
    for (i = 0; i < areaIds.size; i++)
    {
        checkpoint = spawnStruct();
        checkpoint.id = int(areaIds[i][0]);
        level.checkpoints_checkpoints[i] = checkpoint;
    }
    check(isDefined(openCJ\mySQL::mysqlSyncQuery(
              "UPDATE checkpointAreas SET heightAbove=24 WHERE draftName='fixture_route' AND ordinal=0")),
          "seed synthetic area height");
    openCJ\checkpointPublish::loadAreas();
    startCheckpoint = openCJ\checkpoints::getCheckpointByID(level.publicationOriginalIds[0]);
    check(isDefined(startCheckpoint.area) && startCheckpoint.area.size == 4,
          "area loader restores the stored polygon");
    check(startCheckpoint.heightAbove == 24, "area loader restores the stored height");
    check(isDefined(startCheckpoint.routeInfo) && startCheckpoint.routeInfo.hex == "#123456",
          "area loader attaches the current route color");
}

// The database commits normally; only its reply to the publisher is hidden.
checkLostCommitReply(editor)
{
    editor.cpc = routeDraft("lost_reply_route");
    level.hidePublicationCommitReply = true;
    check(!editor openCJ\checkpointPublish::publish(), "lost commit reply does not claim success");
    check(isSubStr(editor.cpc.status, "confirm"), "lost commit reply reports an uncertain outcome");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE draftName='lost_reply_route'", 4,
                "lost reply can accompany a completed commit");
    check(editor openCJ\checkpointPublish::publish(), "retry reconciles the already-published route");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE draftName='lost_reply_route'", 4,
                "retry after a lost commit reply keeps one set of areas");
    checkScalar("SELECT COUNT(*) FROM routes WHERE routeName='lost_reply_route'", 1,
                "retry after a lost commit reply keeps one route identity");
}

publicationQuery(query)
{
    if (isDefined(level.rejectedGraphQueryFragment) &&
        isSubStr(query, level.rejectedGraphQueryFragment))
    {
        return undefined;
    }
    result = openCJ\mySQL::mysqlSyncQuery(query);
    if(query == "COMMIT" && isDefined(level.hidePublicationCommitReply) &&
       level.hidePublicationCommitReply)
    {
        level.hidePublicationCommitReply = false;
        return undefined;
    }
    return result;
}

// Finalization must leave editor mode before the normal run-creation gate can accept it.
checkFinalizationRun(editor)
{
    editor.cpc = routeDraft("finalize_route");
    editor.cpc.routeColor = (0, 1, 0);
    editor openCJ\checkpointCreation::createEditorHuds();
    checkpointHud = editor.cpc.huds["checkpoint"];
    actionsHud = editor.cpc.huds["actions"];
    routeHud = editor.cpc.huds["route"];
    check(isDefined(checkpointHud) && isDefined(actionsHud) && isDefined(routeHud),
          "editor allocates its three named HUD panels");
    editor.cpc.positions = [];
    level.finalizeActivations = 0;
    level.finalizeRunCreated = 0;
    editor.cpc.routeHex = "invalid";
    editor openCJ\checkpointCreation::finalize();
    check(isDefined(editor.cpc) && !isDefined(editor.cpc.finalizing),
          "rejected finalization retains the editable draft");
    check(!editor openCJ\playerRuns::hasRunID() && level.finalizeActivations == 0,
          "rejected publication does not start gameplay or refresh the graph");
    editor.cpc.routeHex = "#123456";
    level.forwardGraphActivation = true;
    level.rejectedGraphQueryFragment = "GROUP_CONCAT";
    editor openCJ\checkpointCreation::finalize();
    level.rejectedGraphQueryFragment = undefined;
    level.forwardGraphActivation = false;
    check(isDefined(editor.cpc) && !isDefined(editor.cpc.finalizing),
          "failed gameplay refresh retains the published draft for retry");
    check(!editor openCJ\playerRuns::hasRunID() && isSubStr(editor.cpc.status, "Published"),
          "failed refresh reports committed publication without starting a run");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE draftName='finalize_route'", 4,
                "failed gameplay refresh does not undo committed publication");
    level.finalizeActivations = 0;
    editor openCJ\checkpointCreation::finalize();
    check(!isDefined(editor.cpc), "successful finalization closes the editor");
    check(!isDefined(checkpointHud) && !isDefined(actionsHud) && !isDefined(routeHud),
          "closing the editor releases all three HUD panels");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE draftName='finalize_route'", 4,
                "finalization publishes the route before returning to gameplay");
    check(level.finalizeActivations == 1, "finalization requests one graph refresh");
    check(editor openCJ\playerRuns::hasRunID(), "finalization creates a fresh gameplay run");
    check(level.finalizeRunCreated == 1, "fresh run reaches the gameplay spawn callback");
    newRunId = editor openCJ\playerRuns::getRunID();
    if (isDefined(newRunId))
    {
        checkScalar("SELECT COUNT(*) FROM playerRuns WHERE runID=" + newRunId +
                    " AND playerID=1 AND archived=0", 1,
                    "finalization stores one active synthetic run");
    }
    else
    {
        check(false, "finalization stores one active synthetic run");
    }
}

recordActivation()
{
    level.finalizeActivations++;
    if (isDefined(level.forwardGraphActivation) && level.forwardGraphActivation)
    {
        return self openCJ\checkpointPublish::activate();
    }
    return true;
}

recordHudRefresh()
{
}

recordPointerRefresh()
{
}

recordRunCreated()
{
    level.finalizeRunCreated++;
}

// A failed refresh must not replace the currently playable graph with incomplete state.
checkGraphReload()
{
    openCJ\checkpoints::onInit();
    check(level.checkpoints_checkpoints.size > 0, "real graph loader connects published checkpoints");
    checkLoadedGraphRoutes();
    previousStart = level.checkpoints_startCheckpoint;
    previousCheckpoint = level.checkpoints_checkpoints[0];
    previousRoute = level.checkpointRoutes["fixture_route"];
    previousRouteEnder = level.routeEnders["fixture_route"][0];
    previousEpoch = level.checkpointLayoutEpoch;
    failedQueries = [];
    failedQueries[0] = "GROUP_CONCAT";
    failedQueries[1] = "SHOW TABLES LIKE 'checkpointAreas'";
    failedQueries[2] = "SHOW COLUMNS FROM routes LIKE 'colorRGB'";
    failedQueries[3] = "FROM routes r JOIN checkpoints c";
    failedQueries[4] = "SHOW COLUMNS FROM checkpointAreas LIKE 'sectionName'";
    failedQueries[5] = "LEFT JOIN checkpointSectionColors";
    for (i = 0; i < failedQueries.size; i++)
    {
        level.rejectedGraphQueryFragment = failedQueries[i];
        reloaded = openCJ\checkpoints::onInit();
        level.rejectedGraphQueryFragment = undefined;
        check(!reloaded, "unavailable graph query rejects refresh: " + failedQueries[i]);
        check(level.checkpoints_startCheckpoint == previousStart &&
              level.checkpoints_checkpoints[0] == previousCheckpoint,
              "failed query preserves current graph objects: " + failedQueries[i]);
        check(level.checkpointRoutes["fixture_route"] == previousRoute &&
              level.routeEnders["fixture_route"][0] == previousRouteEnder,
              "failed query preserves route metadata: " + failedQueries[i]);
        check(level.checkpointLayoutEpoch == previousEpoch,
              "failed query keeps the current layout epoch: " + failedQueries[i]);
    }

    // Simulate the first map load, where there is no earlier playable graph.
    level.checkpoints_startCheckpoint = undefined;
    level.checkpoints_checkpoints = [];
    level.checkpointRoutes = [];
    level.routeEnders = [];
    level.checkpointLayoutEpoch = undefined;
    level.rejectedGraphQueryFragment = "GROUP_CONCAT";
    reloaded = openCJ\checkpoints::onInit();
    level.rejectedGraphQueryFragment = undefined;
    check(!reloaded && isDefined(level.checkpoints_startCheckpoint),
          "failed initial load leaves an explicit empty start checkpoint");
    check(level.checkpoints_startCheckpoint.childs.size == 0 &&
          level.checkpoints_checkpoints.size == 0 && !isDefined(level.checkpointLayoutEpoch),
          "failed initial load has no partial graph or successful-layout epoch");
    check(openCJ\checkpoints::onInit() && level.checkpoints_checkpoints.size > 0,
          "initial load can recover after the database becomes available");
}

// These route lengths come from the synthetic layouts above, independently of loader traversal.
checkLoadedGraphRoutes()
{
    start = openCJ\checkpoints::getCheckpointByID(level.publicationOriginalIds[0]);
    finish = openCJ\checkpoints::getCheckpointByID(level.publicationOriginalIds[3]);
    check(start.childs.size == 1 && start.childs[0].childs.size == 1 &&
          start.childs[0].childs[0] == finish, "migrated route links opening, inserted step and finish");
    check(start.checkpointsFromStart == 1 && start.childs[0].checkpointsFromStart == 2 &&
          finish.checkpointsFromStart == 3, "loaded route counts steps from its opening");
    check(start.checkpointsTillEnd == 2 && start.childs[0].checkpointsTillEnd == 1 &&
          finish.checkpointsTillEnd == 0, "loaded route counts steps to its finish");
    check(openCJ\checkpoints::getRouteNameForCheckpoint(start) == "fixture_route",
          "single-route opening resolves its finish name");

    sharedIds = openCJ\mySQL::mysqlSyncQuery(
        "SELECT cpID FROM checkpointAreas WHERE draftName='shared_opening' ORDER BY ordinal");
    if (!check(isDefined(sharedIds) && sharedIds.size == 3,
               "shared fixture contains an opening and two alternative areas"))
    {
        return;
    }
    sharedStart = openCJ\checkpoints::getCheckpointByID(int(sharedIds[0][0]));
    sharedNext = openCJ\checkpoints::filterOutBrothers(sharedStart.childs);
    check(sharedStart.childs.size == 2 && sharedNext.size == 1,
          "both alternative areas resolve to one next checkpoint group");
    check(sharedNext[0].childs.size == 2 && sharedNext[0].contactAreas.size == 2,
          "shared group retains its two branch finishes and two contact areas");
    check(sharedStart.endCheckpoints.size == 2 &&
          !isDefined(openCJ\checkpoints::getRouteNameForCheckpoint(sharedStart)),
          "shared opening keeps both reachable routes without choosing one");
}
