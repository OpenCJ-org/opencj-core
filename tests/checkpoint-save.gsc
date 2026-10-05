main()
{
    wait 2;
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod")return;
    level.saveTestFailures=0;
    cp=openCJ\checkpointCreation::_empty();
    cp.points[0]=(0,0,0);cp.points[1]=(100,0,0);cp.points[2]=(100,100,0);cp.points[3]=(0,100,0);
    check(openCJ\checkpointArea::touchesPlayer(cp.points,(-14,50,0),true,true),"footprint reaches platform edge");
    check(!openCJ\checkpointArea::touchesPlayer(cp.points,(-16,50,0),true,true),"beyond footprint rejected");
    check(openCJ\checkpointArea::touchesPlayer(cp.points,(-10,-10,0),true,true),"footprint reaches corner");
    check(!openCJ\checkpointArea::touchesPlayer(cp.points,(-14,-14,0),true,true),"outside rounded corner rejected");
    check(!openCJ\checkpointArea::contains(cp.points,(-14,50,0),true,true),"geometric merge test stays strict");
    check(!openCJ\checkpointArea::touchesPlayer(cp.points,(-14,50,30),true,true),"neighboring height rejected");
    check(!openCJ\checkpointArea::touchesPlayer(cp.points,(-14,50,0),false,true),"ground requirement retained");
    check(openCJ\checkpointArea::touchesPlayer(cp.points,(-14,50,0),false,false),"airborne checkpoint permits contact");
    slope=[];slope[0]=(0,0,0);slope[1]=(100,0,50);slope[2]=(100,100,50);slope[3]=(0,100,0);
    check(openCJ\checkpointArea::touchesPlayer(slope,(110,50,52),true,true),"sloped edge uses contact height");
    check(!openCJ\checkpointArea::touchesPlayer(slope,(110,50,80),true,true),"sloped edge rejects other height");
    old=openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(cp));
    check(old.allowSave,"legacy draft defaults allowed");
    rows=[];rows[0]=openCJ\checkpointCreation::_encode(cp);
    check(openCJ\checkpointCreation::checkpointAt(rows,(50,50,0),true)==0,"edit finds current landing");
    check(openCJ\checkpointCreation::checkpointAt(rows,(150,50,0),true)==-1,"edit rejects outside landing");
    check(openCJ\checkpointCreation::checkpointAt(rows,(50,50,80),true)==-1,"edit distinguishes stacked platforms");
    cp.alternatives[0]=[];
    for(i=0;i<cp.points.size;i++)cp.alternatives[0][i]=cp.points[i]+(200,0,0);
    rows[0]=openCJ\checkpointCreation::_encode(cp);
    check(openCJ\checkpointCreation::checkpointAt(rows,(250,50,0),true)==0,"edit finds alternative landing");
    rows[1]=rows[0];
    check(openCJ\checkpointCreation::checkpointAt(rows,(50,50,0),true)==-2,"edit reports ambiguous overlap");
    cp.allowSave=false;
    restored=openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(cp));
    check(!restored.allowSave && restored.onGround,"restricted grounded draft round trip");
    cp.onGround=false;
    restored=openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(cp));
    check(!restored.allowSave && !restored.onGround,"airborne draft round trip");
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpoints LIMIT 1");
    if(isDefined(rows) && rows.size)
    {
        id=int(rows[0][0]);
        openCJ\mySQL::mysqlSyncQuery("UPDATE checkpoints SET allowSave=0 WHERE cpID="+id);
        value=openCJ\mySQL::mysqlSyncQuery("SELECT allowSave FROM checkpoints WHERE cpID="+id);
        check(isDefined(value) && int(value[0][0])==0,"database stores disabled saving");
    }
    else check(false,"database fixture available");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    bot=addTestClient();wait 1;
    if(isDefined(bot))
    {
        savedLogin=bot.login_playerID;savedAdmin=bot.adminLevel;
        savedEditors=getCvar("opencj_checkpoint_editor_playerids");savedEditor=getCvar("opencj_checkpoint_editor_playerid");
        setCvar("opencj_checkpoint_editor_playerids","70");setCvar("opencj_checkpoint_editor_playerid","69");
        bot.adminLevel=0;bot.login_playerID=70;
        check(bot openCJ\checkpointCreation::hasEditorAccess(),"Sardonyx editor access");
        sardonyxPath=bot openCJ\checkpointNetwork::basePath();
        bot.login_playerID=69;
        check(bot openCJ\checkpointCreation::hasEditorAccess(),"existing editor access retained");
        check(sardonyxPath!=bot openCJ\checkpointNetwork::basePath(),"different owners have isolated draft namespaces");
        bot.login_playerID=71;check(!bot openCJ\checkpointCreation::hasEditorAccess(),"other players not granted editor access");
        bot.login_playerID=undefined;bot.adminLevel=40;
        check(!bot openCJ\checkpointCreation::hasEditorAccess(),"login required even for admin");
        bot.login_playerID=savedLogin;bot.adminLevel=savedAdmin;
        setCvar("opencj_checkpoint_editor_playerids",savedEditors);setCvar("opencj_checkpoint_editor_playerid",savedEditor);
        previous=level.checkpoints_checkpoints;
        area=spawnStruct();area.area=cp.points;area.allowSave=false;
        level.checkpoints_checkpoints=[];level.checkpoints_checkpoints[0]=area;
        bot setOrigin((50,50,0));bot.anyPct=false;
        check(!bot openCJ\checkpoints::canSaveHere(),"inside restricted area");
        bot.anyPct=true;check(bot openCJ\checkpoints::canSaveHere(),"any percent exemption");
        bot.anyPct=false;bot.cpc=spawnStruct();check(bot openCJ\checkpoints::canSaveHere(),"editor exemption");savedRun=bot.playerRuns_runID;
        bot openCJ\commands::_restoreLastRun();
        bot openCJ\playerRuns::restoreRun(-1);
        bot openCJ\playerRuns::_createRunID();
        check(!bot openCJ\historySave::historyLoad(-1),"history restore blocked in editor");
        check(isDefined(bot.cpc),"restore commands keep editor active");
        if(isDefined(savedRun))check(bot.playerRuns_runID==savedRun,"restore commands do not change run");
        else check(!isDefined(bot.playerRuns_runID),"restore commands do not create run");
        bot.cpc=undefined;
        bot setOrigin((150,50,0));check(bot openCJ\checkpoints::canSaveHere(),"outside area");
        bot setOrigin((50,50,80));check(bot openCJ\checkpoints::canSaveHere(),"other vertical platform");
        bot setOrigin((50,50,0));area.allowSave=true;check(bot openCJ\checkpoints::canSaveHere(),"allowed area");
        level.checkpoints_checkpoints=previous;
    }
    else check(false,"test client available");
    printf("CHECKPOINT SAVE COMPLETE failures="+level.saveTestFailures+"\n");
}
check(ok,label){if(!ok){level.saveTestFailures++;printf("CHECKPOINT SAVE FAIL "+label+"\n");}}
