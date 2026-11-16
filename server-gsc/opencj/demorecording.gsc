#include openCJ\util;

onInit()
{
    // Do not enable recording against an unmigrated database.
    level.demoStorageReady = isDefined(openCJ\mySQL::mysqlSyncQuery("SELECT runID FROM demoRuns LIMIT 0"));
    level.demoPublicationReady=false;
    if(level.demoStorageReady)
    {
        schema=openCJ\mySQL::mysqlSyncQuery("SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema=DATABASE() AND table_name='demoPublications'),EXISTS(SELECT 1 FROM information_schema.routines WHERE routine_schema=DATABASE() AND routine_name='publishDemo' AND routine_type='PROCEDURE')");
        level.demoPublicationReady=isDefined(schema) && schema.size==1 && int(schema[0][0])==1 && int(schema[0][1])==1;
    }
    // Reclaim abandoned uploads after crashes, with a generous grace period
    // so another server's active publication cannot be mistaken for an orphan.
    if(level.demoPublicationReady)
        level thread openCJ\mySQL::mysqlAsyncQueryNosave("DELETE FROM demoRuns WHERE ready=0 AND createdAt < NOW() - INTERVAL 7 DAY");
}

onConnect()
{
    self.demoRecordings = [];
}

onRunStarted()
{
    if (!isDefined(level.demoPublicationReady) || !level.demoPublicationReady || getCodVersion() != 4)
        return;
    id = self openCJ\playerRuns::getRunID();
    if (!isDefined(id) || isDefined(self.demoRecordings["" + id]))
        return;
    rec = spawnStruct();
    rec.id = id;
    rec.saves = [];
    rec.failed = false;
    rec.finishing = false;
    rec.lastTick = -1;
    self.demoRecordings["" + id] = rec;
    if (createDemo(id) != id)
        rec.failed = true;
    else
        self capture();
}

current()
{
    if (!self openCJ\playerRuns::hasRunID() || !isDefined(self.demoRecordings))
        return undefined;
    return self.demoRecordings["" + self openCJ\playerRuns::getRunID()];
}

capture(force)
{
    rec = self current();
    if (!isDefined(rec) || rec.failed || rec.finishing || (isDefined(self.playerRuns_runFinishing) && self.playerRuns_runFinishing) || self openCJ\demos::isPlayingDemo() || self openCJ\checkpointCreation::isEditing())
        return;
    // AFK pauses capture without discarding this session's run recording.
    if (isDefined(self.isAFK) && self.isAFK)
        return;
    if (self.sessionState != "playing" || self openCJ\playerRuns::isRunPaused() || self openCJ\cheating::isCheating())
        return;
    if (!isDefined(force) || !force)
    {
        if (self openCJ\playerRuns::isRunFinished() || !self openCJ\playTime::isActivelyPlaying() || rec.lastTick == getTime())
            return;
    }
    cp = self openCJ\checkpoints::getCurrentCheckpoint();
    cpID = 0;
    if (isDefined(cp))
    {
        if (isDefined(cp.bigBrother)) cp = cp.bigBrother;
        if (isDefined(cp.id)) cpID = cp.id;
    }
    fps = self openCJ\fps::getCurrentFPS();
    rpg = isDefined(self.eventQueue["rpg"]);
    if (!isDefined(addFrameToDemo(rec.id, self.origin, self getPlayerAngles(), 1, self frameFlags(), 0, int(isDefined(rec.loaded) && rec.loaded), int(rpg), int(fps), cpID, self getEntityNumber())))
    {
        rec.failed = true;
        destroyDemo(rec.id);
        self sendLocalChatMessage("Demo recording stopped: memory limit reached. Your run is unaffected.", true);
        return;
    }
    rec.lastTick = getTime();
    rec.loaded = false;
}

onSaved(saveNum)
{
    rec = self current();
    if (!isDefined(rec) || rec.failed || rec.finishing) return;
    self capture();
    if(rec.failed)return;
    rec.saves["" + saveNum] = numberOfDemoFrames(rec.id);
}

onLoaded(saveNum)
{
    rec = self current();
    if (!isDefined(rec) || rec.failed || rec.finishing) return;
    count = rec.saves["" + saveNum];
    if (!isDefined(count) || !isDefined(demoMarkFailedSince(rec.id, count)))
    {
        rec.failed = true;
        destroyDemo(rec.id);
        return;
    }
    keys = getArrayKeys(rec.saves);
    for (i=0;i<keys.size;i++)
        if (rec.saves[keys[i]] > count) rec.saves[keys[i]] = undefined;
    rec.lastTick = -1;
    rec.loaded = true;
}

onDisconnect()
{
    if (!isDefined(self.demoRecordings)) return;
    keys = getArrayKeys(self.demoRecordings);
    for (i=0;i<keys.size;i++)
    {
        rec = self.demoRecordings[keys[i]];
        if (!rec.failed && !rec.finishing) destroyDemo(rec.id);
    }
    self.demoRecordings = [];
}

onRunFinished()
{
    rec = self current();
    if (!isDefined(rec) || rec.failed || rec.finishing) return;
    if (rec.failed) return;
    rec.finishing = true;
    rec.saves = []; // No further rewind/save lookup is possible for a finished run.
    completeDemo(rec.id);
    level thread persist(rec.id);
}

frameFlags()
{
    flags = 0;
    if (self leftButtonPressed()) flags |= 1;
    if (self rightButtonPressed()) flags |= 2;
    if (self forwardButtonPressed()) flags |= 4;
    if (self backButtonPressed()) flags |= 8;
    if (self sprintButtonPressed()) flags |= 16;
    if (self jumpButtonPressed()) flags |= 32;
    if (self isSprinting()) flags |= 64;
    if (self isMantling()) flags |= 128;
    if (self isOnLadder()) flags |= 256;
    stance = self getStance();
    if (stance == "stand") flags |= 512;
    else if (stance == "duck" || stance == "crouch") flags |= 1024;
    else flags |= 2048;
    if (openCJ\weapons::isRPG(self getCurrentWeapon())) flags |= 4096;
    if (self isOnGround()) flags |= 8192;
    if (isDefined(self.eventQueue["bounced"])) flags |= 16384;
    return flags;
}

// Runs completed in this connection alone reach here; resumed historical runs
// have no in-memory recording. SQL holds only complete candidate payloads.
persist(id)
{
    count = numberOfDemoFrames(id);
    if (!isDefined(count) || count < 2)
    {
        destroyDemo(id);
        return;
    }
    if(!isDefined(level.demoPersisting))level.demoPersisting=0;
    level.demoPersisting++;
    query = "INSERT INTO demoRuns(runID,mapID,routeID,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount) SELECT r.runID,r.mapID,c.finishRouteID,r.FPSMode,r.anyPct+2*r.ele+4*r.hb+8*r.hardTAS,s.timePlayed,s.explosiveJumps," + count + " FROM playerRuns r JOIN checkpoints c ON c.cpID=r.finishcpID JOIN checkpointStatistics s ON s.runID=r.runID AND s.cpID=r.finishcpID WHERE r.runID=" + id + " AND r.finishTimeStamp IS NOT NULL";
    ok = isDefined(openCJ\mySQL::mysqlAsyncBackground(query, "demo:"+id));
    for (first=0;ok && first<count;first+=64)
    {
        length = count-first;
        if (length>64) length=64;
        ok = isDefined(openCJ\mySQL::awaitNative(demoUploadChunk(id,id,0,first,length,int(first/64))));
    }
    if (ok) ok = promote(id);
    if (!isDefined(ok))
        printf("OpenCJ: demo publication outcome uncertain for run " + id + "; candidate retained for reconciliation.\n");
    else if (!ok)
    {
        printf("OpenCJ: demo publication failed for run " + id + "; leaderboard result retained.\n");
        // Only our unpublished candidate can be removed here.
        openCJ\mySQL::mysqlAsyncBackground("DELETE FROM demoRuns WHERE runID=" + id + " AND ready=0", "demo:"+id);
    }
    level.demoPersisting--;
    destroyDemo(id);
}

// A stored procedure owns the entire transaction on one worker connection.
// One publication lane avoids tying up several workers on the same map lock;
// the database lock also serializes publishers on separate game servers.
promote(id)
{
    uncertain=false;
    for(attempt=0;attempt<3;attempt++)
    {
        result=openCJ\mySQL::_request("CALL publishDemo("+id+")",2,"demo-publication","",30000,true);
        if(result.status==0)
        {
            if(isDefined(result.rows) && result.rows.size==1 && result.rows[0].size==2)
                return int(result.rows[0][0])==1;
            return undefined; // A malformed receipt cannot justify deletion.
        }
        if(result.status==3)
        {
            uncertain=true;
            // A lost reply may follow a successful commit, including a loser
            // whose payload was removed. Its durable receipt survives cleanup.
            receipt=openCJ\mySQL::_request("SELECT runID FROM demoPublications WHERE runID="+id,1,"","",10000,true);
            if(receipt.status!=0 || !isDefined(receipt.rows))return undefined;
            if(receipt.rows.size==1)return true;
            // Replaying is safe: the procedure rechecks the receipt under the
            // map lock, including if the first call has not finished yet.
        }
        else if(result.status!=1 || (result.error!=1205 && result.error!=1213))
        {
            if(uncertain)return undefined;
            return false;
        }
        if(attempt<2)wait 0.05*(attempt+1);
    }
    if(uncertain)return undefined;
    return false;
}

isBetter(kind,time,rpgs,oldTime,oldRpgs)
{
    if (kind=="lowrpg") return rpgs<oldRpgs || (rpgs==oldRpgs && time<oldTime);
    if (kind=="walkthrough") return time<oldTime;
    return time<oldTime || (time==oldTime && rpgs<oldRpgs);
}

// An explicitly abandoned run cannot be resumed through the runs menu.
discard(id)
{
    if(!isDefined(id) || !isDefined(self.demoRecordings))return;
    rec=self.demoRecordings[""+id];
    if(!isDefined(rec))return;
    if(!rec.failed && !rec.finishing)destroyDemo(id);
    self.demoRecordings[""+id]=undefined;
}
