#include openCJ\util;
main()
{
    level.history175Checks=0;level.history175Failures=0;level.history175Queries=0;level.history175Peak=0;
    expected=getCvar("history175_database");
    if(getSubStr(expected,0,18)!="opencj_verify_175_")return;
    openCJ\mySQL::onInit();openCJ\historySave::onInit();openCJ\savePosition::onInit();
    level.mapid_mapID=1;level.checkpointLayoutEpoch=1;level.clients=[];
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT DATABASE()");
    check(rows[0][0]==expected,"disposable database");
    wait 1;
    for(i=0;i<32;i++)
    {
        p=addTestClient();check(isDefined(p),"client "+i);if(!isDefined(p)){finish();return;}
        level.clients[i]=p;wait .05;
        p.sessionTeam="allies";p.sessionState="playing";p.pers["team"]="allies";
        p spawn((i*30,0,700),(0,0,0));p freezeControls(true);
        p.login_playerID=i+1;p.playingDemo=false;
        p openCJ\playerRuns::setRunIDAndInstanceNumber(1001+i,1);
        p openCJ\savePosition::resetBackwardsCount();
        p savePosition_initClient();
    }
    a=level.clients[0];b=level.clients[1];
    a nativeChecks(b);
    memoryAudit("baseline",level);
    level.history175Pending=32;
    for(i=0;i<32;i++)level.clients[i] thread loadInitial(1001+i);
    waitPending();
    for(i=0;i<32;i++)
    {
        p=level.clients[i];info=p savePosition_historyInfo();
        check(info[0]==50,"initial page "+i);
        check(p savePosition_selectSave(0)==0 && p savePosition_getSaveNum()==160,"actual newest save number "+i);
        check(p savePosition_selectSave(49)==0 && p savePosition_getSaveNum()==numberAt(49),"gaps preserve oldest number "+i);
        origin=p savePosition_getOrigin();check(origin[0]==numberAt(49),"saved coordinates "+i);
        p thread requestOlder();
    }
    waitPages();
    for(i=0;i<32;i++)
    {
        p=level.clients[i];info=p savePosition_historyInfo();
        check(info[0]==100 && info[1]==numberAt(99),"bounded full history "+i);
        check(p savePosition_selectSave(99)==0 && p savePosition_getSaveNum()==numberAt(99),"oldest reachable "+i);
        check(!p openCJ\historySave::maybePrefetch(99),"no fetch past cap "+i);
        check(p openCJ\savePosition::canLoadError(100)==2,"cap is visible to controls "+i);
    }
    check(level.history175Peak<=2,"at most two retained SQL pages");
    check(level.history175Queries==64,"one initial and one older query per client");
    memoryAudit("loaded",level);
    a raceChecks();
    for(i=0;i<32;i++)level.clients[i] savePosition_initClient();
    memoryAudit("released",level);
    check(level.historySavesActive==0,"all read slots released");
    finish();
}
check(ok,message)
{
    level.history175Checks++;
    if(!isDefined(ok) || !ok){level.history175Failures++;printf("H175 FAILURE "+message+"\n");}
}
finish()
{
    printf("H175 COMPLETE "+level.history175Failures+" "+level.history175Checks+" "+level.history175Peak+" "+level.history175Queries+"\n");
}
numberAt(index)
{
    count=0;
    for(n=160;n>=1;n--)
    {
        if(n%17==0)continue;
        if(count==index)return n;
        count++;
    }
    return -1;
}
loadInitial(run)
{
    self savePosition_initClient();
    ok=self openCJ\historySave::_loadSavesFromDatabase(run,1);
    check(ok,"initial SQL/native restore "+run);level.history175Pending--;
}
waitPending()
{
    for(i=0;i<200 && level.history175Pending>0;i++)wait .05;
    check(level.history175Pending==0,"initial requests complete");
}
requestOlder()
{
    for(j=0;j<10;j++)self openCJ\historySave::maybePrefetch(40);
}
waitPages()
{
    for(k=0;k<200;k++)
    {
        pending=level.historySavesActive;
        for(j=0;j<level.clients.size;j++)
            if(isDefined(level.clients[j].historySaves) && level.clients[j].historySaves.loading)pending++;
        if(pending==0)return;
        wait .05;
    }
    check(false,"page requests complete");
}
nativeChecks(other)
{
    for(n=1;n<=140;n++)self savePosition_save((n,0,700),(0,0,0),undefined,0,0,1,5,0,n);
    info=self savePosition_historyInfo();
    check(info[0]==100 && info[1]==41 && info[4]==140,"live saves evict oldest at 100");
    self savePosition_selectSave(99);
    self savePosition_save((141,0,700),(0,0,0),undefined,0,0,1,5,0,141);
    check(!isDefined(self savePosition_getSaveNum()),"evicted selection invalidated safely");
    check(self savePosition_addOlder((0,0,0),(0,0,0),undefined,0,0,1,5,0,40)==1,"older insertion cannot exceed cap");
    check(self savePosition_selectSave(-1)==2,"negative history index rejected");
    other savePosition_selectWithoutFlag(1,self getEntityNumber());
    self savePosition_initClient();
    check(!isDefined(other savePosition_getOrigin()),"cross-player selection cleared on release");
    after=self savePosition_historyInfo();check(after[2]!=info[2],"clear advances history generation");
    self savePosition_addOlder((200,0,0),(0,0,0),undefined,0,0,1,5,0,200);
    self savePosition_selectSave(0);
    self savePosition_addOlder((199,0,0),(0,0,0),undefined,0,0,1,5,0,199);
    check(self savePosition_getSaveNum()==200,"older append preserves selection");
    check(self savePosition_addOlder((199,0,0),(0,0,0),undefined,0,0,1,5,0,199)==2,"duplicate older insertion rejected");
    check(self savePosition_addOlder((201,0,0),(0,0,0),undefined,0,0,1,5,0,201)==2,"newer insertion rejected at older end");
    self savePosition_initClient();
}
resetInitial()
{
    self openCJ\historySave::cancelPendingPage();
    self savePosition_initClient();self.playingDemo=false;self.cpc=undefined;
    level.checkpointLayoutEpoch=1;
    self openCJ\playerRuns::setRunIDAndInstanceNumber(1001,1);
    check(self openCJ\historySave::_loadSavesFromDatabase(1001,1),"reset initial fixture");
}
raceChecks()
{
    self resetInitial();
    // While initial SQL is pending, neither a new save nor a load may mix runs.
    self savePosition_initClient();
    level.history175DelayOwner=1;level.history175Pending=1;
    self thread loadInitial(1001);
    self waittill("history175_result_ready");
    check(self openCJ\savePosition::canSaveError()==4,"initial restore blocks new saves");
    check(self openCJ\savePosition::canLoadError(0)==3,"initial restore blocks position loads");
    waitPending();level.history175DelayOwner=undefined;

    // Hold both read slots, invalidate the queued request, then release them.
    self resetInitial();
    level.historySavesActive=2;
    queries=level.history175Queries;
    self openCJ\historySave::maybePrefetch(40);
    self savePosition_initClient();
    wait .1;
    check(!self.historySaves.loading && level.history175Queries==queries,"stale queued request stops without querying");
    level.historySavesActive=0;

    self resetInitial();
    level.history175DelayOwner=1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    for(n=161;n<=180;n++)self savePosition_save((n,0,700),(0,0,0),undefined,0,0,1,5,0,n);
    waitPages();level.history175DelayOwner=undefined;
    info=self savePosition_historyInfo();
    check(info[0]==100 && info[4]==180 && info[1]==numberAt(79),"new saves during fetch preserve cap and chronology");
    self resetInitial();
    level.history175DelayOwner=1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self notify("disconnect");self savePosition_initClient();
    self savePosition_save((999,0,700),(0,0,0),undefined,0,0,1,5,0,999);
    waitPages();level.history175DelayOwner=undefined;
    info=self savePosition_historyInfo();
    check(info[0]==1 && info[4]==999,"stale page rejected after native reset/disconnect notification");

    self resetInitial();
    level.history175DelayOwner=1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self.runInstanceNumber=2;
    waitPages();level.history175DelayOwner=undefined;
    info=self savePosition_historyInfo();check(info[0]==50,"stale run-instance page rejected");

    self resetInitial();
    level.history175DelayOwner=1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    level.checkpointLayoutEpoch++;
    waitPages();level.history175DelayOwner=undefined;
    info=self savePosition_historyInfo();check(info[0]==50,"stale layout page rejected");

    self resetInitial();
    level.history175DelayOwner=1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self openCJ\historySave::cancelPendingPage();self.playingDemo=true;
    self.playingDemo=false;wait .3;level.history175DelayOwner=undefined;
    info=self savePosition_historyInfo();check(info[0]==50,"mode cancellation rejects reply even after returning");

    self resetInitial();
    level.history175FailOwner=1;
    self openCJ\historySave::maybePrefetch(40);waitPages();
    info=self savePosition_historyInfo();
    check(info[0]==50 && self.historySaves.failed,"failed page preserves loaded history");
    check(!self openCJ\historySave::maybePrefetch(40),"failed page has retry delay");
    level.history175FailOwner=undefined;wait 1.05;
    self openCJ\historySave::maybePrefetch(40);waitPages();
    info=self savePosition_historyInfo();check(info[0]==100 && !self.historySaves.failed,"failed page can retry without duplicates");

    self savePosition_initClient();
    level.history175FailOwner=1;
    check(!self openCJ\historySave::_loadSavesFromDatabase(1001,1),"initial page failure reported");
    info=self savePosition_historyInfo();
    check(info[0]==0 && !isDefined(self.historySaves),"initial page failure clears state");
    level.history175FailOwner=undefined;

    self savePosition_initClient();
    state=self openCJ\historySave::_beginHistory(1001,1);state.initial=false;
    self openCJ\historySave::_startPage(state,11);waitPages();
    info=self savePosition_historyInfo();
    check(info[0]==10 && info[1]==1 && state.exhausted,"short last page stops prefetch");
    check(!self openCJ\historySave::maybePrefetch(9),"exhausted history does not query again");

    self savePosition_initClient();
    state=self openCJ\historySave::_beginHistory(1001,1);state.initial=false;
    self openCJ\historySave::_startPage(state,1);waitPages();
    info=self savePosition_historyInfo();
    check(info[0]==0 && state.exhausted,"empty history stops prefetch");

    self resetInitial();
    level.history175DelayOwner=1;
    self openCJ\historySave::maybePrefetch(40);
    self waittill("history175_result_ready");
    self.savePosition_backwardsCount=50;
    check(self openCJ\savePosition::canLoadError(50)==3,"unloaded boundary reports loading");
    self openCJ\savePosition::printCanLoadError(3);
    check(self openCJ\savePosition::getBackwardsCount()==49,"pending boundary does not skip a position");
    self setOrigin((321,123,700));
    waitPages();level.history175DelayOwner=undefined;
    check(self.origin[0]==321 && self.origin[1]==123,"late page never teleports player");
    self.savePosition_backwardsCount=100;
    self openCJ\savePosition::printCanLoadError(2);
    check(self openCJ\savePosition::getBackwardsCount()==99,"cap keeps navigation bounded");
}
