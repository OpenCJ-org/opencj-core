main()
{
    wait 2;
    level.migrationFailures = 0;
    originalRows = [];
    originalRows[0] = row(0, false);
    originalRows[1] = row(200, false);
    originalRows[2] = row(400, false);
    originalRows[3] = row(600, false);
    originalRows[4] = row(800, true);
    changedRows = originalRows;
    changedRows[2] = row(450, false);
    migrationPlan = openCJ\checkpointMigration::plan(originalRows, changedRows);
    check(isDefined(migrationPlan) && migrationPlan.mapping[2] == 2 &&
              migrationPlan.mapping[4] == 4,
          "move keeps existing IDs and finish");
    rowsAfterDeletion = [];
    rowsAfterDeletion[0] = originalRows[0];
    rowsAfterDeletion[1] = originalRows[1];
    rowsAfterDeletion[2] = originalRows[3];
    rowsAfterDeletion[3] = originalRows[4];
    migrationPlan = openCJ\checkpointMigration::plan(originalRows, rowsAfterDeletion);
    check(isDefined(migrationPlan) && migrationPlan.mapping[2] == 3 &&
              migrationPlan.mapping[3] == 4,
          "deletion matches unchanged suffix");
    migrationPlan = openCJ\checkpointMigration::plan(rowsAfterDeletion, originalRows);
    check(isDefined(migrationPlan) && migrationPlan.mapping[2] == -1 &&
              migrationPlan.mapping[4] == 3,
          "insertion preserves finish and identifies new checkpoint");
    changedRows = originalRows;
    checkpoint = openCJ\checkpointCreation::_decode(changedRows[2]);
    checkpoint.alternatives[0] =
        openCJ\checkpointArea::decode("500,0,0;600,0,0;600,100,0;500,100,0");
    changedRows[2] = openCJ\checkpointCreation::_encode(checkpoint);
    check(isDefined(openCJ\checkpointMigration::plan(originalRows, changedRows)),
          "alternative area change accepted");
    changedRows = originalRows;
    changedRows[0] = row(50, false);
    check(!isDefined(openCJ\checkpointMigration::plan(originalRows, changedRows)),
          "changed start refused");
    changedRows = originalRows;
    changedRows[4] = row(850, true);
    check(!isDefined(openCJ\checkpointMigration::plan(originalRows, changedRows)),
          "changed finish refused");
    changedRows = originalRows;
    changedRows[1] = originalRows[2];
    changedRows[2] = originalRows[1];
    check(!isDefined(openCJ\checkpointMigration::plan(originalRows, changedRows)),
          "reordering refused");
    changedRows = originalRows;
    checkpoint = openCJ\checkpointCreation::_decode(changedRows[2]);
    checkpoint.allowEle = true;
    changedRows[2] = openCJ\checkpointCreation::_encode(checkpoint);
    check(!isDefined(openCJ\checkpointMigration::plan(originalRows, changedRows)),
          "requirement change refused");
    changedRows = originalRows;
    changedRows[1] = row(250, false);
    changedRows[3] = row(650, false);
    check(!isDefined(openCJ\checkpointMigration::plan(originalRows, changedRows)),
          "multiple edits refused");
    legacyRows = [];
    legacyRows[0] = "0:0:p2483.01,0,0;2583.01,0,0;2583.01,100,0;2483.01,100,0";
    legacyRows[1] = originalRows[1];
    legacyRows[2] = originalRows[2];
    legacyRows[3] = originalRows[3];
    legacyRows[4] = originalRows[4];
    preciseRows = openCJ\checkpointMigration::canonicalRows(legacyRows);
    checkpoint = openCJ\checkpointCreation::_decode(preciseRows[2]);
    checkpoint.alternatives[0] =
        openCJ\checkpointArea::decode("500,0,0;600,0,0;600,100,0;500,100,0");
    preciseRows[2] = openCJ\checkpointCreation::_encode(checkpoint);
    migrationPlan = openCJ\checkpointMigration::plan(legacyRows, preciseRows);
    check(isDefined(migrationPlan) && migrationPlan.mapping[0] == 0 &&
              migrationPlan.mapping[2] == 2,
          "legacy precision does not turn alternative addition into whole-route edits");
    migrationPlan = openCJ\checkpointMigration::unusedPlan(originalRows, rowsAfterDeletion);
    check(migrationPlan.mapping.size == rowsAfterDeletion.size && migrationPlan.mapping[0] == 0,
          "unused route preserves start identity during arbitrary replacement");
    printf("MIGRATION SELFTEST COMPLETE failures=" + level.migrationFailures + "\n");
}

row(x, finish)
{
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points[0] = (x, 0, 0);
    checkpoint.points[1] = (x + 100, 0, 0);
    checkpoint.points[2] = (x + 100, 100, 0);
    checkpoint.points[3] = (x, 100, 0);
    checkpoint.finish = finish;
    return openCJ\checkpointCreation::_encode(checkpoint);
}

check(ok, label)
{
    if(!ok)
    {
        level.migrationFailures++;
        printf("MIGRATION SELFTEST FAIL " + label + "\n");
    }
    else
    {
        printf("MIGRATION SELFTEST PASS " + label + "\n");
    }
}
