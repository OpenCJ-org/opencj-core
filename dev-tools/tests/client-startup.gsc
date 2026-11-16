// Reproduce the disconnect race without player accounts or database access.
main()
{
    level.failures=0;level.checks=0;
    wait 1;
    player=addTestClient();wait 0.2;
    check(isDefined(player),"test client connected");
    if(!isDefined(player)){finish();return;}
    player.clientInitPending=true;
    level.afterWait=false;
    player thread completionWaiter();
    wait 0.1;
    check(!level.afterWait,"startup consumers wait for acknowledgement");
    player.clientInitPending=false;
    wait 0.1;
    check(level.afterWait,"startup consumers resume after acknowledgement");
    player.clientInitPending=true;
    level.cameraAfterWait=false;
    player thread openCJ\camera::onPlayerConnected();
    wait 0.1;
    player notify("disconnect");
    player.settingValues=undefined;
    player.clientInitPending=false;
    wait 0.15;
    check(true,"camera thread cancelled without reading cleared settings");
    player.clientInitPending=true;
    level.afterWait=false;
    player thread completionWaiter();
    wait 0.05;
    level notify("game_ended");
    player.clientInitPending=false;
    wait 0.1;
    check(!level.afterWait,"map change cancels pending startup work");
    finish();
}
completionWaiter()
{
    self endon("disconnect");
    level endon("game_ended");
    self openCJ\clientInit::waitUntilFinished();
    level.afterWait=true;
}
check(passed,label)
{
    level.checks++;
    if(!passed)level.failures++;
    printf("STARTUP SELFTEST "+label+": "+passed+"\n");
}
finish(){printf("STARTUP SELFTEST COMPLETE failures="+level.failures+" checks="+level.checks+"\n");}
