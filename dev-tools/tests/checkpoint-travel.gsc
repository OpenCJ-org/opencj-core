main()
{
 level.fixtureFailures=0;
 wait 2;
 editor=spawnStruct();editor.cpc=spawnStruct();
 editor.cpc.path="checkpoints/tests/travel-persistence";
 editor.cpc.route="travel_selftest";editor.cpc.revision=0;
 editor.cpc.rows=[];editor.cpc.selected=0;editor.cpc.routeHex="#aa55ff";
 editor.cpc.draft=openCJ\checkpointCreation::_empty();
 check(editor openCJ\checkpointCreation::_save(),"write legacy-compatible draft");
 old=openCJ\checkpointCreation::_read(editor.cpc.path+".b",editor.cpc.route);
 check(isDefined(old) && !isDefined(old.savedPosition),"draft without travel still readable");
 editor.cpc.savedPosition=spawnStruct();editor.cpc.savedPosition.origin=(42825.3828,4663.33887,-27877.0723);
 editor.cpc.savedPosition.angles=(12.375,231.125,0);
 check(editor openCJ\checkpointCreation::_save(),"write manual travel position");
 restored=openCJ\checkpointCreation::_read(editor.cpc.path+".a",editor.cpc.route);
 check(isDefined(restored) && isDefined(restored.savedPosition),"travel is read with complete draft");
 if(isDefined(restored) && isDefined(restored.savedPosition))
 {
  check(distanceSquared(restored.savedPosition.origin,editor.cpc.savedPosition.origin)<0.02,"position survives serialization");
  check(distanceSquared(restored.savedPosition.angles,editor.cpc.savedPosition.angles)<0.0001,"view angles survive serialization");
 }
 printf("TRAVEL SELFTEST COMPLETE failures="+level.fixtureFailures+"\n");
}
check(ok,name)
{
 if(ok)printf("TRAVEL PASS "+name+"\n");else {level.fixtureFailures++;printf("TRAVEL FAIL "+name+"\n");}
}
