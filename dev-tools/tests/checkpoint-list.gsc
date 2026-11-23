main()
{
    wait 1;
    level.failures = 0;
    check(isDefined(opencjScanDir(getCvar("fs_homepath"))), "directory enumeration available");
    // Account IDs in these filenames are synthetic.
    check(openCJ\checkpointList::draftName("101_mp_dark_hard.a", "101_mp_dark_") == "hard",
          "own route filename");
    check(!isDefined(openCJ\checkpointList::draftName("102_mp_dark_hard.a", "101_mp_dark_")),
          "other player private");
    check(openCJ\checkpointList::draftName("101_mp_dark_v2_hard.a", "101_mp_dark_") == "v2_hard",
          "filename parser preserves an underscore in the route name");
    check(!isDefined(openCJ\checkpointList::draftName("101_mp_dark_hard.before-reset-2.a",
                                                      "101_mp_dark_")),
          "backup excluded");
    check(!isDefined(openCJ\checkpointList::draftName("101_mp_dark_network.a", "101_mp_dark_")),
          "network metadata excluded");
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points[0] = (0, 0, 0);
    checkpoint.points[1] = (100, 0, 0);
    checkpoint.points[2] = (100, 100, 0);
    checkpoint.points[3] = (0, 100, 0);
    checkpoint.finish = true;
    draftSection = spawnStruct();
    draftSection.rows = [];
    draftSection.rows[0] = openCJ\checkpointCreation::_encode(checkpoint);
    draftSection.selected = 1;
    draftSection.draft = openCJ\checkpointCreation::_empty();
    rows = [];
    rows[0] = draftSection.rows[0];
    check(openCJ\checkpointList::matches(draftSection, rows),
          "retained finalized draft matches publication");
    draftSection.draft = checkpoint;
    check(!openCJ\checkpointList::matches(draftSection, rows),
          "pending selection remains unfinished");
    draftSection.selected = 0;
    check(openCJ\checkpointList::matches(draftSection, rows),
          "selecting unchanged checkpoint does not dirty draft");
    draftSection.draft.allowEle = true;
    check(!openCJ\checkpointList::matches(draftSection, rows), "pending property edit differs");
    draftSection.pending = false;
    check(openCJ\checkpointList::matches(draftSection, rows), "flattened shared route matches");
    draftSection.pending = true;
    check(!openCJ\checkpointList::matches(draftSection, rows),
          "shared section edit remains unfinished");
    checkRouteListMessages();
    printf("LIST SELFTEST COMPLETE failures=" + level.failures + "\n");
}

check(ok, message)
{
    if(!ok)
    {
        level.failures++;
    }
    printf("LIST SELFTEST " + message + ": " + ok + "\n");
}

// Observe the message boundary in the isolated copy; no real client or database is used.
checkRouteListMessages()
{
    editor = spawnStruct();
    editor.login_playerID = -9999;
    editor.cpc = spawnStruct();
    editor.cpc.route = "fixture_route";
    editor.cpc.rows = [];
    editor.cpc.selected = 0;
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    editor.fixtureMessages = [];
    level.routeEnders = [];
    level.checkpointRoutes = [];
    level.checkpoints_checkpoints = [];
    level.mapid_mapID = undefined;
    level.mySQL = undefined;

    published = openCJ\checkpointList::readPublishedRoutes();
    check(isDefined(published) && published.size == 0, "unregistered map has no published routes");
    editor openCJ\checkpointList::show();
    check(editor.fixtureMessages.size == 2 &&
              isSubStr(editor.fixtureMessages[1], "fixture_route - In progress"),
          "own unsaved route appears with its pending status");
    editor openCJ\checkpointList::show();
    check(editor.fixtureMessages.size == 2, "repeated list request is rate limited");

    level.routeEnders["fixture_route"] = spawnStruct();
    count = editor openCJ\checkpointList::printRouteStatus("fixture_route", undefined, [], []);
    check(count == 2 && isSubStr(editor.fixtureMessages[2], "Completed") &&
              isSubStr(editor.fixtureMessages[3], "Unpublished draft changes"),
          "published route and pending changes are reported separately");

    network = spawnStruct();
    network.paths = [];
    sections = [];
    sections["internal_section"] = true;
    count =
        editor openCJ\checkpointList::printRouteStatus("internal_section", network, sections, []);
    check(count == 0 && editor.fixtureMessages.size == 4,
          "internal network sections do not appear as extra routes");

    level.mapid_mapID = 1;
    check(!isDefined(openCJ\checkpointList::readPublishedRoutes()),
          "unavailable database is distinct from an empty route list");
    editor.cpcListTime = undefined;
    editor openCJ\checkpointList::show();
    check(editor.fixtureMessages.size == 5 &&
              isSubStr(editor.fixtureMessages[4], "Could not read published routes"),
          "query failure is reported instead of an empty successful list");
}

recordRouteMessage(message, isError)
{
    self.fixtureMessages[self.fixtureMessages.size] = message;
}
