main()
{
    wait 2;
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod")return;
    rows=openCJ\mySQL::mysqlAsyncQuery("SELECT runID,frameCount FROM demoRuns WHERE ready=1 ORDER BY frameCount DESC LIMIT 1");
    if(!isDefined(rows) || !rows.size){printf("DEMO LOADING NO FIXTURE\n");return;}
    id=int(rows[0][0]);expected=int(rows[0][1]);
    cache=spawnStruct();cache.loading=true;cache.ready=false;cache.refs=1;
    level.demoCache[""+id]=cache;
    started=getTime();
    openCJ\demos::_loadCache(id,expected);
    ok=cache.ready && !cache.loading && numberOfDemoFrames(id)==expected;
    printf("DEMO LOADING ready="+int(ok)+" frames="+expected+" elapsedMs="+(getTime()-started)+"\n");
    openCJ\demos::releaseCache(id);
}
