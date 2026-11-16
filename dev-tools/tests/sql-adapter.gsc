// Exercise production menu cancellation and structured outcomes in the VM.
run(a,b)
{
    a.sqlRendered=0;a.sqlNewest=0;
    a thread render("old",0.3);
    wait 0.10;
    a thread render("new",0.01);
    wait 0.5;
    check(a.sqlRendered==1 && a.sqlNewest==1,"new menu request cancels stale callback");
    a.sqlRendered=0;
    a thread render("closed",0.3);
    wait 0.10;
    a openCJ\mySQL::cancelMenuReads();
    wait 0.4;
    check(a.sqlRendered==0,"closing menu prevents late render");
    a.sqlRendered=0;
    a thread render("old-menu",0.3);
    wait 0.10;
    a thread render("new",0.1,"clips");
    wait 0.08;
    a openCJ\mySQL::cancelMenuReads("opencj_leaderboard");
    wait 0.4;
    check(a.sqlRendered==1,"late close of old menu does not cancel the new menu");
    a.sqlRendered=0;
    a thread render("disconnect",0.3);
    wait 0.10;
    // Same production hook used immediately before disconnect.
    a openCJ\mySQL::cancelMenuReads();
    a notify("disconnect");
    wait 0.4;
    check(a.sqlRendered==0,"disconnect prevents stale menu callback");
    result=openCJ\mySQL::_request("SELECT * FROM no_adapter_fixture",1,"","",10000,true);
    check(result.status==1 && !isDefined(result.rows) && result.error!=0,"GSC receives explicit SQL failure metadata");
    result=openCJ\mySQL::_request("SELECT 1",1,"","",10000,true);
    check(result.status==0 && result.rows[0][0]=="1","GSC receives successful rowset and outcome");
    stats=mysql_async_stats();
    check(stats[0]==4 && stats[4]==0,"four workers and no uncollected GSC jobs");
}
render(label,delay,menu)
{
    if(!isDefined(menu))menu="board";
    token=self openCJ\mySQL::beginMenuRead(menu);
    if (!self openCJ\mySQL::menuReadCurrent(token)) return;
    rows=self openCJ\mySQL::mysqlAsyncMenuQuery("SELECT SLEEP("+delay+"),1",menu);
    if(!isDefined(rows))return;
    self.sqlRendered++;
    if(label=="new")self.sqlNewest=1;
}
check(value,label) { openCJ\history192Test::check(value,label); }

queueForMapChange()
{
    openCJ\mySQL::mysqlSyncQuery("CREATE TABLE adapter_map_probe(id INT) ENGINE=InnoDB");
    id=mysql_async_submit("INSERT INTO adapter_map_probe SELECT 1 FROM (SELECT SLEEP(1)) a",0,"run:map","",10000,1);
    menu=mysql_async_submit("SELECT SLEEP(1),1",3,"","p:99:board",10000,1);
    check(id>0 && menu>0,"map-change fixtures admitted before transition");
    stats=mysql_async_stats();
    setCvar("sql_adapter_accepted",stats[8]);
    setCvar("sql_adapter_checks",level.history192Checks);
    setCvar("sql_adapter_failures",level.history192Failures);
    setCvar("sql_adapter_stage",1);
    printf("SQLPOOL_MAP_READY\n");
    level waittill("sql_adapter_unreachable");
}
afterMap()
{
    level.history192Checks=int(getCvar("sql_adapter_checks"));
    level.history192Failures=int(getCvar("sql_adapter_failures"));
    openCJ\mySQL::onInit();
    stored=false;
    for(i=0;i<60;i++)
    {
        rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM adapter_map_probe");
        if(isDefined(rows) && int(rows[0][0])==1){stored=true;break;}
        wait 0.05;
    }
    check(stored,"accepted write persists through an actual engine map change");
    wait 1.1;
    stats=mysql_async_stats();
    check(stats[0]==4 && stats[8]>=int(getCvar("sql_adapter_accepted")),"actual map change preserves permanent worker pool");
    check(stats[4]==0,"old-map requests/results cleaned after actual map change");
    openCJ\history192Test::finish();
}
