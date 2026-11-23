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
        checkDamagedSectionPreservation(editor);
        checkMissingOpening(editor, network);
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
    editor.cpc = editor openCJ\checkpointNetwork::readSection("net_a");
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
