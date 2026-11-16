main()
{
    wait 2;
    level.brushFailures=0;
    tinySquare=[];tinySquare[0]=(0,0,0);tinySquare[1]=(0.1,0,0);tinySquare[2]=(0.1,0.1,0);tinySquare[3]=(0,0.1,0);
    check(openCJ\checkpointArea::validate(tinySquare)=="","tiny square remains a valid polygon");
    check(openCJ\checkpointArea::contains(tinySquare,(0.05,0.05,0),true),"tiny square contains its center");
    check(!openCJ\checkpointArea::contains(tinySquare,(0.15,0.05,0),true),"tiny square tolerance does not extend into air");
    exact=[];exact[0]=(25766.7539,1881.37524,-27206.8047);exact[1]=(0.000123456789,-0.0123456789,131071.992);
    decoded=openCJ\checkpointArea::decode(openCJ\checkpointArea::encode(exact));
    for(i=0;i<exact.size;i++)for(a=0;a<3;a++)check(exact[i][a]==decoded[i][a],"coordinate serialization preserves exact float "+i+":"+a);


    if(getCvar("mapname")=="mp_blue2")
    {
        // The room floor continues through more than 8192 units of joined
        // brushes. Collect complete faces, then clip at the actual room walls.
        samples=[];samples[0]=(6425,-33,-2031.875);samples[1]=(6170,0,-2031.875);samples[2]=(6900,0,-2031.875);
        for(s=0;s<samples.size;s++)
        {
            joined=openCJ\checkpointPlatform::detectLandingAt(samples[s]);
            check(isDefined(joined),"large joined room floor detected "+s);
            if(isDefined(joined))
            {
                check(openCJ\checkpointArea::contains(joined,(6500,0,-2032),true),"room floor retained "+s);
                check(!openCJ\checkpointArea::contains(joined,(6920,0,-2032),true),"right room wall clips large floor "+s);
                check(!openCJ\checkpointArea::contains(joined,(6150,0,-2032),true),"left room wall clips large floor "+s);
            }
        }
    }

    origins=[];
    if(getCvar("mapname")=="mp_to_the_moon")
    {
        // Coplanar brush seam is ~0.007 units wide, below the merge tolerance.
        // A side branch leaves genuine air which must not enter the convex area.
        samples=[];samples[0]=(6768,-4350,2067.625);samples[1]=(6768,-3650,2067.625);
        for(s=0;s<samples.size;s++)
        {
            joined=openCJ\checkpointPlatform::detectLandingAt(samples[s]);
            check(isDefined(joined),"rounded brush seams produce a landing");
            if(isDefined(joined))
            {
                check(openCJ\checkpointArea::contains(joined,(6768,-4400,2067.625),true),"joined landing retains lower strip");
                check(openCJ\checkpointArea::contains(joined,(6768,-3550,2067.625),true),"joined landing retains upper strip");
                check(!openCJ\checkpointArea::contains(joined,(7000,-4200,2067.625),true),"side-branch empty space stays excluded");
            }
        }
    }

    if(getCvar("mapname")=="mp_to_the_moon")
    {
        samples=[];samples[0]=(6620,-4000,2664.625);samples[1]=(6697,-4000,2664.625);samples[2]=(6538,-4000,2664.625);
        for(s=0;s<samples.size;s++)
        {
            joined=openCJ\checkpointPlatform::detectLandingAt(samples[s]);
            check(isDefined(joined),"checkpoint 21 detected from each floor brush");
            if(isDefined(joined))
            {
                check(openCJ\checkpointArea::contains(joined,(6538,-4000,2664.625),true),"checkpoint 21 includes left strip");
                check(openCJ\checkpointArea::contains(joined,(6697,-4000,2664.625),true),"checkpoint 21 includes right strip");
                check(openCJ\checkpointArea::contains(joined,(6620,-4477,2664.625),true),"checkpoint 21 retains supported lower floor");
                check(!openCJ\checkpointArea::contains(joined,(6538,-4482,2664.625),true),"checkpoint 21 excludes real notch");
                check(!openCJ\checkpointArea::contains(joined,(6620,-4479,2664.625),true),"checkpoint 21 excludes wall");
            }
        }
    }

    if(getCvar("mapname")=="mp_to_the_moon")
    {
        // Three-unit face with less than one unit left beside a slanted wall.
        // The player can stand here with the center hanging over the edge.
        tiny=openCJ\checkpointPlatform::detectLandingAt((11012,-2090,2855));
        check(isDefined(tiny),"sub-unit ledge beside wall detected from overhanging feet");
        if(isDefined(tiny))
        {
            check(openCJ\checkpointArea::validate(tiny)=="","sub-unit ledge passes editor validation");
            check(openCJ\checkpointArea::touchesPlayer(tiny,(11012,-2090,2855),true),"sub-unit ledge triggers for supported player");
            check(!openCJ\checkpointArea::contains(tiny,(11012,-2106,2854.625),true),"sub-unit ledge excludes neighboring wall");
            check(!openCJ\checkpointArea::contains(tiny,(11012,-2104,2854.625),true),"sub-unit ledge does not expand into air");
            check(openCJ\checkpointArea::validate(openCJ\checkpointArea::decode(openCJ\checkpointArea::encode(tiny)))=="","sub-unit ledge survives draft serialization");
        }
    }

    if(getCvar("mapname")=="mp_mystic_v3")
    {
        narrow=openCJ\checkpointPlatform::detectLandingAt((20785.1,23839.9,-6719.88));
        check(isDefined(narrow),"narrow asymmetric frame detected");
        gap=bulletTrace((20785,24178.5,-6718),(20785,24178.5,-6730),false,undefined);
        check(gap["fraction"]==1,"one-unit frame gap is real empty space");
        if(isDefined(narrow))
        {
            // The component is non-convex: the larger supported rectangle near
            // this seed need not retain the entire initially hit narrow brush.
            check(openCJ\checkpointArea::contains(narrow,(20785.1,23839.9,-6719.88),true),"irregular frame retains supported seed");
            check(openCJ\checkpointArea::contains(narrow,(20850,23700,-6719.88),true),"irregular frame includes broad supported section");
            farFrame=openCJ\checkpointPlatform::detectLandingAt((20785,24100,-6719.88));
            check(isDefined(farFrame),"far narrow section remains detectable");
            if(isDefined(farFrame))
            {
                check(openCJ\checkpointArea::contains(farFrame,(20785,24177,-6719.88),true),"far narrow section retains supported far edge");
                check(!openCJ\checkpointArea::contains(farFrame,(20785,24178.5,-6719.88),true),"far narrow section excludes one-unit gap");
            }
            check(!openCJ\checkpointArea::contains(narrow,(20785,24178.5,-6719.88),true),"narrow frame never bridges the one-unit gap");
        }
        mesh=openCJ\checkpointPlatform::detectLandingAt((20863.2,23418.8,-7283.88));
        check(isDefined(mesh),"landing beside sloped collision mesh detected");
        if(isDefined(mesh))
        {
            check(openCJ\checkpointArea::contains(mesh,(20626,23372,-7283.88),true),"mesh clipping preserves left landing edge");
            check(openCJ\checkpointArea::contains(mesh,(21078,23490,-7283.88),true),"mesh clipping preserves full safe width");
            check(!openCJ\checkpointArea::contains(mesh,(20800,23520,-7283.88),true),"sloped mesh interior excluded");
            check(openCJ\checkpointArea::validate(mesh)=="","mesh-clipped polygon remains valid");
            for(v=0;v<mesh.size;v++)check(mesh[v][1]<23493,"all corners stop before mesh wall");
        }
        positions=[];positions[0]=(-2739.52,-2051.97,2480.12);positions[1]=(-2739.52,379,2480.12);
        for(i=0;i<positions.size;i++)
        {
            landing=openCJ\checkpointPlatform::detectLandingAt(positions[i]);
            check(isDefined(landing),"glass-walled landing detected "+i);
            if(isDefined(landing))
            {
                check(openCJ\checkpointArea::contains(landing,positions[i],true),"glass wall keeps supported position "+i);
                blocked=(-2750,-2090,2480.12);safe=(-2750,-2076,2480.12);
                if(i==1){blocked=(-2750,420,2480.12);safe=(-2750,402,2480.12);}
                check(!openCJ\checkpointArea::contains(landing,blocked,true),"glass wall interior excluded "+i);
                check(openCJ\checkpointArea::contains(landing,safe,true),"landing beside glass retained "+i);
            }
        }
    }
    if(getCvar("mapname")=="mp_mystic_v2")
    {
        broken=openCJ\checkpointPlatform::detectLandingAt((17920.0742,-15336.875,-16783.875));
        check(isDefined(broken),"notched frame bridge detected");
        if(isDefined(broken))
        {
            check(openCJ\checkpointArea::contains(broken,(17345,-15336,-16783.875),true),"notched bridge reaches left side");
            check(openCJ\checkpointArea::contains(broken,(18479,-15336,-16783.875),true),"notched bridge reaches right side");
            check(!openCJ\checkpointArea::contains(broken,(17920,-15260,-16783.875),true),"notch stays excluded");
            check(!openCJ\checkpointArea::contains(broken,(17920,-15000,-16783.875),true),"frame interior stays excluded");
        }
        left=openCJ\checkpointPlatform::detectLandingAt((19855.1,-13839.2,-14223.875));
        right=openCJ\checkpointPlatform::detectLandingAt((20088.7,-13823.3,-14223.875));
        check(isDefined(left) && isDefined(right),"broken symmetric platform halves detected");
        if(isDefined(left) && isDefined(right))
        {
            check(openCJ\checkpointArea::contains(left,(19830,-13761,-14223.875),true),"left half reaches upper outer edge");
            check(openCJ\checkpointArea::contains(left,(19830,-13887,-14223.875),true),"left half retains lower outer edge");
            check(openCJ\checkpointArea::contains(right,(20100,-13761,-14223.875),true),"right half retains upper outer edge");
            check(openCJ\checkpointArea::contains(right,(20100,-13887,-14223.875),true),"right half reaches lower outer edge");
            check(!openCJ\checkpointArea::contains(left,(19890,-13830,-14223.875),true),"left cutout excluded");
            check(!openCJ\checkpointArea::contains(right,(20050,-13830,-14223.875),true),"right cutout excluded");
        }
        rim=(12111,-24310,-14311.875);glass=(12088,-24332,-14311.875);
        rimPoints=openCJ\checkpointPlatform::detectLandingAt(rim);
        glassPoints=openCJ\checkpointPlatform::detectLandingAt(glass);
        check(isDefined(rimPoints) && isDefined(glassPoints),"octagon detected from rim and glass");
        if(isDefined(rimPoints) && isDefined(glassPoints))
        {
            check(rimPoints.size==8 && glassPoints.size==8,"frame and glass combine into eight outer corners");
            check(openCJ\checkpointArea::contains(rimPoints,glass,true),"rim detection includes glass interior");
            check(openCJ\checkpointArea::contains(glassPoints,rim,true),"glass detection includes outer rim");
            check(!openCJ\checkpointArea::contains(rimPoints,(12053,-24297,-14311.875),true),"octagon clipped corner stays outside");
            check(openCJ\checkpointArea::validate(rimPoints)=="","merged octagon valid");
        }
    }
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
            check(triangle.size>=3 && triangle.size<=4,"triangle retains its small collision bevel when present");
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
        check(!isDefined(platformBrushFace((640,-2763,22151.625),(0,0,1),true)),"box-only corner overlap outside circular gameplay support rejected");
        check(!isDefined(openCJ\checkpointPlatform::detectLandingAt(origin+(0,0,8))),"detector does not select lower floor");
        if(isDefined(points))
        {
            contacts=[];contacts[0]=origin;contacts[1]=edge;contacts[2]=(640,-2763,22151.625);contacts[3]=(944,-2766,22151.625);contacts[4]=origin+(0,0,8);
            for(c=0;c<contacts.size;c++)
            {
                native=isDefined(platformBrushFace(contacts[c],(0,0,1),true));
                gameplay=openCJ\checkpointArea::touchesPlayer(points,contacts[c],true);
                check(native==gameplay,"native and gameplay player contact agree "+c);
            }
        }

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
            // Joining brushes can make an old outer corner an interior point.
            // It must remain covered, but need not remain a vertex of the union.
            else if(nearest>1.25*1.25 && !openCJ\checkpointArea::contains(detected,points[v]+vectorScale(origin-points[v],0.001),true))retained=false;
        }
    if(getCvar("mapname")=="mp_futile_fixed" && index<2 && isDefined(detected))
    {
        // These boundary strips are inside player-solid sloped clip brushes,
        // not loose props. Verify the actual collision and exact clipped extent.
        if(index==0)
        {
            trace=bulletTrace((40079,8282.22,-28399.5),(40079,8479,-28399.5),false,undefined);
            retained=trace["fraction"]<1 && detected.size==4;
            for(v=0;v<detected.size;v++)if(detected[v][1]>8478.4)retained=false;
            retained=retained && openCJ\checkpointArea::contains(detected,(39105,8477,-28400),true) && openCJ\checkpointArea::contains(detected,(40597,8193,-28400),true);
        }
        else
        {
            trace=bulletTrace((42825.4,4663.34,-27877),(42921,4741,-27901.1),false,undefined);
            expected=openCJ\checkpointArea::decode("42901.6,4742,-27896.8;42705.3,4742,-27847.6;42705.3,4646,-27847.6;42922.3,4646,-27902;42922.3,4737.84,-27902");
            retained=trace["fraction"]<1 && detected.size==expected.size;
            for(v=0;v<expected.size;v++)
            {
                nearest=999999;for(w=0;w<detected.size;w++)nearest=min(nearest,distanceSquared(expected[v],detected[w]));
                if(nearest>0.1)retained=false;
            }
        }
    }
    if(getCvar("mapname")=="mp_futile_fixed" && index==3 && isDefined(detected))
    {
        // This concave assembly now selects a larger convex region, trimming
        // part of the starting brush. Require more floor, seed and no air.
        retained=polygonArea(detected)>=polygonArea(points) && openCJ\checkpointArea::contains(detected,origin,true);
        points=detected;
    }
    if(!retained && isDefined(detected))printf("SELFTEST EXTENTS raw="+openCJ\checkpointArea::encode(points)+" detected="+openCJ\checkpointArea::encode(detected)+"\n");
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

polygonArea(points)
{
    sum=(0,0,0);
    for(i=1;i<points.size-1;i++)sum+=openCJ\checkpointArea::crossProduct(points[i]-points[0],points[i+1]-points[0]);
    return length(sum)*0.5;
}
