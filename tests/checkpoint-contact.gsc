main()
{
    wait 2;
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod")return;
    level.contactFailures=0;
    player=spawnStruct();cp=spawnStruct();cp.onGround=true;
    check(!player openCJ\checkpoints::contactReady(cp,true,0),"landing starts pending");
    check(!player openCJ\checkpoints::contactReady(cp,true,50),"50ms insufficient");
    check(!player openCJ\checkpoints::contactReady(cp,true,100),"100ms insufficient");
    check(player openCJ\checkpoints::contactReady(cp,true,150),"150ms continuous contact awards");
    check(!player openCJ\checkpoints::contactReady(cp,false,160),"airborne clears contact");
    check(!player openCJ\checkpoints::contactReady(cp,true,200),"new landing starts over");
    check(!player openCJ\checkpoints::contactReady(cp,true,400),"missed polls reset contact");
    other=spawnStruct();other.onGround=true;
    check(!player openCJ\checkpoints::contactReady(other,true,450),"different area starts over");
    other.onGround=false;
    check(player openCJ\checkpoints::contactReady(other,false,451),"airborne checkpoint immediate");
    check(!isDefined(player.checkpointContact),"airborne award clears pending contact");
    check(openCJ\demos::leaderboardKind(true)=="walkthrough","walkthrough winner takes priority");
    check(openCJ\demos::leaderboardKind(false)=="speedrun","other leaderboard runs stay complete");
    printf("CHECKPOINT CONTACT COMPLETE failures="+level.contactFailures+"\n");
}
check(ok,label)
{
    if(!ok){level.contactFailures++;printf("CHECKPOINT CONTACT FAIL: "+label+"\n");}
}
