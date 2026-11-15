main()
{
    wait 2;
    level.connectionFailures=0;
    p=spawnStruct();p.name="Loading player";
    check(openCJ\scoreboard::connecting(p),"pre-initialization client recognized");
    check(openCJ\scoreboard::spectatorRow(p),"connecting client grouped with spectators");
    r=openCJ\scoreboard::row(p);
    check(r["name"]==p.name && r["route"]=="^3Connecting...","loading name and status available without initialization");
    check(r["rank"]=="" && r["flag"]=="default" && r["flagSelector"]==0 && r["pingText"]=="-" && r["progress"]==-1,"no invented rank country ping or progress");
    check(r["fps"]==0 && r["ele"]==0 && r["hb"]==0 && r["tas"]==0 && r["any"]==0,"all mode fields reset");
    p.isFullyConnected=false;check(openCJ\scoreboard::connecting(p),"explicit connecting state recognized");
    p.isFullyConnected=true;p.sessionState="playing";
    check(!openCJ\scoreboard::connecting(p) && !openCJ\scoreboard::spectatorRow(p),"joined player transitions to jumpers");
    check(openCJ\scoreboard::status(p)=="Ready","joined status restored");
    bot=addTestClient();wait 0.5;
    check(isDefined(bot),"engine client created");
    if(isDefined(bot))
    {
        bot.isFullyConnected=false;
        openCJ\scoreboard::buildSnapshot();
        check(level.scoreboardPlayers.size==1 && level.scoreboardPlayers[0]==bot,"engine client retained in snapshot while connecting");
        check(level.scoreboardRows.size>0 && level.scoreboardRows[0]["route"]=="^3Connecting..." && level.scoreboardJumperCount==0,"connecting snapshot row displayed");
        bot.isFullyConnected=true;
        openCJ\scoreboard::buildSnapshot();
        check(level.scoreboardPlayers.size==1 && level.scoreboardRows[0]["route"]!="^3Connecting...","transition updates existing row without duplication");
        bot openCJ\scoreboard::onPlayerDisconnected();
        openCJ\scoreboard::buildSnapshot();
        check(level.scoreboardPlayers.size==0,"disconnect removes connecting or joined client");
    }
    printf("CONNECTING SELFTEST COMPLETE failures="+level.connectionFailures+"\n");
}
check(ok,label)
{
    if(!ok){level.connectionFailures++;printf("CONNECTING SELFTEST FAIL "+label+"\n");}
    else printf("CONNECTING SELFTEST PASS "+label+"\n");
}
