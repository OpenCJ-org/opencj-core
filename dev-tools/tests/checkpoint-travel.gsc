main()
{
    level.fixtureFailures = 0;
    wait 2;
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.cpc.path = "checkpoints/tests/travel-persistence";
    editor.cpc.route = "travel_selftest";
    editor.cpc.revision = 0;
    editor.cpc.rows = [];
    editor.cpc.selected = 0;
    editor.cpc.routeHex = "#aa55ff";
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    check(editor openCJ\checkpointCreation::_save(), "write legacy-compatible draft");
    legacyDraft = openCJ\checkpointCreation::_read(editor.cpc.path + ".b", editor.cpc.route);
    check(isDefined(legacyDraft) && !isDefined(legacyDraft.savedPosition), "draft without travel still readable");
    editor.cpc.savedPosition = spawnStruct();
    editor.cpc.savedPosition.origin = (42825.3828, 4663.33887, -27877.0723);
    editor.cpc.savedPosition.angles = (12.375, 231.125, 0);
    check(editor openCJ\checkpointCreation::_save(), "write manual travel position");
    restoredDraft = openCJ\checkpointCreation::_read(editor.cpc.path + ".a", editor.cpc.route);
    check(isDefined(restoredDraft) && isDefined(restoredDraft.savedPosition),
          "travel is read with complete draft");
    if(isDefined(restoredDraft) && isDefined(restoredDraft.savedPosition))
    {
        check(distanceSquared(restoredDraft.savedPosition.origin, editor.cpc.savedPosition.origin) <
                  0.02,
              "position survives serialization");
        check(distanceSquared(restoredDraft.savedPosition.angles, editor.cpc.savedPosition.angles) <
                  0.0001,
              "view angles survive serialization");
    }
    checkInvalidSnapshot(editor);
    checkTravelCapacity(editor);
    printf("TRAVEL SELFTEST COMPLETE failures=" + level.fixtureFailures + "\n");
}
check(condition, scenario)
{
    if(condition)
    {
        printf("TRAVEL PASS " + scenario + "\n");
    }
    else
    {
        level.fixtureFailures++;
        printf("TRAVEL FAIL " + scenario + "\n");
    }
}

// A syntactically complete snapshot still needs a valid revision for alternating-file recovery.
checkInvalidSnapshot(editor)
{
    editor.cpc.path = "checkpoints/tests/invalid-revision";
    editor.cpc.revision = -2;
    check(editor openCJ\checkpointCreation::_save(), "create synthetic negative-revision snapshot");
    restoredDraft = openCJ\checkpointCreation::_read(editor.cpc.path + ".b", editor.cpc.route);
    check(!isDefined(restoredDraft), "reject a negative snapshot revision");
}

// Filling travel history discards only the oldest session positions, never the manual draft save.
checkTravelCapacity(editor)
{
    editor.cpc.positions = [];
    manualOrigin = editor.cpc.savedPosition.origin;
    for (i = 0; i < 300; i++)
    {
        savedPosition = spawnStruct();
        savedPosition.origin = (i, 0, 0);
        savedPosition.angles = (0, 0, 0);
        editor openCJ\checkpointCreation::rememberPosition(savedPosition);
    }
    check(editor.cpc.positions.size == 256, "travel history remains bounded after 300 saves");
    check(editor.cpc.positions[0].origin[0] == 299 &&
          editor.cpc.positions[255].origin[0] == 44,
          "travel capacity retains the newest positions in order");
    check(editor.cpc.savedPosition.origin == manualOrigin,
          "travel history eviction preserves the manual draft save");
}
