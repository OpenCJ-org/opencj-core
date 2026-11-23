main()
{
    wait 2;
    level.eleFailures = 0;
    cp = openCJ\checkpointCreation::_empty();
    cp.points[0] = (0, 0, 0);
    cp.points[1] = (100, 0, 0);
    cp.points[2] = (100, 100, 0);
    cp.points[3] = (0, 100, 0);
    check(!cp.allowEle, "default denies exemption");
    for(ele = 0; ele <= 1; ele++)
    {
        for(save = 0; save <= 1; save++)
        {
            for(ground = 0; ground <= 1; ground++)
            {
                cp.allowEle = ele;
                cp.allowSave = save;
                cp.onGround = ground;
                text = openCJ\checkpointCreation::_encode(cp);
                restored = openCJ\checkpointCreation::_decode(text);
                check(isDefined(restored) && restored.allowEle == ele &&
                          restored.allowSave == save && restored.onGround == ground,
                      "draft properties roundtrip " + ele + save + ground);
                check(openCJ\checkpointNetwork::sameCheckpoint(cp, restored),
                      "network equality roundtrip");
            }
        }
    }
    old = openCJ\checkpointCreation::_decode("0:0:p0,0,0;100,0,0;100,100,0;0,100,0");
    check(isDefined(old) && !old.allowEle && old.allowSave, "old draft keeps defaults");
    cp.allowEle = !old.allowEle;
    check(!openCJ\checkpointNetwork::sameCheckpoint(cp, old),
          "network compares elevator requirement");
    check(!isDefined(openCJ\checkpointCreation::_decode("0:0:p0,0,0;100,0,0;100,100,0:1:1:2")),
          "malformed elevator flag rejected");
    p = spawnStruct();
    p.sessionState = "playing";
    p.playerRuns_runPaused = false;
    p.playerRuns_runFinished = false;
    p.cheating = false;
    p.hasUsedEle = false;
    p.allowEle = false;
    check(!p openCJ\playerRuns::modeDetectionActive(), "no run is inactive");
    p openCJ\elevate::onElevate();
    check(!p.hasUsedEle, "no-run elevator ignored");
    p.playerRuns_runID = 1;
    p.runInstanceNumber = 1;
    cp = spawnStruct();
    cp.childs = [];
    p.checkpoints_checkpoint = cp;
    next = spawnStruct();
    next.isEleAllowed = true;
    cp.childs[0] = next;
    check(p openCJ\playerRuns::modeDetectionActive(), "active run detected");
    p openCJ\elevate::onElevate();
    check(!p.hasUsedEle, "allowed next checkpoint does not mark ele");
    next.isEleAllowed = false;
    p.allowEle = true;
    p openCJ\elevate::onElevate();
    check(p.hasUsedEle, "ordinary elevator still marks ele");
    next.isEleAllowed = true;
    p openCJ\elevate::onElevate();
    check(p.hasUsedEle, "exemption never clears prior ele mode");
    p.hasUsedEle = false;
    p.allowEle = false;
    p.cpc = spawnStruct();
    p openCJ\elevate::onElevate();
    check(!p.hasUsedEle && !p openCJ\playerRuns::modeDetectionActive(),
          "CPC suppresses detection even with stale run ID");
    p.cpc = undefined;
    p.playerRuns_runPaused = true;
    check(!p openCJ\playerRuns::modeDetectionActive(), "paused run inactive");
    p.playerRuns_runPaused = false;
    p.playerRuns_runFinished = true;
    check(!p openCJ\playerRuns::modeDetectionActive(), "finished run inactive");
    p.playerRuns_runFinished = false;
    p.playingDemo = true;
    check(!p openCJ\playerRuns::modeDetectionActive(), "demo inactive");
    p.playingDemo = false;
    p.sessionState = "spectator";
    check(!p openCJ\playerRuns::modeDetectionActive(), "spectator inactive");
    p.sessionState = "playing";
    alt = spawnStruct();
    alt.bigBrother = next;
    cp.childs[1] = alt;
    check(p openCJ\checkpoints::nextAllowsEle(), "alternative area preserves requirement");
    branch = spawnStruct();
    branch.isEleAllowed = false;
    cp.childs[2] = branch;
    check(!p openCJ\checkpoints::nextAllowsEle(), "ambiguous split does not leak exemption");
    p.cpc = spawnStruct();
    p.cpc.route = "easy";
    p.cpc.rows = [];
    a = openCJ\checkpointCreation::_empty();
    a.points[0] = (0, 0, 0);
    a.points[1] = (100, 0, 0);
    a.points[2] = (100, 100, 0);
    a.points[3] = (0, 100, 0);
    p.cpc.rows[0] = openCJ\checkpointCreation::_encode(a);
    // The editor's append selection is the slot after the confirmed rows.
    p.cpc.selected = p.cpc.rows.size;
    p.cpc.draft = openCJ\checkpointCreation::_empty();
    level.checkpoints_checkpoints = [];
    // Detection stores the current outline before asking for overlap warnings.
    p.cpc.draft.points = a.points;
    check(
        isSubStr(p openCJ\checkpointCreation::detectedCheckpointWarning(a.points), "Checkpoint #1"),
        "detect warns about same-draft checkpoint");
    shifted = [];
    for(i = 0; i < a.points.size; i++)
    {
        shifted[i] = a.points[i] + (0, 0, 100);
    }
    p.cpc.draft.points = shifted;
    check(p openCJ\checkpointCreation::detectedCheckpointWarning(shifted) == "",
          "different floor does not warn");
    adjacent = [];
    for(i = 0; i < a.points.size; i++)
    {
        adjacent[i] = a.points[i] + (100, 0, 0);
    }
    p.cpc.draft.points = adjacent;
    check(p openCJ\checkpointCreation::detectedCheckpointWarning(adjacent) == "",
          "touching boundary does not warn");
    a.alternatives[0] = shifted;
    p.cpc.rows[0] = openCJ\checkpointCreation::_encode(a);
    p.cpc.draft.points = shifted;
    check(
        isSubStr(p openCJ\checkpointCreation::detectedCheckpointWarning(shifted), "Checkpoint #1"),
        "detect warns about confirmed alternative");
    p.cpc.rows = [];
    p.cpc.selected = 0;
    p.cpc.draft.alternatives[0] = a.points;
    p.cpc.draft.points = a.points;
    check(p openCJ\checkpointCreation::detectedCheckpointWarning(a.points) == "",
          "pending alternatives belong to the same logical checkpoint");
    p.cpc.draft = openCJ\checkpointCreation::_empty();
    published = spawnStruct();
    published.area = a.points;
    published.id = 42;
    published.routeInfo = spawnStruct();
    published.routeInfo.name = "hard";
    level.checkpoints_checkpoints[0] = published;
    p.cpc.draft.points = a.points;
    beforeWarning = openCJ\checkpointCreation::_encode(p.cpc.draft);
    check(isSubStr(p openCJ\checkpointCreation::detectedCheckpointWarning(a.points),
                   "Published checkpoint #42 (hard)"),
          "detect warns about published checkpoint");
    check(p.cpc.rows.size == 0 && openCJ\checkpointCreation::_encode(p.cpc.draft) == beforeWarning,
          "warning does not change draft");
    printf("ELE SELFTEST COMPLETE failures=" + level.eleFailures + "\n");
}
check(value, name)
{
    if(!value)
    {
        level.eleFailures++;
        printf("ELE SELFTEST FAIL " + name + "\n");
    }
    else
    {
        printf("ELE SELFTEST PASS " + name + "\n");
    }
}
