// Exercise section files and network publication using only the runner's owned resources.
main()
{
    level.networkChecks = 0;
    level.networkFailures = 0;
    openCJ\mySQL::onInit();
    level.mapid_mapID = 1;
    wait 1;
    editor = addTestClient();
    wait .2;
    editor.login_playerID = 1;
    editor.cpc = sectionDraft("net_opening", 1000, false);
    network = createNetwork(editor);
    if (isDefined(network))
    {
        checkNetworkPublication(editor, network);
        checkSnapshotFallback(editor, network);
        checkLostNetworkCommitReply(editor);
        checkSharedOpeningColor(editor);
        checkDamagedSectionPreservation(editor);
        checkMissingOpening(editor, network);
        checkEditingCommands(editor);
    }
    printf("NETWORK SELFTEST COMPLETE failures=" + level.networkFailures +
           " checks=" + level.networkChecks + "\n");
}

sectionDraft(routeName, offsetX, withFinish)
{
    draft = spawnStruct();
    draft.route = routeName;
    draft.routeHex = "#123456";
    draft.revision = 0;
    draft.rows = [];
    draft.rows[0] = row(offsetX, false);
    draft.rows[1] = row(offsetX + 200, withFinish);
    draft.selected = draft.rows.size;
    draft.draft = openCJ\checkpointCreation::_empty();
    return draft;
}

row(offsetX, finish)
{
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points = [];
    checkpoint.points[0] = (offsetX, 0, 0);
    checkpoint.points[1] = (offsetX + 100, 0, 0);
    checkpoint.points[2] = (offsetX + 100, 100, 0);
    checkpoint.points[3] = (offsetX, 100, 0);
    checkpoint.finish = finish;
    return openCJ\checkpointCreation::_encode(checkpoint);
}

createNetwork(editor)
{
    if (!check(editor openCJ\checkpointNetwork::writeSection("net_opening", editor.cpc),
               "save shared opening draft"))
    {
        return undefined;
    }
    check(editor openCJ\checkpointNetwork::writeSection("net_a", sectionDraft("net_a", 1600, true)),
          "save first branch draft");
    check(editor openCJ\checkpointNetwork::writeSection("net_b", sectionDraft("net_b", 2000, true)),
          "save second branch draft");
    network = spawnStruct();
    network.root = "net_opening";
    network.revision = 0;
    network.paths = [];
    routeNames = [];
    routeNames[0] = "net_a";
    routeNames[1] = "net_b";
    for (i = 0; i < routeNames.size; i++)
    {
        routePath = spawnStruct();
        routePath.hex = "#123456";
        routePath.sections = [];
        routePath.sections[0] = network.root;
        routePath.sections[1] = routeNames[i];
        network.paths[routeNames[i]] = routePath;
    }
    if (!check(editor openCJ\checkpointNetwork::save(network), "save two-route network manifest"))
    {
        return undefined;
    }
    loaded = editor openCJ\checkpointNetwork::load();
    check(isDefined(loaded) && loaded.revision == 1, "read persisted network revision");
    check(openCJ\checkpointNetwork::members(loaded, "net_opening").size == 2,
          "both routes own the shared opening");
    editor openEditor("net_a");
    editor.cpc.network = loaded;
    return loaded;
}

checkNetworkPublication(editor, network)
{
    check(editor openCJ\checkpointPublish::publish(), "network publishes all route continuations");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 6, "network shares opening without duplicate areas");
    checkScalar("SELECT COUNT(*) FROM checkpointSectionColors", 3, "network stores each section color");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE sectionName='net_a'", 2,
                "first branch areas retain their section name");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE sectionName='net_b'", 2,
                "second branch areas retain their section name");
    check(editor openCJ\checkpointPublish::publish(), "unchanged network publication succeeds");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 6, "repeated network publication preserves IDs");
    selected = editor.cpc;
    pending = editor openCJ\checkpointNetwork::readSection("net_b");
    pending.draft = openCJ\checkpointCreation::_decode(row(2400, false));
    check(editor openCJ\checkpointNetwork::writeSection("net_b", pending), "save pending branch edit");
    check(!editor openCJ\checkpointPublish::publish(), "network rejects another section's pending edit");
    check(editor.cpc == selected, "rejected network publication restores active draft ownership");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 6, "pending edit leaves published network intact");
    pending.draft = openCJ\checkpointCreation::_empty();
    check(editor openCJ\checkpointNetwork::writeSection("net_b", pending), "discard synthetic pending edit");
}

checkSnapshotFallback(editor, network)
{
    check(editor openCJ\checkpointNetwork::save(network), "save second network revision");
    path = editor openCJ\checkpointNetwork::basePath() + "network.a";
    check(writeText(path, "CPN1 truncated"), "truncate only the fixture's newest manifest");
    recovered = editor openCJ\checkpointNetwork::load();
    check(isDefined(recovered) && recovered.revision == 1,
          "invalid newest manifest falls back to the previous complete revision");
    check(editor openCJ\checkpointNetwork::save(recovered), "recover the alternate manifest slot");
}

checkDamagedSectionPreservation(editor)
{
    path = editor openCJ\checkpointNetwork::basePath() + "damaged_section.b";
    check(writeText(path, "damaged fixture draft"), "prepare damaged section snapshot");
    check(!editor openCJ\checkpointNetwork::newSection("damaged_section", "#123456"),
          "new section refuses an occupied unreadable snapshot");
    file = FS_FOpen(path, "read");
    firstLine = FS_ReadLine(file);
    FS_FClose(file);
    check(firstLine == "damaged fixture draft", "new section preserves damaged recovery bytes");
}

checkMissingOpening(editor, network)
{
    path = editor openCJ\checkpointNetwork::basePath() + network.root;
    if (FS_TestFile(path + ".a"))
    {
        FS_Remove(path + ".a");
    }
    if (FS_TestFile(path + ".b"))
    {
        FS_Remove(path + ".b");
    }
    check(!editor openCJ\checkpointPublish::publish(), "missing opening rejects network publication");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 6, "missing draft leaves published geometry intact");
}

writeText(path, text)
{
    file = FS_FOpen(path, "write");
    if (!file)
    {
        return false;
    }
    written = FS_WriteLine(file, text);
    FS_FClose(file);
    return written;
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
    level.networkChecks++;
    if (!condition)
    {
        level.networkFailures++;
    }
    printf("NETWORK CHECK " + condition + ": " + label + "\n");
    return condition;
}

checkLostNetworkCommitReply(editor)
{
    network = editor openCJ\checkpointNetwork::load();
    network.paths["net_a"].hex = "#654321";
    check(editor openCJ\checkpointNetwork::save(network), "save changed route color before lost reply");
    level.hideNetworkCommitReply = true;
    check(!editor openCJ\checkpointPublish::publish(), "network does not claim success without commit reply");
    check(isSubStr(editor.cpc.status, "confirm"), "network reports uncertain commit outcome");
    checkScalar("SELECT colorRGB FROM routes WHERE routeName='net_a'", 6636321,
                "network commit may succeed even when its reply is missing");
    check(editor openCJ\checkpointPublish::publish(), "network retry reconciles committed route metadata");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas", 6, "network retry does not duplicate areas");
}

publicationQuery(query)
{
    result = openCJ\mySQL::mysqlSyncQuery(query);
    if(query == "COMMIT" && isDefined(level.hideNetworkCommitReply) && level.hideNetworkCommitReply)
    {
        level.hideNetworkCommitReply = false;
        return undefined;
    }
    return result;
}

checkSharedOpeningColor(editor)
{
    opening = editor openCJ\checkpointNetwork::readSection("net_opening");
    opening.routeHex = "#abcdef";
    check(editor openCJ\checkpointNetwork::writeSection("net_opening", opening),
          "save a new shared opening color");
    check(editor openCJ\checkpointPublish::publish(), "shared color-only edit publishes");
    checkScalar("SELECT colorRGB FROM routes WHERE routeName='net_opening'", 11259375,
                "shared opening runtime color follows the draft");
    checkScalar("SELECT colorRGB FROM checkpointSectionColors WHERE sectionName='net_opening'",
                11259375, "shared section metadata uses the same color");
}

// Drive actual split/merge/rename commands. Only HUD reopening and graph refresh are observed.
checkEditingCommands(editor)
{
    arguments = prepareSplitApproaches(editor);
    if (!isDefined(arguments))
    {
        return;
    }
    if (!checkMergeAndSplit(editor, arguments))
    {
        return;
    }
    if (!checkRejoin(editor, arguments))
    {
        return;
    }
    checkRouteRename(editor);
}

prepareSplitApproaches(editor)
{
    editor.login_playerID = 2;
    editor.cpc = sectionDraft("edit_opening", 1000, false);
    check(editor openCJ\checkpointNetwork::writeSection("edit_opening", editor.cpc),
          "save editable opening");
    arguments = [];
    arguments[0] = "split";
    arguments[1] = "edit_easy";
    arguments[2] = "edit_hard";
    if (!check(editor openCJ\checkpointNetwork::split(arguments), "split creates two route approaches"))
    {
        return undefined;
    }
    network = editor openCJ\checkpointNetwork::load();
    check(editor.cpc.route == "edit_easy" && network.paths.size == 2,
          "split opens the first route and persists both paths");
    check(editor openCJ\checkpointNetwork::writeSection("edit_easy", sectionDraft("edit_easy", 3000, false)),
          "save first separate approach");
    check(editor openCJ\checkpointNetwork::writeSection("edit_hard", sectionDraft("edit_hard", 4000, false)),
          "save second separate approach");
    editor openEditor("edit_easy");
    editor.cpc.draft = openCJ\checkpointCreation::_decode(row(5000, false));
    return arguments;
}

checkMergeAndSplit(editor, arguments)
{
    arguments[0] = "merge";
    if (!check(editor openCJ\checkpointNetwork::merge(arguments), "merge creates one shared continuation"))
    {
        return false;
    }
    sharedName = editor.cpc.route;
    check(editor.cpc.rows.size == 0 && editor.cpc.draft.points.size == 4,
          "merge retains the detected landing as a pending shared checkpoint");
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(editor.cpc.draft);
    editor.cpc.rows[1] = row(5200, false);
    editor.cpc.rows[2] = row(5400, true);
    editor.cpc.selected = 0;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    check(editor openCJ\checkpointNetwork::writeSection(sharedName, editor.cpc),
          "save shared continuation with finish");
    arguments[0] = "split";
    if (!check(editor openCJ\checkpointNetwork::split(arguments), "split selected shared landing preserves continuation"))
    {
        return false;
    }
    network = editor openCJ\checkpointNetwork::load();
    retainedSections = network.paths["edit_easy"].sections;
    retainedTail = editor openCJ\checkpointNetwork::readSection(retainedSections[retainedSections.size - 1]);
    check(retainedTail.rows.size == 2 &&
          openCJ\checkpointCreation::_decode(retainedTail.rows[1]).finish,
          "first route retains its original finish");
    check(editor.cpc.rows.size == 0, "second route starts a new approach after the shared landing");
    editor.cpc.rows[0] = row(5100, false);
    editor.cpc.selected = 1;
    editor.cpc.draft = openCJ\checkpointCreation::_decode(row(5200, false));
    check(editor openCJ\checkpointNetwork::writeSection(editor.cpc.route, editor.cpc),
          "save an incoming approach to the existing continuation");
    return true;
}

checkRejoin(editor, arguments)
{
    arguments[0] = "merge";
    if (!check(editor openCJ\checkpointNetwork::merge(arguments), "merge rejoins the existing continuation"))
    {
        return false;
    }
    check(editor.cpc.rows.size == 2 && editor.cpc.selected == 0 &&
          openCJ\checkpointCreation::_decode(editor.cpc.rows[1]).finish,
          "rejoin preserves existing checkpoints and finish");
    check(isDefined(editor.cpc.restoreOrigin), "rejoin queues editor travel to the joining landing");
    check(editor openCJ\checkpointPublish::publish(), "edited network publishes its split and merged routes");
    return true;
}

checkRouteRename(editor)
{
    routeRows = openCJ\mySQL::mysqlSyncQuery("SELECT routeID FROM routes WHERE routeName='edit_hard'");
    if (!check(isDefined(routeRows) && routeRows.size == 1, "published route has a stable identity"))
    {
        return;
    }
    routeId = int(routeRows[0][0]);
    check(editor openCJ\checkpointNetwork::rename("edit_hard", "edit_steep"),
          "rename updates network files and database together");
    network = editor openCJ\checkpointNetwork::load();
    check(isDefined(network.paths["edit_steep"]) && !isDefined(network.paths["edit_hard"]),
          "renamed route is the active manifest entry");
    checkScalar("SELECT routeID FROM routes WHERE routeName='edit_steep'", routeId,
                "rename preserves route identity");
    checkScalar("SELECT COUNT(*) FROM checkpointAreas WHERE draftName='edit_steep'", 6,
                "rename preserves the route's checkpoint areas");
    oldPath = editor openCJ\checkpointNetwork::basePath() + "edit_hard";
    check(!FS_TestFile(oldPath + ".a") && !FS_TestFile(oldPath + ".b") &&
          (FS_TestFile(oldPath + ".renamed.a") || FS_TestFile(oldPath + ".renamed.b")),
          "rename retains an explicit recovery snapshot outside active draft names");
}

closeEditor()
{
    self.cpc = undefined;
}

openEditor(routeName)
{
    sectionName = self openCJ\checkpointNetwork::resolve(routeName);
    self.cpc = self openCJ\checkpointNetwork::readSection(sectionName);
    // _read returns serialized content; _start normally supplies this editor identity.
    self.cpc.route = sectionName;
    self.cpc.path = self openCJ\checkpointNetwork::basePath() + sectionName;
    self.cpc.network = self openCJ\checkpointNetwork::load();
    self.cpc.testing = false;
}

recordActivation()
{
    level.networkActivationObserved = true;
}
