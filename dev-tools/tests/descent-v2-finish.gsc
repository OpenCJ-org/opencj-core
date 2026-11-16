
main()
{
    wait 2;
    player=spawn("script_origin",(0,0,0));
    player.name="Descent finish regression";
    player.sessionstate="playing";
    easy=getEnt("easyend","targetname");
    hard=getEnt("hardend","targetname");
    if(!isDefined(easy) || !isDefined(hard)) { logPrint("[DESCENT_TEST] FAIL missing finish\n");return; }
    easy notify("trigger",player);wait 0.1;
    hard notify("trigger",player);wait 0.1;
    if(isDefined(player.easyEnd) || isDefined(player.hardEnd)) { logPrint("[DESCENT_TEST] FAIL finish before start\n");return; }
    player.startTimeEasy=getTime()-600000;
    player.startTimeHard=getTime()-600000;
    player.sessionstate="spectator";
    easy notify("trigger",player);wait 0.1;
    hard notify("trigger",player);wait 0.1;
    if(isDefined(player.easyEnd) || isDefined(player.hardEnd)) { logPrint("[DESCENT_TEST] FAIL spectator finish\n");return; }
    player.sessionstate="playing";
    easy notify("trigger",player);wait 0.1;
    hard notify("trigger",player);wait 0.1;
    if(!isDefined(player.easyEnd) || !isDefined(player.hardEnd)) { logPrint("[DESCENT_TEST] FAIL first finish\n");return; }
    if(!player.easyEnd || !player.hardEnd) { logPrint("[DESCENT_TEST] FAIL flags false\n");return; }
    easy notify("trigger",player);wait 0.1;
    hard notify("trigger",player);wait 0.1;
    logPrint("[DESCENT_TEST] PASS Easy and Hard: before start, spectator, first finish, repeat\n");
    player delete();
}
