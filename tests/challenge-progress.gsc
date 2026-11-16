// Pure progress projections. Run through the isolated menu fixture; no database writes.
run()
{
    openCJ\challenges::definitions();
    level.challengeTierPoints=[];
    for(t=1;t<=10;t++)level.challengeTierPoints[t]=0;
    keys=getArrayKeys(level.challenges);
    for(i=0;i<keys.size;i++)
    {
        c=level.challenges[keys[i]];level.challengeTierPoints[c.tier]+=c.points;
    }
    lower=0;
    for(rank=1;rank<10;rank++)
    {
        cost=level.challengeTierPoints[rank];
        data=openCJ\challenges::progressForPoints(lower);
        check(data["level"]=="Level "+rank && data["fraction"]==0,"level "+rank+" begins empty");
        data=openCJ\challenges::progressForPoints(lower+cost/2);
        check(data["fraction"]==0.5,"level "+rank+" measures progress within its own interval");
        check(data["points"]==(lower+cost/2)+" points","level "+rank+" retains cumulative points");
        check(data["next"]=="Next: Level "+(rank+1),"level "+rank+" next label");
        data=openCJ\challenges::progressForPoints(lower+cost-1);
        check(data["remaining"]=="1 point to go" && data["fraction"]<1,"level "+rank+" one point remaining");
        lower+=cost;
    }
    data=openCJ\challenges::progressForPoints(lower);
    check(data["level"]=="Level 10" && data["fraction"]==1,"maximum level completes progress");
    check(data["next"]=="Maximum level" && data["remaining"]=="","maximum level has no fictitious next target");
    data=openCJ\challenges::progressForPoints(lower+1000);
    check(data["level"]=="Level 10" && data["fraction"]==1,"extra points preserve maximum level");
    data=openCJ\challenges::progressForPoints(-1);
    check(data["points"]=="0 points" && data["fraction"]==0,"progress cannot go negative");
}
check(value,label)
{
    openCJ\platformTest::check(value,"challenge progress: "+label);
}
