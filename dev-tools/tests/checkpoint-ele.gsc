main()
{
    wait 2;
    level.eleFailures = 0;
    checkElevatorSerialization();
    checkRunModeDetection();
    checkOverlapWarnings();
    printf("ELE SELFTEST COMPLETE failures=" + level.eleFailures + "\n");
}

checkElevatorSerialization()
{
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points[0] = (0, 0, 0);
    checkpoint.points[1] = (100, 0, 0);
    checkpoint.points[2] = (100, 100, 0);
    checkpoint.points[3] = (0, 100, 0);
    check(!checkpoint.allowEle, "default denies exemption");
    for(allowElevator = 0; allowElevator <= 1; allowElevator++)
    {
        for(allowSave = 0; allowSave <= 1; allowSave++)
        {
            for(requireGround = 0; requireGround <= 1; requireGround++)
            {
                checkpoint.allowEle = allowElevator;
                checkpoint.allowSave = allowSave;
                checkpoint.onGround = requireGround;
                text = openCJ\checkpointCreation::_encode(checkpoint);
                restored = openCJ\checkpointCreation::_decode(text);
                check(isDefined(restored) && restored.allowEle == allowElevator &&
                          restored.allowSave == allowSave && restored.onGround == requireGround,
                      "draft properties roundtrip " + allowElevator + allowSave + requireGround);
                check(openCJ\checkpointNetwork::sameCheckpoint(checkpoint, restored),
                      "network equality roundtrip");
            }
        }
    }
    legacyCheckpoint = openCJ\checkpointCreation::_decode("0:0:p0,0,0;100,0,0;100,100,0;0,100,0");
    check(isDefined(legacyCheckpoint) && !legacyCheckpoint.allowEle && legacyCheckpoint.allowSave,
          "old draft keeps defaults");
    checkpoint.allowEle = !legacyCheckpoint.allowEle;
    check(!openCJ\checkpointNetwork::sameCheckpoint(checkpoint, legacyCheckpoint),
          "network compares elevator requirement");
    check(!isDefined(openCJ\checkpointCreation::_decode("0:0:p0,0,0;100,0,0;100,100,0:1:1:2")),
          "malformed elevator flag rejected");
}

checkRunModeDetection()
{
    player = spawnStruct();
    player.sessionState = "playing";
    player.playerRuns_runPaused = false;
    player.playerRuns_runFinished = false;
    player.cheating = false;
    player.hasUsedEle = false;
    player.allowEle = false;
    check(!player openCJ\playerRuns::modeDetectionActive(), "no run is inactive");
    player openCJ\elevate::onElevate();
    check(!player.hasUsedEle, "no-run elevator ignored");
    player.playerRuns_runID = 1;
    player.runInstanceNumber = 1;
    checkpoint = spawnStruct();
    checkpoint.childs = [];
    player.checkpoints_checkpoint = checkpoint;
    nextCheckpoint = spawnStruct();
    nextCheckpoint.isEleAllowed = true;
    checkpoint.childs[0] = nextCheckpoint;
    check(player openCJ\playerRuns::modeDetectionActive(), "active run detected");
    player openCJ\elevate::onElevate();
    check(!player.hasUsedEle, "allowed next checkpoint does not mark ele");
    nextCheckpoint.isEleAllowed = false;
    player.allowEle = true;
    player openCJ\elevate::onElevate();
    check(player.hasUsedEle, "ordinary elevator still marks ele");
    nextCheckpoint.isEleAllowed = true;
    player openCJ\elevate::onElevate();
    check(player.hasUsedEle, "exemption never clears prior ele mode");
    player.hasUsedEle = false;
    player.allowEle = false;
    player.cpc = spawnStruct();
    player openCJ\elevate::onElevate();
    check(!player.hasUsedEle && !player openCJ\playerRuns::modeDetectionActive(),
          "CPC suppresses detection even with stale run ID");
    player.cpc = undefined;
    player.playerRuns_runPaused = true;
    check(!player openCJ\playerRuns::modeDetectionActive(), "paused run inactive");
    player.playerRuns_runPaused = false;
    player.playerRuns_runFinished = true;
    check(!player openCJ\playerRuns::modeDetectionActive(), "finished run inactive");
    player.playerRuns_runFinished = false;
    player.playingDemo = true;
    check(!player openCJ\playerRuns::modeDetectionActive(), "demo inactive");
    player.playingDemo = false;
    player.sessionState = "spectator";
    check(!player openCJ\playerRuns::modeDetectionActive(), "spectator inactive");
    player.sessionState = "playing";
    alternative = spawnStruct();
    alternative.bigBrother = nextCheckpoint;
    checkpoint.childs[1] = alternative;
    check(player openCJ\checkpoints::nextAllowsEle(), "alternative area preserves requirement");
    branch = spawnStruct();
    branch.isEleAllowed = false;
    checkpoint.childs[2] = branch;
    check(!player openCJ\checkpoints::nextAllowsEle(), "ambiguous split does not leak exemption");
}

checkOverlapWarnings()
{
    player = spawnStruct();
    player.cpc = spawnStruct();
    player.cpc.route = "easy";
    player.cpc.rows = [];
    selectedArea = openCJ\checkpointCreation::_empty();
    selectedArea.points[0] = (0, 0, 0);
    selectedArea.points[1] = (100, 0, 0);
    selectedArea.points[2] = (100, 100, 0);
    selectedArea.points[3] = (0, 100, 0);
    player.cpc.rows[0] = openCJ\checkpointCreation::_encode(selectedArea);
    // The editor's append selection is the slot after the confirmed rows.
    player.cpc.selected = player.cpc.rows.size;
    player.cpc.draft = openCJ\checkpointCreation::_empty();
    level.checkpoints_checkpoints = [];
    // Detection stores the current outline before asking for overlap warnings.
    player.cpc.draft.points = selectedArea.points;
    check(isSubStr(player openCJ\checkpointCreation::detectedCheckpointWarning(selectedArea.points),
                   "Checkpoint #1"),
          "detect warns about same-draft checkpoint");
    shifted = [];
    for(i = 0; i < selectedArea.points.size; i++)
    {
        shifted[i] = selectedArea.points[i] + (0, 0, 100);
    }
    player.cpc.draft.points = shifted;
    check(player openCJ\checkpointCreation::detectedCheckpointWarning(shifted) == "",
          "different floor does not warn");
    adjacent = [];
    for(i = 0; i < selectedArea.points.size; i++)
    {
        adjacent[i] = selectedArea.points[i] + (100, 0, 0);
    }
    player.cpc.draft.points = adjacent;
    check(player openCJ\checkpointCreation::detectedCheckpointWarning(adjacent) == "",
          "touching boundary does not warn");
    selectedArea.alternatives[0] = shifted;
    player.cpc.rows[0] = openCJ\checkpointCreation::_encode(selectedArea);
    player.cpc.draft.points = shifted;
    check(isSubStr(player openCJ\checkpointCreation::detectedCheckpointWarning(shifted),
                   "Checkpoint #1"),
          "detect warns about confirmed alternative");
    player.cpc.rows = [];
    player.cpc.selected = 0;
    player.cpc.draft.alternatives[0] = selectedArea.points;
    player.cpc.draft.points = selectedArea.points;
    check(player openCJ\checkpointCreation::detectedCheckpointWarning(selectedArea.points) == "",
          "pending alternatives belong to the same logical checkpoint");
    player.cpc.draft = openCJ\checkpointCreation::_empty();
    published = spawnStruct();
    published.area = selectedArea.points;
    published.id = 42;
    published.routeInfo = spawnStruct();
    published.routeInfo.name = "hard";
    level.checkpoints_checkpoints[0] = published;
    player.cpc.draft.points = selectedArea.points;
    beforeWarning = openCJ\checkpointCreation::_encode(player.cpc.draft);
    check(isSubStr(player openCJ\checkpointCreation::detectedCheckpointWarning(selectedArea.points),
                   "Published checkpoint #42 (hard)"),
          "detect warns about published checkpoint");
    check(player.cpc.rows.size == 0 &&
              openCJ\checkpointCreation::_encode(player.cpc.draft) == beforeWarning,
          "warning does not change draft");
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
