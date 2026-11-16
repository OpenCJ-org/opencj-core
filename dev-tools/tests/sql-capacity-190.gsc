// Isolated 32-client benchmark. No production database or account callbacks.
main()
{
    level.capPhase=0;level.capStage="setup";level.capFailures=0;level.capChecks=0;level.capPending=0;
    expected=getCvar("capacity_database");
    if(getSubStr(expected,0,18)!="opencj_verify_190_")return;
    openCJ\mySQL::onInit();
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT DATABASE()");
    check(isDefined(rows) && rows[0][0]==expected,"isolated schema selected");
    openCJ\settings::onInit();openCJ\commands_base::onInit();
    openCJ\huds\infiniteHuds::onInit();openCJ\huds\hudFPSHistory::onInit();
    openCJ\huds\infiniteHuds::initInfiniteHud("fps");
    level.weapons_rpgs=[];level.weapons_rpgs["default"]="rpg_mp";
    level.demoCache=[];level.demoStorageReady=true;level.demoPersisting=0;
    level.capFrames=getCvarInt("capacity_frames");level.capTicks=getCvarInt("capacity_ticks");
    level.clients=[];
    wait 1;
    for(i=0;i<32;i++)
    {
        p=addTestClient();check(isDefined(p),"test client "+i);
        if(!isDefined(p)){finish();return;}
        level.clients[i]=p;
        wait .05;
        p.sessionTeam="allies";p.sessionState="playing";p.pers["team"]="allies";
        p spawn((i*50,0,500),(0,0,0));p freezeControls(true);
        p.login_playerID=i+1;p.FPS=333;p.cheating=false;p.isFirstSpawn=false;
        p.eventQueue=[];p.playerRuns_runPaused=false;p.playerRuns_runFinished=false;
        p openCJ\playerRuns::setRunIDAndInstanceNumber(1001+i,1);
        p openCJ\huds\base::onPlayerConnect();
        p openCJ\huds\hudFPSHistory::onPlayerConnect();
        p.fpsHistoryMode="detailed";
        p openCJ\demoRecording::onConnect();
        rec=spawnStruct();rec.id=1001+i;rec.failed=false;rec.finishing=false;rec.lastTick=-1;
        rec.saves=[];p.demoRecordings[""+rec.id]=rec;
        check(createDemo(rec.id)==rec.id,"native recording buffer "+i);
    }
    clipTransfers();
    phase("record32",32,false,false);
    phase("mixed16",16,false,false);
    // Fill each real native recording buffer to the configured run duration.
    level.capStage="prepare";setCvar("capacity_stage",0);
    for(i=0;i<32;i++)
    {
        p=level.clients[i];id=1001+i;
        for(f=numberOfDemoFrames(id);f<level.capFrames;f++)
        {
            flags=517;if(f%40>20)flags=518;if(f%100<5)flags|=8192;
            ok=addFrameToDemo(id,(f*.7,i*20,500+sin(f)*80),(0,f%360,0),1,flags,0,0,0,333,i+1,p getEntityNumber());
            if(!isDefined(ok)){check(false,"recording memory capacity "+i);finish();return;}
            if(f%1024==0)wait .05;
        }
    }
    phase("finish32_watch32",0,false,true);
    phase("shared32",0,true,false);
    level.capStage="verify";
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoRuns WHERE runID BETWEEN 1001 AND 1032 AND ready=1");
    check(isDefined(rows) && int(rows[0][0])==32,"all 32 native recordings published");
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoChunks WHERE runID BETWEEN 1001 AND 1032");
    check(isDefined(rows) && int(rows[0][0])==32*int(ceil(level.capFrames/64.0)),"all upload chunks persisted");
    stats=mysql_async_stats();
    check(stats[0]==4 && stats[4]==0,"four workers and empty completion backlog");
    check(stats[10]==0 && stats[12]==0 && stats[13]==0 && stats[14]==0,"no SQL failures rejections expirations or uncertain writes");
    finish();
}
phase(name,recorders,shared,upload)
{
    level.capPhase++;setCvar("capacity_stage",level.capPhase);level.capStage=name;level.capPending=0;started=capacityClock();
    printf("CAP BEGIN "+name+" "+started+"\n");
    for(i=0;i<recorders;i++)level.clients[i].capBefore=numberOfDemoFrames(1001+i);
    if(upload)
        for(i=0;i<32;i++){completeDemo(1001+i);level thread upload(1001+i);}
    for(i=recorders;i<32;i++)
    {
        id=3001+i;if(shared)id=3001;
        level.capPending++;level.clients[i] thread watch(id);
    }
    // Menus and saves begin in the same tick as cold playback loads/uploads.
    for(tick=0;tick<level.capTicks || level.capPending>0 || level.demoPersisting>0;tick++)
    {
        if(tick>2400){check(false,"phase deadline "+name);break;}
        loopStart=capacityClock();
        for(i=0;i<32;i++)
        {
            p=level.clients[i];
            if(i<recorders)p openCJ\demoRecording::capture(true);
            else if(isDefined(p.capWatching) && p.capWatching)
            {
                frame=p openCJ\demos::advanceDemoFrame();
                p openCJ\demos::syncDemoFPSHistory(frame.number);
                // Native playback presentation is exercised without opening UI.
                p demoApplyPresentation();
            }
            if((tick<level.capTicks || level.demoPersisting>0) && tick%10==0)p thread menu(i,tick);
            if((tick<level.capTicks || level.demoPersisting>0) && tick%20==0)p thread progress(i,tick);
        }
        if(tick%20==0)
        {
            st=mysql_async_stats();
            printf("CAP SAMPLE "+name+" "+st[1]+" "+st[2]+" "+st[3]+" "+st[4]+" "+st[5]+" "+(capacityClock()-loopStart)+"\n");
        }
        wait .05;
    }
    while(level.capPending>0)wait .05;
    wait .2;
    for(i=recorders;i<32;i++)
    {
        p=level.clients[i];
        if(isDefined(p.capWatching) && p.capWatching)
        {
            p demoEndPresentation();p demoFPSReset();p.playingDemo=false;
            openCJ\demos::releaseCache(p.demoID);p.capWatching=false;
            p openCJ\huds\hudFPSHistory::_clearFPSHistory();
        }
    }
    for(i=0;i<recorders;i++)check(numberOfDemoFrames(1001+i)-level.clients[i].capBefore==tick,"every recording tick captured");
    st=mysql_async_stats();
    printf("CAP END "+name+" "+(capacityClock()-started)+" "+tick+" "+st[6]+" "+st[7]+"\n");
}
watch(id)
{
    began=capacityClock();
    ok=self openCJ\demos::acquireCache(id,level.capFrames);
    check(ok,"playback cache "+id);
    if(ok)
    {
        self.demoPendingId=undefined;
        self selectPlaybackDemo(id);self.demoID=id;
        self.demoBegin=0;self.demoEnd=level.capFrames-1;self.demoStyle=0;self.playingDemo=true;
        self.demoFirstFrame=true;self.demoRate=1;self.demoStepRemainder=0;self.demoStepRate=1;
        self.demoFPSCacheKey=undefined;self.demoFPSCache=[];self.demoFPSCacheFrames=[];
        self.playbackPaused=false;self.demoPreviousOnGround=true;self.demoPreviousFPS=undefined;
        check(self demoBeginPresentation(),"native demo presentation");
        self.capWatching=true;
    }
    printf("CAP LOAD "+level.capStage+" "+id+" "+(capacityClock()-began)+"\n");
    level.capPending--;
}
upload(id)
{
    began=capacityClock();
    openCJ\demoRecording::persist(id);
    printf("CAP UPLOAD "+level.capStage+" "+id+" "+(capacityClock()-began)+"\n");
}
menu(i,tick)
{
    level.capPending++;
    token=self openCJ\mySQL::beginMenuRead("board");
    if(self openCJ\mySQL::menuReadCurrent(token))
    {
        // Same joins/window functions as the production leaderboard and runs menu.
        if(int(tick/10)%2==0)
        {
            q="SELECT COUNT(*) OVER(),b.playerName,a.timePlayed,a.runID FROM (SELECT pr.playerID,cs.timePlayed,cs.runID,ROW_NUMBER() OVER(PARTITION BY pr.playerID ORDER BY cs.timePlayed,cs.explosiveJumps) rn ";
            q+="FROM checkpointStatistics cs JOIN playerRuns pr ON pr.runID=cs.runID WHERE cs.cpID=1 AND pr.finishcpID IS NOT NULL AND pr.finishTimeStamp IS NOT NULL AND pr.ele<=1 AND pr.anyPct<=1 AND pr.hb<=1 AND pr.hardTAS<=1 AND pr.FPSMode IN ('125','mix','hax')) a JOIN playerDisplayNames b ON a.playerID=b.playerID WHERE a.rn=1 ORDER BY a.timePlayed LIMIT 10";
        }
        else
        {
            q="SELECT COUNT(*) OVER(),a.runID,rl.runLabel,a.timePlayed,a.explosiveJumps FROM (SELECT ROW_NUMBER() OVER(PARTITION BY pr.runID ORDER BY ps.saveNumber DESC) rn,pr.playerID,pr.runID,pr.timePlayed,ps.explosiveJumps ";
            q+="FROM playerSaves ps JOIN playerRuns pr ON pr.runID=ps.runID WHERE pr.finishTimeStamp IS NULL AND pr.finishcpID IS NULL AND pr.archived=0 AND pr.mapID=1) a LEFT JOIN runLabels rl ON a.runID=rl.runID WHERE a.rn=1 AND a.playerID="+(i+1)+" ORDER BY a.timePlayed LIMIT 10";
        }
        rows=self openCJ\mySQL::mysqlAsyncMenuQuery(q,"board");
        if(self openCJ\mySQL::menuReadCurrent(token))check(isDefined(rows),"current menu query");
    }
    level.capPending--;
}
progress(i,tick)
{
    level.capPending++;
    id=2001+i;self.capSave=0;if(isDefined(self.capSaveCount))self.capSave=self.capSaveCount;
    self.capSave++;self.capSaveCount=self.capSave;
    q="SELECT savePosition("+id+",1,10,20,30,0,90,0,"+(self.capSave*1000)+","+self.capSave+",0,0,0,0,1,'mix',0,NULL,NULL)";
    rows=openCJ\mySQL::mysqlAsyncWrite(q,"run:"+id);
    check(isDefined(rows) && rows.size>0 && isDefined(rows[0][0]),"progress save");
    level.capPending--;
}
queryMetric(policy,started,outcome)
{
    printf("CAP SQL "+level.capStage+" "+policy+" "+(capacityClock()-started)+" "+outcome[0]+" "+outcome[2]+" "+outcome[3]+"\n");
}
check(ok,label)
{
    level.capChecks++;if(!ok){level.capFailures++;printf("CAP FAILURE "+label+"\n");}
}
finish(){setCvar("capacity_stage",5);wait .1;printf("CAP COMPLETE "+level.capFailures+" "+level.capChecks+"\n");}

clipTransfers()
{
    legacy=demoCreateTransient();
    check(demoDecodeChunk(legacy,"789cf377f63264640081067b20e100440e0c10a050cb2008a2014807033c")==1,"legacy OCJ1 codec remains compatible");
    destroyDemo(legacy);
    level.mapid_mapID=1;level.clipSession="capacity";level.capStage="clip32";level.capPending=0;
    for(i=0;i<32;i++)
    {
        p=level.clients[i];p.playingDemo=false;
        id=demoCreateTransient();check(isDefined(id),"clip native buffer "+i);
        for(f=0;f<1200;f++)
        {
            flags=517;if(f%40>=20)flags=518;
            check(isDefined(addFrameToDemo(id,(f*.6,i*20,500+sin(f)*80),(0,f%360,0),1,flags,0,0,0,333,0,p getEntityNumber())),"clip frame");
        }
        completeDemo(id);rec=spawnStruct();rec.id=id;rec.first=0;rec.last=1199;
        rec.permanent=true;rec.busy=false;rec.date="2026-11-13 00:00:00";
        p.clipEdit=rec;p.capClipNative=id;
        wait .05;
    }
    for(i=0;i<32;i++){level.capPending++;level.clients[i] thread publishClip();}
    tick=0;
    while(level.capPending>0 && tick<2400)
    {
        for(i=0;i<32;i++)
        {
            if(tick%10==0)level.clients[i] thread menu(i,tick);
            if(tick%20==0)level.clients[i] thread progress(i,tick);
        }
        tick++;wait .05;
    }
    check(level.capPending==0,"clip upload completion deadline");
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoClips WHERE ready=1");
    check(isDefined(rows) && int(rows[0][0])==32,"32 simultaneous clip publications");
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM demoClipChunks");
    check(isDefined(rows) && int(rows[0][0])==32*19,"all clip chunks persisted");
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT clipID FROM demoClips ORDER BY clipID LIMIT 1");
    clip=int(rows[0][0]);native=demoCreateTransient();
    receipt=openCJ\mySQL::awaitNative(demoLoadChunks(native,clip,1,0));
    check(isDefined(receipt) && receipt[0][0]==19 && numberOfDemoFrames(native)==1200,"clip uses native binary download");
    destroyDemo(native);
    // Reusing an ID must never let an old SQL completion append into a new demo.
    native=770002;createDemo(native);job=demoLoadChunks(native,clip,1,0);
    destroyDemo(native);createDemo(native);
    receipt=openCJ\mySQL::awaitNative(job);
    check(!isDefined(receipt) && numberOfDemoFrames(native)==0,"stale load rejects reused native ID");
    destroyDemo(native);
    // No script waiter remains after a map change; its native result is drained.
    native=demoCreateTransient();job=demoLoadChunks(native,clip,1,0);
    mysql_async_newmap();wait .5;
    stats=mysql_async_stats();
    check(stats[4]==0 && numberOfDemoFrames(native)==0,"map change drains abandoned native read");
    destroyDemo(native);
    // Malformed bytes fail normally, without touching script strings or crashing.
    openCJ\mySQL::mysqlSyncQuery("UPDATE demoClipChunks SET payload=UNHEX('00') WHERE clipID="+clip+" AND chunkNum=0");
    native=demoCreateTransient();receipt=openCJ\mySQL::awaitNative(demoLoadChunks(native,clip,1,0));
    check(!isDefined(receipt) && numberOfDemoFrames(native)==0,"corrupt binary payload rejected");
    destroyDemo(native);
    printf("CAP CLIPS COMPLETE\n");
}
publishClip()
{
    native=self.capClipNative;
    // submit pins the native source before its first SQL wait. This sibling
    // simulates closing the editor and releasing its playback owner meanwhile.
    self thread closeClipDuringUpload(native);
    self openCJ\clips::submit("Capacity clip");
    check(self.playingDemo && self.demoID==-1,"completed upload does not stop subsequent playback");
    self.playingDemo=false;
    check(!isDefined(self.clipUploadNative),"clip upload released native ownership");
    check(!isDefined(self.clipUploadToken),"finished upload permits next submission");
    check(!isDefined(numberOfDemoFrames(native)),"closed clip buffer reclaimed after upload");
    self.clipEdit=undefined;
    level.capPending--;
}
closeClipDuringUpload(native)
{
    self endon("disconnect");
    wait .05;
    destroyDemo(native);
    self.clipEdit=spawnStruct();self.clipEdit.busy=false;
    token=self.clipUploadToken;
    self openCJ\clips::submit("Overlapping clip");
    check(self.clipUploadNative==native && self.clipUploadToken==token && !self.clipEdit.busy,"overlapping submission preserves pending upload ownership");
    self.clipEdit=undefined;self.playingDemo=true;self.demoID=-1;
}
