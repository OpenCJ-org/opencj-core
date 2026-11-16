#include openCJ\util;

// Record announcements compare exact categories. Broader leaderboard filters
// must never turn an any% result into an improvement over a checkpoint run.
finishQuery(runID)
{
    // Reuse eligible rows; only each scope/metric winner is needed.
    return "WITH finished AS ( " +
        "SELECT r.runID,r.playerID,r.mapID,r.FPSMode,r.ele,r.anyPct,r.hb,r.hardTAS,c.finishRouteID AS routeID,route.routeName,s.timePlayed,s.explosiveJumps,p.playerName  " +
        "FROM playerRuns r  " +
        "JOIN checkpoints c ON c.cpID=r.finishcpID  " +
        "AND c.retired=0  " +
        "JOIN routes route ON route.routeID=c.finishRouteID  " +
        "JOIN checkpointStatistics s ON s.runID=r.runID  " +
        "AND s.cpID=r.finishcpID  " +
        "JOIN playerDisplayNames p ON p.playerID=r.playerID  " +
        "WHERE r.runID=" + runID + "  " +
        "AND r.finishTimeStamp IS NOT NULL), eligible AS ( " +
        "SELECT r.runID,r.playerID,s.timePlayed,s.explosiveJumps  " +
        "FROM finished f  " +
        "JOIN playerRuns r ON r.mapID=f.mapID  " +
        "AND r.FPSMode=f.FPSMode  " +
        "AND r.ele=f.ele  " +
        "AND r.anyPct=f.anyPct  " +
        "AND r.hb=f.hb  " +
        "AND r.hardTAS=f.hardTAS  " +
        "JOIN checkpoints c ON c.cpID=r.finishcpID  " +
        "AND c.finishRouteID=f.routeID  " +
        "AND c.retired=0  " +
        "JOIN checkpointStatistics s ON s.runID=r.runID  " +
        "AND s.cpID=r.finishcpID  " +
        "WHERE r.finishTimeStamp IS NOT NULL  " +
        "AND r.runID<>f.runID) " +
        ", " +
        "prior AS ( " +
        "(SELECT /*+ NO_MERGE(e) */ 0 AS scope,0 AS metric,e.timePlayed,e.explosiveJumps FROM eligible e ORDER BY e.timePlayed,e.explosiveJumps,e.runID LIMIT 1) " +
        "UNION ALL " +
        "(SELECT /*+ NO_MERGE(e) */ 0 AS scope,1 AS metric,e.timePlayed,e.explosiveJumps FROM eligible e ORDER BY e.explosiveJumps,e.timePlayed,e.runID LIMIT 1) " +
        "UNION ALL " +
        "(SELECT /*+ NO_MERGE(e) */ 1 AS scope,0 AS metric,e.timePlayed,e.explosiveJumps FROM eligible e JOIN finished f ON e.playerID=f.playerID ORDER BY e.timePlayed,e.explosiveJumps,e.runID LIMIT 1) " +
        "UNION ALL " +
        "(SELECT /*+ NO_MERGE(e) */ 1 AS scope,1 AS metric,e.timePlayed,e.explosiveJumps FROM eligible e JOIN finished f ON e.playerID=f.playerID ORDER BY e.explosiveJumps,e.timePlayed,e.runID LIMIT 1) " +
        ") " +
        ", boards AS (SELECT 0 AS scope,0 AS metric UNION ALL SELECT 0,1 UNION ALL SELECT 1,0 UNION ALL SELECT 1,1) " +
        "SELECT b.scope,b.metric,f.routeName,f.FPSMode,f.ele,f.anyPct,f.hb,f.hardTAS,f.timePlayed,f.explosiveJumps, " +
        "old.timePlayed,old.explosiveJumps,f.playerName,f.playerID,f.runID FROM finished f CROSS JOIN boards b " +
        "LEFT JOIN prior old ON old.scope=b.scope AND old.metric=b.metric ORDER BY b.scope,b.metric ";
}
category(fps,ele,any,hb,tas)
{
    label="Standard FPS";
    if(fps=="125")label="125 FPS";
    if(fps=="hax")label="Any FPS";
    if(any)label+=", any%";
    else label+=", checkpoints";
    if(ele)label+=", elevators";
    if(hb)label+=", halfbeat";
    if(tas)label+=", TAS";
    return label;
}
improvement(row)
{
    if(!isDefined(row[10]) || !isDefined(row[11]))return ""; // First finish is not a beaten record.
    time=int(row[8]);rpg=int(row[9]);oldTime=int(row[10]);oldRpg=int(row[11]);
    if(int(row[1])==0)
    {
        if(time<oldTime)return "time: "+formatTimeString(oldTime-time,false)+" faster";
        if(time==oldTime && rpg<oldRpg)return "time: tied, "+(oldRpg-rpg)+" fewer RPGs";
    }
    else
    {
        if(rpg<oldRpg)return "RPGs: "+(oldRpg-rpg)+" fewer";
        if(rpg==oldRpg && time<oldTime)return "RPGs: tied, "+formatTimeString(oldTime-time,false)+" faster";
    }
    return "";
}
details(rows,scope)
{
    result="";
    for(i=0;i<rows.size;i++)
    {
        if(int(rows[i][0])!=scope)continue;
        part=improvement(rows[i]);
        if(part=="")continue;
        if(result!="")result+="; ";
        result+=part;
    }
    return result;
}
onRunFinished(runID)
{
    self endon("disconnect");
    if(isDefined(self.notificationFinishedRun) && self.notificationFinishedRun==runID)return;
    self.notificationFinishedRun=runID;
    owner=self openCJ\login::getPlayerID();
    rows=self openCJ\mySQL::mysqlAsyncRead(finishQuery(runID));
    if(!isDefined(rows) || rows.size!=4 || rows[0].size!=15)return;
    if(int(rows[0][13])!=owner || int(rows[0][14])!=runID)return;
    label=category(rows[0][3],int(rows[0][4]),int(rows[0][5]),int(rows[0][6]),int(rows[0][7]));
    route=rows[0][2]+" ["+label+"]";
    server=details(rows,0);
    personal=details(rows,1);
    if(server!="" || personal!="")self openCJ\notifications::result("record",runID);
    if(server!="")iprintln(rows[0][12]+"^7 | "+route+" | ^2Server record: ^7"+server);
    if(personal!="" && self openCJ\login::getPlayerID()==owner)
        self iprintln(route+" | ^2Personal best: ^7"+personal);
}
checkpointQuery(runID,cpID,fps,ele,any,hb,tas,metric)
{
    sort="cs.timePlayed,cs.explosiveJumps";
    if(metric=="rpgs")sort="cs.explosiveJumps,cs.timePlayed";
    return "SELECT cs.timePlayed,cs.explosiveJumps FROM checkpointStatistics cs STRAIGHT_JOIN playerRuns r ON r.runID=cs.runID "+
        "WHERE cs.cpID="+cpID+" AND r.runID<>"+runID+" AND r.finishTimeStamp IS NOT NULL "+
        "AND r.FPSMode="+dbStr(fps)+" AND r.ele="+int(ele)+" AND r.anyPct="+int(any)+" AND r.hb="+int(hb)+" AND r.hardTAS="+int(tas)+
        " ORDER BY "+sort+",cs.runID LIMIT 1";
}
checkpoint(runID,cpID,timePlayed)
{
    self endon("disconnect");
    self openCJ\notifications::cancelCheckpoint();
    self endon("notificationCheckpointStop");
    self openCJ\notifications::action("checkpoint");
    if(!self openCJ\notifications::wantsText("checkpoint"))return;
    instance=self openCJ\playerRuns::getRunInstanceNumber();epoch=level.checkpointLayoutEpoch;
    fps=self openCJ\fps::getCurrentFPSMode();ele=self openCJ\elevate::hasUsedEle();
    any=self openCJ\anyPct::hasAnyPct();hb=self openCJ\halfBeat::isHalfBeatAllowed();tas=self openCJ\tas::hasHardTAS();
    rpg=self openCJ\statistics::getExplosiveJumps();
    sort=self openCJ\settings::getSetting("lbsort");metric="time";
    if(isDefined(sort)){parts=strTok(sort,":");if(parts[0]=="rpgs")metric="rpgs";}
    rows=self openCJ\mySQL::mysqlAsyncRead(checkpointQuery(runID,cpID,fps,ele,any,hb,tas,metric));
    if(self openCJ\playerRuns::getRunID()!=runID || self openCJ\playerRuns::getRunInstanceNumber()!=instance ||
       level.checkpointLayoutEpoch!=epoch || self openCJ\demos::isPlayingDemo() || !self openCJ\notifications::wantsText("checkpoint"))return;
    message="Checkpoint passed";
    if(isDefined(rows) && rows.size && rows[0].size==2)
    {
        if(metric=="rpgs")
        {
            diff=rpg-int(rows[0][1]);
            if(diff<0)message+=" | ^2"+(0-diff)+" fewer RPGs";
            else if(diff>0)message+=" | ^1"+diff+" more RPGs";
            else message+=" | same RPG count";
        }
        else
        {
            diff=timePlayed-int(rows[0][0]);
            if(diff<0)message+=" | ^2"+formatTimeString(0-diff,false)+" ahead";
            else if(diff>0)message+=" | ^1"+formatTimeString(diff,false)+" behind";
            else message+=" | same split time";
        }
    }
    self iprintln(message);
}
