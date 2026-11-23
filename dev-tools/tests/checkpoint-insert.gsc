main()
{
    wait 2;
    level.brushFailures = 0;
    editor = spawnStruct();
    editor.login_playerID = -9999;
    editor.cpc = spawnStruct();
    editor.cpc.route = "test";
    editor.cpc.path = "insert-test";
    editor.cpc.routeHex = "#00ff00";
    editor.cpc.revision = 0;
    editor.cpc.history = [];
    editor.cpc.testing = false;
    editor.cpc.rows = [];
    startCheckpoint = checkpointAtX(0);
    middleCheckpoint = checkpointAtX(200);
    middleCheckpoint.double = true;
    middleCheckpoint.allowEle = true;
    middleCheckpoint.allowSave = false;
    alternativeCheckpoint = checkpointAtX(240);
    middleCheckpoint.alternatives[0] = alternativeCheckpoint.points;
    finishCheckpoint = checkpointAtX(400);
    finishCheckpoint.finish = true;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(startCheckpoint);
    editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(middleCheckpoint);
    editor.cpc.rows[2] = openCJ\checkpointCreation::_encode(finishCheckpoint);
    original = spawnStruct();
    original.startRow = editor.cpc.rows[0];
    original.middleRow = editor.cpc.rows[1];
    original.finishRow = editor.cpc.rows[2];
    editor.cpc.selected = 0;
    editor.cpc.draft = startCheckpoint;
    checkInsertAfterAndUndo(editor, original);
    checkInsertionGuards(editor, original);
    checkInsertBefore(editor, original);
    for(i = 3; i < 256; i++)
    {
        editor.cpc.rows[i] = original.startRow;
    }
    check(!(editor openCJ\checkpointCreation::beginInsertion()),
          "256 checkpoint limit enforced before insertion");
    printf("BRUSH SELFTEST COMPLETE failures=" + level.brushFailures + "\n");
}
// Saving and Undo must preserve the untouched suffix and the pending insertion.
checkInsertAfterAndUndo(editor, original)
{
    check(openCJ\checkpointCreation::nextPreviewIndex(editor.cpc) == 1,
          "editing previews next checkpoint");
    check(editor openCJ\checkpointCreation::beginInsertion(),
          "begin insertion after selected checkpoint");
    check(editor.cpc.rows.size == 3 && editor.cpc.rows[1] == original.middleRow,
          "starting insertion leaves confirmed rows untouched");
    check(editor.cpc.selected == 3 && editor.cpc.insertAfter == 0,
          "pending geometry is outside confirmed rows");
    check(openCJ\checkpointNetwork::pendingEdit(editor.cpc), "empty insertion is pending work");
    check(!openCJ\checkpointCreation::readyToFinalize(editor.cpc),
          "empty insertion cannot look ready to finalize");
    check(openCJ\checkpointCreation::nextPreviewIndex(editor.cpc) == 1,
          "insertion previews displaced next checkpoint");
    restoredDraft = openCJ\checkpointCreation::_read("insert-test.b", "test");
    check(isDefined(restoredDraft) && restoredDraft.insertAfter == 0 && restoredDraft.rows.size == 3,
          "empty insertion survives draft save and restore");
    editor openCJ\checkpointCreation::_action("finish");
    check(editor.cpc.draft.finish && editor.cpc.rows[2] == original.finishRow,
          "pending properties do not edit last existing checkpoint");
    editor.cpc.draft = checkpointAtX(100);
    editor.cpc.savedPosition = spawnStruct();
    editor.cpc.savedPosition.origin = (100, 10, 0);
    editor.cpc.savedPosition.angles = (0, 90, 0);
    editor openCJ\checkpointCreation::_save();
    suffix = ".a";
    if(editor.cpc.revision % 2)
    {
        suffix = ".b";
    }
    restoredDraft = openCJ\checkpointCreation::_read("insert-test" + suffix, "test");
    check(isDefined(restoredDraft) && restoredDraft.insertAfter == 0 && restoredDraft.draft.points[0][0] == 100 &&
              restoredDraft.savedPosition.angles[1] == 90,
          "insertion geometry and manual travel save both roundtrip");
    check(!(editor openCJ\checkpointPublish::publish()),
          "pending insertion cannot publish through direct path");
    editor openCJ\checkpointCreation::_action("confirm");
    check(editor.cpc.rows.size == 4 && editor.cpc.rows[0] == original.startRow && editor.cpc.rows[2] == original.middleRow &&
              editor.cpc.rows[3] == original.finishRow,
          "confirm shifts suffix intact including properties and alternatives");
    check(!isDefined(editor.cpc.insertAfter) && editor.cpc.selected == editor.cpc.rows.size &&
              editor.cpc.draft.points.size == 0,
          "confirm insertion returns to empty new-checkpoint state");
    check(openCJ\checkpointCreation::nextPreviewIndex(editor.cpc) > editor.cpc.rows.size,
          "confirmed insertion leaves no editing neighbor selection");
    countAfterFirst = editor.cpc.rows.size;
    editor openCJ\checkpointCreation::_action("confirm");
    check(editor.cpc.rows.size == countAfterFirst && editor.cpc.rows[1] != original.middleRow &&
              editor.cpc.rows[2] == original.middleRow,
          "second Enter does not insert twice or replace successor");
    editor openCJ\checkpointCreation::_action("undo");
    check(openCJ\checkpointPublish::validationError(editor.cpc.rows) == "",
          "inserted route validates for sequential publication");
    editor openCJ\checkpointCreation::_action("undo");
    check(editor.cpc.rows.size == 3 && editor.cpc.insertAfter == 0 && editor.cpc.draft.points.size == 4,
          "undo confirm restores pending insertion");
    editor openCJ\checkpointCreation::_discard();
    check(!isDefined(editor.cpc.insertAfter) && editor.cpc.rows.size == 3 && editor.cpc.rows[1] == original.middleRow &&
              editor.cpc.selected == 0,
          "discard insertion preserves existing checkpoints");
    editor openCJ\checkpointCreation::_action("undo");
    check(editor.cpc.insertAfter == 0 && editor.cpc.rows.size == 3, "undo discard restores insertion");
    editor openCJ\checkpointCreation::_action("confirm");
    editor openCJ\checkpointCreation::_action("undo");
    editor openCJ\checkpointCreation::_discard();
}

// Reject insertion into pending edits, protected openings, invalid geometry or after a finish.
checkInsertionGuards(editor, original)
{
    editor.cpc.selected = 2;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(original.finishRow);
    check(!(editor openCJ\checkpointCreation::beginInsertion()), "cannot insert after a finish");
    editor.cpc.selected = 0;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    editor.cpc.draft.double = true;
    check(!(editor openCJ\checkpointCreation::beginInsertion()),
          "pending selected edit must be applied first");
    editor.cpc.draft = openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    editor.cpc.sharedCount = 2;
    check(!(editor openCJ\checkpointCreation::beginInsertion()),
          "branch cannot insert inside read-only shared prefix");
    editor.cpc.sharedCount = undefined;
    check(editor openCJ\checkpointCreation::beginInsertion(), "repeat insertion starts safely");
    editor openCJ\checkpointCreation::_action("confirm");
    check(editor.cpc.rows.size == 3 && isDefined(editor.cpc.insertAfter),
          "invalid geometry does not shift rows");
    editor openCJ\checkpointCreation::_discard();
}

// Inserting before the finish or the first checkpoint shifts existing rows without changing them.
checkInsertBefore(editor, original)
{
    editor.cpc.selected = 2;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(editor.cpc.rows[2]);
    editor openCJ\checkpointCreation::_action("presert");
    check(editor.cpc.insertAfter == 1, "presert can insert before the finish");
    editor.cpc.draft = checkpointAtX(300);
    editor openCJ\checkpointCreation::_action("confirm");
    check(editor.cpc.rows.size == 4 && editor.cpc.rows[3] == original.finishRow && editor.cpc.rows[1] == original.middleRow,
          "presert retains finish and earlier checkpoint properties");
    editor openCJ\checkpointCreation::_action("undo");
    editor openCJ\checkpointCreation::_discard();
    editor.cpc.selected = 0;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    editor openCJ\checkpointCreation::_action("presert");
    check(editor.cpc.insertAfter == -1 && openCJ\checkpointCreation::nextPreviewIndex(editor.cpc) == 0,
          "presert before first checkpoint has no previous neighbor");
    suffix = ".a";
    if(editor.cpc.revision % 2)
    {
        suffix = ".b";
    }
    restoredDraft = openCJ\checkpointCreation::_read("insert-test" + suffix, "test");
    check(isDefined(restoredDraft) && restoredDraft.insertAfter == -1,
          "presert before first checkpoint roundtrips in draft");
    editor.cpc.draft = checkpointAtX(-100);
    editor openCJ\checkpointCreation::_action("confirm");
    check(editor.cpc.rows.size == 4 && editor.cpc.rows[1] == original.startRow && editor.cpc.rows[2] == original.middleRow,
          "presert shifts all original checkpoints intact");
    editor openCJ\checkpointCreation::_action("undo");
    editor openCJ\checkpointCreation::_discard();
    check(editor.cpc.selected == 0 && editor.cpc.rows[0] == original.startRow,
          "discard before first checkpoint restores valid selection");
    editor.cpc.sharedCount = 1;
    check(!(editor openCJ\checkpointCreation::beginInsertion(true)), "presert protects shared prefix");
    editor.cpc.sharedCount = undefined;
    editor openCJ\checkpointCreation::_action("postsert");
    check(editor.cpc.insertAfter == 0, "postsert command preserves insertion-after behavior");
    editor openCJ\checkpointCreation::_discard();
}

checkpointAtX(x)
{
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points[0] = (x, 0, 0);
    checkpoint.points[1] = (x + 20, 0, 0);
    checkpoint.points[2] = (x + 20, 20, 0);
    checkpoint.points[3] = (x, 20, 0);
    return checkpoint;
}
check(condition, scenario)
{
    if(!condition)
    {
        level.brushFailures++;
        printf("BRUSH SELFTEST FAIL " + scenario + "\n");
    }
    else
    {
        printf("BRUSH SELFTEST PASS " + scenario + "\n");
    }
}
