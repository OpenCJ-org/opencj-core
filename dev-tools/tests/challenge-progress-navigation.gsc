// Engine integration fixture: real Challenges navigation with an in-memory query backend.
run(player)
{
    level.challengesReady=true;
    player.login_playerID=69;
    player.progressTestPoints=150;player.progressTestFail=false;
    player.progressTestReads=0;player.progressTestListReads=0;
    player.progressTestResets=0;player.progressTestWrites=0;player.progressTestCvars=[];
    player.challengeTab=0;player.challengePage=0;
    player openCJ\challenges::refresh();
    check(player.progressTestReads==1,"initial load reads points once");
    check(player.progressTestCvars["ocj_ch_player_points"]=="150 points" && player.progressTestCvars["ocj_ch_progress_ready"]==1,"initial progress published");
    writes=player.progressTestWrites;
    for(tab=0;tab<3;tab++)
    {
        player.challengeTab=tab;
        player runShow(false);
    }
    check(player.progressTestListReads==3,"each tab still refreshes its list");
    check(player.progressTestReads==1,"tab navigation never queries player stats");
    check(player.progressTestWrites==writes,"tab navigation leaves progress fields untouched");
    check(player.progressTestResets==0,"tab navigation never hides progress");
    player.progressTestPoints=250;
    player runShow(true);
    check(player.progressTestReads==2,"reopening refreshes points once");
    check(player.progressTestCvars["ocj_ch_player_points"]=="250 points","reopening publishes newer points");
    check(player.progressTestResets==0,"reopening keeps progress visible during refresh");
    player.progressTestPoints=300;
    player openCJ\challenges::refresh();
    check(player.progressTestCvars["ocj_ch_player_points"]=="300 points","point updates publish without a tab click");
    player.progressTestFail=true;
    player runShow(true);
    check(player.progressTestCvars["ocj_ch_player_points"]=="300 points","failed refresh retains last known points");
    check(player.progressTestCvars["ocj_ch_progress_ready"]==1 && player.progressTestResets==0,"failed refresh does not hide progress");
}
runShow(refreshProgress)
{
    self.progressTestDone=false;
    self thread showAndFinish(refreshProgress);
    for(i=0;i<30 && !self.progressTestDone;i++)wait .05;
    check(self.progressTestDone,"menu refresh completed");
}
showAndFinish(refreshProgress)
{
    self openCJ\challenges::show(refreshProgress);
    self.progressTestDone=true;
}
query(sql,menu)
{
    rows=[];
    if(isSubStr(sql,"WHERE a.playerID="))
    {
        self.progressTestReads++;
        if(self.progressTestFail)return undefined;
        rows[0]=[];rows[0][0]=""+self.progressTestPoints;
    }
    else
    {
        self.progressTestListReads++;
        if(isSubStr(sql,"LIMIT 10"))
        {
            rows[0]=[];rows[0][0]="Test runner";rows[0][1]="150";rows[0][2]="69";
        }
    }
    return rows;
}
captureCvar(key,value)
{
    if(!isDefined(self.progressTestCvars))self.progressTestCvars=[];
    self.progressTestCvars[key]=value;
    if(key=="ocj_ch_progress_ready" && value==0)self.progressTestResets++;
    if(key=="ocj_ch_player_level" || key=="ocj_ch_player_points" || key=="ocj_ch_next_level" || key=="ocj_ch_points_remaining" || key=="ocj_ch_progress" || key=="ocj_ch_progress_ready")self.progressTestWrites++;
    self setClientCvar(key,value);
}
check(value,label)
{
    openCJ\platformTest::check(value,"progress navigation: "+label);
}
