main()
{
    wait 2;level.migrationFailures=0;
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod"){check(false,"isolated database required");return;}
    openCJ\mySQL::onInit();
    q("START TRANSACTION");
    q("INSERT INTO mapids(mapname) VALUES('mp_migration_fixture')");level.mapid_mapID=scalar("SELECT LAST_INSERT_ID()");
    player=scalar("SELECT playerID FROM playerInformation LIMIT 1");
    editor=spawnStruct();editor.cpc=spawnStruct();editor.cpc.route="hard";editor.cpc.routeHex="#ffffff";
    editor.cpc.path="migration-fixture";editor.cpc.rows=[];
    for(i=0;i<5;i++)editor.cpc.rows[i]=row(i*200,i==4);
    original=editor.cpc.rows;
    check(editor openCJ\checkpointPublish::_writeSequentialRoute(),"initial fixture publication");
    ids=q("SELECT cpID FROM checkpointAreas WHERE mapID="+level.mapid_mapID+" ORDER BY ordinal");
    finish=ids[4][0];removed=ids[2][0];
    q("INSERT INTO playerRuns(playerID,mapID,finishcpID,finishTimeStamp) VALUES("+player+","+level.mapid_mapID+","+finish+",NOW())");completed=scalar("SELECT LAST_INSERT_ID()");
    q("INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives) VALUES("+completed+","+finish+",12345,0,0,7,7,0),("+completed+","+removed+",4000,0,0,2,2,0)");
    q("INSERT INTO playerRuns(playerID,mapID) VALUES("+player+","+level.mapid_mapID+")");unfinished=scalar("SELECT LAST_INSERT_ID()");
    q("INSERT INTO playerSaves(runID,saveNumber,alpha,beta,gamma,explosiveJumps,doubleExplosives,checkpointID,flags) VALUES("+unfinished+",1,0,0,0,0,0,"+removed+",0)");
    q("INSERT INTO demoRuns(runID,mapID,routeName,FPSMode,modeMask,timePlayed,explosiveJumps,frameCount,ready) VALUES("+completed+","+level.mapid_mapID+",'hard','mix',0,12345,7,2,1)");
    q("INSERT INTO demoChunks VALUES("+completed+",0,'fixture')");
    q("INSERT INTO demoWinners VALUES("+level.mapid_mapID+",'hard','mix',0,'speedrun',"+completed+")");
    q("SAVEPOINT original_layout");
    editor.cpc.rows=[];editor.cpc.rows[0]=original[0];editor.cpc.rows[1]=original[1];editor.cpc.rows[2]=original[3];editor.cpc.rows[3]=original[4];
    check(editor openCJ\checkpointPublish::_writeSequentialRoute(),"delete checkpoint migration succeeds");
    check(scalar("SELECT COUNT(*) FROM checkpointAreas WHERE mapID="+level.mapid_mapID)==4,"new area count");
    check(scalar("SELECT COUNT(*) FROM checkpointConnections WHERE cpID="+ids[1][0]+" AND childcpID="+ids[3][0])==1,"previous linked to next");
    check(scalar("SELECT retired FROM checkpoints WHERE cpID="+removed)==1,"removed ID retained and retired");
    check(scalar("SELECT finishcpID FROM playerRuns WHERE runID="+completed)==int(finish),"completed finish identity retained");
    check(scalar("SELECT timePlayed FROM checkpointStatistics WHERE runID="+completed+" AND cpID="+finish)==12345,"completed time retained");
    check(scalar("SELECT explosiveJumps FROM checkpointStatistics WHERE runID="+completed+" AND cpID="+finish)==7,"completed RPG result retained");
    check(scalar("SELECT COUNT(*) FROM checkpointStatistics WHERE runID="+completed)==2,"historical checkpoint stats retained");
    check(scalar("SELECT archived+0 FROM playerRuns WHERE runID="+unfinished)==1,"unfinished run archived");
    check(scalar("SELECT archived+0 FROM playerRuns WHERE runID="+completed)==0,"completed run not archived");
    check(scalar("SELECT COUNT(*) FROM playerSaves WHERE runID="+unfinished)==1,"historical saves retained");
    check(scalar("SELECT ready FROM demoRuns WHERE runID="+completed)==2,"old demo excluded");
    check(scalar("SELECT COUNT(*) FROM demoChunks WHERE runID="+completed)==1,"demo payload retained");
    q("ROLLBACK TO SAVEPOINT original_layout");
    editor.cpc.routeHex="invalid";
    check(!(editor openCJ\checkpointPublish::_writeSequentialRoute()),"late failure returned");
    q("ROLLBACK TO SAVEPOINT original_layout");
    check(scalar("SELECT COUNT(*) FROM checkpointAreas WHERE mapID="+level.mapid_mapID)==5,"failed migration restores areas");
    check(scalar("SELECT retired FROM checkpoints WHERE cpID="+removed)==0,"failed migration restores checkpoint");
    check(scalar("SELECT archived+0 FROM playerRuns WHERE runID="+unfinished)==0,"failed migration restores resumable run");
    check(scalar("SELECT ready FROM demoRuns WHERE runID="+completed)==1,"failed migration restores demo availability");
    editor.cpc.routeHex="#ffffff";editor.cpc.rows=original;editor.cpc.rows[2]=row(450,false);
    check(editor openCJ\checkpointPublish::_writeSequentialRoute(),"move checkpoint migration succeeds");
    check(scalar("SELECT cpID FROM checkpointAreas WHERE mapID="+level.mapid_mapID+" AND ordinal=2")==int(removed),"move retains checkpoint ID");
    q("ROLLBACK TO SAVEPOINT original_layout");
    editor.cpc.rows=[];for(i=0;i<3;i++)editor.cpc.rows[i]=original[i];editor.cpc.rows[3]=row(500,false);editor.cpc.rows[4]=original[3];editor.cpc.rows[5]=original[4];
    check(editor openCJ\checkpointPublish::_writeSequentialRoute(),"insert checkpoint migration succeeds");
    check(scalar("SELECT cpID FROM checkpointAreas WHERE mapID="+level.mapid_mapID+" AND ordinal=5")==int(finish),"insertion preserves finish ID");
    q("ROLLBACK TO SAVEPOINT original_layout");
    editor.cpc.rows=original;cp=openCJ\checkpointCreation::_decode(original[2]);cp.alternatives[0]=openCJ\checkpointArea::decode("500,0,0;600,0,0;600,100,0;500,100,0");editor.cpc.rows[2]=openCJ\checkpointCreation::_encode(cp);
    check(editor openCJ\checkpointPublish::_writeSequentialRoute(),"alternative area migration succeeds");
    check(scalar("SELECT COUNT(*) FROM checkpointBrothers WHERE bigBrotherID="+removed)==1,"alternative linked to retained leader");
    q("ROLLBACK TO SAVEPOINT original_layout");
    q("INSERT INTO checkpoints(mapID) VALUES("+level.mapid_mapID+")");external=scalar("SELECT LAST_INSERT_ID()");
    q("INSERT INTO checkpointConnections(cpID,childcpID) VALUES("+removed+","+external+")");
    check(!(editor openCJ\checkpointPublish::_writeSequentialRoute()),"shared route migration refused");
    check(scalar("SELECT COUNT(*) FROM checkpointAreas WHERE mapID="+level.mapid_mapID)==5,"refused route remains unchanged");
    q("ROLLBACK");
    printf("MIGRATION SELFTEST COMPLETE failures="+level.migrationFailures+"\n");
}
q(sql){r=openCJ\mySQL::mysqlSyncQuery(sql);if(!isDefined(r))check(false,"SQL fixture statement failed");return r;}
scalar(sql){r=q(sql);if(!isDefined(r)||!r.size)return -1;return int(r[0][0]);}
row(x,finish){cp=openCJ\checkpointCreation::_empty();cp.points[0]=(x,0,0);cp.points[1]=(x+100,0,0);cp.points[2]=(x+100,100,0);cp.points[3]=(x,100,0);cp.finish=finish;return openCJ\checkpointCreation::_encode(cp);}
check(ok,label){if(!ok){level.migrationFailures++;printf("MIGRATION SELFTEST FAIL "+label+"\n");}else printf("MIGRATION SELFTEST PASS "+label+"\n");}
