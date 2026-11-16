#include openCJ\util;

onInit()
{
    level.historySavesActive=0;
    level.historySavesSequence=0;
}

historyLoad(runID)
{
    self openCJ\mapBoost::cancel();
    if(isDefined(self.cpc))return false;
    self notify("history_load_changed");
    self endon("history_load_changed");
    self endon("cpc_started");
    self endon("disconnect");
    self cancelPendingPage();
    self endon("history_load_cancelled");
    self.historySaves=undefined;
    initial=self savePosition_historyInfo();generation=initial[2];layout=level.checkpointLayoutEpoch;
    allowed=self openCJ\mySQL::mysqlAsyncRead("SELECT runID FROM playerRuns WHERE runID="+runID+" AND archived=0");
    current=self savePosition_historyInfo();
    if(current[2]!=generation || layout!=level.checkpointLayoutEpoch)return false;
    if(!isDefined(allowed)||!allowed.size)
    {
        self iprintlnbold("This run is archived and cannot be resumed. Start a new run.");
        return false;
    }
    rows=self openCJ\mySQL::mysqlAsyncWrite("SELECT historyLoad("+openCJ\mapID::getMapID()+", "+self openCJ\login::getPlayerID()+", "+runID+")","run:"+runID);
    current=self savePosition_historyInfo();
    if(current[2]!=generation || layout!=level.checkpointLayoutEpoch)return false;
    if(!isDefined(rows) || !isDefined(rows[0]) || !isDefined(rows[0][0]))
    {
        self iprintlnbold("^1Failed loading history for run: "+runID);
        return false;
    }
    self savePosition_initClient();
    self openCJ\savePosition::resetBackwardsCount();
    return self _loadSavesFromDatabase(runID,int(rows[0][0]));
}

_loadSavesFromDatabase(runID,instanceNumber)
{
    self endon("disconnect");
    state=self _beginHistory(runID,instanceNumber);
    rowsRun=self openCJ\mySQL::mysqlAsyncRead("SELECT timePlayed,saveCount,loadCount,explosiveLaunches FROM playerRuns WHERE archived=0 AND runID="+runID+" AND instanceNumber="+instanceNumber);
    if(!self _current(state) || !isDefined(rowsRun) || !rowsRun.size)
    {
        if(self _current(state))self.historySaves=undefined;
        return false;
    }
    self _startPage(state,undefined);
    while(self _current(state) && state.loading)wait .05;
    if(!self _current(state) || state.failed)
    {
        if(self _current(state)){self savePosition_initClient();self.historySaves=undefined;}
        return false;
    }
    self _restoreRunState(runID,instanceNumber,rowsRun);
    state.initial=false;
    info=self savePosition_historyInfo();
    if(info[0]==0)
    {
        spawnpoint=self openCJ\spawnpoints::getPlayerSpawnpoint();
        self freezeControls(true);self setVelocity((0,0,0));
        wait .05;
        if(!self _current(state)){self freezeControls(false);return false;}
        self openCJ\mapBoost::cancel();
        self setOrigin(spawnpoint.origin);self setPlayerAngles(spawnpoint.angles);
        self freezeControls(false);
    }
    return true;
}

_restoreRunState(runID,instanceNumber,rowsRun)
{
    // Update run
    self openCJ\playerRuns::setRunIDAndInstanceNumber(runID, instanceNumber);

    // Update statistics
    self openCJ\statistics::clear();
    self openCJ\statistics::setSaveCount(int(rowsRun[0][1]));
    self openCJ\statistics::setLoadCount(int(rowsRun[0][2]));
    self openCJ\statistics::setExplosiveLaunches(int(rowsRun[0][3])); // TODO: tbh should not be overall count, but instead bound per save

    self openCJ\playtime::setTimePlayed(int(rowsRun[0][0]));
    self openCJ\healthRegen::resetHealthRegen();
    self openCJ\shellShock::resetShellShock();
    self openCJ\checkpointPointers::showCheckpointPointers();

}

_beginHistory(runID,instanceNumber)
{
    info=self savePosition_historyInfo();
    level.historySavesSequence++;
    state=spawnStruct();state.id=level.historySavesSequence;
    state.runID=runID;state.instance=instanceNumber;
    state.owner=self openCJ\login::getPlayerID();state.map=openCJ\mapID::getMapID();
    state.generation=info[2];state.layout=level.checkpointLayoutEpoch;
    state.initial=true;state.loading=false;state.failed=false;state.exhausted=false;
    state.request=0;state.retryAt=0;
    self.historySaves=state;
    return state;
}

_current(state)
{
    if(!isDefined(self) || !isPlayer(self) || !isDefined(self.historySaves) ||
       self.historySaves.id!=state.id || !isDefined(state.map) || !isDefined(state.owner) ||
       !isDefined(state.instance) || isDefined(self.cpc) ||
       self openCJ\demos::isPlayingDemo() || state.layout!=level.checkpointLayoutEpoch)return false;
    if(state.owner!=self openCJ\login::getPlayerID() || state.map!=openCJ\mapID::getMapID())return false;
    info=self savePosition_historyInfo();
    if(info[2]!=state.generation)return false;
    if(!state.initial && (self openCJ\playerRuns::getRunID()!=state.runID ||
       self openCJ\playerRuns::getRunInstanceNumber()!=state.instance))return false;
    return true;
}

isLoadingInitial()
{
    return isDefined(self.historySaves) && self.historySaves.initial && self _current(self.historySaves);
}

_finishPage(state,request)
{
    if(isDefined(self) && isDefined(self.historySaves) &&
       self.historySaves.id==state.id && state.request==request)state.loading=false;
}

cancelPendingPage()
{
    self notify("history_load_cancelled");
    if(!isDefined(self.historySaves))return;
    state=self.historySaves;state.request++;state.loading=false;
    if(state.initial)self.historySaves=undefined;
}

// Returns true while the requested older data is queued/loading.
maybePrefetch(backwardsCount)
{
    if(!isDefined(self.historySaves))return false;
    state=self.historySaves;
    if(!self _current(state))return false;
    if(state.initial)return true;
    info=self savePosition_historyInfo();
    if(info[0]>=info[3] || state.exhausted)return false;
    if(state.loading)return true;
    if(info[0]==0 || backwardsCount<info[0]-10 || getTime()<state.retryAt)return false;
    self _startPage(state,info[1]);
    return true;
}

_startPage(state,cursor)
{
    state.loading=true;state.failed=false;state.request++;
    // Level owns the task: disconnect cannot abandon an occupied read slot.
    level thread _fetchPage(self,state,cursor,state.request);
}

_fetchPage(player,state,cursor,request)
{
    while(level.historySavesActive>=2)
    {
        if(!isDefined(player) || !player _current(state) || state.request!=request)
        {
            if(isDefined(player))player _finishPage(state,request);
            return;
        }
        wait .05;
    }
    if(!isDefined(player) || !player _current(state) || state.request!=request)
        {
            if(isDefined(player))player _finishPage(state,request);
            return;
        }
    level.historySavesActive++;
    info=player savePosition_historyInfo();
    amount=info[3]-info[0];if(amount>50)amount=50;
    if(amount>0)
    {
        before="";
        if(isDefined(cursor))before=" AND s.saveNumber<"+cursor;
        query="SELECT s.saveNumber,s.x,s.y,s.z,s.alpha,s.beta,s.gamma,s.explosiveJumps,s.doubleExplosives,s.checkpointID,s.FPSMode,s.flags,s.entTargetName,s.numOfEnt FROM playerSaves s JOIN playerRuns r ON r.runID=s.runID WHERE r.runID="+state.runID+" AND r.playerID="+state.owner+" AND r.mapID="+state.map+" AND r.instanceNumber="+state.instance+" AND r.archived=0"+before+" ORDER BY s.saveNumber DESC LIMIT "+amount;
        rows=openCJ\mySQL::mysqlAsyncRead(query);
        if(isDefined(player) && player _current(state) && state.request==request)
        {
            state.failed=!isDefined(rows);
            if(isDefined(rows))
            {
                // No yields or retained row arrays: copy directly into native nodes.
                for(i=0;i<rows.size;i++)
                {
                    result=player _restoreOlderRow(rows[i]);
                    if(!isDefined(result)){state.failed=true;break;}
                    if(result==1)break; // New live saves may have filled the cap.
                }
                state.exhausted=rows.size<amount;
            }
            if(state.failed)state.retryAt=getTime()+1000;
        }
    }
    // Free the page before another queued reader acquires its slot.
    rows=undefined;
    level.historySavesActive--;
    if(isDefined(player))player _finishPage(state,request);
}

_restoreOlderRow(row)
{
    if(row.size!=14 || !isDefined(row[0]) || !isDefined(row[1]) ||
       !isDefined(row[2]) || !isDefined(row[3]))return undefined;
    origin=(strToPreciseFloat(row[1]),strToPreciseFloat(row[2]),strToPreciseFloat(row[3])+.01);
    angles=(int(row[4]),int(row[5]),int(row[6]));
    entity=_getEntNum(row[12],intOrUndefined(row[13]));
    return self savePosition_addOlder(origin,angles,entity,int(row[7]),int(row[8]),
        intOrUndefined(row[9]),openCJ\fps::FPSModeToInt(row[10]),int(row[11]),int(row[0]));
}

_getEntNum(targetName, numOfEnt)
{
    if(!isDefined(targetName) || !isDefined(numOfEnt) || numOfEnt<0)
    {
        return undefined;
    }
    ents = getEntArray(targetName, "targetname");
    if(isDefined(ents) && isDefined(ents[numOfEnt]))
    {
        return ents[numOfEnt] getEntityNumber();
    }
    return undefined;
}

saveToDatabase(origin, angles, entTargetName, numOfEnt, explosiveJumps, doubleExplosives, checkpointID, FPSMode, flags)
{
    self endon("disconnect");

    if(self openCJ\demos::isPlayingDemo())
    {
        return;
    }
    if(self openCJ\playerRuns::isRunFinished())
    {
        return;
    }
    if(!self openCJ\playerRuns::hasRunID())
    {
        return;
    }
    if(self openCJ\cheating::isCheating())
    {
        return;
    }

    runID = self openCJ\playerRuns::getRunID();
    timePlayed = self openCJ\playTime::getTimePlayed();
    saveCount = self openCJ\statistics::getSaveCount();
    loadCount = self openCJ\statistics::getLoadCount();
    explosiveLaunches = self openCJ\statistics::getExplosiveLaunches();

    runInstance = self openCJ\playerRuns::getRunInstanceNumber();
    if(!isDefined(entTargetName))
    {
        entTargetName = "NULL";
    }
    else
    {
        entTargetName = "'" + openCJ\mySQL::escapeString(entTargetName) + "'";
    }
    if(!isDefined(numOfEnt))
    {
        numOfEnt = "NULL";
    }
    if(!isDefined(checkpointID))
    {
        checkpointID = "NULL";
    }
    x = preciseFloatToStr(origin[0]);
    y = preciseFloatToStr(origin[1]);
    z = preciseFloatToStr(origin[2]);

    alpha = int(angles[0]);
    beta = int(angles[1]);
    gamma = int(angles[2]);
    FPSMode = "'" + FPSMode + "'";

    query = "SELECT savePosition(" + runID + ", " + runInstance + ", " + x + ", " + y + ", " + z + ", " + alpha + ", " + beta + ", " + gamma + ", " + timePlayed + ", " + saveCount + ", " + loadCount + ", " + explosiveLaunches + ", " + explosiveJumps + ", " + doubleExplosives + ", " + checkpointID + ", " + FPSMode + ", " + flags + ", " + entTargetName + ", " + numOfEnt + ")";
    
    rows = openCJ\mySQL::mysqlAsyncWrite(query, "run:"+runID);
    message = self openCJ\runStorage::resultMessage(runID, runInstance, rows, "this position");
    if (message != "") self iPrintLnBold(message);
}
