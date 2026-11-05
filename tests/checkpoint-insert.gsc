main()
{
    wait 2;level.brushFailures=0;
    p=spawnStruct();p.login_playerID=-9999;p.cpc=spawnStruct();
    p.cpc.route="test";p.cpc.path="insert-test";p.cpc.routeHex="#00ff00";
    p.cpc.revision=0;p.cpc.history=[];p.cpc.testing=false;p.cpc.rows=[];
    a=area(0);b=area(200);b.double=true;b.allowEle=true;b.allowSave=false;
    alt=area(240);b.alternatives[0]=alt.points;
    finish=area(400);finish.finish=true;
    p.cpc.rows[0]=openCJ\checkpointCreation::_encode(a);
    p.cpc.rows[1]=openCJ\checkpointCreation::_encode(b);
    p.cpc.rows[2]=openCJ\checkpointCreation::_encode(finish);
    originalA=p.cpc.rows[0];originalB=p.cpc.rows[1];originalFinish=p.cpc.rows[2];
    p.cpc.selected=0;p.cpc.draft=a;
    check(openCJ\checkpointCreation::nextPreviewIndex(p.cpc)==1,"editing previews next checkpoint");
    check(p openCJ\checkpointCreation::beginInsertion(),"begin insertion after selected checkpoint");
    check(p.cpc.rows.size==3 && p.cpc.rows[1]==originalB,"starting insertion leaves confirmed rows untouched");
    check(p.cpc.selected==3 && p.cpc.insertAfter==0,"pending geometry is outside confirmed rows");
    check(openCJ\checkpointNetwork::pendingEdit(p.cpc),"empty insertion is pending work");
    check(!openCJ\checkpointCreation::readyToFinalize(p.cpc),"empty insertion cannot look ready to finalize");
    check(openCJ\checkpointCreation::nextPreviewIndex(p.cpc)==1,"insertion previews displaced next checkpoint");
    saved=openCJ\checkpointCreation::_read("insert-test.b","test");
    check(isDefined(saved) && saved.insertAfter==0 && saved.rows.size==3,"empty insertion survives draft save and restore");
    p openCJ\checkpointCreation::_action("finish");
    check(p.cpc.draft.finish && p.cpc.rows[2]==originalFinish,"pending properties do not edit last existing checkpoint");
    p.cpc.draft=area(100);
    p.cpc.savedPosition=spawnStruct();p.cpc.savedPosition.origin=(100,10,0);p.cpc.savedPosition.angles=(0,90,0);
    p openCJ\checkpointCreation::_save();
    suffix=".a";if(p.cpc.revision%2)suffix=".b";
    saved=openCJ\checkpointCreation::_read("insert-test"+suffix,"test");
    check(isDefined(saved) && saved.insertAfter==0 && saved.draft.points[0][0]==100 && saved.savedPosition.angles[1]==90,"insertion geometry and manual travel save both roundtrip");
    check(!(p openCJ\checkpointPublish::publish()),"pending insertion cannot publish through direct path");
    p openCJ\checkpointCreation::_action("confirm");
    check(p.cpc.rows.size==4 && p.cpc.rows[0]==originalA && p.cpc.rows[2]==originalB && p.cpc.rows[3]==originalFinish,"confirm shifts suffix intact including properties and alternatives");
    check(!isDefined(p.cpc.insertAfter) && p.cpc.selected==p.cpc.rows.size && p.cpc.draft.points.size==0,"confirm insertion returns to empty new-checkpoint state");
    check(openCJ\checkpointCreation::nextPreviewIndex(p.cpc)>p.cpc.rows.size,"confirmed insertion leaves no editing neighbor selection");
    countAfterFirst=p.cpc.rows.size;
    p openCJ\checkpointCreation::_action("confirm");
    check(p.cpc.rows.size==countAfterFirst && p.cpc.rows[1]!=originalB && p.cpc.rows[2]==originalB,"second Enter does not insert twice or replace successor");
    p openCJ\checkpointCreation::_action("undo");
    check(openCJ\checkpointPublish::validationError(p.cpc.rows)=="","inserted route validates for sequential publication");
    p openCJ\checkpointCreation::_action("undo");
    check(p.cpc.rows.size==3 && p.cpc.insertAfter==0 && p.cpc.draft.points.size==4,"undo confirm restores pending insertion");
    p openCJ\checkpointCreation::_discard();
    check(!isDefined(p.cpc.insertAfter) && p.cpc.rows.size==3 && p.cpc.rows[1]==originalB && p.cpc.selected==0,"discard insertion preserves existing checkpoints");
    p openCJ\checkpointCreation::_action("undo");
    check(p.cpc.insertAfter==0 && p.cpc.rows.size==3,"undo discard restores insertion");
    p openCJ\checkpointCreation::_action("confirm");
    p openCJ\checkpointCreation::_action("undo");
    p openCJ\checkpointCreation::_discard();
    p.cpc.selected=2;p.cpc.draft=finish;
    check(!(p openCJ\checkpointCreation::beginInsertion()),"cannot insert after a finish");
    p.cpc.selected=0;p.cpc.draft=openCJ\checkpointCreation::_decode(p.cpc.rows[0]);p.cpc.draft.double=true;
    check(!(p openCJ\checkpointCreation::beginInsertion()),"pending selected edit must be applied first");
    p.cpc.draft=openCJ\checkpointCreation::_decode(p.cpc.rows[0]);p.cpc.sharedCount=2;
    check(!(p openCJ\checkpointCreation::beginInsertion()),"branch cannot insert inside read-only shared prefix");
    p.cpc.sharedCount=undefined;
    check(p openCJ\checkpointCreation::beginInsertion(),"repeat insertion starts safely");
    p openCJ\checkpointCreation::_action("confirm");
    check(p.cpc.rows.size==3 && isDefined(p.cpc.insertAfter),"invalid geometry does not shift rows");
    p openCJ\checkpointCreation::_discard();
    p.cpc.selected=2;p.cpc.draft=openCJ\checkpointCreation::_decode(p.cpc.rows[2]);
    p openCJ\checkpointCreation::_action("presert");
    check(p.cpc.insertAfter==1,"presert can insert before the finish");
    p.cpc.draft=area(300);p openCJ\checkpointCreation::_action("confirm");
    check(p.cpc.rows.size==4 && p.cpc.rows[3]==originalFinish && p.cpc.rows[1]==originalB,"presert retains finish and earlier checkpoint properties");
    p openCJ\checkpointCreation::_action("undo");p openCJ\checkpointCreation::_discard();
    p.cpc.selected=0;p.cpc.draft=openCJ\checkpointCreation::_decode(p.cpc.rows[0]);
    p openCJ\checkpointCreation::_action("presert");
    check(p.cpc.insertAfter==-1 && openCJ\checkpointCreation::nextPreviewIndex(p.cpc)==0,"presert before first checkpoint has no previous neighbor");
    suffix=".a";if(p.cpc.revision%2)suffix=".b";
    saved=openCJ\checkpointCreation::_read("insert-test"+suffix,"test");
    check(isDefined(saved) && saved.insertAfter==-1,"presert before first checkpoint roundtrips in draft");
    p.cpc.draft=area(-100);p openCJ\checkpointCreation::_action("confirm");
    check(p.cpc.rows.size==4 && p.cpc.rows[1]==originalA && p.cpc.rows[2]==originalB,"presert shifts all original checkpoints intact");
    p openCJ\checkpointCreation::_action("undo");p openCJ\checkpointCreation::_discard();
    check(p.cpc.selected==0 && p.cpc.rows[0]==originalA,"discard before first checkpoint restores valid selection");
    p.cpc.sharedCount=1;
    check(!(p openCJ\checkpointCreation::beginInsertion(true)),"presert protects shared prefix");
    p.cpc.sharedCount=undefined;
    p openCJ\checkpointCreation::_action("postsert");
    check(p.cpc.insertAfter==0,"postsert command preserves insertion-after behavior");
    p openCJ\checkpointCreation::_discard();
    for(i=3;i<256;i++)p.cpc.rows[i]=originalA;
    check(!(p openCJ\checkpointCreation::beginInsertion()),"256 checkpoint limit enforced before insertion");
    printf("BRUSH SELFTEST COMPLETE failures="+level.brushFailures+"\n");
}
area(x)
{
    cp=openCJ\checkpointCreation::_empty();cp.points[0]=(x,0,0);cp.points[1]=(x+20,0,0);cp.points[2]=(x+20,20,0);cp.points[3]=(x,20,0);return cp;
}
check(value,name)
{
    if(!value){level.brushFailures++;printf("BRUSH SELFTEST FAIL "+name+"\n");}
    else printf("BRUSH SELFTEST PASS "+name+"\n");
}
