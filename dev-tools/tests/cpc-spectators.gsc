#include openCJ\util;

// Spectators following a checkpoint editor: they receive its world shapes and
// property panel with developer on, and lose both when they stop following.
// The editor state is synthetic; client cvars and commands are recorded.
main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.cpcViewerChecks = 0;
    level.cpcViewerFailures = 0;
    wait 1;
    editor = addTestClient();
    viewer = addTestClient();
    wait .2;
    check(isDefined(editor) && isDefined(viewer), "two test clients available");
    if(isDefined(editor) && isDefined(viewer))
    {
        prepare(editor, viewer);
        checkFollowingStartsView(editor, viewer);
        checkShapesReachFollowers(editor, viewer);
        checkStoppingClearsView(editor, viewer);
        checkSuspendedEditorKeepsDeveloper(editor, viewer);
        checkEditorStopResetsFollowers(editor, viewer);
    }
    printf("CPC SPECTATORS COMPLETE failures=" + level.cpcViewerFailures +
           " checks=" + level.cpcViewerChecks + "\n");
}

prepare(editor, viewer)
{
    editor.sessionTeam = "allies";
    editor.sessionState = "playing";
    editor spawn((0, 0, 700), (0, 0, 0));
    editor freezeControls(true);
    editor.cpc = spawnStruct();
    editor.cpc.viewers = [];
    editor.cpc.drawCommands = 0;
    editor.cpc.propertiesText = "Ground contact: yes";
    editor.cpc.panelHeight = 3;
    editor.fixtureCvars = [];
    editor.fixtureCommands = [];
    viewer.fixtureCvars = [];
    viewer.fixtureCommands = [];
    // Real spectators have spawned once, which puts them in the player entity list.
    viewer spawn((64, 0, 700), (0, 0, 0));
    viewer.sessionTeam = "spectator";
    viewer.sessionState = "spectator";
    viewer.spectatorClient = editor getEntityNumber();
    wait .1;
}

checkFollowingStartsView(editor, viewer)
{
    editor.cpc.viewers = editor openCJ\checkpointCreation::_syncEditorViewers();
    check(editor.cpc.viewers.size == 1 && editor.cpc.viewers[0] == viewer,
          "the editor finds its follower");
    check(isDefined(viewer.cpcViewedEditor) && viewer.cpcViewedEditor == editor,
          "the follower is marked as watching the editor");
    check(viewer.fixtureCvars["developer"] == "1", "the follower gets developer on");
    check(viewer.fixtureCvars["opencj_cpc_properties"] == "Ground contact: yes",
          "the follower sees the current property panel");
}

checkShapesReachFollowers(editor, viewer)
{
    editor openCJ\checkpointCreation::_drawCommand("M l fixture");
    check(editor.fixtureCommands.size == 1 && viewer.fixtureCommands.size == 1 &&
          viewer.fixtureCommands[0] == "M l fixture", "a shape goes to the editor and the follower");
    editor openCJ\checkpointCreation::_setPanelCvar("opencj_cpc_properties", "Height: 64");
    check(viewer.fixtureCvars["opencj_cpc_properties"] == "Height: 64",
          "property panel changes reach the follower");
}

checkStoppingClearsView(editor, viewer)
{
    viewer openCJ\checkpointCreation::onSpectatorClientChanged(undefined);
    check(!isDefined(viewer.cpcViewedEditor), "free spectating ends the view");
    check(viewer.fixtureCvars["developer"] == "0", "developer is switched off again");
    check(viewer.fixtureCvars["opencj_cpc_properties"] == "", "the property panel is cleared");
    viewer.fixtureCommands = [];
    editor openCJ\checkpointCreation::_drawCommand("M l after");
    check(viewer.fixtureCommands.size == 0, "a former follower receives no more shapes");
}

checkSuspendedEditorKeepsDeveloper(editor, viewer)
{
    viewer.cpc = spawnStruct(); // The follower is itself an editor, suspended while spectating.
    viewer openCJ\checkpointCreation::_startViewingEditor(editor);
    viewer.fixtureCvars["developer"] = "unchanged";
    viewer openCJ\checkpointCreation::stopViewingEditor();
    check(viewer.fixtureCvars["developer"] == "unchanged",
          "a suspended editor keeps developer on for its own editor");
    viewer.cpc = undefined;
}

checkEditorStopResetsFollowers(editor, viewer)
{
    viewer openCJ\checkpointCreation::_startViewingEditor(editor);
    editor openCJ\checkpointCreation::_stopEditorViewers();
    check(!isDefined(viewer.cpcViewedEditor) && viewer.fixtureCvars["developer"] == "0",
          "closing, suspending or leaving the editor resets its followers");
}

// Replaces setClientCvar in the isolated copy of checkpointcreation.gsc.
recordClientCvar(name, value)
{
    self.fixtureCvars[name] = "" + value;
}

// Replaces SV_GameSendServerCommand in the isolated copy of checkpointcreation.gsc.
recordServerCommand(command, reliable)
{
    self.fixtureCommands[self.fixtureCommands.size] = command;
}

check(condition, description)
{
    level.cpcViewerChecks++;
    if(!condition)
    {
        level.cpcViewerFailures++;
        printf("CPC SPECTATORS FAILURE: " + description + "\n");
    }
}

