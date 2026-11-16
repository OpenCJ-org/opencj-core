// Called only by the isolated, database-free timeline harness.
run()
{
    level.demoSelectionChecks=0;
    level.demoCache=[];
    cp=spawnStruct();cp.id=17;cp.origin=(0,0,100);cp.radius=100;cp.onGround=false;
    cp.hasChildren=true;cp.endCheckpoints=[];
    easy=spawnStruct();easy.finishRouteID=11;hard=spawnStruct();hard.finishRouteID=12;
    cp.endCheckpoints[0]=easy;cp.endCheckpoints[1]=hard;
    sibling=spawnStruct();sibling.id=19;sibling.origin=cp.origin;sibling.radius=100;
    sibling.onGround=false;sibling.bigBrother=cp;
    stale=spawnStruct();stale.id=99;
    level.checkpoints_checkpoints=[];level.checkpoints_checkpoints[0]=cp;level.checkpoints_checkpoints[1]=sibling;
    self setOrigin(cp.origin);self.route="unrelated";self.checkpoints_checkpoint=stale;
    location=self openCJ\demos::selectionLocation();
    check(location.checkpoints.size==1,"overlapping pieces normalize to one checkpoint");
    check(isDefined(location.routes["11"]) && isDefined(location.routes["12"]),"shared checkpoint includes both routes");
    check(!isDefined(location.routes["unrelated"]),"stale route is excluded");
    check(self.route=="unrelated" && self.checkpoints_checkpoint==stale,"location lookup preserves progress");

    ids=[];rows=[];
    for(i=0;i<4;i++)
    {
        id=1800000100+i;ids[i]=id;
        count=60;if(i==1)count=20;if(i==3)count=40;
        origin=(0,0,100);if(i==0)origin=(3000,0,100);
        makeRecording(id,count,origin,i==1);
        cache=spawnStruct();cache.loading=false;cache.ready=true;cache.refs=1;
        level.demoCache[""+id]=cache; // Fixture owns a reference throughout.
        row=[];row[0]=""+id;row[1]="0";row[2]=""+count;rows[i]=row;
    }
    check(!isDefined(openCJ\demos::segmentAtLocation(ids[0],0,1,location)),"wrong setup is rejected despite matching checkpoint ID");
    range=openCJ\demos::segmentAtLocation(ids[1],0,1,location);
    check(range[2]==1 && range[3]==20,"segment reports its own shots and sample count");
    selected=self openCJ\demos::selectCandidate(rows,location,"walkthrough");
    check(isDefined(selected) && selected.id==ids[3],"shared walkthrough prefers no RPG then shorter local segment");
    check(!isDefined(self.demoPendingId) && self.demoSelectionId==ids[3],"selected cache reference is retained without a pending load");
    check(level.demoCache[""+ids[0]].refs==1 && level.demoCache[""+ids[1]].refs==1 && level.demoCache[""+ids[2]].refs==1,"rejected candidates release their references");
    check(level.demoCache[""+ids[3]].refs==2,"selected candidate is not loaded twice or prematurely freed");
    self openCJ\demos::releaseSelection();
    check(level.demoCache[""+ids[3]].refs==1,"selection release returns cache to fixture owner");
    selected=self openCJ\demos::selectCandidate(rows,location,"speedrun");
    check(selected.id==ids[1],"speedrun picks first matching time-ranked recording even when it uses RPG");
    self openCJ\demos::releaseSelection();
    selected=self openCJ\demos::selectCandidate(rows,location,"lowrpg");
    check(selected.id==ids[1],"low-RPG preserves the database winner ordering");
    self openCJ\demos::releaseSelection();

    self setOrigin((10,0,100));level.checkpoints_checkpoints=[];
    nearby=self openCJ\demos::selectionLocation();
    check(nearby.checkpoints.size==0 && nearby.routes.size==0,"outside checkpoint does not inherit stale route");
    selected=self openCJ\demos::selectCandidate(rows,nearby,"speedrun");
    check(selected.id==ids[1],"speedrun finds nearby spatial segment without checkpoint or route");
    self openCJ\demos::releaseSelection();
    nearby.origin=(50000,0,100);
    selected=self openCJ\demos::selectCandidate(rows,nearby,"speedrun");
    check(!isDefined(selected) && !isDefined(self.demoPendingId) && !isDefined(self.demoSelectionId),"no nearby passage leaves no selected recording or reference");
    check(!isDefined(demoFindSegment(ids[1],0,nearby.origin,1,0,1)),"strict Any% rejects whole-route fallback");
    range=demoFindSegment(ids[1],0,nearby.origin,1,0);
    check(isDefined(range) && range[0]==0 && range[1]==19,"legacy callers retain their explicit fallback");

    self.demoSelectionId=ids[2];level.demoCache[""+ids[2]].refs++;
    self.demoPendingId=ids[3];level.demoCache[""+ids[3]].refs++;
    self openCJ\demos::cancelRequest();
    check(!isDefined(self.demoPendingId) && !isDefined(self.demoSelectionId),"cancellation releases both held candidates");
    check(level.demoCache[""+ids[2]].refs==1 && level.demoCache[""+ids[3]].refs==1,"cancellation preserves other cache owners");
    failed=spawnStruct();failed.loading=false;failed.ready=false;failed.refs=0;
    level.demoCache["1800000110"]=failed;
    check(!self openCJ\demos::acquireCache(1800000110,20),"failed recording is skipped");
    check(!isDefined(level.demoCache["1800000110"]) && !isDefined(self.demoPendingId),"failed recording releases cache reference");
    check(self.route=="unrelated" && self.checkpoints_checkpoint==stale,"selection and cancellation never mutate progress");
    for(i=0;i<ids.size;i++)openCJ\demos::releaseCache(ids[i]);

    id=1800000111;createDemo(id);
    for(i=0;i<30;i++)
    {
        addFrameToDemo(id,(0,0,100),(0,0,0),1,8192,0,0,int(i==5),125,17);
        if(i==9)demoMarkFailedSince(id,0);
    }
    range=demoFindSegment(id,17,(0,0,100),0,1,1);
    check(range[2]==0 && range[3]==20,"walkthrough ranking excludes failed-attempt shots and samples");
    range=demoFindSegment(id,17,(0,0,100),0,0,1);
    check(range[2]==1 && range[3]==30,"speedrun keeps failed-attempt shots and samples");
    destroyDemo(id);
    // Emit actual production queries for execution against SQL fixture tables.
    printf("DEMO SELECTION QUERY walkthrough "+openCJ\demos::candidateQuery(location,"walkthrough","hax",15,7)+"\n");
    printf("DEMO SELECTION QUERY speedrun "+openCJ\demos::candidateQuery(location,"speedrun","mix",4,7)+"\n");
    printf("DEMO SELECTION QUERY lowrpg "+openCJ\demos::candidateQuery(location,"lowrpg","mix",0,7)+"\n");
    nearby.origin=(0,0,100);
    printf("DEMO SELECTION QUERY nearby "+openCJ\demos::candidateQuery(nearby,"speedrun","mix",0,7)+"\n");
    printf("DEMO SELECTION COMPLETE checks="+level.demoSelectionChecks+"\n");
}
makeRecording(id,count,origin,rpg)
{
    createDemo(id);
    for(i=0;i<count;i++)
        addFrameToDemo(id,origin,(0,0,0),1,8192,0,0,int(rpg && i==5),125,17);
}
check(ok,label)
{
    level.demoSelectionChecks++;
    if(!ok){level.demoTimelineFailures++;printf("DEMO SELECTION FAIL: "+label+"\n");}
}
