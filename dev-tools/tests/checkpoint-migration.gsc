main()
{
    wait 2;level.migrationFailures=0;
    old=[];old[0]=row(0,false);old[1]=row(200,false);old[2]=row(400,false);old[3]=row(600,false);old[4]=row(800,true);
    changed=old;changed[2]=row(450,false);
    p=openCJ\checkpointMigration::plan(old,changed);check(isDefined(p)&&p.mapping[2]==2&&p.mapping[4]==4,"move keeps existing IDs and finish");
    removed=[];removed[0]=old[0];removed[1]=old[1];removed[2]=old[3];removed[3]=old[4];
    p=openCJ\checkpointMigration::plan(old,removed);check(isDefined(p)&&p.mapping[2]==3&&p.mapping[3]==4,"deletion matches unchanged suffix");
    p=openCJ\checkpointMigration::plan(removed,old);check(isDefined(p)&&p.mapping[2]==-1&&p.mapping[4]==3,"insertion preserves finish and identifies new checkpoint");
    changed=old;cp=openCJ\checkpointCreation::_decode(changed[2]);cp.alternatives[0]=openCJ\checkpointArea::decode("500,0,0;600,0,0;600,100,0;500,100,0");changed[2]=openCJ\checkpointCreation::_encode(cp);
    check(isDefined(openCJ\checkpointMigration::plan(old,changed)),"alternative area change accepted");
    changed=old;changed[0]=row(50,false);check(!isDefined(openCJ\checkpointMigration::plan(old,changed)),"changed start refused");
    changed=old;changed[4]=row(850,true);check(!isDefined(openCJ\checkpointMigration::plan(old,changed)),"changed finish refused");
    changed=old;changed[1]=old[2];changed[2]=old[1];check(!isDefined(openCJ\checkpointMigration::plan(old,changed)),"reordering refused");
    changed=old;cp=openCJ\checkpointCreation::_decode(changed[2]);cp.allowEle=true;changed[2]=openCJ\checkpointCreation::_encode(cp);check(!isDefined(openCJ\checkpointMigration::plan(old,changed)),"requirement change refused");
    changed=old;changed[1]=row(250,false);changed[3]=row(650,false);check(!isDefined(openCJ\checkpointMigration::plan(old,changed)),"multiple edits refused");
    legacy=[];legacy[0]="0:0:p2483.01,0,0;2583.01,0,0;2583.01,100,0;2483.01,100,0";
    legacy[1]=old[1];legacy[2]=old[2];legacy[3]=old[3];legacy[4]=old[4];
    precise=openCJ\checkpointMigration::canonicalRows(legacy);
    cp=openCJ\checkpointCreation::_decode(precise[2]);cp.alternatives[0]=openCJ\checkpointArea::decode("500,0,0;600,0,0;600,100,0;500,100,0");precise[2]=openCJ\checkpointCreation::_encode(cp);
    p=openCJ\checkpointMigration::plan(legacy,precise);
    check(isDefined(p) && p.mapping[0]==0 && p.mapping[2]==2,"legacy precision does not turn alternative addition into whole-route edits");
    p=openCJ\checkpointMigration::unusedPlan(old,removed);
    check(p.mapping.size==removed.size && p.mapping[0]==0,"unused route preserves start identity during arbitrary replacement");
    printf("MIGRATION SELFTEST COMPLETE failures="+level.migrationFailures+"\n");
}
row(x,finish)
{
    cp=openCJ\checkpointCreation::_empty();cp.points[0]=(x,0,0);cp.points[1]=(x+100,0,0);cp.points[2]=(x+100,100,0);cp.points[3]=(x,100,0);cp.finish=finish;return openCJ\checkpointCreation::_encode(cp);
}
check(ok,label){if(!ok){level.migrationFailures++;printf("MIGRATION SELFTEST FAIL "+label+"\n");}else printf("MIGRATION SELFTEST PASS "+label+"\n");}
