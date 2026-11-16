main()
{
 wait 2;
 cp=openCJ\checkpointCreation::_empty();
 cp.points=[];cp.points[0]=(0,0,0);cp.points[1]=(100,0,0);cp.points[2]=(100,100,0);cp.points[3]=(0,100,0);
 old=openCJ\checkpointCreation::_encode(cp);
 decoded=openCJ\checkpointCreation::_decode(old);
 check(decoded.onGround,"existing drafts default to grounded");
 check(!openCJ\checkpointCreation::contains(decoded,(50,50,1),false),"grounded area rejects airborne player");
 cp.onGround=false;
 encoded=openCJ\checkpointCreation::_encode(cp);decoded=openCJ\checkpointCreation::_decode(encoded);
 check(!decoded.onGround,"airborne property survives draft serialization");
 check(openCJ\checkpointCreation::contains(decoded,(50,50,1),false),"airborne area skips ground requirement");
 check(!openCJ\checkpointCreation::contains(decoded,(150,50,1),false),"airborne area still rejects outside geometry");
 check(!isDefined(openCJ\checkpointCreation::_decode(old+":invalid")),"invalid ground flag rejected");
 decoded.onGround=true;
 check(openCJ\checkpointCreation::_encode(decoded)==old,"grounded encoding stays backward compatible");
 hud=newHudElem();openCJ\checkpointCreation::configureHud(hud);
 check(hud.x==124 && hud.y==6 && hud.archived,"panel is right of minimap in archived HUD pool");
 hud.color=(0,0,0);hud.alpha=0.65;hud.sort=-1;hud setShader("white",320,104);hud destroy();
 printf("PANEL SELFTEST COMPLETE\n");
}
check(ok,text)
{
 if(ok)printf("PANEL PASS "+text+"\n");else printf("PANEL FAIL "+text+"\n");
}
