main()
{
    wait 1;
    level.failures=0;
    input=spawnStruct();
    check(!(input openCJ\buttonPress::registerFragTap(1000)),"first tap waits");
    check(input openCJ\buttonPress::registerFragTap(1300),"300 ms accepted");
    check(!(input openCJ\buttonPress::registerFragTap(1400)),"third tap starts new pair");
    check(!(input openCJ\buttonPress::registerFragTap(1701)),"301 ms rejected");
    check(input openCJ\buttonPress::registerFragTap(1800),"late tap starts next pair");
    input openCJ\buttonPress::registerFragTap(2000);
    input openCJ\buttonPress::resetButtons();
    check(!(input openCJ\buttonPress::registerFragTap(2100)),"spawn/demo reset clears pair");
    floor=(21168.140625,383.943176,-2415.875);
    eye=floor+(0,0,60);
    dest=aimTeleportDestination(eye,floor-(0,0,20),1023);
    printf("TELEPORT SELFTEST destination="+dest+" floor="+floor+"\n");
    hit=bulletTrace(eye,floor-(0,0,20),false,undefined);
    printf("TELEPORT SELFTEST hit="+hit["position"]+" normal="+hit["normal"]+"\n");
    check(isDefined(dest),"platform top has safe destination");
    if(isDefined(dest))
    {
        check(abs(dest[0]-floor[0])<0.1 && abs(dest[1]-floor[1])<0.1,"platform retains aimed XY");
        check(dest[2]>floor[2]-0.2 && dest[2]<floor[2]+2,"feet land just above platform");
    }
    check(!isDefined(aimTeleportDestination(eye,eye+(0,0,1),1023)),"no hit does not teleport");
    check(!isDefined(aimTeleportDestination(floor-(0,0,4),eye,1023)),"start in solid rejected");
    // This landing is sloped; check support-plane clearance, not flat-floor Z.
    slope=(4392.528320,4160.322266,-735.972107);
    eye=slope+(0,0,60);
    hit=bulletTrace(eye,slope-(0,0,20),false,undefined);
    dest=aimTeleportDestination(eye,slope-(0,0,20),1023);
    check(isDefined(dest),"sloped platform destination found");
    if(isDefined(dest))
    {
        n=hit["normal"];
        delta=dest+(0,0,35)-hit["position"];
        clearance=delta[0]*n[0]+delta[1]*n[1]+delta[2]*n[2];
        support=15*(abs(n[0])+abs(n[1]))+35*abs(n[2]);
        check(clearance>=support+0.5,"slope leaves full standing hull above surface");
    }
    dirs=[];dirs[0]=(1,0,0);dirs[1]=(-1,0,0);dirs[2]=(0,1,0);dirs[3]=(0,-1,0);
    walls=0;
    for(i=0;i<dirs.size;i++)
    {
        end=eye+vectorScale(dirs[i],10000);
        hit=bulletTrace(eye,end,false,undefined);
        dest=aimTeleportDestination(eye,end,1023);
        if(isDefined(dest) && hit["fraction"]<1 && abs(hit["normal"][2])<0.01)
        {
            delta=dest-hit["position"];
            separation=delta[0]*hit["normal"][0]+delta[1]*hit["normal"][1];
            check(separation>=15.9,"wall destination leaves full hull clearance");
            walls++;
        }
    }
    check(walls>0,"wall geometry exercised");
    // Low wall hits above a supporting floor used to leave the feet embedded.
    lowWalls=0;
    probes=[];probes[0]=slope;probes[1]=floor;
    probes[2]=(-4947.176758,-987.563171,-535.875);
    probes[3]=(-554.897949,-46.286156,-697.875);
    for(p=0;p<probes.size;p++)for(i=0;i<dirs.size;i++)
    {
        lowEye=probes[p]+(0,0,4);
        end=lowEye+vectorScale(dirs[i],1000);
        hit=bulletTrace(lowEye,end,false,undefined);
        if(hit["fraction"]>=1 || abs(hit["normal"][2])>0.01)continue;
        dest=aimTeleportDestination(lowEye,end,1023);
        if(!isDefined(dest))continue;
        if(dest[2]<=hit["position"][2]-34)continue;
        supportHit=bulletTrace(dest+(0,0,1),dest-(0,0,4),false,undefined);
        if(supportHit["fraction"]>=1 || supportHit["normal"][2]<0.7)continue;
        delta=dest-hit["position"];
        clearance=delta[0]*hit["normal"][0]+delta[1]*hit["normal"][1];
        check(clearance>=15.9,"low wall keeps body outside wall");
        check(dest[2]>=supportHit["position"][2],"low wall feet above supporting platform");
        printf("TELEPORT SELFTEST low-wall fixture eye="+lowEye+" end="+end+" destination="+dest+"\n");
        lowWalls++;
    }
    check(lowWalls>0,"low wall and supporting platform exercised");
    player=addTestClient();
    check(isDefined(player),"real test client created");
    if(isDefined(player))
    {
        wait 0.2;
        player.sessionTeam="allies";
        player.sessionState="playing";
        player.pers["team"]="allies";
        player spawn(floor+(0,0,100),(90,0,0));
        player.login_playerID=1;
        player.settingsLoaded=true;
        player.cheating=false;
        player.eventQueue=[];
        player openCJ\noclip::onPlayerConnect();
        player openCJ\noclip::enableNoclip();
        check(player.noclip && player.cheating,"real player linked in noclip");
        before=player.origin;
        player openCJ\buttonPress::onFragButton();
        player openCJ\buttonPress::onFragButton();
        check(isDefined(player.eventQueue["aimTeleport"]),"double frag queues request");
        check(player.noclip && distance(player.origin,before)<0.01,"input callback does not move or unlink player");
        request=player.eventQueue["aimTeleport"];
        expected=aimTeleportDestination(request.eye,request.eye+vectorScale(anglesToForward(request.angles),100000),player getEntityNumber());
        check(isDefined(expected),"queued aim has clear destination");
        wait 0.05;
        player openCJ\buttonPress::processFragTeleport();
        check(!player.noclip && player.cheating,"queued teleport exits noclip and retains cheating");
        printf("TELEPORT SELFTEST actual="+player.origin+" expected="+expected+"\n");
        check(isDefined(expected) && distance(player.origin,expected)<3,"real player reaches collision-checked destination");
        check(!isDefined(player.eventQueue["aimTeleport"]),"request consumed once");
        wait 0.1;
        check(isDefined(player),"server survives subsequent movement frames");
        player setOriginAndAngles(floor+(0,0,100),(85,0,0));
        player.cheating=false;
        player openCJ\buttonPress::onFragButton();
        player openCJ\buttonPress::onFragButton();
        check(!player.cheating && !player.noclip,"ordinary input callback only queues");
        wait 0.05;
        player openCJ\buttonPress::processFragTeleport();
        check(player.cheating && !player.noclip,"ordinary teleport marks cheating");
        player openCJ\buttonPress::onFragButton();
        player openCJ\buttonPress::onFragButton();
        player openCJ\buttonPress::resetButtons();
        check(!isDefined(player.eventQueue["aimTeleport"]),"lifecycle reset cancels queued teleport");
    }
    printf("TELEPORT SELFTEST COMPLETE failures="+level.failures+"\n");
}
check(ok,message)
{
    if(!ok)level.failures++;
    printf("TELEPORT SELFTEST "+message+": "+ok+"\n");
}
