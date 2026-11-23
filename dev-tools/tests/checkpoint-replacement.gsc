main()
{
    wait 2;
    level.replacementFailures = 0;
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.cpc.rows = [];
    editor.cpc.history = [];
    editor.cpc.testing = false;
    editor.cpc.revision = 0;
    editor.cpc.route = "replacement_test";
    editor.cpc.routeHex = "#ff7777";
    editor.cpc.path = "replacement_test";
    startCheckpoint = area(0);
    middleCheckpoint = area(200);
    finishCheckpoint = area(400);
    finishCheckpoint.finish = true;
    middleCheckpoint.alternatives[0] = area(600).points;
    middleCheckpoint.double = true;
    middleCheckpoint.allowEle = true;
    middleCheckpoint.allowSave = false;
    middleCheckpoint.onGround = false;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(startCheckpoint);
    editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(middleCheckpoint);
    editor.cpc.rows[2] = openCJ\checkpointCreation::_encode(finishCheckpoint);
    originalMiddleRow = editor.cpc.rows[1];
    precedingRow = editor.cpc.rows[0];
    followingRow = editor.cpc.rows[2];
    editor.cpc.selected = 1;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(originalMiddleRow);
    editor openCJ\checkpointCreation::_action("replace");
    check(editor.cpc.selected == 1 && editor.cpc.rows.size == 3,
          "replacement keeps route position");
    check(editor.cpc.rows[1] == originalMiddleRow && editor.cpc.rows[0] == precedingRow &&
              editor.cpc.rows[2] == followingRow,
          "confirmed route untouched before Apply");
    check(editor.cpc.draft.points.size == 0 && editor.cpc.draft.alternatives.size == 0,
          "all old geometry cleared from pending selection");
    check(openCJ\checkpointNetwork::pendingEdit(editor.cpc), "empty replacement remains pending");
    restored = openCJ\checkpointCreation::_read(editor.cpc.path + ".b", editor.cpc.route);
    check(isDefined(restored) && restored.selected == 1 && restored.draft.points.size == 0 &&
              restored.rows[1] == originalMiddleRow,
          "autosave retains pending replacement and confirmed row");
    editor openCJ\checkpointCreation::_action("undo");
    check(openCJ\checkpointCreation::_encode(editor.cpc.draft) == originalMiddleRow &&
              editor.cpc.selected == 1,
          "Undo restores multi-area selection");
    editor openCJ\checkpointCreation::_action("area");
    editor openCJ\checkpointCreation::_action("deletearea");
    check(editor.cpc.draft.alternatives.size == 0 &&
              distanceSquared(editor.cpc.draft.points[0], middleCheckpoint.points[0]) == 0,
          "delete area removes cycled alternative only");
    check(editor.cpc.rows[1] == originalMiddleRow && editor.cpc.rows.size == 3,
          "area deletion waits for Apply");
    editor openCJ\checkpointCreation::_action("deletearea");
    check(editor.cpc.selected == 1 && editor.cpc.draft.points.size == 0,
          "last area removal keeps replacement slot");
    editor.cpc.draft.points = area(800).points;
    editor openCJ\checkpointCreation::_action("confirm");
    replacement = openCJ\checkpointCreation::_decode(editor.cpc.rows[1]);
    check(editor.cpc.rows.size == 3 && editor.cpc.rows[0] == precedingRow &&
              editor.cpc.rows[2] == followingRow,
          "Apply preserves predecessor successor and route count");
    // Confirm may rotate the perimeter order; every selected corner must survive.
    check(replacement.alternatives.size == 0 && sameCorners(area(800).points, replacement.points),
          "Apply replaces middle checkpoint with single new area");
    check(replacement.double &&replacement.allowEle && !replacement.allowSave &&
              !replacement.onGround,
          "requirements preserved");
    editor openCJ\checkpointCreation::_action("undo");
    check(editor.cpc.rows[1] == originalMiddleRow && editor.cpc.selected == 1,
          "Undo Apply restores original linked checkpoint");
    editor.cpc.sharedCount = 2;
    editor openCJ\checkpointCreation::_action("replace");
    check(editor.cpc.draft.points.size == 4, "legacy shared opening protected");
    editor.cpc.sharedCount = undefined;
    editor.cpc.selected = editor.cpc.rows.size;
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    check(!openCJ\checkpointNetwork::pendingEdit(editor.cpc), "empty append slot is not pending");
    editor openCJ\checkpointCreation::_action("replace");
    check(editor.cpc.rows.size == 3 && editor.cpc.selected == 3,
          "replace requires existing checkpoint");
    editor.cpc.selected = 1;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(originalMiddleRow);
    editor openCJ\checkpointCreation::_action("discard");
    check(editor.cpc.rows.size == 2 && editor.cpc.rows[0] == precedingRow &&
              editor.cpc.rows[1] == followingRow,
          "Discard deletes selected middle checkpoint and retains finish");
    replacement = openCJ\checkpointCreation::_decode(editor.cpc.rows[1]);
    check(replacement.finish, "finish marker survives selected discard");
    editor openCJ\checkpointCreation::_action("undo");
    check(editor.cpc.rows.size == 3 && editor.cpc.rows[1] == originalMiddleRow &&
              editor.cpc.selected == 1,
          "Undo restores selected discard and its links");
    editor.cpc.sharedCount = 2;
    editor.cpc.selected = 0;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(precedingRow);
    editor openCJ\checkpointCreation::_action("discard");
    check(editor.cpc.rows.size == 3 && editor.cpc.rows[2] == followingRow,
          "selected shared opening cannot be discarded");
    editor.cpc.sharedCount = undefined;
    editor.cpc.selected = 3;
    editor.cpc.draft = area(900);
    editor openCJ\checkpointCreation::_action("discard");
    check(editor.cpc.rows.size == 3 && editor.cpc.rows[2] == followingRow &&
              editor.cpc.draft.points.size == 0,
          "Discard new geometry preserves finish");
    printf("REPLACEMENT SELFTEST COMPLETE failures=" + level.replacementFailures + "\n");
}

area(x)
{
    replacement = openCJ\checkpointCreation::_empty();
    replacement.points[0] = (x, 0, 0);
    replacement.points[1] = (x + 100, 0, 0);
    replacement.points[2] = (x + 100, 100, 0);
    replacement.points[3] = (x, 100, 0);
    return replacement;
}

check(ok, label)
{
    if(!ok)
    {
        level.replacementFailures++;
        printf("REPLACEMENT SELFTEST FAIL " + label + "\n");
    }
    else
    {
        printf("REPLACEMENT SELFTEST PASS " + label + "\n");
    }
}

sameCorners(expected, actual)
{
    if(expected.size != actual.size)
    {
        return false;
    }
    for(pointIndex = 0; pointIndex < expected.size; pointIndex++)
    {
        found = false;
        for(candidateIndex = 0; candidateIndex < actual.size; candidateIndex++)
        {
            if(expected[pointIndex] == actual[candidateIndex])
            {
                found = true;
                break;
            }
        }
        if(!found)
        {
            return false;
        }
    }
    return true;
}
