main()
{
    wait 2;
    if(getCvar("db_base")!="opencj_demo_test_20260924_cod")return;
    level.scoreboardTestFailures=0;
    check(openCJ\scoreboard::clean("bad\"\\\nname",32)=="badname","safe dvar transport");
    p=spawnStruct();p.sessionState="playing";p.isFullyConnected=true;
    check(openCJ\scoreboard::status(p)=="Ready","idle player status");
    p.cpc=spawnStruct();check(openCJ\scoreboard::status(p)=="^5CPC","CPC priority");
    p.cpc=undefined;p.clipEdit=spawnStruct();check(openCJ\scoreboard::status(p)=="^5Clip editor","clip editor priority");p.clipEdit=undefined;
    p.sessionState="spectator";check(openCJ\scoreboard::spectatorRow(p),"spectators separate");
    p.playingDemo=true;check(!openCJ\scoreboard::spectatorRow(p),"playback remains jumper activity");
    bot=addTestClient();wait 1;
    if(isDefined(bot))
    {
        bot.isFullyConnected=true;bot.scoreboardCache=[];
        bot openCJ\scoreboard::update();
        check(isDefined(bot.scoreboardCache["opencj_sb_r31_exists"]),"all 32 row slots updated");
        check(float(bot.scoreboardCache["opencj_sb_height"])<150,"small population has compact height");
        snapshotExpiry=level.scoreboardNextUpdate;
        bot openCJ\scoreboard::update();
        check(level.scoreboardNextUpdate==snapshotExpiry,"reopening reuses the same snapshot");
        row=bot openCJ\scoreboard::row(bot);
        check(bot getPingVariation()==-1,"bots do not invent network variation");
        check(isDefined(row["pingText"]),"formatted network text available");
        check(isDefined(row["name"]) && isDefined(row["ping"]),"connected row available");
        check(row["progress"]==-1 && row["route"]=="-","inactive run has no invented route or progress");
        check(isDefined(row["fps"]) && isDefined(row["ele"]) && isDefined(row["hb"]) && isDefined(row["tas"]) && isDefined(row["any"]),"all mode icon fields present");
    }
    else check(false,"test player available");
    printf("SCOREBOARD COMPLETE failures="+level.scoreboardTestFailures+"\n");
}
check(ok,label){if(!ok){level.scoreboardTestFailures++;printf("SCOREBOARD FAIL "+label+"\n");}}
