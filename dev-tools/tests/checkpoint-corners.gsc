main()
{
    wait 1;
    level.failures = 0;
    base = [];
    base[0] = (0, 0, 0);
    base[1] = (100, 0, 0);
    base[2] = (100, 100, 0);
    base[3] = (0, 100, 0);
    permutations = 0;
    // Exhaust this fixed four-corner input; the nested loops contain only scenario setup.
    for(a = 0; a < 4; a++)
    {
        for(b = 0; b < 4; b++)
        {
            for(c = 0; c < 4; c++)
            {
                for(d = 0; d < 4; d++)
                {
                    if(a == b || a == c || a == d || b == c || b == d || c == d)
                    {
                        continue;
                    }
                    points = [];
                    points[0] = base[a];
                    points[1] = base[b];
                    points[2] = base[c];
                    points[3] = base[d];
                    checkClickOrder(points, "" + a + b + c + d);
                    permutations++;
                }
            }
        }
    }
    check(permutations == 24, "all click orders exercised");
    bad = [];
    bad[0] = (0, 0, 0);
    bad[1] = (100, 0, 0);
    bad[2] = (100, 100, 0);
    bad[3] = (50, 40, 0);
    check(openCJ\checkpointArea::validate(openCJ\checkpointArea::orderCorners(bad)) != "",
          "interior corner rejected");
    bad[3] = (0, 100, 10);
    check(openCJ\checkpointArea::validate(openCJ\checkpointArea::orderCorners(bad)) != "",
          "nonplanar selection rejected");
    bad[3] = bad[0];
    check(openCJ\checkpointArea::validate(openCJ\checkpointArea::orderCorners(bad)) != "",
          "duplicate retained and rejected");
    printf("CORNERS SELFTEST COMPLETE failures=" + level.failures + "\n");
}
check(ok, message)
{
    if(!ok)
    {
        level.failures++;
        printf("CORNERS SELFTEST FAIL " + message + "\n");
    }
}

// The 24 click orders must keep every corner and the same sloped/flat footprint.
checkClickOrder(points, clickOrder)
{
    ordered = openCJ\checkpointArea::orderCorners(points);
    check(openCJ\checkpointArea::validate(ordered) == "", "rectangle permutation " + clickOrder);
    check(ordered.size == 4 && openCJ\checkpointArea::contains(ordered, (50, 50, 0), true),
          "rectangle area preserved " + clickOrder);
    for(i = 0; i < 4; i++)
    {
        found = false;
        for(j = 0; j < 4; j++)
        {
            if(points[i] == ordered[j])
            {
                found = true;
            }
        }
        check(found, "selected point " + i + " preserved in " + clickOrder);
        points[i] = (points[i][0], points[i][1], points[i][0] * 0.25);
    }
    check(openCJ\checkpointArea::validate(openCJ\checkpointArea::orderCorners(points)) == "",
          "sloped rectangle permutation " + clickOrder);
}
