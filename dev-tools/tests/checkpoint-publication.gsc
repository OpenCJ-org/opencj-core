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
    checkRouteMigration(editor);
    checkPartialWriteRollback(editor);
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
