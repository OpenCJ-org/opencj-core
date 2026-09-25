// Only load on the isolated demo-test database, never the live server.
main()
{
    wait 3;
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod")return;
    level.demoTestFailures=0;
    a=1800000001;b=1800000002;
    check(createDemo(a)==a && createDemo(b)==b,"create native demos");
    for(i=0;i<130;i++)
    {
        cp=17;
        if(i>=50)cp=18;
        check(isDefined(addFrameToDemo(a,(i*1.0,20,30),(0,90,0),1,8192,0,0,0,125,cp)),"append contiguous frame");
    }
    check(numberOfDemoFrames(a)==130,"frame count has no hole after first append");
    check(demoDecodeChunk(b,"789cf377f63264640081067b20e100440e0c10a050cb2008a2014807033c") == 1,"legacy OCJ1 recordings remain readable");
    demoTruncate(b,0);
    chunks=[];
    for(i=0;i<130;i+=64)
    {
        n=130-i;if(n>64)n=64;
        chunks[chunks.size]=demoEncodeChunk(a,i,n);
        check(demoDecodeChunk(b,chunks[chunks.size-1])==n,"compressed chunk roundtrip");
    }
    encodedA=demoEncodeChunk(a,64,64);
    encodedB=demoEncodeChunk(b,64,64);
    check(sameBytes(encodedA,encodedB),"decoded positions, angles, FPS and checkpoint IDs preserved");
    check(!isDefined(demoDecodeChunk(b,"bad")),"malformed hex rejected");
    check(numberOfDemoFrames(b)==130,"bad chunk leaves frames unchanged");
    segment=demoFindSegment(b,17,(0,20,30),0);
    check(isDefined(segment)&&segment[0]==0&&segment[1]==50,"checkpoint segment ends on next landing");
    check(!isDefined(demoFindSegment(b,17,(900,20,30),0)),"distant alternative does not masquerade as matching setup");
    segment=demoFindSegment(b,0,(900,20,30),1);
    check(segment[0]==0&&segment[1]==129,"any-percent missing nearby passage falls back to whole run");
    check(demoTruncate(a,30)==30,"load removes failed attempt frames");
    addFrameToDemo(a,(1000,0,0),(0,0,0),1,8192,0,0,0,333,19);
    check(numberOfDemoFrames(a)==31,"recording continues directly after rewind");
    check(demoEncodeChunk(a,30,1)!=demoEncodeChunk(b,30,1),"rewound branch overwritten by successful continuation");
    destroyDemo(a);destroyDemo(b);
    createDemo(a);
    for(i=0;i<75001;i++)
    {
        if(!isDefined(addFrameToDemo(a,(i*1.0,0,0),(0,0,0),1,8192,0,0,0,125,17)))break;
        if(i%2000==1999)wait 0.05;
    }
    check(numberOfDemoFrames(a)==75001,"native buffer grows beyond old one-hour limit");
    check(isDefined(demoEncodeChunk(a,75000,1)),"last frame of grown buffer is readable");
    destroyDemo(a);
    createDemo(a);
    for(i=0;i<70;i++)
    {
        flags=8192;
        if((i>=10&&i<20)||(i>=23&&i<30)||(i>=50&&i<60))flags=0;
        x=i*1.0;if(i>=40)x+=1000;
        addFrameToDemo(a,(x,0,0),(0,0,0),1,flags,0,0,0,125,0);
    }
    segment=demoFindSegment(a,0,(15,0,0),1);
    check(segment[0]==0&&segment[1]==39,"short bunny-hop contact remains inside jump segment");
    destroyDemo(a);
    check(openCJ\demoRecording::isBetter("lowrpg",900,1,100,2),"low-RPG prioritizes RPG jumps over time");
    check(openCJ\demoRecording::isBetter("lowrpg",90,2,100,2),"low-RPG ties use time");
    check(!openCJ\demoRecording::isBetter("speedrun",100,2,100,2),"exact ties keep incumbent");
    retentionTests();
    playbackTest();
    printf("DEMO SELFTEST COMPLETE failures="+level.demoTestFailures+"\n");
}

check(ok,label)
{
    if(!ok){level.demoTestFailures++;printf("DEMO SELFTEST FAIL: "+label+"\n");}
}

retentionTests()
{
    row=openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
    player=int(row[0][0]);map=openCJ\mapID::getMapID();ids=[];
    for(i=0;i<4;i++)
    {
        row=openCJ\mySQL::mysqlSyncQuery("SELECT createRunID("+player+","+map+")");
        id=int(row[0][0]);ids[i]=id;
        time=100;rpgs=2;mask=0;
        if(i==1){time=90;rpgs=3;}
        if(i==2){time=110;rpgs=3;}
        if(i==3){time=80;rpgs=1;mask=2;}
        openCJ\mySQL::mysqlSyncQuery("INSERT INTO demoRuns(runID,mapID,routeName,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount) VALUES("+id+","+map+",'demo_selftest','125',"+mask+","+time+","+rpgs+",2)");
        openCJ\mySQL::mysqlSyncQuery("INSERT INTO demoChunks VALUES("+id+",0,UNHEX('1234'))");
        check(openCJ\demoRecording::promote(id),"winner promotion transaction");
    }
    row=openCJ\mySQL::mysqlSyncQuery("SELECT kind,runID FROM demoWinners WHERE mapID="+map+" AND routeName='demo_selftest' AND modeMask=0 ORDER BY kind");
    check(row.size==3,"one payload may serve multiple demo categories");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT runID FROM demoWinners WHERE mapID="+map+" AND routeName='demo_selftest' AND kind='speedrun' AND modeMask=0");
    check(int(row[0][0])==ids[1],"faster clean run replaces speedrun incumbent");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT runID FROM demoWinners WHERE mapID="+map+" AND routeName='demo_selftest' AND kind='lowrpg' AND modeMask=0");
    check(int(row[0][0])==ids[0],"slower low-RPG winner retained independently");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT runID FROM demoRuns WHERE runID="+ids[2]);
    check(!row.size,"nonwinning candidate removed");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT runID FROM demoChunks WHERE runID="+ids[2]);
    check(!row.size,"nonwinning binary payload removed by cascade");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT runID FROM demoWinners WHERE mapID="+map+" AND routeName='demo_selftest' AND kind='walkthrough' AND modeMask=2");
    check(!row.size,"elevator run cannot become walkthrough");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoWinners WHERE mapID="+map+" AND routeName='demo_selftest'");
    for(i=0;i<ids.size;i++)
    {
        openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoRuns WHERE runID="+ids[i]);
        openCJ\mySQL::mysqlSyncQuery("DELETE FROM playerRuns WHERE runID="+ids[i]);
    }
}

// CoD4x compares interned string IDs; long strings can have distinct IDs.
// Compare the transport bytes so this tests the codec, not string interning.
sameBytes(a,b)
{
    if(a.size!=b.size)return false;
    for(i=0;i<a.size;i++)if(a[i]!=b[i])return false;
    return true;
}

playbackTest()
{
    bot=addTestClient();
    if(!isDefined(bot)){check(false,"spawn playback test client");return;}
    wait 1;
    row=openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
    bot.login_playerID=int(row[0][0]);
    bot.isFullyConnected=true;
    bot thread openCJ\events\spawnPlayer::main(false);
    wait 1;
    bot notify("spawned"); // Stop the normal frame loop; drive playback deterministically below.
    bot.sessionState="playing";
    bot.playerRuns_runPaused=false;
    presentationTest(bot);
    recordingHooksTest(bot);
    bot.playerRuns_runFinished=false;
    bot.playerRuns_runFinishing=false;
    bot.startTime=getTime()-5000;bot.stopTime=undefined;
    row=openCJ\mySQL::mysqlSyncQuery("SELECT createRunID("+bot.login_playerID+","+openCJ\mapID::getMapID()+")");
    id=int(row[0][0]);
    createDemo(id);
    for(i=0;i<20;i++)addFrameToDemo(id,(i*1.0,20,100),(0,90,0),1,8192|512,0,0,0,125,0,bot getEntityNumber());
    row=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpoints WHERE mapID="+openCJ\mapID::getMapID()+" AND ender IS NOT NULL LIMIT 1");
    finish=int(row[0][0]);
    openCJ\mySQL::mysqlSyncQuery("UPDATE playerRuns SET finishcpID="+finish+",finishTimeStamp=NOW(),FPSMode='125',anyPct=0,ele=0,hb=0,hardTAS=0 WHERE runID="+id);
    openCJ\mySQL::mysqlSyncQuery("INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives) VALUES("+id+","+finish+",1000,0,0,0,0,0)");
    completeDemo(id);
    openCJ\demoRecording::persist(id);
    row=openCJ\mySQL::mysqlSyncQuery("SELECT ready,frameCount FROM demoRuns WHERE runID="+id);
    check(isDefined(row)&&row.size==1&&int(row[0][0])==1&&int(row[0][1])==20,"completed run publishes compressed payload and winner metadata");
    bot setoriginandangles((500,500,200),(0,45,0));
    bot freezeControls(true);
    origin=bot.origin;angles=bot getPlayerAngles();
    bot openCJ\demos::playRun(id,true);
    check(bot openCJ\demos::isPlayingDemo(),"load shared payload and start client playback");
    if(bot openCJ\demos::isPlayingDemo())
    {
        origin=bot.demoReturn.origin;angles=bot.demoReturn.angles;
        pausedTime=bot openCJ\playTime::getTimePlayed();
        bot openCJ\demos::whilePlayingDemo();
        check(bot readPlaybackFrame_origin()==(0,20,100),"first playback frame is original recording start");
        for(i=0;i<21;i++)bot openCJ\demos::whilePlayingDemo();
        check(bot openCJ\demos::isPlayingDemo(),"full run loops by default");
        bot openCJ\events\eventHandler::onSavePositionRequest();
        check(!isDefined(bot.eventQueue["save"]),"playback rejects save requests");
        bot openCJ\events\eventHandler::onLoadPositionRequest(0);
        bot openCJ\events\eventHandler::onSavePositionRequest();
        check(bot openCJ\demos::isPlayingDemo() && !isDefined(bot.eventQueue["save"]),"load cancellation keeps save guard until return is restored");
        bot openCJ\demos::whilePlayingDemo();
        check(!(bot openCJ\demos::isPlayingDemo()) && !isDefined(bot.eventQueue["load"]),"load exits demo without loading a run save");
        check(bot.origin==origin,"playback restores exact original position");
        check(distanceSquared(bot getPlayerAngles(),angles)<0.01,"playback restores view angles");
        check(!bot.playerRuns_runPaused,"playback restores active run state");
        check(bot openCJ\playTime::getTimePlayed()==pausedTime,"playback contributes no run time");
        check(!isDefined(level.demoCache[""+id]),"last viewer releases disposable native cache");
    }
    kick(bot getEntityNumber());
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoWinners WHERE runID="+id);
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM demoRuns WHERE runID="+id);
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM playerRuns WHERE runID="+id);
}

recordingHooksTest(bot)
{
    previousRun=bot.playerRuns_runID;
    id=1800000003;
    bot.playerRuns_runID=id;
    bot.playerRuns_runFinished=false;
    bot.playerRuns_runFinishing=false;
    bot.isActivelyPlaying=true;
    bot.FPS=125;
    bot openCJ\demoRecording::onRunStarted();
    rec=bot openCJ\demoRecording::current();
    check(isDefined(rec)&&!rec.failed,"fresh run creates recording automatically");
    if(isDefined(rec)&&!rec.failed)
    {
        bot openCJ\demoRecording::onSaved(5);
        saved=numberOfDemoFrames(id);
        bot openCJ\demoRecording::capture(true);
        check(numberOfDemoFrames(id)==saved+1,"active run appends frames");
        bot.playerRuns_runPaused=true;
        bot openCJ\demoRecording::capture(true);
        check(numberOfDemoFrames(id)==saved+1,"paused run adds no frames");
        bot.playerRuns_runPaused=false;
        bot.playingDemo=true;
        bot openCJ\demoRecording::capture(true);
        check(numberOfDemoFrames(id)==saved+1,"watching a demo adds no run frames");
        bot.playingDemo=false;
        bot.isAFK=true;
        for(i=0;i<100;i++)bot openCJ\demoRecording::capture(true);
        check(numberOfDemoFrames(id)==saved+1,"AFK adds no frames even through forced capture");
        bot.isAFK=false;
        bot openCJ\demoRecording::capture(true);
        check(numberOfDemoFrames(id)==saved+2,"leaving AFK resumes the same run recording");
        bot.isAFK=true;bot.playerRuns_runID=undefined;bot.isAFK=false;
        bot openCJ\demoRecording::capture(true);
        check(numberOfDemoFrames(id)==saved+2,"leaving AFK outside a run does not resume capture");
        bot.playerRuns_runID=id;
        bot openCJ\demoRecording::onLoaded(5);
        check(numberOfDemoFrames(id)==saved,"normal load rewinds failed attempt to its saved frame");
        bot openCJ\demoRecording::discard(id);
        check(!isDefined(bot openCJ\demoRecording::current()),"abandoned recording released");
    }
    bot.playerRuns_runID=previousRun;
}

presentationTest(bot)
{
    a=1800000021;b=1800000022;createDemo(a);createDemo(b);
    bot giveWeapon(level.weapons_loadouts["default"]);
    bot setSpawnWeapon(level.weapons_loadouts["default"]);
    savedVelocity=bot getVelocity();savedWeapon=bot getCurrentWeapon();
    for(i=0;i<3;i++)
    {
        if (i == 1)bot setSpawnWeapon(level.weapons_rpgs["default"]);
        bot setVelocity((123.25,45.5,6.75));
        flags=8192|512;
        if(i>0)flags|=4096|64|128|256;
        addFrameToDemo(a,bot.origin,bot getPlayerAngles(),1,flags,0,0,int(i==1),125,17,bot getEntityNumber());
    }
    bot setSpawnWeapon(savedWeapon);
    encoded=demoEncodeChunk(a,0,3);
    check(demoDecodeChunk(b,encoded)==3,"detailed movement and delta weapon chunk decodes");
    check(sameBytes(encoded,demoEncodeChunk(b,0,3)),"detailed presentation roundtrip is stable");
    bot selectPlaybackDemo(b);bot skipPlaybackFrames(2);
    check(bot readPlaybackFrame_weapon()==level.weapons_rpgs["default"],"seeking reconstructs actual changed weapon");
    bot skipPlaybackFrames(-2);
    check(bot readPlaybackFrame_weapon()==savedWeapon,"reverse seek restores original weapon");
    bot skipPlaybackFrames(1);
    sound=bot readPlaybackFrame_rpgSound();
    check(isDefined(sound),"RPG firing resolves a local weapon sound without spawning a rocket");
    if(isDefined(sound))bot playLocalSound(sound);
    bot skipPlaybackFrames(1);
    bot setVelocity(savedVelocity);
    hadRpg=bot hasWeapon(level.weapons_rpgs["default"]);
    check(bot demoBeginPresentation(),"snapshot player presentation before demo");
    check(bot demoApplyPresentation(),"apply detailed frame presentation");
    check(distanceSquared(bot getVelocity(),(123.25,45.5,6.75))<0.001,"recorded velocity drives accurate speedometer");
    check(bot isOnLadder() && bot isMantling() && bot isSprinting(),"native presentation restores ladder, mantle and sprint state");
    // The old implementation passed immediate checks but let the engine lower
    // the weapon to none between presentation updates (disableWeapons conflict).
    bot skipPlaybackFrames(-2);
    for(tick=0;tick<12;tick++)
    {
        bot disableWeapons();
        bot demoApplyPresentation();
        wait 0.05;
        check(bot getCurrentWeapon()==savedWeapon,"recorded weapon remains equipped across simulation ticks");
    }
    bot demoEndPresentation();
    check(distanceSquared(bot getVelocity(),savedVelocity)<0.001 && bot getCurrentWeapon()==savedWeapon,"restore original weapon and velocity after demo");
    check((bot hasWeapon(level.weapons_rpgs["default"]))==hadRpg,"temporary playback weapon does not leak into run inventory");
    check(demoTruncate(a,1)==1,"rewind detailed recording");
    addFrameToDemo(a,bot.origin,bot getPlayerAngles(),1,8192|512,0,0,0,125,17,bot getEntityNumber());
    check(numberOfDemoFrames(a)==2,"detailed capture continues after truncation");
    destroyDemo(a);destroyDemo(b);
}
