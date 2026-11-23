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
