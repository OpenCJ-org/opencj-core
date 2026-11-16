main()
{
    wait 2;
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod")return;
    level.clipTestFailures=0;
    a=demoCreateTransient();b=demoCreateTransient();
    check(isDefined(a) && isDefined(b) && a!=b,"transient handles unique");
    for(i=0;i<1300;i++)
    {
        addFrameToDemo(a,(i,0,0),(0,90,0),1,8192,int(i==1150),int(i==1200),0,125,0);
        demoKeepLast(a,1200);
        if(i%100==0)wait 0.05;
    }
    check(numberOfDemoFrames(a)==1200,"60 second recording cap");
    info=demoClipInfo(a,0);
    check(info[0][0]==100 && info[2]==1100,"sliding buffer origin and latest load");
    info=demoClipInfo(a,1100);
    check(info[0][0]==1200,"latest load can be initial trim start");
    // A trim is an encoded slice: all earlier footage stays editable.
    check(demoDecodeChunk(b,demoEncodeChunk(a,1100,64))==64,"trimmed payload decodes");
    info=demoClipInfo(b,0);check(info[0][0]==1200,"trimmed lookup origin follows start marker");
    info=demoClipInfo(b,63);check(info[0][0]==1263,"trim includes exact last selected frame");
    check(numberOfDemoFrames(a)==1200,"trimming does not delete editable footage");
    info=demoClipInfo(a,0,1199);
    check(info[3][35]==1 && info[3][36]==2,"save and load colors survive rolling buffer");
    info=demoClipInfo(a,1100,1199);
    check(info[3][35]==0 && info[3][36]==2,"events outside selection are excluded");
    destroyDemo(a);destroyDemo(b);
    workflow();
    printf("CLIP BUFFER COMPLETE failures="+level.clipTestFailures+"\n");
}
check(ok,label){if(!ok){level.clipTestFailures++;printf("CLIP BUFFER FAIL "+label+"\n");}}

workflow()
{
    bot=addTestClient();
    if(!isDefined(bot)){check(false,"spawn clip test player");return;}
    wait 1;
    row=openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
    bot.login_playerID=int(row[0][0]);bot.isFullyConnected=true;
    bot thread openCJ\events\spawnPlayer::main(false);
    wait 1;
    bot notify("spawned");bot.sessionState="playing";bot.playerRuns_runPaused=false;
    bot.playerRuns_runFinished=false;bot.playerRuns_runFinishing=false;
    bot.startTime=getTime()-5000;bot.stopTime=undefined;
    origin=bot.origin;angles=bot getPlayerAngles();
    bot openCJ\clips::record();
    check(isDefined(bot.clipRecording),"manual clip starts alongside run");
    if(!isDefined(bot.clipRecording))return;
    id=bot.clipRecording.id;
    for(i=0;i<40;i++)addFrameToDemo(id,(100+i,200,300),(0,90,0),1,8192,0,int(i==10),0,125,0,bot getEntityNumber());
    queuedBefore=bot getQueuedReliableMessages();
    bot setVelocity((120,0,0));
    bot openCJ\clips::edit();
    check(bot openCJ\demos::isPlayingDemo() && isDefined(bot.clipEdit),"stoprecord enters safe playback editor");
    if(!isDefined(bot.clipEdit))return;
    check(bot.clipEdit.first==11,"initial trim starts at latest load");
    check(bot.clipEdit.layoutCommands<=5 && bot.clipEdit.eventCommands<=2,"editor batches 120 dvars into at most seven commands");
    queuedAfter=bot getQueuedReliableMessages();
    printf("CLIP BUFFER editor reliable delta="+(queuedAfter-queuedBefore)+" layout="+bot.clipEdit.layoutCommands+" events="+bot.clipEdit.eventCommands+"\n");
    check(queuedAfter-queuedBefore<64,"editor startup stays below half the reliable queue");
    check(openCJ\clips::validDescription("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"),"32 character names allowed");
    check(!openCJ\clips::validDescription("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456"),"33 character names rejected");
    check(!openCJ\clips::validDescription("bad'name") && !openCJ\clips::validDescription("bad_name") && !openCJ\clips::validDescription("bad;name"),"special characters rejected");
    check(!openCJ\clips::validDescription("   "),"blank names rejected");
    bot openCJ\clips::seek(12);bot openCJ\demos::demoUpdateOverlay();
    check(bot.demoClipCursor==12,"cursor updates within same displayed second");
    bot openCJ\clips::seek(13);bot openCJ\demos::demoUpdateOverlay();
    check(bot.demoClipCursor==13,"frame-step cursor is not gated by whole seconds");
    bot openCJ\demos::whilePlayingDemo();
    check(bot.keyboard["forward"].alpha==0,"editor hides movement-key HUD");
    check(bot.hudSpeed["curr"].alpha==0 && bot.hudSpeed["max"].alpha==0,"editor hides speedometer");
    check(bot.hudSpeed["curr"].hideWhenInMenu && bot.keyboard["forward"].hideWhenInMenu,"editor uses native menu HUD suppression");
    count=numberOfDemoFrames(bot.clipEdit.id);cells=count;if(cells>40)cells=40;
    for(cell=0;cell<cells;cell++)
    {
        target=int((count*cell+cells-1)/cells);
        bot openCJ\clips::seek(target);
        check(bot skipPlaybackFrames(0)==target,"bin seek uses exact first frame");
    }
    bot.demoBegin=10;bot.demoEnd=12;
    bot openCJ\clips::seek(11);bot.demoFirstFrame=false;bot.playbackPaused=false;bot.demoRate=1;
    bot openCJ\demos::whilePlayingDemo();
    check(bot skipPlaybackFrames(0)==12 && bot.demoLastPresentedFrame==12,"last frame stays selected through presentation");
    check(bot.demoLoopPending,"loop deferred until next tick");
    bot openCJ\demos::whilePlayingDemo();
    check(bot skipPlaybackFrames(0)==12,"terminal frame held before client teleport cut");
    bot.demoLoopAt=getTime();
    bot openCJ\demos::whilePlayingDemo();
    check(bot skipPlaybackFrames(0)==10 && bot.demoLastPresentedFrame==10,"loop presents exact first trim frame");
    bot openCJ\clips::seek(11);
    check(!bot.demoLoopPending,"manual seeking cancels pending loop");
    bot.playbackPaused=true;
    bot.clipEdit.first=0;bot.clipEdit.last=20;
    bot openCJ\clips::submit("clip test");
    check(!bot openCJ\demos::isPlayingDemo(),"submit exits editor");
    check(distanceSquared(bot.origin,origin)<0.01,"editor restores original position");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT clipID,frameCount FROM demoClips WHERE description='clip test' AND sessionID='"+level.clipSession+"' AND ready=1");
    check(row.size==1 && int(row[0][1])==21,"trimmed session clip published");
    if(!row.size)return;
    clip=int(row[0][0]);
    // Exit must load the real save, not a moving/airborne pre-preview position.
    bot setoriginandangles(origin,angles);
    bot openCJ\savePosition::setSavedPosition();
    saved=bot openCJ\savePosition::getSavedPosition(0);
    bot setoriginandangles(origin+(0,0,200),angles);
    bot setVelocity((120,0,-80));
    bot openCJ\clips::play(clip,true);
    check(isDefined(bot.clipPreview) && bot.playbackPaused,"single browser click freezes location preview");
    check(bot.hudSpeed["curr"].hideWhenInMenu && bot.keyboard["forward"].hideWhenInMenu,"browser preview hides movement HUDs");
    bot openCJ\demos::whilePlayingDemo();
    bot openCJ\events\eventHandler::onSavePositionRequest();
    check(!isDefined(bot.eventQueue["save"]),"preview cannot create a run save");
    bot openCJ\clips::play(clip,true);
    check(!isDefined(bot.clipPreview) && !bot.playbackPaused,"second click plays the clip");
    check(!bot.hudSpeed["curr"].hideWhenInMenu && !bot.keyboard["forward"].hideWhenInMenu,"playback toolbar retains movement HUDs");
    bot openCJ\demos::stopDemo();
    check(distanceSquared(bot.origin,saved.origin)<0.01,"clip exit loads the actual saved position");
    check(length(bot getVelocity())<0.01,"clip exit load clears playback and airborne velocity");
    check(bot.hudSpeed["curr"].hideWhenInMenu && bot.keyboard["forward"].hideWhenInMenu,"normal menus hide movement HUDs after demo exit");
    owner=bot.login_playerID;bot.login_playerID=owner+1000000;
    bot openCJ\clips::remove(clip);
    row=openCJ\mySQL::mysqlSyncQuery("SELECT clipID FROM demoClips WHERE clipID="+clip);
    check(row.size==1,"non-owner cannot delete a clip");
    bot openCJ\clips::rename(clip,"Not mine");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT description FROM demoClips WHERE clipID="+clip);
    check(row[0][0]=="clip test","non-owner cannot rename");
    bot.login_playerID=owner;bot.clipRenameAt=undefined;
    args=[];args[0]=""+clip;args[1]="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    bot openCJ\clips::_rename(args);
    wait 0.3;
    row=openCJ\mySQL::mysqlSyncQuery("SELECT description FROM demoClips WHERE clipID="+clip);
    check(row[0][0]=="ABCDEFGHIJKLMNOPQRSTUVWXYZ012345","rename truncates to 32");
    bot openCJ\clips::rename(clip,"Should be throttled");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT description FROM demoClips WHERE clipID="+clip);
    check(row[0][0]=="ABCDEFGHIJKLMNOPQRSTUVWXYZ012345","rename cooldown prevents repeated writes");
    bot.clipRenameAt=undefined;
    args=[];args[0]=""+clip;args[1]="Hi";args[2]="this";args[3]="is";args[4]="a";args[5]="name";
    bot openCJ\clips::_rename(args);
    wait 0.3;
    row=openCJ\mySQL::mysqlSyncQuery("SELECT description FROM demoClips WHERE clipID="+clip);
    check(row[0][0]=="Hi this is a name","rename retains spaces");
    bot openCJ\clips::remove(clip);
    row=openCJ\mySQL::mysqlSyncQuery("SELECT clipID FROM demoClips WHERE clipID="+clip);
    check(row.size==0,"owner can delete their clip");
    row=openCJ\mySQL::mysqlSyncQuery("SELECT clipID FROM demoClipChunks WHERE clipID="+clip);
    check(row.size==0,"deletion removes associated footage");
    bot openCJ\clips::record();
    check(isDefined(bot.clipRecording),"recording before spectator transition");
    bot openCJ\events\spawnSpectator::main();
    check(!isDefined(bot.clipRecording),"spectator transition discards unfinished recording");
    bot.sessionState="playing";bot.playerRuns_runPaused=false;
    bot openCJ\clips::record();
    bot openCJ\clips::onDisconnect();
    check(!isDefined(bot.clipRecording),"disconnect discards unfinished recording");
}
