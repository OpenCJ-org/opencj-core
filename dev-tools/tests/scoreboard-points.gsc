main()
{
    a=spawnStruct();a.challengePoints=40;
    b=spawnStruct();b.challengePoints=100;
    c=spawnStruct();c.challengePoints=40;
    d=spawnStruct();
    list=[];list[0]=a;list[1]=b;list[2]=c;list[3]=d;
    list=openCJ\scoreboard::sortByPoints(list);
    if(list[0]==b && list[1]==a && list[2]==c && list[3]==d && openCJ\scoreboard::points(d)==0)
        printf("SCOREBOARD POINTS PASS descending stable order and uninitialized player\n");
    else {printf("SCOREBOARD POINTS FAIL\n");return;}

    for(j=0;j<=32;j++)
    {
        for(offset=-3;offset<=35;offset++)
        {
            v=openCJ\scoreboard::viewLayout(offset,32,j);
            if(v.count!=15 || v.first<0 || v.first>17 || v.first+v.count>32 || v.top+v.height>480)
            {printf("SCOREBOARD SCROLL FAIL bounds\n");return;}
            if(v.split!=(j>v.first && j<v.first+v.count))
            {printf("SCOREBOARD SCROLL FAIL section boundary\n");return;}
        }
    }
    v=openCJ\scoreboard::viewLayout(17,2,1);
    if(v.first!=0 || v.count!=2 || !v.split){printf("SCOREBOARD SCROLL FAIL shrinking list\n");return;}
    printf("SCOREBOARD POINTS COMPLETE failures=0\n");
}
