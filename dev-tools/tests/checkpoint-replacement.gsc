main()
{
    wait 2;
    level.replacementFailures=0;
    p=spawnStruct();p.cpc=spawnStruct();
    p.cpc.rows=[];p.cpc.history=[];p.cpc.testing=false;p.cpc.revision=0;
    p.cpc.route="replacement_test";p.cpc.routeHex="#ff7777";
    p.cpc.path="replacement_test";
    a=area(0);b=area(200);c=area(400);c.finish=true;
    b.alternatives[0]=area(600).points;
    b.double=true;b.allowEle=true;b.allowSave=false;b.onGround=false;
    p.cpc.rows[0]=openCJ\checkpointCreation::_encode(a);
    p.cpc.rows[1]=openCJ\checkpointCreation::_encode(b);
    p.cpc.rows[2]=openCJ\checkpointCreation::_encode(c);
    original=p.cpc.rows[1];before=p.cpc.rows[0];after=p.cpc.rows[2];
    p.cpc.selected=1;p.cpc.draft=openCJ\checkpointCreation::_decode(original);
    p openCJ\checkpointCreation::_action("replace");
    check(p.cpc.selected==1 && p.cpc.rows.size==3,"replacement keeps route position");
    check(p.cpc.rows[1]==original && p.cpc.rows[0]==before && p.cpc.rows[2]==after,"confirmed route untouched before Apply");
    check(p.cpc.draft.points.size==0 && p.cpc.draft.alternatives.size==0,"all old geometry cleared from pending selection");
    check(openCJ\checkpointNetwork::pendingEdit(p.cpc),"empty replacement remains pending");
    restored=openCJ\checkpointCreation::_read(p.cpc.path+".b",p.cpc.route);
    check(isDefined(restored)&&restored.selected==1&&restored.draft.points.size==0&&restored.rows[1]==original,"autosave retains pending replacement and confirmed row");
    p openCJ\checkpointCreation::_action("undo");
    check(openCJ\checkpointCreation::_encode(p.cpc.draft)==original && p.cpc.selected==1,"Undo restores multi-area selection");
    p openCJ\checkpointCreation::_action("area");
    p openCJ\checkpointCreation::_action("deletearea");
    check(p.cpc.draft.alternatives.size==0 && distanceSquared(p.cpc.draft.points[0],b.points[0])==0,"delete area removes cycled alternative only");
    check(p.cpc.rows[1]==original && p.cpc.rows.size==3,"area deletion waits for Apply");
    p openCJ\checkpointCreation::_action("deletearea");
    check(p.cpc.selected==1 && p.cpc.draft.points.size==0,"last area removal keeps replacement slot");
    p.cpc.draft.points=area(800).points;
    p openCJ\checkpointCreation::_action("confirm");
    cp=openCJ\checkpointCreation::_decode(p.cpc.rows[1]);
    check(p.cpc.rows.size==3 && p.cpc.rows[0]==before && p.cpc.rows[2]==after,"Apply preserves predecessor successor and route count");
    check(cp.alternatives.size==0 && distanceSquared(cp.points[0],(800,0,0))==0,"Apply replaces middle checkpoint with single new area");
    check(cp.double&&cp.allowEle&&!cp.allowSave&&!cp.onGround,"requirements preserved");
    p openCJ\checkpointCreation::_action("undo");
    check(p.cpc.rows[1]==original && p.cpc.selected==1,"Undo Apply restores original linked checkpoint");
    p.cpc.sharedCount=2;
    p openCJ\checkpointCreation::_action("replace");
    check(p.cpc.draft.points.size==4,"legacy shared opening protected");
    p.cpc.sharedCount=undefined;p.cpc.selected=p.cpc.rows.size;p.cpc.draft=openCJ\checkpointCreation::_empty();
    check(!openCJ\checkpointNetwork::pendingEdit(p.cpc),"empty append slot is not pending");
    p openCJ\checkpointCreation::_action("replace");
    check(p.cpc.rows.size==3 && p.cpc.selected==3,"replace requires existing checkpoint");
    p.cpc.selected=1;p.cpc.draft=openCJ\checkpointCreation::_decode(original);
    p openCJ\checkpointCreation::_action("discard");
    check(p.cpc.rows.size==2 && p.cpc.rows[0]==before && p.cpc.rows[1]==after,"Discard deletes selected middle checkpoint and retains finish");
    cp=openCJ\checkpointCreation::_decode(p.cpc.rows[1]);check(cp.finish,"finish marker survives selected discard");
    p openCJ\checkpointCreation::_action("undo");
    check(p.cpc.rows.size==3 && p.cpc.rows[1]==original && p.cpc.selected==1,"Undo restores selected discard and its links");
    p.cpc.sharedCount=2;p.cpc.selected=0;p.cpc.draft=openCJ\checkpointCreation::_decode(before);
    p openCJ\checkpointCreation::_action("discard");
    check(p.cpc.rows.size==3 && p.cpc.rows[2]==after,"selected shared opening cannot be discarded");
    p.cpc.sharedCount=undefined;p.cpc.selected=3;p.cpc.draft=area(900);
    p openCJ\checkpointCreation::_action("discard");
    check(p.cpc.rows.size==3 && p.cpc.rows[2]==after && p.cpc.draft.points.size==0,"Discard new geometry preserves finish");
    printf("REPLACEMENT SELFTEST COMPLETE failures="+level.replacementFailures+"\n");
}
area(x)
{
    cp=openCJ\checkpointCreation::_empty();cp.points[0]=(x,0,0);cp.points[1]=(x+100,0,0);cp.points[2]=(x+100,100,0);cp.points[3]=(x,100,0);return cp;
}
check(ok,label)
{
    if(!ok){level.replacementFailures++;printf("REPLACEMENT SELFTEST FAIL "+label+"\n");}
    else printf("REPLACEMENT SELFTEST PASS "+label+"\n");
}
