main()
{
    wait 2;
    level.brushFailures=0;
    a=area(0,100); b=area(80,180); c=area(160,260);
    cp=openCJ\checkpointCreation::_empty();cp.points=a;cp.alternatives[0]=b;cp.alternatives[1]=c;
    p=spawnStruct();p.cpc=spawnStruct();p.cpc.rows=[];p.cpc.route="test";
    p.cpc.rows[0]=openCJ\checkpointCreation::_encode(cp);p.cpc.selected=0;p.cpc.draft=cp;
    level.checkpoints_checkpoints=[];
    check(p openCJ\checkpointCreation::detectedCheckpointWarning(a)=="","own overlapping alternatives do not warn");
    p.cpc.selected=1;
    check(p openCJ\checkpointCreation::detectedCheckpointWarning(a)!="","different logical checkpoint still warns");
    decoded=openCJ\checkpointCreation::_decode(p.cpc.rows[0]);
    check(decoded.alternatives.size==2,"three areas survive serialization");
    first=spawnStruct();first.id=1;first.area=a;first.onGround=true;
    second=spawnStruct();second.id=2;second.area=b;second.onGround=true;second.bigBrother=first;
    third=spawnStruct();third.id=3;third.area=c;third.onGround=true;third.bigBrother=first;
    all=[];all[0]=first;all[1]=second;all[2]=third;
    openCJ\checkpoints::linkContactAreas(all);
    p.checkpoints_passed=[];p.checkpoints_passed[0]=second;
    check(p openCJ\checkpoints::hasPassedCheckpoint(first) && p openCJ\checkpoints::hasPassedCheckpoint(third),"all alternatives count as one progress step");
    p.origin=(90,50,0);
    check(p openCJ\checkpoints::touchesCheckpointGroup(second,true,undefined),"overlapping region belongs to current group");
    p.origin=(240,50,0);
    check(p openCJ\checkpoints::touchesCheckpointGroup(second,true,undefined),"another alternative protects current checkpoint contact");
    check(!(p openCJ\checkpoints::touchesCheckpointGroup(second,false,undefined)),"ground requirement retained");
    p.origin=(300,50,0);
    check(!(p openCJ\checkpoints::touchesCheckpointGroup(second,true,undefined)),"leaving every alternative clears group contact");
    printf("BRUSH SELFTEST COMPLETE failures="+level.brushFailures+"\n");
}
area(x1,x2)
{
    p=[];p[0]=(x1,0,0);p[1]=(x2,0,0);p[2]=(x2,100,0);p[3]=(x1,100,0);return p;
}
check(value,name)
{
    if(!value){level.brushFailures++;printf("BRUSH SELFTEST FAIL "+name+"\n");}
    else printf("BRUSH SELFTEST PASS "+name+"\n");
}
