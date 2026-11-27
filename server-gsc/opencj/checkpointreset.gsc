#include openCJ\util;

// Rebuild a standalone draft from active geometry. The editor operation is held while
// the published areas are read, so the current draft cannot change meanwhile.
reset(routeName)
{
    // An endon in a helper ends only that helper and returns to its caller, so the
    // operation's own frame ends it on disconnect. checkpointOperation::onDisconnect
    // has already restored the draft and released the transaction.
    self endon("disconnect");
    if(!self openCJ\checkpointOperation::begin())
    {
        return false;
    }
    restored = self resetFromPublished(routeName);
    self openCJ\checkpointOperation::end();
    return restored;
}

// Rebuild the draft only after saving its recovery copies.
resetFromPublished(routeName)
{
    if(!openCJ\checkpointCreation::_validName(routeName) || self.sessionState != "playing" ||
       self openCJ\demos::isPlayingDemo())
    {
        return self fail("Spawn first, then use !cpc reset <route>.");
    }
    // Validate existence before saving, closing or changing any draft.
    if(!isDefined(level.routeEnders[routeName]) || !isDefined(level.checkpointRoutes[routeName]))
    {
        return self fail("No active finalized route named " + routeName + "; draft unchanged.");
    }
    draftBasePath = self openCJ\checkpointNetwork::basePath();
    // Shared sections need a network-wide reset; never silently detach or edit other routes.
    if(FS_TestFile(draftBasePath + "network.a") || FS_TestFile(draftBasePath + "network.b"))
    {
        return self fail("Reset of shared network drafts is not supported; all drafts kept.");
    }
    // A publication during this read can retire some IDs; rowsFromActive then refuses.
    checkpointIdRows = self openCJ\mySQL::mysqlAsyncRead(
        "SELECT cpID " +
        "FROM checkpointAreas " +
        "WHERE mapID=" + openCJ\mapID::getMapID() +
        " AND draftName=" + dbStr(routeName) +
        " ORDER BY ordinal");
    if(!isDefined(checkpointIdRows) || !checkpointIdRows.size)
    {
        return self fail("Finalized route has no editable CPC areas; draft unchanged.");
    }
    checkpoints = [];
    for(i = 0; i < checkpointIdRows.size; i++)
    {
        checkpointId = int(checkpointIdRows[i][0]);
        checkpoints[i] = openCJ\checkpoints::getCheckpointByID(checkpointId);
    }
    restoredRows = rowsFromActive(checkpoints, routeName);
    if(!isDefined(restoredRows))
    {
        return self fail("Cannot safely reconstruct this finalized route; draft unchanged.");
    }
    draftPath = draftBasePath + routeName;
    if(self openCJ\checkpointCreation::isEditing() && !self openCJ\checkpointCreation::_save())
    {
        return self fail("Could not save current draft; reset cancelled.");
    }
    snapshotA = openCJ\checkpointCreation::_read(draftPath + ".a", routeName);
    snapshotB = openCJ\checkpointCreation::_read(draftPath + ".b", routeName);
    latestSnapshot = snapshotA;
    if(isDefined(snapshotB) && (!isDefined(snapshotA) || snapshotB.revision > snapshotA.revision))
    {
        latestSnapshot = snapshotB;
    }
    if(isDefined(latestSnapshot) && isDefined(latestSnapshot.sharedRoute))
    {
        return self fail("Shared branch draft kept; reset requires a standalone route.");
    }
    previousRevision = 0;
    if(isDefined(latestSnapshot))
    {
        previousRevision = latestSnapshot.revision;
    }
    backupPath = backupDraft(draftPath, previousRevision);
    if(!isDefined(backupPath))
    {
        return self fail("Could not back up the draft; reset cancelled.");
    }
    replacementDraft = spawnStruct();
    replacementDraft.route = routeName;
    replacementDraft.path = draftPath;
    replacementDraft.rows = restoredRows;
    replacementDraft.selected = restoredRows.size;
    replacementDraft.draft = openCJ\checkpointCreation::_empty();
    replacementDraft.revision = previousRevision;
    replacementDraft.routeHex = level.checkpointRoutes[routeName].hex;
    if(isDefined(latestSnapshot))
    {
        replacementDraft.savedPosition = latestSnapshot.savedPosition;
    }
    // The writer uses self.cpc; restore the current editor even if writing fails.
    activeDraft = self.cpc;
    self.cpc = replacementDraft;
    savedReplacement = self openCJ\checkpointCreation::_save();
    self.cpc = activeDraft;
    if(!savedReplacement)
    {
        return self fail("Could not write restored draft; backup retained at " + backupPath);
    }
    if(isDefined(activeDraft))
    {
        self openCJ\checkpointCreation::_close();
    }
    self openCJ\checkpointCreation::_start(routeName, replacementDraft.routeHex);
    self sendLocalChatMessage("Reset " + routeName + " draft to " + restoredRows.size +
                              " finalized checkpoints. Previous draft backup: " + backupPath);
    return true;
}

// Preserve the active geometry and requirements, grouping alternative areas
// back into a single logical checkpoint. No database writes are performed.
rowsFromActive(checkpoints, routeName)
{
    maximumAlternativeAreas = 7;
    maximumLogicalCheckpoints = 256;
    if(!isDefined(checkpoints) || !checkpoints.size)
    {
        return undefined;
    }
    groups = [];
    groupIndexById = [];
    for(i = 0; i < checkpoints.size; i++)
    {
        checkpoint = checkpoints[i];
        if(!isDefined(checkpoint) || !isDefined(checkpoint.area) ||
           (!openCJ\checkpointMoving::isMoving(checkpoint) &&
            openCJ\checkpointArea::validate(checkpoint.area) != ""))
        {
            return undefined;
        }
        if(isDefined(checkpoint.ender) && checkpoint.ender != routeName)
        {
            return undefined;
        }
        if(isDefined(checkpoint.bigBrother))
        {
            groupIndex = groupIndexById[checkpoint.bigBrother.id];
            if(!isDefined(groupIndex) ||
               groups[groupIndex].alternatives.size >= maximumAlternativeAreas)
            {
                return undefined;
            }
            group = groups[groupIndex];
            if(!sameRequirements(group, checkpoint))
            {
                return undefined;
            }
            group.alternatives[group.alternatives.size] = checkpoint.area;
        }
        else
        {
            if(groups.size >= maximumLogicalCheckpoints || isDefined(groupIndexById[checkpoint.id]))
            {
                return undefined;
            }
            group = draftFromActive(checkpoint);
            groupIndexById[checkpoint.id] = groups.size;
            groups[groups.size] = group;
        }
    }
    rows = [];
    for(i = 0; i < groups.size; i++)
    {
        rows[i] = openCJ\checkpointCreation::_encode(groups[i]);
    }
    if(openCJ\checkpointPublish::validationError(rows) != "")
    {
        return undefined;
    }
    return rows;
}

// Alternative areas share the same finish, movement and save requirements.
sameRequirements(group, checkpoint)
{
    if(!openCJ\checkpointHeight::same(group, checkpoint) ||
       group.finish != isDefined(checkpoint.ender) || group.double != checkpoint.allowDoubleRPG ||
       group.onGround != checkpoint.onGround || group.allowSave != checkpoint.allowSave ||
       group.allowEle != checkpoint.isEleAllowed)
    {
        return false;
    }
    return true;
}

// Decode active checkpoint fields into the editable draft representation.
draftFromActive(checkpoint)
{
    group = openCJ\checkpointCreation::_empty();
    group.points = checkpoint.area;
    group.platformRef = checkpoint.platformRef;
    group.heightAbove = openCJ\checkpointHeight::above(checkpoint);
    group.finish = isDefined(checkpoint.ender);
    group.double = checkpoint.allowDoubleRPG;
    group.onGround = checkpoint.onGround;
    group.allowSave = checkpoint.allowSave;
    group.allowEle = checkpoint.isEleAllowed;
    return group;
}

// Keep both alternating snapshots without overwriting any earlier reset backup.
backupDraft(draftPath, draftRevision)
{
    maximumBackupNames = 10000;
    backupPath = "";
    for(candidateIndex = 0; candidateIndex < maximumBackupNames; candidateIndex++)
    {
        backupPath = draftPath + ".before-reset-" + draftRevision + "-" + candidateIndex;
        if(!FS_TestFile(backupPath + ".a") && !FS_TestFile(backupPath + ".b"))
        {
            break;
        }
    }
    if(candidateIndex == maximumBackupNames)
    {
        return undefined;
    }
    if(!copySnapshot(draftPath + ".a", backupPath + ".a") ||
       !copySnapshot(draftPath + ".b", backupPath + ".b"))
    {
        return undefined;
    }
    return backupPath;
}

// A missing slot is normal; an existing slot must be copied completely.
copySnapshot(sourcePath, destinationPath)
{
    if(!FS_TestFile(sourcePath))
    {
        return true;
    }
    inputFile = FS_FOpen(sourcePath, "read");
    if(!inputFile)
    {
        return false;
    }
    outputFile = FS_FOpen(destinationPath, "write");
    if(!outputFile)
    {
        FS_FClose(inputFile);
        return false;
    }
    copied = true;
    for(;;)
    {
        line = FS_ReadLine(inputFile);
        if(!isDefined(line))
        {
            break;
        }
        if(!FS_WriteLine(outputFile, line))
        {
            copied = false;
            break;
        }
    }
    FS_FClose(inputFile);
    FS_FClose(outputFile);
    return copied;
}

fail(message)
{
    self sendLocalChatMessage(message, true);
    return false;
}
