// Isolated engine fixture; no database, player drafts or live map state.
main()
{
    wait 2;
    level.brushFailures=0;
    platform=getEnt("yellow","targetname");
    check(isDefined(platform),"mp_qube real moving platform exists");
    if (!isDefined(platform)) return;
    key=openCJ\checkpointMoving::reference(platform);
    check(isDefined(key),"stable brush reference created");
    if (!isDefined(key)) return;
    check(openCJ\checkpointMoving::resolve(key)==platform,"reference resolves exact platform");
    cp=openCJ\checkpointCreation::_empty();cp.platformRef=key;
    cp.points=openCJ\checkpointMoving::points(cp);
    check(cp.points.size==4,"whole platform visual bounds");
    check(openCJ\checkpointMoving::valid(cp)=="","moving checkpoint validates");
    cp.allowEle=true;cp.allowSave=false;cp.finish=true;
    encoded=openCJ\checkpointCreation::_encode(cp);
    decoded=openCJ\checkpointCreation::_decode(encoded);
    check(isDefined(decoded) && decoded.platformRef==key && decoded.allowEle && !decoded.allowSave && decoded.finish,"draft roundtrip preserves reference and requirements");
    player=spawnStruct();
    check(player openCJ\checkpointMoving::touches(cp,true,platform),"ground entity contact accepted");
    check(!(player openCJ\checkpointMoving::touches(cp,false,platform)),"airborne contact rejected");
    check(!(player openCJ\checkpointMoving::touches(cp,true,undefined)),"world contact rejected");
    other=getEnt("yellow1","targetname");
    check(!(player openCJ\checkpointMoving::touches(cp,true,other)),"other moving platform rejected");
    check(!player openCJ\checkpoints::contactReady(cp,true,1000),"initial contact does not pass");
    check(!player openCJ\checkpoints::contactReady(cp,true,1050),"short bunnyhop does not pass");
    check(!player openCJ\checkpoints::contactReady(cp,false,1100),"airborne clears dwell");
    check(!player openCJ\checkpoints::contactReady(cp,true,1150),"new landing restarts dwell");
    player openCJ\checkpoints::contactReady(cp,true,1200);
    player openCJ\checkpoints::contactReady(cp,true,1250);
    check(player openCJ\checkpoints::contactReady(cp,true,1300),"settled landing passes");
    stationary=openCJ\checkpointCreation::_empty();stationary.points=cp.points;
    check(!openCJ\checkpointNetwork::areaOverlap(cp,stationary,stationary.points),"moving over stationary floor is not shared geometry");
    check(openCJ\checkpointNetwork::areaOverlap(cp,decoded,decoded.points),"same moving platform is shared geometry");
    before=openCJ\checkpointMoving::center(cp);
    start=platform.origin;angles=platform.angles;
    platform moveTo(start+(100,50,25),0.2);
    platform waittill("movedone");
    after=openCJ\checkpointMoving::center(cp);
    check(distance(after,before+(100,50,25))<0.1,"indicator follows actual translation");
    platform rotateTo(angles+(0,90,0),0.2);
    platform waittill("rotatedone");
    p=openCJ\checkpointMoving::points(cp);
    check(distance(p[0],p[1])>0 && abs(distance(p[0],p[1])-distance(cp.points[0],cp.points[1]))<0.1,"rotation preserves bounds dimensions");
    check(openCJ\checkpointMoving::resolve(key)==platform,"identity unchanged by movement");
    level.checkpointMovingCache=undefined;
    check(openCJ\checkpointMoving::resolve(key)==platform,"saved key resolves without cached entity slot");
    check(openCJ\checkpointCreation::_encode(decoded)==encoded,"movement does not rewrite persisted geometry");
    missing=openCJ\checkpointCreation::_empty();missing.platformRef="b999999";missing.points=cp.points;
    check(openCJ\checkpointMoving::valid(missing)!="","missing entity fails validation");
    check(!(player openCJ\checkpointMoving::touches(missing,true,platform)),"missing entity never awards checkpoint");
    printf("BRUSH SELFTEST COMPLETE failures="+level.brushFailures+"\n");
}
check(value,name)
{
    if(!value){level.brushFailures++;printf("BRUSH SELFTEST FAIL "+name+"\n");}
    else printf("BRUSH SELFTEST PASS "+name+"\n");
}
