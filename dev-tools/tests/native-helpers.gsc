#include openCJ\util;
main()
{
    if(getCvarInt("opencj_isolated_demo_test")!=1)return;
    level.helperChecks=0;level.helperFailures=0;
    check(getAscii("A")==65,"ASCII uppercase");
    check(getAscii("z")==122,"ASCII lowercase");
    check(getAscii("9")==57,"ASCII digit");
    check(getAscii("!")==33,"ASCII punctuation");
    check(getAscii("")==0,"empty ASCII input retains zero");
    check(getAscii("Ab")==65,"only first byte converted");

    // Exercise actual precaching and the production HUD lookup wrapper.
    openCJ\huds\infiniteHuds::onInit();
    for(i=0;i<3;i++)
    {
        name="helperhud"+i;
        openCJ\huds\infiniteHuds::initInfiniteHud(name);
        entry=level.infiniteHudStrings[name];
        check(entry.configstringIndex>309 && entry.configstringIndex<821,"HUD absolute localized index "+i);
        check(sv_getconfigstring(entry.configstringIndex)==entry.string,"HUD lookup resolves its own string "+i);
        if(i>0)check(entry.configstringIndex!=level.infiniteHudStrings["helperhud0"].configstringIndex,"HUD indices do not collide "+i);
    }
    // Use a scratch portion of the localized table, then restore every slot.
    saved=[];
    for(i=789;i<=795;i++)saved[i]=sv_getconfigstring(i);
    setconfigstringbyindex(789,"native_helper_duplicate");
    setconfigstringbyindex(790,"native_helper_reserved");
    setconfigstringbyindex(791,"native_helper_first");
    setconfigstringbyindex(792,"");
    setconfigstringbyindex(793,"native_helper_duplicate");
    setconfigstringbyindex(794,"native_helper_last");
    setconfigstringbyindex(795,"native_helper_outside");
    check(G_FindConfigstringIndex("native_helper_first",790,5)==791,"range starts at first usable slot");
    check(G_FindConfigstringIndex("native_helper_last",790,5)==794,"range includes last slot");
    check(G_FindConfigstringIndex("native_helper_duplicate",790,5)==793,"matching text outside range ignored");
    check(G_FindConfigstringIndex("NATIVE_HELPER_FIRST",790,5)==791,"case-insensitive compatibility");
    check(G_FindConfigstringIndex("native_helper_reserved",790,5)==0,"table zero slot reserved");
    check(G_FindConfigstringIndex("native_helper_outside",790,5)==0,"end bound exclusive");
    check(G_FindConfigstringIndex("",790,5)==0,"empty lookup rejected");
    check(G_FindConfigstringIndex("missing",790,5)==0,"missing lookup returns zero");
    check(G_FindConfigstringIndex("missing",-1,5)==0,"negative start rejected");
    check(G_FindConfigstringIndex("missing",4883,5)==0,"out-of-range start rejected");
    check(G_FindConfigstringIndex("missing",790,0)==0,"empty range rejected");
    check(G_FindConfigstringIndex("missing",790,-1)==0,"negative count rejected");
    check(G_FindConfigstringIndex("missing",790,2147483647)==0,"overflowing count rejected");
    check(G_FindConfigstringIndex("missing",4882,2)==0,"range beyond table rejected");
    for(i=789;i<=795;i++)setconfigstringbyindex(i,saved[i]);

    wait 1;
    player=addTestClient();wait .2;
    check(isDefined(player),"test client available");
    if(isDefined(player))
    {
        player.sessionTeam="allies";player.sessionState="playing";player.pers["team"]="allies";
        player spawn((0,0,700),(0,0,0));player freezeControls(true);
        player setVelocity((10,-20,30));
        check(player addVelocity((5,8,-12))==1,"addVelocity succeeds");
        check(player getVelocity()==(15,-12,18),"velocity addition preserves all axes");
        player addVelocity((-5,-8,12));
        check(player getVelocity()==(10,-20,30),"inverse addition restores velocity");
        check(player getIP()=="bot","client address comes from engine without port");
        check(player isSprinting()==0,"stationary player is not sprinting");
        check(isDefined(player getQueuedReliableMessages()),"native reliable-queue helper available");
        player.isFirstSpawn=true;
        hud=player openCJ\huds\infiniteHuds::createInfiniteStringHud("helperhud0");
        hud openCJ\huds\infiniteHuds::setInfiniteHudText("Native helper HUD test",player,true);
        check(hud.configstringIndex==level.infiniteHudStrings["helperhud0"].configstringIndex,"HUD sends text to correct absolute index");
        hud destroy();
    }
    other=spawn("script_origin",(0,0,700));
    check(other addVelocity((1,2,3))==0,"non-player velocity call rejected safely");
    check(other getIP()=="","non-player IP call returns empty");
    check(other isSprinting()==0,"non-player sprint call returns false");
    check(other getQueuedReliableMessages()==0,"non-player queue call returns zero");
    other delete();
    printf("NATIVE HELPERS COMPLETE failures="+level.helperFailures+" checks="+level.helperChecks+"\n");
}
check(ok,label)
{
    level.helperChecks++;
    if(!ok){level.helperFailures++;printf("NATIVE HELPERS FAIL: "+label+"\n");}
}
