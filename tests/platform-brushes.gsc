main()
{
    wait 2;
    level.brushFailures=0;
    origins=[];
    if(getCvar("mapname")=="mp_dark")
    {
        origins[0]=(4392.528320,4160.322266,-735.972107);
        origins[1]=(21168.140625,383.943176,-2415.875);
        origins[2]=(-526.78186,-1365.322876,-5624.875);
        origins[3]=(-4947.176758,-987.563171,-535.875);
        origins[4]=(-554.897949,-46.286156,-697.875);
    }
    if(getCvar("mapname")=="mp_futile_fixed")
    {
        origins[0]=(40078.9648,8282.21973,-28399.875);
        origins[1]=(42825.3828,4663.33887,-27877.0723);
        origins[2]=(35584.875,6391.88477,-27909.1738);
        origins[3]=(25766.7539,1881.37524,-27206.8047);
        origins[4]=(25333.9004,1882.79773,-27331.0879);
    }
    for(i=0;i<origins.size;i++)testFace(origins[i],i);
    check(!isDefined(platformBrushFace((0,0,0),(0,0,-1))),"non-walkable normal rejected");
    check(!isDefined(platformBrushFace((131073,0,0),(0,0,1))),"out of range origin rejected");
    check(!isDefined(platformBrushFace((0,0,120000),(0,0,1))),"no nearby brush returns undefined");
    if(getCvar("mapname")=="mp_futile_fixed")
    {
        points=openCJ\checkpointPlatform::detectLandingAt(origins[3]);
        check(!openCJ\checkpointArea::contains(points,(25500,1881,-27274),true),"cutout not filled");
        points=openCJ\checkpointPlatform::detectLandingAt(origins[0]);
        check(!openCJ\checkpointArea::contains(points,origins[0]+(0,0,32),true),"raised height not accepted as base landing");
    }
    printf("BRUSH SELFTEST COMPLETE failures="+level.brushFailures+"\n");
}

testFace(origin,index)
{
    top=bulletTrace(origin+(0,0,2),origin-(0,0,24),false,undefined);
    points=platformBrushFace(top["position"],top["normal"]);
    check(isDefined(points),"native face "+index+" found");
    if(!isDefined(points))return;
    check(openCJ\checkpointArea::validate(points)=="","native face "+index+" valid");
    check(openCJ\checkpointArea::contains(points,origin,true),"native face "+index+" contains player");
    detected=openCJ\checkpointPlatform::detectLandingAt(origin);
    check(openCJ\checkpointArea::encode(detected)==openCJ\checkpointArea::encode(points),"editor selects native face "+index);
    check(openCJ\checkpointArea::validate(openCJ\checkpointArea::decode(openCJ\checkpointArea::encode(points)))=="","native face "+index+" serializes");
    center=(0,0,0);for(j=0;j<points.size;j++)center+=points[j];center=vectorScale(center,1.0/points.size);
    supported=true;
    for(edge=0;edge<points.size;edge++)
    {
        for(u=0;u<=16;u++)
        {
            a=points[edge]+vectorScale(points[(edge+1)%points.size]-points[edge],(u+0.02)/16.04);
            for(v=0;v<=16;v++)
            {
                sample=center+vectorScale(a-center,(v+0.02)/16.04);
                // A raised brush can intercept the ray just above the base plane.
                // Verify collision at/above that plane, not the obstacle's normal.
                hit=bulletTrace(sample+vectorScale(top["normal"],0.25),sample-vectorScale(top["normal"],0.5),false,undefined);
                if(hit["fraction"]==1 || vectorDot(hit["position"]-sample,top["normal"]) < -0.25)supported=false;
            }
        }
        wait 0.01;
    }
    check(supported,"native face "+index+" has no sampled air");
}
check(value,name)
{
    if(!value){level.brushFailures++;printf("BRUSH SELFTEST FAIL "+name+"\n");}
    else printf("BRUSH SELFTEST PASS "+name+"\n");
}
