main()
{
    wait 2;
    level.brushFailures = 0;
    checkHeightVolumes();
    editor = createEditor();
    checkHeightConflicts(editor);
    checkHeightControls(editor);
    checkHeightPersistence(editor);
    checkInvalidHeightPreviews();
    printf("BRUSH SELFTEST COMPLETE failures=" + level.brushFailures + "\n");
}

checkHeightVolumes()
{
    baseArea = area(0, 0, 100, 100, 0);
    upperArea = area(20, 20, 80, 80, 40);
    check(!openCJ\checkpointHeight::groupsOverlap(baseArea, upperArea),
          "separate stacked checkpoints do not overlap by default");
    baseArea.heightAbove = 40;
    check(openCJ\checkpointHeight::groupsOverlap(baseArea, upperArea),
          "expanded height detects stacked checkpoint");
    check(openCJ\checkpointCreation::contains(baseArea, (50, 50, 40), true),
          "expanded area triggers on ground");
    check(!openCJ\checkpointCreation::contains(baseArea, (50, 50, 40), false),
          "height does not bypass on-ground requirement");
    check(!openCJ\checkpointCreation::contains(baseArea, (50, 50, 45), true),
          "upper bound excludes above volume");
    check(openCJ\checkpointCreation::contains(baseArea, (50, 50, -2), true),
          "lower boundary included");
    check(!openCJ\checkpointCreation::contains(baseArea, (50, 50, -3), true),
          "below lower boundary excluded");
    restored = openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(baseArea));
    check(restored.heightAbove == 40, "height draft fields roundtrip");
    check(openCJ\checkpointNetwork::sameCheckpoint(baseArea, restored),
          "network identity includes height");
    restored.heightAbove = 44;
    check(!openCJ\checkpointNetwork::sameCheckpoint(baseArea, restored),
          "height change is a pending edit");
    legacyArea = openCJ\checkpointCreation::_decode("0:0:p0,0,0;100,0,0;100,100,0;0,100,0");
    check(legacyArea.heightAbove == 0, "old drafts retain zero offsets");
    check(openCJ\checkpointCreation::contains(legacyArea, (50, 50, 4), true) &&
              !openCJ\checkpointCreation::contains(legacyArea, (50, 50, 5), true),
          "old trigger height unchanged");
    curvedArea = area(0, 0, 100, 100, 0);
    curvedArea.points[1] = (100, 0, 20);
    curvedArea.points[2] = (100, 100, 5);
    curvedArea.points[3] = (0, 100, 10);
    check(openCJ\checkpointHeight::flatten(curvedArea), "curved corners automatically flatten");
    for(i = 0; i < curvedArea.points.size; i++)
    {
        check(curvedArea.points[i][2] == 0, "lowest corner sets base");
    }
    check(curvedArea.heightAbove == 20, "flattening preserves selected vertical span");
    slope = area(0, 0, 100, 100, 0);
    slope.points[1] = (100, 0, 25);
    slope.points[2] = (100, 100, 25);
    check(!openCJ\checkpointHeight::flatten(slope), "planar slopes stay sloped");
    overheadArea = area(20, 20, 80, 80, 40);
    slope.heightAbove = 40;
    check(openCJ\checkpointHeight::groupsOverlap(slope, overheadArea),
          "sloped volume overlap detected");
    crossing = area(49, -50, 51, 150, 0);
    narrow = area(-50, 49, 150, 51, 0);
    check(openCJ\checkpointHeight::groupsOverlap(crossing, narrow),
          "narrow crossing volumes detected");
    adjacent = area(100, 0, 200, 100, 0);
    check(!openCJ\checkpointHeight::groupsOverlap(legacyArea, adjacent),
          "touching side boundaries allowed");
    upperArea = area(0, 0, 100, 100, 6);
    check(!openCJ\checkpointHeight::groupsOverlap(legacyArea, upperArea),
          "touching vertical boundaries allowed");
    upperArea = area(0, 0, 100, 100, 5);
    check(openCJ\checkpointHeight::groupsOverlap(legacyArea, upperArea),
          "positive vertical overlap rejected");
    invalid = "0:0:p0,0,0;100,0,0;100,100,0:1:1:0:-:-1";
    check(!isDefined(openCJ\checkpointCreation::_decode(invalid)),
          "negative draft height rejected");
}

createEditor()
{
    editor = spawnStruct();
    editor.login_playerID = -9999;
    editor.cpc = spawnStruct();
    editor.cpc.route = "test";
    editor.cpc.rows = [];
    editor.cpc.selected = 0;
    return editor;
}

checkHeightConflicts(editor)
{
    selected = area(0, 0, 100, 100, 0);
    otherArea = area(20, 20, 80, 80, 40);
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(selected);
    editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(otherArea);
    editor.cpc.draft = selected;
    level.checkpoints_checkpoints = [];
    candidate = openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(selected));
    candidate.heightAbove = 40;
    check(isSubStr(editor openCJ\checkpointHeight::conflict(candidate), "checkpoint 2"),
          "increase is blocked by another draft checkpoint");
    check(selected.heightAbove == 0, "rejected proposal leaves original height unchanged");
    candidate.heightAbove = 20;
    check(editor openCJ\checkpointHeight::conflict(candidate) == "", "safe increase allowed");
    editor.cpc.rows[1] = undefined;
    candidate.heightAbove = 40;
    published = spawnStruct();
    published.area = otherArea.points;
    published.id = 42;
    published.heightAbove = 0;
    level.checkpoints_checkpoints[0] = published;
    check(isSubStr(editor openCJ\checkpointHeight::conflict(candidate), "published checkpoint #42"),
          "increase is blocked by published checkpoint");
    published.area = selected.points;
    check(editor openCJ\checkpointHeight::conflict(candidate) == "",
          "editing own published geometry does not collide with itself");
    level.checkpoints_checkpoints = [];
    // Alternate areas of the selected logical checkpoint may still overlap.
    selected.alternatives[0] = otherArea.points;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(selected);
    candidate = openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    candidate.heightAbove = 40;
    check(editor openCJ\checkpointHeight::conflict(candidate) == "",
          "same-checkpoint alternatives remain allowed");
}

checkHeightControls(editor)
{
    editor.cpc.rows = [];
    editor.cpc.selected = 0;
    editor.cpc.draft = area(0, 0, 100, 100, 0);
    editor openCJ\checkpointHeight::edit("height");
    check(isDefined(editor.cpc.heightTarget), "Num7 enables height editing");
    editor openCJ\checkpointHeight::edit("heightup");
    check(editor.cpc.draft.heightAbove == 4, "plus raises top four units");
    editor openCJ\checkpointHeight::edit("heightdown");
    check(editor.cpc.draft.heightAbove == 0, "minus lowers top to original height");
    editor.cpc.heightRequestValue = 64;
    editor openCJ\checkpointHeight::edit("heightset");
    editor openCJ\checkpointHeight::edit("height");
    check(!isDefined(editor.cpc.heightTarget) && editor.cpc.draft.heightAbove == 64,
          "Num7 exits editing without resetting height");
    editor.cpc.heightTarget = "upper";
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    editor openCJ\checkpointHeight::edit("height");
    check(!isDefined(editor.cpc.heightTarget),
          "height editing can always be disabled after discard");
}

checkHeightPersistence(editor)
{
    editor.cpc.draft = area(0, 0, 100, 100, 0);
    editor.cpc.draft.heightAbove = 64;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(editor.cpc.draft);
    editor.cpc.path = "height-roundtrip";
    editor.cpc.route = "test";
    editor.cpc.routeHex = "#00ff00";
    editor.cpc.revision = 0;
    check(editor openCJ\checkpointCreation::_save(), "draft height writes to filesystem");
    saved = openCJ\checkpointCreation::_read("height-roundtrip.b", "test");
    check(isDefined(saved) && saved.draft.heightAbove == 64,
          "pending height restores from filesystem");
    restored = openCJ\checkpointCreation::_decode(saved.rows[0]);
    check(restored.heightAbove == 64, "confirmed height restores from filesystem");
    origin = openCJ\checkpointCreation::restoreOrigin(saved);
    check(origin[2] == 70,
          "volume draft resumes above upper boundary instead of inside curved platform");
}

area(x1, y1, x2, y2, z)
{
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points[0] = (x1, y1, z);
    checkpoint.points[1] = (x2, y1, z);
    checkpoint.points[2] = (x2, y2, z);
    checkpoint.points[3] = (x1, y2, z);
    return checkpoint;
}

check(value, name)
{
    if(!value)
    {
        level.brushFailures++;
        printf("BRUSH SELFTEST FAIL " + name + "\n");
    }
    else
    {
        printf("BRUSH SELFTEST PASS " + name + "\n");
    }
}

// A corner edit can temporarily stop forming a plane while height editing remains active.
checkInvalidHeightPreviews()
{
    editor = addtestclient();
    check(isDefined(editor), "preview fixture has a client");
    if(!isDefined(editor))
    {
        return;
    }
    wait 0.1;
    editor.cpc = spawnStruct();
    editor.cpc.drawCommands = 0;
    editor.cpc.heightTarget = "upper";

    collinear = [];
    collinear[0] = (0, 0, 0);
    collinear[1] = (100, 0, 0);
    collinear[2] = (200, 0, 0);
    editor openCJ\checkpointCreation::_outline(collinear, "1 1 1 1", 0);
    check(editor.cpc.heightTarget == "upper",
          "collinear preview returns without losing active height editing");

    editor.cpc.heightTarget = undefined;
    vertical = [];
    vertical[0] = (0, 0, 0);
    vertical[1] = (0, 100, 0);
    vertical[2] = (0, 100, 100);
    vertical[3] = (0, 0, 100);
    editor openCJ\checkpointCreation::_outline(vertical, "1 1 1 1", 64);
    check(!isDefined(editor.cpc.heightTarget),
          "vertical preview with a saved height returns without enabling height editing");
}
