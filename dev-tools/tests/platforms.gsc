// Geometry-only engine tests; no draft or database mutations.
main()
{
    wait 2;
    level.cpcTestFailures = 0;
    if (getCvar("mapname") == "mp_dark")
    {
        small = openCJ\checkpointPlatform::detectAt((4392.528320,4160.322266,-735.972107));
        check(isDefined(small), "detect small tapered Hard slope");
        if (isDefined(small))
        {
            check(openCJ\checkpointArea::validate(small) == "", "small tapered slope has valid perimeter");
            check(openCJ\checkpointArea::contains(small,(4392.528320,4160.322266,-735.972107),true), "small slope contains grounded player");
            check(!openCJ\checkpointArea::contains(small,(4392.5,4141.9,-745.57),true), "unsupported tapered tip is excluded");
            normal = openCJ\checkpointArea::planeNormal(small);
            supported = true;
            along = vectorNormalize(small[1]-small[0]);
            across = vectorNormalize(small[3]-small[0]);
            for (x=0;x<=8;x++)
            {
                for (y=0;y<=8;y++)
                {
                    p=small[0]+vectorScale(along,0.5)+vectorScale(across,0.5);
                    p+=vectorScale(small[1]-small[0]-along,x/8.0)+vectorScale(small[3]-small[0]-across,y/8.0);
                    if (!openCJ\checkpointPlatform::_sameTop(p,normal)) supported=false;
                }
            }
            check(supported, "small slope interior and inset edges are supported");
        }
        green = openCJ\checkpointPlatform::detectAt((21168.140625,383.943176,-2415.875));
        check(isDefined(green), "detect Hard platform beside inclined green wall");
        if (isDefined(green))
        {
            check(openCJ\checkpointArea::validate(green) == "", "green-wall landing is a valid rectangle");
            check(openCJ\checkpointArea::contains(green,(21168.140625,383.943176,-2415.875),true), "green-wall landing contains actual player position");
            supported = true;
            for (x=0;x<=4;x++)
            {
                for (y=0;y<=16;y++)
                {
                    p=(green[1][0]+0.5+(green[0][0]-green[1][0]-1)*x/4.0,green[2][1]+0.5+(green[1][1]-green[2][1]-1)*y/16.0,green[0][2]);
                    if (!openCJ\checkpointPlatform::_sameTop(p)) supported=false;
                }
            }
            check(supported, "green-wall landing supported across interior and inset edges");
        }
        narrowGap = openCJ\checkpointPlatform::detectAt((-526.78186,-1365.322876,-5624.875));
        check(isDefined(narrowGap), "detect platform separated from wall by narrow gap");
        if (isDefined(narrowGap))
        {
            check(abs(narrowGap[0][0] + 464.875) < 0.01, "use drop edge instead of nearby wall face");
            check(!openCJ\checkpointArea::contains(narrowGap,(-464.625,-1365,-5624.875),true), "narrow gap excluded from checkpoint area");
        }
        trimmed = openCJ\checkpointPlatform::detectAt((-4947.176758,-987.563171,-535.875));
        check(isDefined(trimmed), "detect platform with partial wall overlap");
        if (isDefined(trimmed))
        {
            check(abs(trimmed[1][0] + 5020.875) < 0.01, "trim overlapped edge to actual wall face");
            supported = true;
            for (x = 0; x <= 8; x++)
            {
                for (y = 0; y <= 8; y++)
                {
                    point = (-5020.375 + 146 * x / 8, -1031.375 + 124 * y / 8, -535.875);
                    if (!openCJ\checkpointPlatform::_sameTop(point))
                        supported = false;
                }
            }
            check(supported, "trimmed rectangle has supported interior and edges");
        }
        landing = openCJ\checkpointPlatform::detectAt((-554.897949,-46.286156,-697.875));
        other = openCJ\checkpointPlatform::detectAt((-600,450,-697.875));
        check(isDefined(landing) && isDefined(other), "detect long mp_dark landing beside wall");
        if (isDefined(landing) && isDefined(other))
        {
            check(openCJ\checkpointArea::encode(landing) == openCJ\checkpointArea::encode(other), "same boundary from different landing positions");
            check(openCJ\checkpointArea::validate(landing) == "", "detected landing has valid perimeter");
            wall = openCJ\checkpointPlatform::_side((-554.897949,-46.286156,-698.875), (1,0,0));
            check(isDefined(wall) && abs(wall["position"][0] + 433.125) < 0.01 && wall["normal"][0] > 0.999, "adjoining wall uses near face and outward normal");
            supported = true;
            // Sample the interior, including points half a unit from each edge.
            for (x = 0; x <= 8; x++)
            {
                for (y = 0; y <= 32; y++)
                {
                    point = (-744.625 + 311 * x / 8, -1018.625 + 1823.25 * y / 32, -697.875);
                    if (!openCJ\checkpointPlatform::_sameTop(point))
                        supported = false;
                }
            }
            check(supported, "detected mp_dark rectangle supported across its interior");
        }
    }

    if ((getCvar("mapname") == "mp_futile" || getCvar("mapname") == "mp_futile_fixed"))
    {
        origin = (25333.9004,1882.79773,-27331.0879);
        points = openCJ\checkpointPlatform::detectAt(origin);
        check(isDefined(points), "detect tapered mp_futile slope near its edge");
        if (isDefined(points))
        {
            check(openCJ\checkpointArea::validate(points) == "", "slope has valid convex perimeter");
            check(openCJ\checkpointArea::contains(points, origin, true), "slope contains grounded player");
            normal = openCJ\checkpointArea::planeNormal(points);
            supported = true;
            for (x = 0; x <= 16; x++)
            {
                for (y = 0; y <= 16; y++)
                {
                    u = 0.001 + 0.998*x/16.0;
                    v = 0.001 + 0.998*y/16.0;
                    a = points[0] + vectorScale(points[1]-points[0],u);
                    b = points[3] + vectorScale(points[2]-points[3],u);
                    p = a + vectorScale(b-a,v);
                    if (!openCJ\checkpointPlatform::_sameTop(p,normal)) supported = false;
                }
            }
            check(supported, "slope supports all 289 inset perimeter and interior samples");
        }
    }
    if ((getCvar("mapname") == "mp_futile" || getCvar("mapname") == "mp_futile_fixed")) { cutoutTest(); wallSlopeTest(); raisedTest(); }
    printf("PLATFORM SELFTEST COMPLETE failures="+level.cpcTestFailures+"\n");
}
check(value, name)
{
    if (!value)
    {
        level.cpcTestFailures++;
        printf("CPC SELFTEST FAIL: " + name + "\n");
    }
    else
        printf("CPC SELFTEST PASS: " + name + "\n");
}


// Keep the supported strip containing the editor, rather than filling a notch.
cutoutTest()
{
    origin=(25766.7539,1881.37524,-27206.8047);
    points=openCJ\checkpointPlatform::detectAt(origin);
    check(isDefined(points), "detect solid section of notched mp_futile slope");
    if(!isDefined(points))return;
    check(openCJ\checkpointArea::validate(points)=="", "notched platform selection is valid");
    check(openCJ\checkpointArea::contains(points,origin,true), "notched selection contains editor");
    top=bulletTrace(origin+(0,0,2),origin-(0,0,24),false,undefined);
    normal=top["normal"];
    supported=true;
    for(x=0;x<=64;x++)
    {
        for(y=0;y<=64;y++)
        {
            u=0.001+0.998*x/64.0;v=0.001+0.998*y/64.0;
            a=points[0]+vectorScale(points[1]-points[0],u);
            b=points[3]+vectorScale(points[2]-points[3],u);
            pt=a+vectorScale(b-a,v);
            if(!openCJ\checkpointPlatform::_sameTop(pt,normal))supported=false;
        }
        if(x%8==0)wait 0.01;
    }
    check(supported,"all 4225 samples inside trimmed selection have collision support");
    axis=vectorNormalize((normal[2],0,0-normal[0]));
    gap=top["position"]-vectorScale(axis,128);
    check(!openCJ\checkpointPlatform::_sameTop(gap,normal),"cutout test position really is unsupported");
    check(!openCJ\checkpointArea::contains(points,gap,true),"missing chunk is outside the checkpoint");
}

wallSlopeTest()
{
    origin=(35584.875,6391.88477,-27909.1738);
    points=openCJ\checkpointPlatform::detectAt(origin);
    check(isDefined(points),"detect narrow slope against mp_futile wall");
    if(!isDefined(points))return;
    check(openCJ\checkpointArea::validate(points)=="","wall slope perimeter is valid");
    check(openCJ\checkpointArea::contains(points,origin,true),"wall slope contains grounded editor");
    top=bulletTrace(origin+(0,0,2),origin-(0,0,24),false,undefined);
    supported=true;
    for(x=0;x<=8;x++)
    {
        for(y=0;y<=128;y++)
        {
            u=0.04+0.92*x/8.0;v=0.0002+0.9996*y/128.0;
            a=points[0]+vectorScale(points[1]-points[0],u);
            b=points[3]+vectorScale(points[2]-points[3],u);
            pt=a+vectorScale(b-a,v);
            if(!openCJ\checkpointPlatform::_sameTop(pt,top["normal"]))supported=false;
        }
        wait 0.01;
    }
    check(supported,"all 1161 wall slope samples have collision support");
    check(!openCJ\checkpointArea::contains(points,origin-(2,0,0),true),"air beside narrow slope excluded");
}

raisedTest()
{
    origin=(42825.3828,4663.33887,-27877.0723);
    points=openCJ\checkpointPlatform::detectAt(origin);
    check(isDefined(points),"detect landing with raised oblique brush");
    if(!isDefined(points))return;
    check(openCJ\checkpointArea::validate(points)=="","raised-brush landing has valid perimeter");
    check(openCJ\checkpointArea::contains(points,origin,true),"raised-brush landing contains editor");
    top=bulletTrace(origin+(0,0,2),origin-(0,0,24),false,undefined);
    supported=true;obstructed=0;
    for(x=0;x<=32;x++)
    {
        for(y=0;y<=32;y++)
        {
            u=0.003+0.994*x/32.0;v=0.006+0.988*y/32.0;
            a=points[0]+vectorScale(points[1]-points[0],u);
            b=points[3]+vectorScale(points[2]-points[3],u);
            pt=a+vectorScale(b-a,v);
            if(!openCJ\checkpointPlatform::_sameTop(pt,top["normal"]))
            {
                if(openCJ\checkpointPlatform::_solidAt(pt,top["normal"]))obstructed++;
                else supported=false;
            }
        }
    }
    check(supported,"all 1089 landing samples are supported or obstructed by solid, not air");
    check(obstructed>0,"test includes the raised brush");
    probe=(42922,4741.62,-27901.7);
    raised=bulletTrace(probe+(0,0,256),probe-(0,0,1),false,undefined);
    check(raised["fraction"]<1 && !openCJ\checkpointArea::contains(points,raised["position"],true),"raised brush top does not pass lower checkpoint");
}
