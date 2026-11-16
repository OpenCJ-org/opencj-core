#include openCJ\util;
main()
{
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod")return;
    for(n=0;n<100 && !level.challengesReady;n++)wait .1;
    check(level.challengesReady,"ready");
    check(getArrayKeys(level.challenges).size==56,"catalogue count");
    check(openCJ\challenges::rankForPoints(0)==1,"initial rank");
    check(openCJ\challenges::rankForPoints(99)==1,"rank boundary below");
    check(openCJ\challenges::rankForPoints(100)==2,"rank boundary exact");
    check(openCJ\challenges::rankForPoints(2299)==9,"rank ten below");
    check(openCJ\challenges::rankForPoints(2300)==10,"rank ten exact");
    check(openCJ\challenges::rankForPoints(2900)==10,"rank capped");
    icons=openCJ\challenges::allowedModeIcons("125,mix",0);
    check(icons.size==2 && icons[0]=="opencj_icon_fps_classic" && icons[1]=="opencj_icon_fps_standard","default allowed mode icons");
    icons=openCJ\challenges::allowedModeIcons("125,mix,hax",15);
    check(icons.size==7 && icons[3]=="opencj_icon_anypct" && icons[4]=="opencj_icon_ele" && icons[5]=="opencj_icon_halfbeat" && icons[6]=="opencj_icon_tas","all allowed mode icons");
    icons=openCJ\challenges::allowedModeIcons("mix",2);
    check(icons.size==2 && icons[1]=="opencj_icon_ele","sparse modes compact without gaps");
    q("START TRANSACTION");
    row=q("SELECT playerID FROM playerInformation LIMIT 1");player=row[0][0];
    q("INSERT IGNORE INTO mapids(mapname) VALUES('mp_dark')");
    row=q("SELECT mapID FROM mapids WHERE mapname='mp_dark'");map=row[0][0];
    q("INSERT INTO checkpoints(mapID,ender) VALUES("+map+",'hard')");
    row=q("SELECT LAST_INSERT_ID()");cp=row[0][0];
    q("DELETE FROM challengeCompletions WHERE playerID="+player);
    q("INSERT INTO playerRuns(playerID,mapID,finishcpID,finishTimeStamp,FPSMode,ele,anyPct,hb,hardTAS) VALUES("+player+","+map+","+cp+",NOW(),'mix',0,0,0,0)");
    row=q("SELECT LAST_INSERT_ID()");id=row[0][0];
    q("INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives) VALUES("+id+","+cp+",1000,3,2,2,99,0)");
    extra="AND r.runID="+id;
    q(openCJ\challenges::awardSQL(extra));
    row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==1,"clean mix accepted");
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==1,"idempotent");
    q("DELETE FROM challengeCompletions WHERE playerID="+player);
    bad=[];bad[0]="anyPct=1";bad[1]="ele=1";bad[2]="hb=1";bad[3]="hardTAS=1";bad[4]="FPSMode='hax'";bad[5]="finishTimeStamp=NULL";
    for(i=0;i<bad.size;i++)
    {
        q("UPDATE playerRuns SET anyPct=0,ele=0,hb=0,hardTAS=0,FPSMode='mix',finishTimeStamp=NOW() WHERE runID="+id);
        q("UPDATE playerRuns SET "+bad[i]+" WHERE runID="+id);
        q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==0,"reject "+bad[i]);
    }
    q("UPDATE playerRuns SET FPSMode='125',finishTimeStamp=NOW() WHERE runID="+id);
    q("UPDATE challenges SET maxTimeMs=1000,maxRPG=2 WHERE challengeKey='dark.hard'");
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==1,"125 exact time and RPG jumps ignores shots");
    q("DELETE FROM challengeCompletions WHERE playerID="+player);
    q("UPDATE challenges SET maxTimeMs=999 WHERE challengeKey='dark.hard'");
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==0,"time bound");
    q("UPDATE challenges SET maxTimeMs=1000,maxRPG=1 WHERE challengeKey='dark.hard'");
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==0,"RPG bound");
    q("UPDATE challenges SET maxRPG=2,routeName=NULL WHERE challengeKey='dark.hard'");
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==0,"unlinked excluded");
    q("UPDATE challenges SET routeName='hard' WHERE challengeKey='dark.hard'");
    q("INSERT INTO challenges(challengeKey,tier,points,mapName,routeLabel,routeName,maxTimeMs) VALUES('test.timed',10,100,'mp_dark','Hard','hard',1000)");
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==2,"regular and timed awarded together");
    q("DELETE FROM challengeCompletions WHERE playerID="+player);
    q("UPDATE challenges SET requiredModes=1,allowedModes=1 WHERE challengeKey IN ('dark.hard','test.timed')");
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==0,"required mode absent");
    q("UPDATE playerRuns SET anyPct=1 WHERE runID="+id);
    q(openCJ\challenges::awardSQL(extra));row=q("SELECT COUNT(*) FROM challengeCompletions WHERE playerID="+player);check(int(row[0][0])==2,"explicit allowed and required mode");
    q("ROLLBACK");
    printf("CHALLENGES TEST COMPLETE\n");
}
q(sql){return openCJ\mySQL::mysqlSyncQuery(sql);}
check(value,label){if(value)printf("CHALLENGES PASS "+label+"\n");else printf("CHALLENGES FAIL "+label+"\n");}
