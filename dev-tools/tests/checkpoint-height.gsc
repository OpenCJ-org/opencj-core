main()
{
    wait 2;level.brushFailures=0;
    a=area(0,0,100,100,0);b=area(20,20,80,80,40);
    check(!openCJ\checkpointHeight::groupsOverlap(a,b),"separate stacked checkpoints do not overlap by default");
    a.heightAbove=40;
    check(openCJ\checkpointHeight::groupsOverlap(a,b),"expanded height detects stacked checkpoint");
    check(openCJ\checkpointCreation::contains(a,(50,50,40),true),"expanded area triggers on ground");
    check(!openCJ\checkpointCreation::contains(a,(50,50,40),false),"height does not bypass on-ground requirement");
    check(!openCJ\checkpointCreation::contains(a,(50,50,45),true),"upper bound excludes above volume");
    check(openCJ\checkpointCreation::contains(a,(50,50,-2),true),"lower boundary included");
    check(!openCJ\checkpointCreation::contains(a,(50,50,-3),true),"below lower boundary excluded");
    restored=openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(a));
    check(restored.heightAbove==40,"height draft fields roundtrip");
    check(openCJ\checkpointNetwork::sameCheckpoint(a,restored),"network identity includes height");
    restored.heightAbove=44;check(!openCJ\checkpointNetwork::sameCheckpoint(a,restored),"height change is a pending edit");
    old=openCJ\checkpointCreation::_decode("0:0:p0,0,0;100,0,0;100,100,0;0,100,0");
    check(old.heightAbove==0,"old drafts retain zero offsets");
    check(openCJ\checkpointCreation::contains(old,(50,50,4),true) && !openCJ\checkpointCreation::contains(old,(50,50,5),true),"old trigger height unchanged");
    c=area(0,0,100,100,0);c.points[1]=(100,0,20);c.points[2]=(100,100,5);c.points[3]=(0,100,10);
    check(openCJ\checkpointHeight::flatten(c),"curved corners automatically flatten");
    for(i=0;i<c.points.size;i++)check(c.points[i][2]==0,"lowest corner sets base");
    check(c.heightAbove==20,"flattening preserves selected vertical span");
    slope=area(0,0,100,100,0);slope.points[1]=(100,0,25);slope.points[2]=(100,100,25);
    check(!openCJ\checkpointHeight::flatten(slope),"planar slopes stay sloped");
    over=area(20,20,80,80,40);slope.heightAbove=40;
    check(openCJ\checkpointHeight::groupsOverlap(slope,over),"sloped volume overlap detected");
    crossing=area(49,-50,51,150,0);narrow=area(-50,49,150,51,0);
    check(openCJ\checkpointHeight::groupsOverlap(crossing,narrow),"narrow crossing volumes detected");
    adjacent=area(100,0,200,100,0);
    check(!openCJ\checkpointHeight::groupsOverlap(old,adjacent),"touching side boundaries allowed");
    b=area(0,0,100,100,6);
    check(!openCJ\checkpointHeight::groupsOverlap(old,b),"touching vertical boundaries allowed");
    b=area(0,0,100,100,5);
    check(openCJ\checkpointHeight::groupsOverlap(old,b),"positive vertical overlap rejected");
    invalid="0:0:p0,0,0;100,0,0;100,100,0:1:1:0:-:-1";
    check(!isDefined(openCJ\checkpointCreation::_decode(invalid)),"negative draft height rejected");
    p=spawnStruct();p.login_playerID=-9999;p.cpc=spawnStruct();p.cpc.route="test";p.cpc.rows=[];p.cpc.selected=0;
    selected=area(0,0,100,100,0);other=area(20,20,80,80,40);
    p.cpc.rows[0]=openCJ\checkpointCreation::_encode(selected);p.cpc.rows[1]=openCJ\checkpointCreation::_encode(other);p.cpc.draft=selected;
    level.checkpoints_checkpoints=[];
    candidate=openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(selected));candidate.heightAbove=40;
    check(isSubStr(p openCJ\checkpointHeight::conflict(candidate),"checkpoint 2"),"increase is blocked by another draft checkpoint");
    check(selected.heightAbove==0,"rejected proposal leaves original height unchanged");
    candidate.heightAbove=20;check(p openCJ\checkpointHeight::conflict(candidate)=="","safe increase allowed");
    p.cpc.rows[1]=undefined;candidate.heightAbove=40;
    published=spawnStruct();published.area=other.points;published.id=42;published.heightAbove=0;
    level.checkpoints_checkpoints[0]=published;
    check(isSubStr(p openCJ\checkpointHeight::conflict(candidate),"published checkpoint #42"),"increase is blocked by published checkpoint");
    published.area=selected.points;
    check(p openCJ\checkpointHeight::conflict(candidate)=="","editing own published geometry does not collide with itself");
    level.checkpoints_checkpoints=[];
    // Alternate areas of the selected logical checkpoint may still overlap.
    selected.alternatives[0]=other.points;p.cpc.rows[0]=openCJ\checkpointCreation::_encode(selected);
    candidate=openCJ\checkpointCreation::_decode(p.cpc.rows[0]);candidate.heightAbove=40;
    check(p openCJ\checkpointHeight::conflict(candidate)=="","same-checkpoint alternatives remain allowed");
    p.cpc.rows=[];p.cpc.selected=0;p.cpc.draft=area(0,0,100,100,0);
    p openCJ\checkpointHeight::edit("height");check(isDefined(p.cpc.heightTarget),"Num7 enables height editing");
    p openCJ\checkpointHeight::edit("heightup");check(p.cpc.draft.heightAbove==4,"plus raises top four units");
    p openCJ\checkpointHeight::edit("heightdown");check(p.cpc.draft.heightAbove==0,"minus lowers top to original height");
    p.cpc.heightRequestValue=64;p openCJ\checkpointHeight::edit("heightset");
    p openCJ\checkpointHeight::edit("height");check(!isDefined(p.cpc.heightTarget) && p.cpc.draft.heightAbove==64,"Num7 exits editing without resetting height");
    p.cpc.heightTarget="upper";p.cpc.draft=openCJ\checkpointCreation::_empty();
    p openCJ\checkpointHeight::edit("height");check(!isDefined(p.cpc.heightTarget),"height editing can always be disabled after discard");
    p.cpc.draft=area(0,0,100,100,0);p.cpc.draft.heightAbove=64;p.cpc.rows[0]=openCJ\checkpointCreation::_encode(p.cpc.draft);
    p.cpc.path="height-roundtrip";p.cpc.route="test";p.cpc.routeHex="#00ff00";p.cpc.revision=0;
    check(p openCJ\checkpointCreation::_save(),"draft height writes to filesystem");
    saved=openCJ\checkpointCreation::_read("height-roundtrip.b","test");
    check(isDefined(saved) && saved.draft.heightAbove==64,"pending height restores from filesystem");
    restored=openCJ\checkpointCreation::_decode(saved.rows[0]);check(restored.heightAbove==64,"confirmed height restores from filesystem");
    origin=openCJ\checkpointCreation::restoreOrigin(saved);
    check(origin[2]==70,"volume draft resumes above upper boundary instead of inside curved platform");
    printf("BRUSH SELFTEST COMPLETE failures="+level.brushFailures+"\n");
}
area(x1,y1,x2,y2,z)
{
    cp=openCJ\checkpointCreation::_empty();cp.points[0]=(x1,y1,z);cp.points[1]=(x2,y1,z);cp.points[2]=(x2,y2,z);cp.points[3]=(x1,y2,z);return cp;
}
check(value,name)
{
    if(!value){level.brushFailures++;printf("BRUSH SELFTEST FAIL "+name+"\n");}
    else printf("BRUSH SELFTEST PASS "+name+"\n");
}
