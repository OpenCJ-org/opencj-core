main()
{
    wait 2;
    level.resetFailures = 0;
    checkpoints = buildRouteWithAlternative();
    rows = openCJ\checkpointReset::rowsFromActive(checkpoints, "hard");
    check(isDefined(rows) && rows.size == 78, "large route restores all 78 logical checkpoints");
    checkpoint = openCJ\checkpointCreation::_decode(rows[45]);
    check(checkpoint.alternatives.size == 1, "checkpoint 46 retains both areas");
    checkpoint = openCJ\checkpointCreation::_decode(rows[77]);
    check(checkpoint.finish, "finish restored");
    check(!isDefined(openCJ\checkpointReset::rowsFromActive([], "hard")), "empty route refused");
    check(!isDefined(openCJ\checkpointReset::rowsFromActive(checkpoints, "absent")),
          "wrong route refused");
    checkpoints[78].ender = undefined;
    check(!isDefined(openCJ\checkpointReset::rowsFromActive(checkpoints, "hard")),
          "route without finish refused");
    checkpoints[78].ender = "hard";
    checkpoints[0].area = [];
    check(!isDefined(openCJ\checkpointReset::rowsFromActive(checkpoints, "hard")),
          "invalid geometry refused");
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.cpc.route = "hard";
    editor.cpc.path = "reset_fixture";
    editor.cpc.rows = rows;
    editor.cpc.selected = 78;
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    editor.cpc.revision = 0;
    editor.cpc.routeHex = "#ff7777";
    check(editor openCJ\checkpointCreation::_save(), "fixture saved");
    backupPath = openCJ\checkpointReset::backupDraft("reset_fixture", 1);
    restored = openCJ\checkpointCreation::_read(backupPath + ".b", "hard");
    check(isDefined(restored) && restored.rows.size == 78 && restored.rows[77] == rows[77],
          "backup preserves complete snapshot");
    secondBackupPath = openCJ\checkpointReset::backupDraft("reset_fixture", 1);
    check(secondBackupPath != backupPath, "repeated reset cannot overwrite backup");
    editor.cpc.rows = [];
    editor.cpc.rows[0] = rows[0];
    editor openCJ\checkpointCreation::_save();
    restored = openCJ\checkpointCreation::_read(backupPath + ".b", "hard");
    check(restored.rows.size == 78, "backup survives subsequent draft changes");
    printf("RESET SELFTEST COMPLETE failures=" + level.resetFailures + "\n");
}

check(ok, label)
{
    if(!ok)
    {
        level.resetFailures++;
        printf("RESET SELFTEST FAIL " + label + "\n");
    }
    else
    {
        printf("RESET SELFTEST PASS " + label + "\n");
    }
}

// Keep the large-route regression without a dump of installation-specific rows.
buildRouteWithAlternative()
{
    checkpoints = [];
    logicalCheckpointCount = 78;
    alternativeOfIndex = 45;
    for(i = 0; i <= logicalCheckpointCount; i++)
    {
        checkpoint = spawnStruct();
        checkpoint.id = i + 1;
        x = i * 200;
        checkpoint.area = [];
        checkpoint.area[0] = (x, 0, 0);
        checkpoint.area[1] = (x + 100, 0, 0);
        checkpoint.area[2] = (x + 100, 100, 0);
        checkpoint.area[3] = (x, 100, 0);
        checkpoint.onGround = true;
        checkpoint.allowSave = true;
        checkpoint.isEleAllowed = false;
        checkpoint.allowDoubleRPG = false;
        if(i == alternativeOfIndex + 1)
        {
            checkpoint.bigBrother = checkpoints[alternativeOfIndex];
        }
        checkpoints[i] = checkpoint;
    }
    checkpoints[logicalCheckpointCount].ender = "hard";
    return checkpoints;
}
