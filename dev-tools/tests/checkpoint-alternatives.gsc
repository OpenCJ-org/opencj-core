main()
{
    wait 2;
    level.brushFailures = 0;
    firstArea = area(0, 100);
    secondArea = area(80, 180);
    thirdArea = area(160, 260);
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.points = firstArea;
    checkpoint.alternatives[0] = secondArea;
    checkpoint.alternatives[1] = thirdArea;
    player = spawnStruct();
    player.cpc = spawnStruct();
    player.cpc.rows = [];
    player.cpc.route = "test";
    player.cpc.rows[0] = openCJ\checkpointCreation::_encode(checkpoint);
    player.cpc.selected = 0;
    player.cpc.draft = checkpoint;
    level.checkpoints_checkpoints = [];
    check(player openCJ\checkpointCreation::detectedCheckpointWarning(firstArea) == "",
          "own overlapping alternatives do not warn");
    player.cpc.selected = 1;
    check(player openCJ\checkpointCreation::detectedCheckpointWarning(firstArea) != "",
          "different logical checkpoint still warns");
    decoded = openCJ\checkpointCreation::_decode(player.cpc.rows[0]);
    check(decoded.alternatives.size == 2, "three areas survive serialization");
    first = spawnStruct();
    first.id = 1;
    first.area = firstArea;
    first.onGround = true;
    second = spawnStruct();
    second.id = 2;
    second.area = secondArea;
    second.onGround = true;
    second.bigBrother = first;
    third = spawnStruct();
    third.id = 3;
    third.area = thirdArea;
    third.onGround = true;
    third.bigBrother = first;
    contactAreas = [];
    contactAreas[0] = first;
    contactAreas[1] = second;
    contactAreas[2] = third;
    openCJ\checkpoints::linkContactAreas(contactAreas);
    player.checkpoints_passed = [];
    player.checkpoints_passed[0] = second;
    check(player openCJ\checkpoints::hasPassedCheckpoint(first) &&
              player openCJ\checkpoints::hasPassedCheckpoint(third),
          "all alternatives count as one progress step");
    player.origin = (90, 50, 0);
    check(player openCJ\checkpoints::touchesCheckpointGroup(second, true, undefined),
          "overlapping region belongs to current group");
    player.origin = (240, 50, 0);
    check(player openCJ\checkpoints::touchesCheckpointGroup(second, true, undefined),
          "another alternative protects current checkpoint contact");
    check(!(player openCJ\checkpoints::touchesCheckpointGroup(second, false, undefined)),
          "ground requirement retained");
    player.origin = (300, 50, 0);
    check(!(player openCJ\checkpoints::touchesCheckpointGroup(second, true, undefined)),
          "leaving every alternative clears group contact");
    printf("BRUSH SELFTEST COMPLETE failures=" + level.brushFailures + "\n");
}

area(x1, x2)
{
    player = [];
    player[0] = (x1, 0, 0);
    player[1] = (x2, 0, 0);
    player[2] = (x2, 100, 0);
    player[3] = (x1, 100, 0);
    return player;
}

check(value, name)
{
    if(!value)
    {
        level.brushFailures++;
        printf("BRUSH SELFTEST FAIL " + name + "\n");
    }
    else
    {
        printf("BRUSH SELFTEST PASS " + name + "\n");
    }
}
