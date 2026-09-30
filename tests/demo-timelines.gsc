
// Isolated in-memory demo tests; never modify live runs or stored demos.
main()
{
    wait 2;
    if(getCvar("db_base") != "opencj_demo_test_20260924_cod") return;
    level.demoTimelineFailures=0;
    bot=addTestClient();
    if(!isDefined(bot)){check(false,"create test viewer");return;}
    wait 1;
    a=1800000081;b=1800000082;
    createDemo(a);createDemo(b);
    for(i=0;i<1300;i++)
    {
        flags=8192;
        if((i>=20 && i<40) || (i>=1240 && i<1280))flags=0;
        if(i>=1250 && i<1253)flags=8192; // Short bunny-hop ground contact.
        cp=17;if(i>=1280)cp=18;
        addFrameToDemo(a,(i%20,0,100),(0,0,0),1,flags,0,int(i==40),0,125,cp);
        if(i==39)check(demoMarkFailedSince(a,20)==40,"load retains failed frames");
    }
    check(numberOfDemoFrames(a)==1300,"speedrun retains the complete recording");
    for(i=0;i<1300;i+=64)
    {
        count=1300-i;if(count>64)count=64;
        check(demoDecodeChunk(b,demoEncodeChunk(a,i,count))==count,"chunk roundtrip");
    }
    bot selectPlaybackDemo(b);
    range=bot demoPlaybackStyle(0,0,1299);
    time=bot demoPlaybackTime(0,1299);
    check(time[1]==1299,"speedrun duration includes setup and failed attempts");
    bot skipPlaybackFrames(20);
    check(bot readPlaybackFrame_flags()==0,"speedrun includes failed airborne attempt");
    range=bot demoPlaybackStyle(1,0,1299);
    time=bot demoPlaybackTime(0,1299);
    check(time[1]==1279,"low-RPG skips failures but keeps setup");
    check(bot skipPlaybackKeyFrames(20)==40,"successful path crosses failed section");
    range=bot demoPlaybackStyle(2,0,1299);
    time=bot demoPlaybackTime(0,1299);
    check(time[1]==79,"walkthrough trims a minute of setup to a short approach");
    check(bot skipPlaybackFrames(0)==1220,"walkthrough begins after the last load and setup");
    check(bot skipPlaybackKeyFrames(20)==1240,"walkthrough retains the full successful jump");
    check(bot demoSeekCheckpoint(1)==1280,"next checkpoint follows edited timeline");
    bot skipPlaybackFrames(40);
    check(bot demoSeekCheckpoint(-1)==1220,"previous checkpoint follows edited timeline");
    check(bot skipPlaybackKeyFrames(-20)==1260,"reverse uses edited frame sequence");
    range=demoFindSegment(b,17,(0,0,100),0,1);
    check(isDefined(range) && range[1]==1289,"successful checkpoint segment includes grounded landing tail");
    destroyDemo(a);destroyDemo(b);

    // A load at the next checkpoint must not erase the arrival of this jump.
    a=1800000084;createDemo(a);
    for(i=0;i<120;i++)
    {
        cp=17;if(i>=40)cp=18;
        flags=8192;if(i>=20 && i<40)flags=0;
        addFrameToDemo(a,(0,0,100),(0,0,0),1,flags,0,int(i==80),0,125,cp);
    }
    bot selectPlaybackDemo(a);
    segment=demoFindSegment(a,17,(0,0,100),0,1);
    check(segment[1]==49,"segment stops after arrival, before later load");
    edited=bot demoPlaybackStyle(2,segment[0],segment[1]);
    check(edited[1]==49,"walkthrough retains landing despite destination load");
    current=bot skipPlaybackFrames(0);bot skipPlaybackFrames(edited[1]-current);
    check((bot readPlaybackFrame_flags()&8192)!=0,"terminal frame is grounded");
    edited=bot demoPlaybackStyle(2,40,119);
    check(edited[0]>=80,"starting at destination still omits pre-load setup");
    destroyDemo(a);

    // No ammo bytes are recorded. The renderer gets ammo only during playback.
    a=1800000083;
    createDemo(a);
    rpg=level.weapons_rpgs["default"];
    bot giveWeapon(rpg);bot setSpawnWeapon(rpg);
    bot setWeaponAmmoClip(rpg,0);
    addFrameToDemo(a,bot.origin,bot getPlayerAngles(),1,8192|4096,0,0,0,125,17,bot getEntityNumber());
    bot selectPlaybackDemo(a);
    check(bot demoBeginPresentation(),"save original presentation");
    check(bot demoApplyPresentation(),"apply RPG presentation");
    check(bot getWeaponAmmoClip(rpg)>0,"playback supplies ammo for visible rocket");
    bot demoEndPresentation();
    check(bot getWeaponAmmoClip(rpg)==0,"leaving playback restores exact original ammo");
    destroyDemo(a);
    printf("DEMO TIMELINE COMPLETE failures="+level.demoTimelineFailures+"\n");
}
check(ok,label)
{
    if(!ok){level.demoTimelineFailures++;printf("DEMO TIMELINE FAIL: "+label+"\n");}
}
