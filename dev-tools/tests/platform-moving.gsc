// Isolated engine fixture; no database, player drafts or live map state.
main()
{
    wait 2;
    level.brushFailures = 0;
    platform = getEnt("yellow", "targetname");
    check(isDefined(platform), "mp_qube real moving platform exists");
    if (!isDefined(platform))
    {
        return;
    }
    key = openCJ\checkpointMoving::reference(platform);
    check(isDefined(key), "stable brush reference created");
    if (!isDefined(key))
    {
        return;
    }
    check(openCJ\checkpointMoving::resolve(key) == platform, "reference resolves exact platform");
    checkpoint = openCJ\checkpointCreation::_empty();
    checkpoint.platformRef = key;
    checkpoint.points = openCJ\checkpointMoving::points(checkpoint);
    check(checkpoint.points.size == 4, "whole platform visual bounds");
    check(openCJ\checkpointMoving::valid(checkpoint) == "", "moving checkpoint validates");
    checkpoint.allowEle = true;
    checkpoint.allowSave = false;
    checkpoint.finish = true;
    encoded = openCJ\checkpointCreation::_encode(checkpoint);
    decoded = openCJ\checkpointCreation::_decode(encoded);
    check(isDefined(decoded) && decoded.platformRef == key && decoded.allowEle &&
              !decoded.allowSave && decoded.finish,
          "draft roundtrip preserves reference and requirements");
    player = spawnStruct();
    check(player openCJ\checkpointMoving::touches(checkpoint, true, platform),
          "ground entity contact accepted");
    check(!(player openCJ\checkpointMoving::touches(checkpoint, false, platform)),
          "airborne contact rejected");
    check(!(player openCJ\checkpointMoving::touches(checkpoint, true, undefined)),
          "world contact rejected");
    other = getEnt("yellow1", "targetname");
    check(!(player openCJ\checkpointMoving::touches(checkpoint, true, other)),
          "other moving platform rejected");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1000),
          "initial contact does not pass");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1050),
          "short bunnyhop does not pass");
    check(!player openCJ\checkpoints::contactReady(checkpoint, false, 1100),
          "airborne clears dwell");
    check(!player openCJ\checkpoints::contactReady(checkpoint, true, 1150),
          "new landing restarts dwell");
    player openCJ\checkpoints::contactReady(checkpoint, true, 1200);
    player openCJ\checkpoints::contactReady(checkpoint, true, 1250);
    check(player openCJ\checkpoints::contactReady(checkpoint, true, 1300),
          "settled landing passes");
    stationary = openCJ\checkpointCreation::_empty();
    stationary.points = checkpoint.points;
    check(!openCJ\checkpointNetwork::areaOverlap(checkpoint, stationary, stationary.points),
          "moving over stationary floor is not shared geometry");
    check(openCJ\checkpointNetwork::areaOverlap(checkpoint, decoded, decoded.points),
          "same moving platform is shared geometry");
    centerBeforeMove = openCJ\checkpointMoving::center(checkpoint);
    initialOrigin = platform.origin;
    initialAngles = platform.angles;
    platform moveTo(initialOrigin + (100, 50, 25), 0.2);
    platform waittill("movedone");
    centerAfterMove = openCJ\checkpointMoving::center(checkpoint);
    check(distance(centerAfterMove, centerBeforeMove + (100, 50, 25)) < 0.1,
          "indicator follows actual translation");
    platform rotateTo(initialAngles + (0, 90, 0), 0.2);
    platform waittill("rotatedone");
    rotatedCorners = openCJ\checkpointMoving::points(checkpoint);
    check(distance(rotatedCorners[0], rotatedCorners[1]) > 0 &&
              abs(distance(rotatedCorners[0], rotatedCorners[1]) -
                  distance(checkpoint.points[0], checkpoint.points[1])) < 0.1,
          "rotation preserves bounds dimensions");
    check(openCJ\checkpointMoving::resolve(key) == platform, "identity unchanged by movement");
    level.checkpointMovingCache = undefined;
    check(openCJ\checkpointMoving::resolve(key) == platform,
          "saved key resolves without cached entity slot");
    check(openCJ\checkpointCreation::_encode(decoded) == encoded,
          "movement does not rewrite persisted geometry");
    missing = openCJ\checkpointCreation::_empty();
    missing.platformRef = "b999999";
    missing.points = checkpoint.points;
    check(openCJ\checkpointMoving::valid(missing) != "", "missing entity fails validation");
    check(!(player openCJ\checkpointMoving::touches(missing, true, platform)),
          "missing entity never awards checkpoint");
    incompleteCheckpoint = openCJ\checkpointCreation::_empty();
    incompleteCheckpoint.platformRef = key;
    incompleteCheckpoint.finish = true;
    incompleteRows = [];
    incompleteRows[0] = openCJ\checkpointCreation::_encode(incompleteCheckpoint);
    check(isDefined(openCJ\checkpointCreation::_decode(incompleteRows[0])),
          "unfinished moving draft still decodes for editing");
    check(openCJ\checkpointPublish::validationError(incompleteRows) != "",
          "publication rejects moving draft without stored geometry");
    checkReferenceCacheCapacity(key, platform);
    printf("BRUSH SELFTEST COMPLETE failures=" + level.brushFailures + "\n");
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

// Stale saved references must not retain a cache entry forever for every miss.
checkReferenceCacheCapacity(validReference, platform)
{
    referenceCapacity = 1024;
    for(i = 0; i <= referenceCapacity; i++)
    {
        openCJ\checkpointMoving::resolve("b" + (10000 + i));
        if(i % 32 == 0)
        {
            wait 0.05;
        }
    }
    check(level.checkpointMovingCache.size <= referenceCapacity,
          "reference cache stays bounded after many missing platforms");
    check(openCJ\checkpointMoving::resolve(validReference) == platform,
          "valid platform resolves after reference cache reaches capacity");
}
