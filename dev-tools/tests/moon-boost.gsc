main()
{
    wait 1;
    level.failures = 0;
    level.checkpointLayoutEpoch = 1;
    a=addTestClient(); b=addTestClient();
    wait 0.5;
    check(isDefined(a) && isDefined(b), "two real clients");
    if(!isDefined(a) || !isDefined(b))return;
    a setup(); b setup();
    // Stationary, grounded placements inside ramp 1, separated across its width.
    a place((-1000,-2200,1669)); b place((-1200,-2200,1669));
    thread maps\mp\mp_to_the_moon::speed();
    trigger=getEnt("svt_accelerate_1","targetname");
    trigger notify("trigger",a);
    trigger notify("trigger",b);
    wait 0.1;
    level notify("moon_test_stop_listener");
    check(a.testScale==12 && b.testScale==12,"same production trigger boosts two players independently");
    a openCJ\mapBoost::cancel();
    wait 0.1;
    check(a.testScale==1 && !isDefined(a.mapBoostOwned) && b.testScale==12,"cancelling A leaves B boosted");
    check(isAlive(a) && a isOnGround(),"A ready for boost");
    a thread openCJ\mapBoost::start(12);
    wait 0.1;
    check(a.testScale==12 && b.testScale==12,"A immediately reacquires without stale-thread interference");
    a openCJ\mapBoost::cancel(); b openCJ\mapBoost::cancel();

    a place((-1000,-2200,1900));
    a thread openCJ\mapBoost::start(12);
    check(!isDefined(a.mapBoostOwned),"airborne touch does not consume cooldown");

    for(i=0;i<2;i++)
    {
        a place((-1000,-2200,1669));
        check(isAlive(a) && a isOnGround(),"A ready for boost");
    a thread openCJ\mapBoost::start(12);
        wait 0.1;
        a openCJ\events\eventHandler::onLoadPositionRequest(i);
        check(a.testScale==1 && !isDefined(a.mapBoostOwned),"load request cancels synchronously "+i);
        a thread openCJ\mapBoost::start(12);
        wait 0.1;
        check(a.testScale==12,"direct load begins boosted "+i);
        a openCJ\events\loadPosition::main(i);
        check(distance(a.origin,a.testSaves[i].origin)<4,"real load reaches destination "+i);
        wait 0.15;
        check(a.testScale==1 && !isDefined(a.mapBoostOwned),"load cannot reapply boost "+i);
    }

    a place((-1000,-2200,1669));
    check(isAlive(a) && a isOnGround(),"A ready for boost");
    a thread openCJ\mapBoost::start(12);
    wait 0.1;
    a openCJ\events\spawnSpectator::main();
    check(a.sessionstate=="spectator" && a.testScale==1 && !isDefined(a.mapBoostOwned),"real spectator transition clears boost");
    a openCJ\events\spawnPlayer::main(false);
    check(a.sessionstate=="playing" && a.testScale==1,"real respawn retains normal scale");
    wait 0.15;
    check(a.testScale==1 && !isDefined(a.mapBoostOwned),"spectator-respawn cannot revive worker");

    for(i=0;i<2;i++)
    {
        a place((-1000,-2200,1669));
        a.testNoSaves=i;
        check(isAlive(a) && a isOnGround(),"A ready for boost");
    a thread openCJ\mapBoost::start(12);
        wait 0.1;
        a openCJ\playerRuns::restoreRun(999);
        wait 0.2;
        check(a.testScale==1 && !isDefined(a.mapBoostOwned),"run restore cancels boost, empty="+i);
        if(i==0)expected=a.testSaves[0].origin;
        else expected=a.testSpawn.origin;
        check(distance(a.origin,expected)<6,"run restore destination, empty="+i);
    }

    a place((-1000,-2200,1669));
    a thread openCJ\mapBoost::start(12);
    wait 0.1;
    a openCJ\noclip::enableNoclip();
    check(a.noclip && a.testScale==1 && !isDefined(a.mapBoostOwned),"real noclip activation cancels boost");
    a thread openCJ\mapBoost::start(12);
    check(!isDefined(a.mapBoostOwned),"noclip cannot acquire boost");
    a openCJ\noclip::disableNoclip();

    a place((-1000,-2200,1669));
    a thread openCJ\mapBoost::start(12);
    wait 0.1;
    a openCJ\events\playerKilled::main(a,a,100,"MOD_SUICIDE","none",(0,0,0),"none",0,0);
    check(a.sessionstate=="dead" && a.testScale==1 && !isDefined(a.mapBoostOwned),"death clears boost");

    // A genuine boost cooldown cannot later clear a new owner.
    a place((-1000,-2200,1669));
    check(isAlive(a) && a isOnGround(),"A ready for boost");
    a thread openCJ\mapBoost::start(12);
    wait 0.1;
    a setOriginAndAngles((-1000,-2200,1900),(0,90,0)); // test-only simulated takeoff
    wait 0.1;
    check(a.testScale==1 && isDefined(a.mapBoostOwned),"successful attempt enters original cooldown");
    a openCJ\mapBoost::cancel();
    a place((-1000,-2200,1669));
    check(isAlive(a) && a isOnGround(),"A ready for boost");
    a thread openCJ\mapBoost::start(12);
    wait 2.2;
    check(a.testScale==12 && isDefined(a.mapBoostOwned),"cancelled cooldown cannot clear new owner");
    a openCJ\mapBoost::cancel();

    a editorBoostTest();

    // Compare real engine movement using the original loop and production loop.
    // Automatic map boost listeners are disabled only in this fixture, so each
    // trial has exactly one known owner.
    starts=[];goals=[];
    starts[0]=(-1060,-2200,1669);goals[0]=(-1060,1800,4000);
    starts[1]=(2248,-1450,1585);goals[1]=(1760,-2300,1583);
    starts[2]=(7740,-1150,1989);goals[2]=(9300,-1150,4000);
    for(r=0;r<3;r++)
    {
        baseline=a trial(starts[r],goals[r],r,true);
        actual=a trial(starts[r],goals[r],r,false);
        maxPos=0;maxVel=0;scaleMatches=true;airSamples=0;boostSamples=0;
        for(i=0;i<baseline.size;i++)
        {
            maxPos=max(maxPos,distance(baseline[i].origin,actual[i].origin));
            maxVel=max(maxVel,distance(baseline[i].velocity,actual[i].velocity));
            if(baseline[i].scale!=actual[i].scale)scaleMatches=false;
            if(!baseline[i].grounded)airSamples++;
            if(baseline[i].scale==12)boostSamples++;
        }
        printf("MOON SELFTEST trajectory ramp="+r+" position_delta="+maxPos+" velocity_delta="+maxVel+"\n");
        check(airSamples>0 && boostSamples>0,"trajectory includes boost and takeoff ramp "+r);
        check(maxPos<0.1 && maxVel<0.1 && scaleMatches,"matched trajectory and scale timing ramp "+r);
    }
    printf("MOON SELFTEST COMPLETE failures="+level.failures+"\n");
}
setup()
{
    self.sessionTeam="allies"; self.sessionState="playing"; self.pers["team"]="allies";
    self.noclip=false;self.playingDemo=false;self.isFirstSpawn=true;self.eventQueue=[];
    self.testNoSaves=false;self.testScale=1;
    self.testSpawn=spawnStruct(); self.testSpawn.origin=(1760,-1290,1585); self.testSpawn.angles=(0,90,0);
    self.testSaves=[];
    for(i=0;i<2;i++)
    {
        s=spawnStruct();s.origin=(1550+i*300,-1290,1585);s.angles=(0,90,0);
        s.explosiveJumps=0;s.doubleExplosives=0;s.FPSMode=125;s.checkpointID=0;s.saveNum=i;
        self.testSaves[i]=s;
    }
}
place(origin)
{
    self notify("moon_test_baseline_cancel");
    self openCJ\mapBoost::cancel();
    self botStop();
    self.sessionTeam="allies";self.sessionState="playing";self.pers["team"]="allies";
    self spawn(origin,(0,90,0));
    self.maxhealth=100;self.health=100;
    self setMoveSpeedScale(1);self.testScale=1;
    self setg_speed(190);
    self setOriginAndAngles(origin,(0,90,0));
    self setVelocity((0,0,0));
    wait 0.3;
}
trial(origin,goal,ramp,original)
{
    self place(origin);
    printf("MOON SELFTEST trial origin="+self.origin+" alive="+isAlive(self)+"\n");
    check(self isOnGround(),"trial starts grounded ramp "+ramp);
    self.testTrace=[];
    if(original)self thread originalBoost();
    else self thread openCJ\mapBoost::start(12);
    if(ramp==1)self botMoveTo((2248,-1288,1583));
    else self botMoveTo(goal);
    for(i=0;i<60;i++)
    {
        if(ramp==0 && i==30)self botAction("+gostand");
        if(ramp==0 && i==31)self botAction("-gostand");
        if(ramp==1 && i==4)self botMoveTo((1760,-1288,1583));
        if(ramp==1 && i==10)self botMoveTo(goal);
        t=spawnStruct();t.origin=self.origin;t.velocity=self getVelocity();t.scale=self.testScale;t.grounded=self isOnGround();
        self.testTrace[i]=t;
        wait 0.05;
    }
    printf("MOON SELFTEST trajectory endpoint="+self.origin+" velocity="+self getVelocity()+"\n");
    trace=self.testTrace;
    self notify("moon_test_baseline_cancel");
    self openCJ\mapBoost::cancel();
    self setMoveSpeedScale(1);
    self botStop();
    return trace;
}
originalBoost()
{
    self endon("disconnect");
    self endon("moon_test_baseline_cancel");
    while(self isOnGround())
    {
        self.testScale=12;self setMoveSpeedScale(12);
        wait 0.05;
    }
    self.testScale=1;self setMoveSpeedScale(1);
    wait 2;
}
check(ok,message)
{
    if(!ok)level.failures++;
    printf("MOON SELFTEST "+message+": "+ok+"\n");
}

editorBoostTest()
{
    self.cpc=spawnStruct();
    self.cpc.positions=[];
    self.cpc.positions[0]=self.testSaves[0];
    self.cpc.positions[1]=self.testSaves[1];
    self.cpc.travelIndex=0;
    for(i=0;i<2;i++)
    {
        self place((7740,-1150,1989));
        thread maps\mp\mp_to_the_moon::speed3();
        trigger=getEnt("svt_accelerate_3","targetname");
        trigger notify("trigger",self);
        wait 0.1;
        level notify("moon_test_stop_listener");
        check(self.testScale==12 && isDefined(self.mapBoostOwned),"editor can activate actual inter-ramp trigger "+i);
        self openCJ\events\eventHandler::onLoadPositionRequest(i);
        check(self.testScale==1 && !isDefined(self.mapBoostOwned),"editor load request cancels active boost "+i);
        self openCJ\checkpointCreation::processTravelRequests();
        check(distance(self.origin,self.testSaves[i].origin)<4,"real editor load reaches destination "+i);
        wait 0.15;
        check(self.testScale==1 && !isDefined(self.mapBoostOwned),"editor teleport cannot revive boost "+i);
    }
    self place((7740,-1150,1989));
    self thread openCJ\mapBoost::start(12);
    wait 0.1;
    check(self.testScale==12,"editor can reactivate after loading");
    self.cpc.restoreOrigin=self.testSaves[0].origin;
    self.cpc.restoreAngles=self.testSaves[0].angles;
    self openCJ\checkpointCreation::processTravelRequests();
    check(self.testScale==1 && !isDefined(self.mapBoostOwned),"editor restore-origin travel cancels boost");
    check(distance(self.origin,self.testSaves[0].origin)<4,"editor restore-origin reaches destination");
    self.cpc=undefined;
}
