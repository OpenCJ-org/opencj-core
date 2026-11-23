#include openCJ\util;
// Isolated synthetic clients and in-memory demos. No database initialization.
main()
{
    openCJ\demoRecording::_initConstants();
    level.lifecycleChecks=0;level.lifecycleFailures=0;
    openCJ\settings::onInit();openCJ\commands_base::onInit();
    openCJ\settings::addSettingBool("sharehistory",true,"History sharing");
    openCJ\huds\infiniteHuds::onInit();openCJ\huds\hudFPSHistory::onInit();
    openCJ\huds\infiniteHuds::initInfiniteHud("fps");
    openCJ\statistics::onInit();openCJ\showRecords::onInit();
    openCJ\huds\hudProgressBar::onInit();openCJ\huds\hudRunInfo::onInit();
    openCJ\huds\hudOnScreenKeyboard::onInit();openCJ\checkpointPointers::onInit();
    openCJ\notifications::onInit();
    precacheMenu("opencj_demo");precacheMenu("opencj_clipedit");precacheMenu("opencj_clips");precacheItem("rpg_mp");
    level.demoCache=[];level.menu["ingame"]="opencj_ingame";level.demoStorageReady=true;
    wait 1;
    p=addTestClient();other=addTestClient();wait .2;
    setup(p);setup(other);
    p.playerRuns_runPaused=false;p.playerRuns_runFinishing=false;p.playerRuns_runFinished=false;
    other.playerRuns_runPaused=false;other.playerRuns_runFinishing=false;other.playerRuns_runFinished=false;
    p.startTime=getTime();other.startTime=getTime();
    id=demoCreateTransient();
    // WA -> WD -> WA; non-key samples model the failed part of a run.
    for(i=0;i<15;i++)
    {
        flags=5;if(i>=5 && i<10)flags=6;if(i==0 || i==14)flags|=8192;
        addFrameToDemo(id,(i,0,100),(0,90,0),int(i!=3),flags,0,0,int(i==13),333,0,p getEntityNumber(),int(i==11));
    }
    p selectPlaybackDemo(id);
    p skipPlaybackFrames(6);
    p demoSetTechnique(2);
    check((p readPlaybackFrame_flags() & 15)==2,"fullbeat converted to halfbeat keys");
    angle=p readPlaybackFrame_angles();
    check(angle[1]>90 && angle[1]<=135,"camera eases into converted strafe near RPG aiming");
    check(p readPlaybackFrame_fps()==333,"conversion preserves FPS");
    p demoSetTechnique(0);
    check((p readPlaybackFrame_flags() & 15)==6,"original keys restored");
    p demoSetTechnique(2);p skipPlaybackFrames(7);
    check(!(p demoTechniqueFallback()),"compatible RPG aim keeps consistent conversion");
    angle=p readPlaybackFrame_angles();check(abs(angle[1]-90)<.01,"RPG aim direction remains exact");
    copy=demoCopyHistory(id);
    check(isDefined(copy) && copy!=id && numberOfDemoFrames(copy)==15,"history copied natively");
    addFrameToDemo(id,(999,0,0),(0,0,0),1,0,0,0,0,125);
    demoMarkFailedSince(id,0);
    check(numberOfDemoFrames(copy)==15 && numberOfDemoFrames(id)==16,"copy independent of source growth");
    p selectPlaybackDemo(copy);p demoSetTechnique(0);
    check(numberOfDemoKeyFrames(copy)==14,"copied successful frames preserved after source rewind");
    info=demoRangeInfo(copy,0,14);
    check(info[0]==1 && info[1]==1 && info[2]==1,"full range captures shot/FPS/elevation");
    info=demoRangeInfo(copy,0,9);
    check(info[0]==0 && info[2]==0,"trim excludes later shot and elevation");
    encoded=demoEncodeChunk(copy,0,15);decoded=demoCreateTransient();
    check(demoDecodeChunk(decoded,encoded)==15,"OCJ5 round trip");
    info=demoRangeInfo(decoded,0,14);
    check(info[0]==1 && info[2]==1,"OCJ5 retains event metadata");
    check(numberOfDemoKeyFrames(decoded)==14,"OCJ5 retains failed frames");
    legacy=demoCreateTransient();
    check(demoDecodeChunk(legacy,"789cf377f63261644006279ca00c055f8804003888028a")==1,"legacy OCJ4 loads");
    info=demoRangeInfo(legacy,0,0);check(info[2]==-1,"legacy elevation remains unknown");
    check(info[1]==-1,"ground-only footage does not invent an airborne FPS category");
    destroyDemo(id);destroyDemo(decoded);destroyDemo(legacy);
    check(numberOfDemoFrames(copy)==15,"source destruction leaves fixed copy playable");
    destroyDemo(copy);

    style=demoCreateTransient();
    for(i=0;i<40;i++)
    {
        flags=5;if((i>=10 && i<20) || i>=30)flags=6;
        if(i==0 || i==39)flags|=8192;
        fps=333;if(i>=15 && i<25)fps=250;
        addFrameToDemo(style,(i*5,0,100),(0,90,0),1,flags,0,0,0,fps);
    }
    p selectPlaybackDemo(style);p.demoID=style;p.demoStyle=0;p.demoBegin=0;p.demoEnd=39;
    p.demoFPSWaiting=false;p.demoFPSFloor=undefined;
    p.fpsHistoryMode="compact";p.demoTechnique=0;p demoSetTechnique(0);
    p skipPlaybackFrames(38);p openCJ\demos::syncDemoFPSHistory(38);
    original=p.fpsHistoryText;
    p.demoTechnique=2;p demoSetTechnique(2);p openCJ\demos::syncDemoFPSHistory(38);
    check(p.fpsHistoryText==original,"Compact is unchanged by viewing technique");
    p.fpsHistoryMode="detailed";p openCJ\demos::syncDemoFPSHistory(38);converted=p demoFPSRead(38);
    p.demoTechnique=0;p demoSetTechnique(0);p openCJ\demos::syncDemoFPSHistory(38);
    check((p demoFPSRead(38))!=converted,"Detailed follows converted key interpretation");
    printf("DEMO VIEWING FPS original="+(p demoFPSRead(38))+" halfbeat="+converted+" compact="+original+"\n");
    p.demoTechnique=2;p demoSetTechnique(2);
    p skipPlaybackFrames(12-(p skipPlaybackFrames(0)));p openCJ\demos::syncDemoFPSHistory(12);
    p skipPlaybackFrames(38-(p skipPlaybackFrames(0)));p openCJ\demos::syncDemoFPSHistory(38);
    check((p demoFPSRead(38))==converted,"converted Detailed survives reverse/seek rebuild");
    p.playingDemo=true;p.demoFPSCacheKey=undefined;
    p skipPlaybackFrames(14-(p skipPlaybackFrames(0)));p openCJ\demos::syncDemoFPSHistory(14);
    check(isSubStr(p demoFPSRead(14),"^2D ^7"),"Detailed shows converted halfbeat before return or landing");
    p.demoTechnique=3;check(p demoSetTechnique(3),"native Invert mode accepted");
    p.demoFPSCacheKey=undefined;p skipPlaybackFrames(24-(p skipPlaybackFrames(0)));
    p openCJ\demos::syncDemoFPSHistory(24);
    inverted=p demoFPSRead(24);
    check((p readPlaybackFrame_flags() & 15)==1,"Invert converts the return strafe to A");
    check(isSubStr(inverted,"^2D ^7") && isSubStr(inverted,"^6A ^7"),"Detailed shows both Invert sides while airborne");
    check(isSubStr(inverted,"^6WA ^7"),"Invert history keeps diagonal takeoff");
    p.fpsHistoryMode="compact";p openCJ\demos::syncDemoFPSHistory(38);
    check(p.fpsHistoryText==original,"Invert keeps Compact FPS independent of keys");
    p.fpsHistoryMode="detailed";
    p skipPlaybackFrames(14-(p skipPlaybackFrames(0)));p openCJ\demos::syncDemoFPSHistory(14);
    check((p readPlaybackFrame_flags() & 15)==2,"reverse Invert selects D");
    p skipPlaybackFrames(24-(p skipPlaybackFrames(0)));p openCJ\demos::syncDemoFPSHistory(24);
    check((p demoFPSRead(24))==inverted,"Invert Detailed survives reverse and forward seek");
    p.demoTechnique=0;p demoSetTechnique(0);
    for(m=1;m<=4;m++)
    {
        p openCJ\demos::toggleTechnique();
        check(p.demoTechnique==m%4,"viewer cycles all four techniques");
    }
    check(p.demoTechniqueLabel=="Original","fourth toggle returns to Original label");
    check(!(p demoSetTechnique(4)),"invalid fifth technique rejected");
    p.playingDemo=false;
    destroyDemo(style);p.demoID=undefined;
    p.demoTechnique=0;p.fpsHistoryMode="compact";



    rpg=demoCreateTransient();
    for(i=0;i<35;i++)
    {
        flags=5;if(i>=7 && i<21)flags=6;if(i==0 || i==34)flags|=8192;
        addFrameToDemo(rpg,(i*5,0,100),(0,90,0),1,flags,0,0,int(i==14),333);
    }
    p selectPlaybackDemo(rpg);p.demoID=rpg;p.demoStyle=0;p.demoBegin=0;p.demoEnd=34;
    p.demoTechnique=2;p demoSetTechnique(2);p.fpsHistoryMode="detailed";p.playingDemo=true;
    p.demoFPSCacheKey=undefined;
    for(i=0;i<=25;i++)
    {
        p skipPlaybackFrames(i-(p skipPlaybackFrames(0)));
        p openCJ\demos::syncDemoFPSHistory(i);
        if(i==3)check((p readPlaybackFrame_flags() & 15)==5,"RPG-aware halfbeat preserves diagonal takeoff");
        if(i>=7 && i<21)check((p readPlaybackFrame_flags() & 15)==2,"RPG strafe remains converted through the shot");
        if(i==14){angle=p readPlaybackFrame_angles();check(abs(angle[1]-90)<.01,"RPG-aware conversion retains exact shot aim");}
    }
    check(isSubStr(p demoFPSRead(25),"^2D ^7"),"Detailed includes the converted RPG strafe during the jump");
    check(isSubStr(p demoFPSRead(25),"^6WA ^7"),"Detailed keeps initial takeoff instead of relabeling it");
    p skipPlaybackFrames(14-25);p openCJ\demos::syncDemoFPSHistory(14);
    check(isSubStr(p demoFPSRead(14),"^2D ^7"),"reverse restores converted RPG strafe label");
    p.playingDemo=false;destroyDemo(rpg);p.demoID=undefined;

    cp=spawnStruct();cp.id=123;cp.checkpointsFromStart=3;
    ending=spawnStruct();ending.checkpointsFromStart=52;
    level.checkpoints_checkpoints=[];level.checkpoints_checkpoints[0]=cp;
    level.routeEnders=[];level.routeEnders["test"]=[];level.routeEnders["test"][0]=ending;
    progress=demoCreateTransient();
    addFrameToDemo(progress,(0,0,0),(0,0,0),1,8192,0,0,0,125,0);
    addFrameToDemo(progress,(0,0,0),(0,0,0),1,8192,0,0,0,125,123);
    p selectPlaybackDemo(progress);p.demoRouteName="test";p.demoCheckpointed=true;
    check((p openCJ\demos::demoCheckpointText())=="Checkpoint 0 / 52","demo starts at route checkpoint zero");
    p skipPlaybackFrames(1);
    check((p openCJ\demos::demoCheckpointText())=="Checkpoint 3 / 52","progress uses recorded checkpoint and selected route");
    p skipPlaybackFrames(-1);
    check((p openCJ\demos::demoCheckpointText())=="Checkpoint 0 / 52","checkpoint progress follows reverse seek");
    p.demoCheckpointed=false;
    check((p openCJ\demos::demoCheckpointText())=="","Any percent hides checkpoint progress");
    p.demoRouteName=undefined;destroyDemo(progress);
    // Actual command path: source capture continues; stop releases only the copy.
    source=demoCreateTransient();
    for(i=0;i<20;i++)addFrameToDemo(source,(i,0,100),(0,0,0),1,8192,0,0,0,125);
    other.runInstanceNumber=1;other.playerRuns_runID=source;other.playerRuns_runFinished=false;
    other.demoRecordings=[];rec=spawnStruct();rec.id=source;rec.failed=false;rec.finishing=false;other.demoRecordings[""+source]=rec;
    args=[];args[0]=other.name;
    p thread openCJ\demos::viewHistory(args);wait .1;
    check(p openCJ\demos::isPlayingDemo(),"view command starts fixed history");
    watched=p.demoID;
    check(p.demoHistorySource==other && p.demoAuthor==other.name,"correct source attribution");
    check(watched!=source && numberOfDemoFrames(watched)==20,"view command owns separate native copy");
    p.settingValues["demoloop"]=true;
    p skipPlaybackFrames(p.demoEnd-(p skipPlaybackFrames(0)));
    p openCJ\demos::_endOfDemo();
    check(p.playbackPaused && !p.demoLoopPending,"fixed history pauses at the end despite demoloop");
    last=p skipPlaybackFrames(0);p.demoFirstFrame=false;
    p openCJ\demos::whilePlayingDemo();
    check((p skipPlaybackFrames(0))==last && p openCJ\demos::isPlayingDemo(),"history remains on final frame for review");
    p.demoHistorySource=undefined;p.playbackPaused=false;
    p openCJ\demos::_endOfDemo();
    check(p.playbackPaused && !p.demoLoopPending,"source disconnection cannot enable history looping");
    p.demoHistorySource=other;
    other openCJ\demos::_shareHistory(false);
    check(p.demoExitRequested,"opt-out ends an existing other-player view");
    p openCJ\demos::stopDemo(false);
    check(!isDefined(level.demoCache[""+watched]) && numberOfDemoFrames(source)==20,"exit frees copy without source damage");
    other.settingValues["sharehistory"]=false;
    p thread openCJ\demos::viewHistory(args);wait .1;
    check(!p openCJ\demos::isPlayingDemo(),"opt-out denies a new view");
    other.settingValues["sharehistory"]=true;
    p thread openCJ\demos::viewHistory(args);wait .1;
    p.demoTechnique=2;p demoSetTechnique(2);
    p openCJ\demos::stopDemo(false);
    check(p.demoTechnique==2,"technique choice survives viewer close");
    destroyDemo(source);

    // Bound native memory with all 32 potential viewers; reject excess without
    // touching the source. Measure copying separately from fixture creation.
    source=demoCreateTransient();
    for(i=0;i<36000;i++)
    {
        addFrameToDemo(source,(0,0,100),(0,0,0),1,8192,0,0,0,125);
        if(i%500==0)wait .05;
    }
    copies=[];
    for(i=0;i<32;i++)
    {
        next=demoCopyHistory(source);
        if(isDefined(next))copies[copies.size]=next;
    }
    check(copies.size>0 && numberOfDemoFrames(source)==36000,"32 viewers respect native memory bound and preserve recording");
    printf("DEMO VIEWING COPY copies="+copies.size+" requested=32 frames=36000\n");
    rejected=false;
    for(i=copies.size;i<64;i++)
    {
        next=demoCopyHistory(source);
        if(!isDefined(next)){rejected=true;break;}
        copies[copies.size]=next;
    }
    check(rejected && numberOfDemoFrames(source)==36000,"extra copies stop at the native budget without corrupting the source");
    for(i=0;i<copies.size;i++)destroyDemo(copies[i]);
    destroyDemo(source);
    printf("DEMO VIEWING COMPLETE failures="+level.lifecycleFailures+" checks="+level.lifecycleChecks+"\n");
}

setup(p)
{
    p.sessionState="playing";p.sessionTeam="allies";p.pers["team"]="allies";
    p spawn((0,0,300),(0,0,0));p freezeControls(true);p.isFirstSpawn=false;
    p openCJ\settings::onPlayerConnect();
    p openCJ\huds\base::onPlayerConnect();
    p openCJ\huds\hudFPSHistory::onPlayerConnect();p.fpsHistoryMode="compact";
    p openCJ\huds\hudSpeedometer::onPlayerConnect();
    p openCJ\huds\hudOnScreenKeyboard::onPlayerConnect();
    p openCJ\huds\hudProgressBar::onPlayerConnect();
    p openCJ\huds\hudRunInfo::onPlayerConnect();
    p openCJ\huds\hudTimeLimit::onPlayerConnect();
    p openCJ\showRecords::onPlayerConnect();
    p openCJ\checkpointPointers::onPlayerConnect();
    p openCJ\statistics::onPlayerConnect();
    p openCJ\playerCollision::onPlayerConnect();
    p.statisticsHudString="";p.showRecords_nameString="";p.currSpeed=0;p.maxSpeed=0;
    p.demoLinker=spawn("script_origin",(0,0,0));p.playingDemo=false;
    p.cheating=false;p.allowHalfBeat=false;
    p giveWeapon("rpg_mp");p setSpawnWeapon("rpg_mp");
}
check(ok,label)
{
    level.lifecycleChecks++;
    if(!isDefined(ok) || !ok){level.lifecycleFailures++;printf("DEMO VIEWING FAIL "+label+"\n");}
}
