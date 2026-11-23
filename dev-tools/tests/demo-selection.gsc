// Called only by the isolated, database-free timeline harness.
run()
{
    openCJ\demoRecording::_initConstants();
    level.demoSelectionChecks = 0;
    level.demoCache = [];
    location = self verifyPhysicalLocation();
    originalCheckpoint = self.checkpoints_checkpoint;
    candidates = makeCandidateRecordings();
    self verifyCandidatePreference(candidates, location);
    nearbyLocation = self verifySpatialFallback(candidates);
    self verifyCancellation(candidates);
    check(self.route == "unrelated" && self.checkpoints_checkpoint == originalCheckpoint,
          "selection and cancellation never mutate progress");
    for(i = 0; i < candidates.recordingIDs.size; i++)
    {
        openCJ\demos::releaseCache(candidates.recordingIDs[i]);
    }

    verifyFailedAttemptRanking();
    emitSelectionQueries(location, nearbyLocation);
    printf("DEMO SELECTION COMPLETE checks=" + level.demoSelectionChecks + "\n");
}

// Normalize overlapping checkpoint pieces without reading or changing stale run progress.
verifyPhysicalLocation()
{
    checkpoint = spawnStruct();
    checkpoint.id = 17;
    checkpoint.origin = (0, 0, 100);
    checkpoint.radius = 100;
    checkpoint.onGround = false;
    checkpoint.hasChildren = true;
    checkpoint.endCheckpoints = [];
    easyRoute = spawnStruct();
    easyRoute.finishRouteID = 11;
    hardRoute = spawnStruct();
    hardRoute.finishRouteID = 12;
    checkpoint.endCheckpoints[0] = easyRoute;
    checkpoint.endCheckpoints[1] = hardRoute;
    siblingCheckpoint = spawnStruct();
    siblingCheckpoint.id = 19;
    siblingCheckpoint.origin = checkpoint.origin;
    siblingCheckpoint.radius = 100;
    siblingCheckpoint.onGround = false;
    siblingCheckpoint.bigBrother = checkpoint;
    staleCheckpoint = spawnStruct();
    staleCheckpoint.id = 99;
    level.checkpoints_checkpoints = [];
    level.checkpoints_checkpoints[0] = checkpoint;
    level.checkpoints_checkpoints[1] = siblingCheckpoint;
    self setOrigin(checkpoint.origin);
    self.route = "unrelated";
    self.checkpoints_checkpoint = staleCheckpoint;
    location = self openCJ\demos::selectionLocation();
    check(location.checkpoints.size == 1, "overlapping pieces normalize to one checkpoint");
    check(isDefined(location.routes["11"]) && isDefined(location.routes["12"]),
          "shared checkpoint includes both routes");
    check(!isDefined(location.routes["unrelated"]), "stale route is excluded");
    check(self.route == "unrelated" && self.checkpoints_checkpoint == staleCheckpoint,
          "location lookup preserves progress");

    return location;
}

// Build four ordered candidates: wrong location, RPG, longer, and shorter successful lessons.
makeCandidateRecordings()
{
    recordingIDs = [];
    rows = [];
    for(i = 0; i < 4; i++)
    {
        recordingID = 1800000100 + i;
        recordingIDs[i] = recordingID;
        frameCount = 60;
        if(i == 1)
        {
            frameCount = 20;
        }
        if(i == 3)
        {
            frameCount = 40;
        }
        origin = (0, 0, 100);
        if(i == 0)
        {
            origin = (3000, 0, 100);
        }
        makeRecording(recordingID, frameCount, origin, i == 1);
        cache = spawnStruct();
        cache.loading = false;
        cache.ready = true;
        cache.refs = 1;
        level.demoCache["" + recordingID] = cache; // Fixture owns a reference throughout.
        row = [];
        row[0] = "" + recordingID;
        row[1] = "0";
        row[2] = "" + frameCount;
        rows[i] = row;
    }
    candidates = spawnStruct();
    candidates.recordingIDs = recordingIDs;
    candidates.rows = rows;
    candidates.wrongSetupID = recordingIDs[0];
    candidates.rpgID = recordingIDs[1];
    candidates.longID = recordingIDs[2];
    candidates.shortID = recordingIDs[3];
    return candidates;
}

// Walkthroughs rank the local lesson; competitive modes retain database winner order.
verifyCandidatePreference(candidates, location)
{
    check(!isDefined(openCJ\demos::segmentAtLocation(candidates.wrongSetupID, 0, 1, location)),
          "wrong setup is rejected despite matching checkpoint ID");
    frameRange = openCJ\demos::segmentAtLocation(candidates.rpgID, 0, 1, location);
    check(frameRange[2] == 1 && frameRange[3] == 20,
          "segment reports its own shots and sample count");
    selectedCandidate =
        self openCJ\demos::selectCandidate(candidates.rows, location, "walkthrough");
    check(isDefined(selectedCandidate) && selectedCandidate.id == candidates.shortID,
          "shared walkthrough prefers no RPG then shorter local segment");
    check(!isDefined(self.demoPendingId) && self.demoSelectionId == candidates.shortID,
          "selected cache reference is retained without a pending load");
    check(level.demoCache["" + candidates.wrongSetupID].refs == 1 &&
              level.demoCache["" + candidates.rpgID].refs == 1 &&
              level.demoCache["" + candidates.longID].refs == 1,
          "rejected candidates release their references");
    check(level.demoCache["" + candidates.shortID].refs == 2,
          "selected candidate is not loaded twice or prematurely freed");
    self openCJ\demos::releaseSelection();
    check(level.demoCache["" + candidates.shortID].refs == 1,
          "selection release returns cache to fixture owner");
    selectedCandidate = self openCJ\demos::selectCandidate(candidates.rows, location, "speedrun");
    check(selectedCandidate.id == candidates.rpgID,
          "speedrun picks first matching time-ranked recording even when it uses RPG");
    self openCJ\demos::releaseSelection();
    selectedCandidate = self openCJ\demos::selectCandidate(candidates.rows, location, "lowrpg");
    check(selectedCandidate.id == candidates.rpgID,
          "low-RPG preserves the database winner ordering");
    self openCJ\demos::releaseSelection();
}

// Spatial lookup can find nearby recordings but must reject unrelated whole-route fallbacks.
verifySpatialFallback(candidates)
{
    self setOrigin((10, 0, 100));
    level.checkpoints_checkpoints = [];
    nearbyLocation = self openCJ\demos::selectionLocation();
    check(nearbyLocation.checkpoints.size == 0 && nearbyLocation.routes.size == 0,
          "outside checkpoint does not inherit stale route");
    selectedCandidate =
        self openCJ\demos::selectCandidate(candidates.rows, nearbyLocation, "speedrun");
    check(selectedCandidate.id == candidates.rpgID,
          "speedrun finds nearby spatial segment without checkpoint or route");
    self openCJ\demos::releaseSelection();
    nearbyLocation.origin = (50000, 0, 100);
    selectedCandidate =
        self openCJ\demos::selectCandidate(candidates.rows, nearbyLocation, "speedrun");
    check(!isDefined(selectedCandidate) && !isDefined(self.demoPendingId) &&
              !isDefined(self.demoSelectionId),
          "no nearby passage leaves no selected recording or reference");
    check(!isDefined(demoFindSegment(candidates.rpgID, 0, nearbyLocation.origin, 1, 0, 1)),
          "strict Any% rejects whole-route fallback");
    frameRange = demoFindSegment(candidates.rpgID, 0, nearbyLocation.origin, 1, 0);
    check(isDefined(frameRange) && frameRange[0] == 0 && frameRange[1] == 19,
          "legacy callers retain their explicit fallback");

    return nearbyLocation;
}

// Release this request's references while preserving the fixture's independent cache ownership.
verifyCancellation(candidates)
{
    self.demoSelectionId = candidates.longID;
    self.demoSelectionCache = level.demoCache["" + candidates.longID];
    level.demoCache["" + candidates.longID].refs++;
    self.demoPendingId = candidates.shortID;
    self.demoPendingCache = level.demoCache["" + candidates.shortID];
    level.demoCache["" + candidates.shortID].refs++;
    self openCJ\demos::cancelRequest();
    check(!isDefined(self.demoPendingId) && !isDefined(self.demoSelectionId),
          "cancellation releases both held candidates");
    check(level.demoCache["" + candidates.longID].refs == 1 &&
              level.demoCache["" + candidates.shortID].refs == 1,
          "cancellation preserves other cache owners");
    failedCache = spawnStruct();
    failedCache.loading = false;
    failedCache.ready = false;
    failedCache.refs = 0;
    level.demoCache["1800000110"] = failedCache;
    check(!self openCJ\demos::acquireCache(1800000110, 20), "failed recording is skipped");
    check(!isDefined(level.demoCache["1800000110"]) && !isDefined(self.demoPendingId),
          "failed recording releases cache reference");
}

// Failed attempts count for speedruns but not for walkthrough lesson ranking.
verifyFailedAttemptRanking()
{
    recordingID = 1800000111;
    createDemo(recordingID);
    for(i = 0; i < 30; i++)
    {
        addFrameToDemo(recordingID, (0, 0, 100), (0, 0, 0), 1, 8192, 0, 0, int(i == 5), 125, 17);
        if(i == 9)
        {
            demoMarkFailedSince(recordingID, 0);
        }
    }
    frameRange = demoFindSegment(recordingID, 17, (0, 0, 100), 0, 1, 1);
    check(frameRange[2] == 0 && frameRange[3] == 20,
          "walkthrough ranking excludes failed-attempt shots and samples");
    frameRange = demoFindSegment(recordingID, 17, (0, 0, 100), 0, 0, 1);
    check(frameRange[2] == 1 && frameRange[3] == 30,
          "speedrun keeps failed-attempt shots and samples");
    destroyDemo(recordingID);
}

// Emit real query text for the companion SQL replay check.
emitSelectionQueries(location, nearbyLocation)
{
    // Emit actual production queries for execution against SQL fixture tables.
    printf("DEMO SELECTION QUERY walkthrough " +
           openCJ\demos::candidateQuery(location, "walkthrough", "hax", 15, 7) + "\n");
    printf("DEMO SELECTION QUERY speedrun " +
           openCJ\demos::candidateQuery(location, "speedrun", "mix", 4, 7) + "\n");
    printf("DEMO SELECTION QUERY lowrpg " +
           openCJ\demos::candidateQuery(location, "lowrpg", "mix", 0, 7) + "\n");
    nearbyLocation.origin = (0, 0, 100);
    printf("DEMO SELECTION QUERY nearby " +
           openCJ\demos::candidateQuery(nearbyLocation, "speedrun", "mix", 0, 7) + "\n");
}

makeRecording(recordingID, frameCount, origin, hasRPGShot)
{
    createDemo(recordingID);
    for(i = 0; i < frameCount; i++)
    {
        addFrameToDemo(recordingID, origin, (0, 0, 0), 1, 8192, 0, 0, int(hasRPGShot && i == 5),
                       125, 17);
    }
}
check(ok, label)
{
    level.demoSelectionChecks++;
    if(!ok)
    {
        level.demoTimelineFailures++;
        printf("DEMO SELECTION FAIL: " + label + "\n");
    }
}
