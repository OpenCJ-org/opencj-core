main()
{
    level.fixtureFailures = 0;
    precacheShader("white");
    wait 2;
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points = [];
    checkpoint.points[0] = (0, 0, 0);
    checkpoint.points[1] = (100, 0, 0);
    checkpoint.points[2] = (100, 100, 0);
    checkpoint.points[3] = (0, 100, 0);
    groundedEncoding = openCJ\checkpointCreation::_encode(checkpoint);
    restoredCheckpoint = openCJ\checkpointCreation::_decode(groundedEncoding);
    check(restoredCheckpoint.onGround, "existing drafts default to grounded");
    check(!openCJ\checkpointCreation::contains(restoredCheckpoint, (50, 50, 1), false),
          "grounded area rejects airborne player");
    checkpoint.onGround = false;
    encoded = openCJ\checkpointCreation::_encode(checkpoint);
    restoredCheckpoint = openCJ\checkpointCreation::_decode(encoded);
    check(!restoredCheckpoint.onGround, "airborne property survives draft serialization");
    check(openCJ\checkpointCreation::contains(restoredCheckpoint, (50, 50, 1), false),
          "airborne area skips ground requirement");
    check(!openCJ\checkpointCreation::contains(restoredCheckpoint, (150, 50, 1), false),
          "airborne area still rejects outside geometry");
    check(!isDefined(openCJ\checkpointCreation::_decode(groundedEncoding + ":invalid")),
          "invalid ground flag rejected");
    restoredCheckpoint.onGround = true;
    check(openCJ\checkpointCreation::_encode(restoredCheckpoint) == groundedEncoding,
          "grounded encoding stays backward compatible");
    panelHud = newHudElem();
    openCJ\checkpointCreation::configureHud(panelHud);
    check(panelHud.x == 124 && panelHud.y == 6 && panelHud.archived,
          "panel is right of minimap in archived HUD pool");
    panelHud.color = (0, 0, 0);
    panelHud.alpha = 0.65;
    panelHud.sort = -1;
    panelHud setShader("white", 320, 104);
    panelHud destroy();
    checkPanelStates(checkpoint);
    printf("PANEL SELFTEST COMPLETE failures=" + level.fixtureFailures + "\n");
}
check(condition, panelText)
{
    if(condition)
    {
        printf("PANEL PASS " + panelText + "\n");
    }
    else
    {
        level.fixtureFailures++;
        printf("PANEL FAIL " + panelText + "\n");
    }
}

// Exercise the production text choices without requiring a live player's HUD.
checkPanelStates(checkpoint)
{
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.cpc.route = "panel_test";
    editor.cpc.routeHex = "#00ff00";
    editor.cpc.routeColor = (0, 1, 0);
    editor.cpc.rows = [];
    editor.cpc.selected = 0;
    editor.cpc.testing = false;
    editor.cpc.draft = openCJ\checkpointCreation::_empty();

    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(panelText == "^2Detect:^7 Num 0",
          "empty route offers detection without deletion or publication");

    editor.cpc.draft = checkpoint;
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(isSubStr(panelText, "Confirm:") && !isSubStr(panelText, "Apply changes:"),
          "new landing offers confirmation");

    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(checkpoint);
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(isSubStr(panelText, "Apply changes:") && isSubStr(panelText, "!cp replace"),
          "existing landing offers apply and replacement");

    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(isSubStr(panelText, "Detect replacement:") && isSubStr(panelText, "Undo:"),
          "empty replacement retains undo guidance");

    checkpoint.finish = true;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(checkpoint);
    editor.cpc.selected = 1;
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(preview.showRouteSummary && preview.checkpoint.finish && preview.checkpointNumber == 1,
          "empty slot after finish previews the completed route");
    check(isSubStr(panelText, "!cp finalize"), "completed route offers publication");

    editor.cpc.insertAfter = -1;
    editor.cpc.draft = checkpoint;
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(!preview.showRouteSummary && isSubStr(panelText, "Before checkpoint 1") &&
              isSubStr(panelText, "Confirm insert:"),
          "pending insertion shows its location and confirmation");

    editor.cpc.insertAfter = undefined;
    editor.cpc.heightTarget = "upper";
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(isSubStr(panelText, "Raise top:") && isSubStr(panelText, "Lower top:"),
          "height mode replaces ordinary action hints");
    checkpoint.heightAbove = 16;
    panelText = editor openCJ\checkpointCreation::propertyPanelText(checkpoint);
    check(isSubStr(panelText, "Extra height: +16") && isSubStr(panelText, "Bottom: fixed"),
          "height properties describe the fixed base and raised top");

    editor.cpc.heightTarget = undefined;
    editor.cpc.testing = true;
    editor.cpc.testNext = 0;
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(isSubStr(panelText, "Follow the outline") && isSubStr(panelText, "Exit test: !cp test"),
          "testing explains how to return to editing");

    editor.cpc.testing = false;
    editor.cpc.selected = 0;
    editor.cpc.network = spawnStruct();
    editor.cpc.network.paths = [];
    routeNames = strTok("easy hard", " ");
    for (i = 0; i < routeNames.size; i++)
    {
        routeName = routeNames[i];
        route = spawnStruct();
        route.sections = [];
        route.sections[0] = editor.cpc.route;
        editor.cpc.network.paths[routeName] = route;
    }
    preview = editor openCJ\checkpointCreation::previewSelection();
    panelText = editor openCJ\checkpointCreation::actionPanelText(preview);
    check(preview.followingShared && isSubStr(panelText, "Follow shared landings") &&
              isSubStr(panelText, "!cp split"),
          "shared selection explains continuation and splitting");
}
