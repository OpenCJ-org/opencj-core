// Faults are injected only by the isolated fixture's SQL wrapper.
run()
{
    openCJ\demoRecording::onInit();
    openCJ\sqlCapacity::check(level.demoStorageReady && level.demoPublicationReady,"publication schema enables recording");
    openCJ\mySQL::mysqlSyncQuery("RENAME TABLE demoPublications TO capacityPublications");
    openCJ\demoRecording::onInit();
    openCJ\sqlCapacity::check(level.demoStorageReady && !level.demoPublicationReady,"missing migration disables new recording but preserves playback");
    openCJ\mySQL::mysqlSyncQuery("RENAME TABLE capacityPublications TO demoPublications");
    openCJ\demoRecording::onInit();
    openCJ\sqlCapacity::check(level.demoPublicationReady,"restored publication schema enables recording");

    modes=[];modes[0]="deadlock";modes[1]="timeout";modes[2]="before";
    modes[3]="after";modes[4]="lookupFailure";modes[5]="known";
    modes[6]="malformed";modes[7]="deadlockAlways";modes[8]="unknownAlways";
    for(i=0;i<modes.size;i++)
    {
        id=90001+i;elapsed=100000-i;
        if(modes[i]=="after")elapsed=200000; // committed loser is removed
        openCJ\mySQL::mysqlSyncQuery("INSERT INTO playerRuns(runID,playerID,mapID,FPSMode) VALUES("+id+",1,1,'mix')");
        openCJ\mySQL::mysqlSyncQuery("INSERT INTO demoRuns(runID,mapID,routeName,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount) VALUES("+id+",1,'recovery','mix',0,"+elapsed+",0,2)");
        openCJ\mySQL::mysqlSyncQuery("INSERT INTO demoChunks VALUES("+id+",0,UNHEX('01'))");
        level.publicationFault=modes[i];level.publicationCalls=0;
        result=openCJ\demoRecording::promote(id);
        if(i<4)
        {
            openCJ\sqlCapacity::check(isDefined(result) && result,"publication recovers from "+modes[i]);
            expected=2;if(modes[i]=="after")expected=1;
            openCJ\sqlCapacity::check(level.publicationCalls==expected,"bounded publication calls "+modes[i]);
            rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoPublications WHERE runID="+id);
            openCJ\sqlCapacity::check(int(rows[0][0])==1,"one durable publication receipt "+modes[i]);
            if(modes[i]=="after")
            {
                rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoRuns WHERE runID="+id);
                openCJ\sqlCapacity::check(int(rows[0][0])==0,"lost acknowledgement recovered after losing payload cleanup");
            }
        }
        else
        {
            if(modes[i]=="known" || modes[i]=="deadlockAlways")
                openCJ\sqlCapacity::check(isDefined(result) && !result,"known publication failure "+modes[i]);
            else openCJ\sqlCapacity::check(!isDefined(result),"publication uncertainty remains explicit "+modes[i]);
            expected=1;if(i>=7)expected=3;
            openCJ\sqlCapacity::check(level.publicationCalls==expected,"publication failure retry bound "+modes[i]);
            rows=openCJ\mySQL::mysqlSyncQuery("SELECT ready FROM demoRuns WHERE runID="+id);
            openCJ\sqlCapacity::check(rows.size==1 && int(rows[0][0])==0,"uncertain candidate retained "+modes[i]);
        }
        level.publicationFault=undefined;
    }
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoWinners WHERE mapID=1 AND routeName='recovery'");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoRuns WHERE runID BETWEEN 90001 AND 90009");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM playerRuns WHERE runID BETWEEN 90001 AND 90009");
    printf("CAP PUBLICATION RECOVERY COMPLETE\n");
}

request(query,policy,key,scope,deadline,save)
{
    prefix="CALL publishDemo(";
    if(isDefined(level.publicationFault) && query.size>=prefix.size && getSubStr(query,0,prefix.size)==prefix)
    {
        level.publicationCalls++;
        mode=level.publicationFault;
        if(level.publicationCalls==1 || mode=="deadlockAlways" || mode=="unknownAlways")
        {
            if(mode=="after")openCJ\mySQL::_capacityRealRequest(query,policy,key,scope,deadline,save);
            result=spawnStruct();result.rows=undefined;result.status=3;result.error=2013;
            if(mode=="deadlock" || mode=="deadlockAlways"){result.status=1;result.error=1213;}
            if(mode=="timeout"){result.status=1;result.error=1205;}
            if(mode=="known"){result.status=1;result.error=1064;}
            if(mode=="malformed"){result.status=0;result.error=0;result.rows=[];}
            return result;
        }
    }
    prefix="SELECT runID FROM demoPublications WHERE runID=";
    if(isDefined(level.publicationFault) && level.publicationFault=="lookupFailure" &&
       query.size>=prefix.size && getSubStr(query,0,prefix.size)==prefix)
    {
        result=spawnStruct();result.rows=undefined;result.status=2;result.error=2006;return result;
    }
    return openCJ\mySQL::_capacityRealRequest(query,policy,key,scope,deadline,save);
}
