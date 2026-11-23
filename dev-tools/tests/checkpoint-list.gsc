main()
{
    wait 1;
    level.failures = 0;
    check(isDefined(opencjScanDir(getCvar("fs_homepath"))), "directory enumeration available");
    check(openCJ\checkpointList::draftName("69_mp_dark_hard.a", "69_mp_dark_") == "hard",
          "own route filename");
    check(!isDefined(openCJ\checkpointList::draftName("70_mp_dark_hard.a", "69_mp_dark_")),
          "other player private");
    check(!isDefined(openCJ\checkpointList::draftName("69_mp_dark_v2_hard.a", "69_mp_dark_")) ||
              openCJ\checkpointList::draftName("69_mp_dark_v2_hard.a", "69_mp_dark_") == "v2_hard",
          "reader validates ambiguous map prefixes");
    check(!isDefined(
              openCJ\checkpointList::draftName("69_mp_dark_hard.before-reset-2.a", "69_mp_dark_")),
          "backup excluded");
    check(!isDefined(openCJ\checkpointList::draftName("69_mp_dark_network.a", "69_mp_dark_")),
          "network metadata excluded");
    cp = openCJ\checkpointCreation::_empty();
    cp.points[0] = (0, 0, 0);
    cp.points[1] = (100, 0, 0);
    cp.points[2] = (100, 100, 0);
    cp.points[3] = (0, 100, 0);
    cp.finish = true;
    part = spawnStruct();
    part.rows = [];
    part.rows[0] = openCJ\checkpointCreation::_encode(cp);
    part.selected = 1;
    part.draft = openCJ\checkpointCreation::_empty();
    rows = [];
    rows[0] = part.rows[0];
    check(openCJ\checkpointList::matches(part, rows),
          "retained finalized draft matches publication");
    part.draft = cp;
    check(!openCJ\checkpointList::matches(part, rows), "pending selection remains unfinished");
    part.selected = 0;
    check(openCJ\checkpointList::matches(part, rows),
          "selecting unchanged checkpoint does not dirty draft");
    part.draft.allowEle = true;
    check(!openCJ\checkpointList::matches(part, rows), "pending property edit differs");
    part.pending = false;
    check(openCJ\checkpointList::matches(part, rows), "flattened shared route matches");
    part.pending = true;
    check(!openCJ\checkpointList::matches(part, rows), "shared section edit remains unfinished");
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
