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
    if(getCvar("mapname")=="mp_blue2")
    {
        origin=(502.735,13191.3,-367.875);
        points=openCJ\checkpointPlatform::detectLandingAt(origin);
        check(isDefined(points),"cubby detected");
        if(isDefined(points))
        {
            check(openCJ\checkpointArea::contains(points,origin,true),"cubby contains player");
            check(!openCJ\checkpointArea::contains(points,(700,13191.3,-367.875),true),"cubby excludes neighboring floor");
            check(!openCJ\checkpointArea::contains(points,(300,13191.3,-367.875),true),"cubby excludes opposite neighboring floor");
        }
    }
    if(getCvar("mapname")=="mp_galaxy")
    {
        triangleOrigin=(-2828.47998,2795.85107,21078.125);
        triangle=openCJ\checkpointPlatform::detectLandingAt(triangleOrigin);
        check(isDefined(triangle),"triangle with sub-unit collision bevel detected");
        if(isDefined(triangle))
        {
            check(triangle.size==3,"collision bevel reduced to three real corners");
            check(openCJ\checkpointArea::validate(triangle)=="","normalized triangle passes editor validation");
            check(openCJ\checkpointArea::contains(triangle,triangleOrigin,true),"triangle retains grounded player");
        }
        nextOrigin=(219.291611,-355.542236,21805.125);
        nextPoints=openCJ\checkpointPlatform::detectLandingAt(nextOrigin);
        check(isDefined(nextPoints),"next angled platform detected");
        if(isDefined(nextPoints))
        {
            check(openCJ\checkpointArea::contains(nextPoints,nextOrigin,true),"next platform retains player");
            check(!openCJ\checkpointArea::contains(nextPoints,(190.563,-311.962,21805.125),true),"54-unit wall excludes buried corner");
            clear=true;
            for(k=0;k<nextPoints.size;k++)
            {
                target=nextPoints[k]+vectorScale(nextOrigin-nextPoints[k],0.01);
                hit=bulletTrace(nextOrigin+(0,0,1),target+(0,0,1),false,undefined);
                if(hit["fraction"]<1)clear=false;
            }
            check(clear,"next platform corners all outside wall");
        }
        cornerOrigin=(280.39032,-310.745605,21757.125);
        cp=openCJ\checkpointPlatform::detectLandingAt(cornerOrigin);
        check(isDefined(cp),"angled wall landing detected without rectangle fallback");
        if(isDefined(cp))
        {
            check(openCJ\checkpointArea::validate(cp)=="","angled wall perimeter valid");
            check(openCJ\checkpointArea::contains(cp,cornerOrigin,true),"angled wall retains player");
            check(!openCJ\checkpointArea::contains(cp,(253,-280.192,21757.125),true),"buried third corner excluded");
            clear=true;
            for(k=0;k<cp.size;k++)
            {
                target=cp[k]+vectorScale(cornerOrigin-cp[k],0.01);
                hit=bulletTrace(cornerOrigin+(0,0,1),target+(0,0,1),false,undefined);
                if(hit["fraction"]<1)clear=false;
            }
            check(clear,"all resulting corners visible above platform surface");
        }
        wallOrigin=(1284.32251,-571.936157,21512.125);
        wallPoints=openCJ\checkpointPlatform::detectLandingAt(wallOrigin);
        check(isDefined(wallPoints),"single-wall landing detected");
        if(isDefined(wallPoints))
        {
            check(openCJ\checkpointArea::contains(wallPoints,wallOrigin,true),"wall-clipped landing retains player");
            check(!openCJ\checkpointArea::contains(wallPoints,(1284,-780,21512.125),true),"checkpoint stops before single wall");
            check(openCJ\checkpointArea::contains(wallPoints,(1450,-700,21512.125),true),"single wall retains full landing width");
        }
        // Grounded with the center beyond the thin ledge: real player regression.
        origin=(944.017883,-2754.125,22151.625);
        points=openCJ\checkpointPlatform::detectLandingAt(origin);
        check(isDefined(points),"thin ledge supports overhanging feet");
        if(isDefined(points))
        {
            check(openCJ\checkpointArea::validate(points)=="","thin ledge perimeter valid");
            check(!openCJ\checkpointArea::contains(points,origin,true),"ledge not expanded to include player center");
            printf("SUPPORT FACE "+openCJ\checkpointArea::encode(points)+"\n");
        }
        check(!isDefined(platformBrushFace(origin+(0,0,8),(0,0,1),true)),"nearby platform below feet rejected");
        edge=(944,-2764,22151.625);
        check(isDefined(openCJ\checkpointPlatform::detectLandingAt(edge)),"one-unit footprint overlap detected");
        check(!isDefined(platformBrushFace((944,-2766,22151.625),(0,0,1),true)),"platform beyond player footprint rejected");
        check(isDefined(platformBrushFace((640,-2763,22151.625),(0,0,1),true)),"corner footprint overlap detected");
        check(!isDefined(openCJ\checkpointPlatform::detectLandingAt(origin+(0,0,8))),"detector does not select lower floor");
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
    // Real walls along brush edges can inset by their thickness/collision padding.
    // Objects must not truncate the platform: every vertex stays within 1.25 units.
    retained=isDefined(detected) && detected.size==points.size;
    if(retained)
        for(v=0;v<points.size;v++)
        {
            nearest=999999;
            for(w=0;w<detected.size;w++)nearest=min(nearest,distanceSquared(points[v],detected[w]));
            if(getCvar("mapname")=="mp_dark" && index==3)
            {
                // Two actual boundary walls: x=-5021 and y=-1032, plus 0.125 padding.
                expected=points[v];
                if(expected[0]<-5020.875)expected=(-5020.875,expected[1],expected[2]);
                if(expected[1]<-1031.875)expected=(expected[0],-1031.875,expected[2]);
                nearest=999999;
                for(w=0;w<detected.size;w++)nearest=min(nearest,distanceSquared(expected,detected[w]));
                if(nearest>0.01)retained=false;
            }
            else if(nearest>1.25*1.25)retained=false;
        }
    check(retained,"editor retains brush extent around objects "+index);
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
