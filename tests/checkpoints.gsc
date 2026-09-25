// Run on an isolated smoke server after OpenCJ init; never on the live map.
main()
{
    wait 1;
    level.cpcTestFailures = 0;
    ambientTest();
    slopeTests();
    check(openCJ\checkpointCreation::defaultRouteColor("EaSy") == "#00ff00", "route palette is case insensitive");
    check(openCJ\checkpointCreation::defaultRouteColor("Advanced+") == openCJ\checkpointCreation::defaultRouteColor("adv+"), "advanced color aliases agree");
    check(openCJ\checkpointCreation::_validName("inter+") && openCJ\checkpointCreation::_validName("advanced+"), "plus difficulty route names accepted");
    check(openCJ\checkpointCreation::routeRGB("#FFFFFF") == (1,1,1), "explicit white hex color accepted");
    check(openCJ\checkpointCreation::routeRGB("#ff00ff") == (1,0,1), "hex color channels decoded");
    check(!isDefined(openCJ\checkpointCreation::routeRGB("#ff00fg")) && !isDefined(openCJ\checkpointCreation::routeRGB("#fff")), "malformed colors rejected");
    hud = newHudElem();
    openCJ\checkpointCreation::configureHud(hud);
    check(hud.archived && hud.fontScale >= 1.4, "editor HUD engine properties");
    hud destroy();
    longText = "";
    for (i = 0; i < 400; i++)
        longText += "x";
    check(openCJ\checkpointCreation::boundedHudText(longText).size == 240, "panel text stays below client 255-character limit");
    check(openCJ\checkpointCreation::boundedHudText("CHECKPOINT EDITOR") == "CHECKPOINT EDITOR", "short panel text preserved");
    // A rotated rectangular brush must be reconstructed in its face axes.
    ds = []; ds[0]=30; ds[1]=20; ds[2]=10; ds[3]=40;
    rect = openCJ\checkpointPlatform::rectangle((0,0,10), (0.6,0.8,0), (-0.8,0.6,0), ds);
    check(distanceSquared(rect[0], (2,36,10)) < 0.001, "rectangle uses collision orientation");
    check(openCJ\checkpointArea::validate(rect) == "", "rotated detector corners form convex perimeter");
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
    points = [];
    points[0] = (0, 0, 10);
    points[1] = (100, 0, 10);
    points[2] = (100, 100, 10);
    points[3] = (0, 100, 10);
    check(openCJ\checkpointArea::validate(points) == "", "valid rectangle");
    check(openCJ\checkpointArea::contains(points, (50, 50, 10), true), "inside grounded");
    check(!openCJ\checkpointArea::contains(points, (50, 50, 10), false), "airborne rejected");
    check(!openCJ\checkpointArea::contains(points, (101, 50, 10), true), "outside edge");
    check(openCJ\checkpointArea::contains(points, (50, 50, 14), true), "landing-volume upper boundary included");
    check(!openCJ\checkpointArea::contains(points, (50, 50, 14.1), true), "above landing-volume volume rejected");
    check(!openCJ\checkpointArea::contains(points, (50, 50, 7.9), true), "below floor tolerance rejected");
    check(!openCJ\checkpointArea::contains(points, (50, 50, 12), false, true), "grounded checkpoint rejects airborne player inside volume");
    check(openCJ\checkpointArea::contains(points, (50, 50, 12), false, false), "airborne checkpoint skips ground requirement");
    check(!openCJ\checkpointArea::contains(points, (101, 50, 12), false, false), "airborne checkpoint still requires horizontal containment");
    check(!openCJ\checkpointArea::contains(points, (50, 50, 15), false, false), "airborne checkpoint still requires vertical containment");
    check(openCJ\checkpointArea::contains(points, (100, 50, 10), true), "boundary included");
    reverse = [];
    for (i = 0; i < 4; i++)
        reverse[i] = points[3-i];
    check(openCJ\checkpointArea::validate(reverse) == "", "reverse winding accepted");
    check(openCJ\checkpointArea::contains(reverse, (50, 50, 10), true), "reverse winding detection");
    crossed = [];
    crossed[0] = points[0]; crossed[1] = points[2]; crossed[2] = points[1]; crossed[3] = points[3];
    check(openCJ\checkpointArea::validate(crossed) != "", "crossed polygon rejected");
    parsed = openCJ\checkpointArea::decode(openCJ\checkpointArea::encode(points));
    check(isDefined(parsed) && parsed.size == 4 && parsed[2] == points[2], "geometry serialization");
    check(!isDefined(openCJ\checkpointArea::decode("1,wat,3")), "invalid geometry input rejected");

    // Draft persistence and interrupted-save recovery, using a non-player script struct.
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.eventQueue = [];
    editor.cpc.finalizing = true;
    editor.cpc.restoreOrigin = (1,2,3);
    editor.anyPct = false;
    editor.checkpoints_passed = [];
    editor openCJ\checkpoints::whileAlive();
    editor openCJ\checkpointCreation::processTravelRequests();
    check(!editor.anyPct && editor.checkpoints_passed.size == 0, "finalizing editor suppresses checkpoint scoring while fresh run is pending");
    check(editor.cpc.restoreOrigin == (1,2,3), "pending finalization cannot restore travel position over fresh spawn");
    editor.cpc.finalizing = undefined;
    editor.cpc.restoreOrigin = undefined;
    editor openCJ\events\eventHandler::onSavePositionRequest();
    editor openCJ\events\eventHandler::onLoadPositionRequest(1);
    check(isDefined(editor.eventQueue["save"]) && editor.eventQueue["load"] == 1, "CPC travel requests queued outside command callback");
    editor.cpc.route = "cpc_selftest";
    editor.cpc.path = "checkpoints/selftest";
    editor.cpc.routeHex = "#12abef";
    editor.cpc.rows = [];
    cp = openCJ\checkpointCreation::_empty();
    cp.points = points;
    cp.finish = true;
    cp.double = true;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(cp);
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    editor.cpc.selected = 1;
    editor.cpc.revision = 0;
    check(editor openCJ\checkpointCreation::_save(), "save draft");
    loaded = openCJ\checkpointCreation::_read("checkpoints/selftest.b", "cpc_selftest");
    check(isDefined(loaded) && loaded.rows.size == 1 && loaded.revision == 1, "reopen draft");
    check(openCJ\checkpointCreation::restoreOrigin(loaded) == (50,50,12), "empty next selection restores last confirmed landing center");
    check(loaded.routeHex == "#12abef", "draft preserves exact custom route color");
    check(!isDefined(openCJ\checkpointCreation::_read("checkpoints/selftest.b", "wrong_route")), "wrong route rejected");
    file = FS_FOpen("checkpoints/selftest.a", "write");
    FS_WriteLine(file, "CPC2 " + getCvar("mapname") + " cpc_selftest 2 1 1");
    FS_FClose(file);
    check(!isDefined(openCJ\checkpointCreation::_read("checkpoints/selftest.a", "cpc_selftest")), "interrupted save rejected");
    check(isDefined(openCJ\checkpointCreation::_read("checkpoints/selftest.b", "cpc_selftest")), "previous save survives");
    FS_Remove("checkpoints/selftest.a");
    FS_Remove("checkpoints/selftest.b");

    // Exercise actual SQL publication but roll it back; no checkpoint definitions survive.
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    ok = editor openCJ\checkpointPublish::_writeRoute();
    check(ok, "publish transaction");
    if (!ok)
        printf("CPC TEST DETAIL: " + editor.cpc.status + "\n");
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT vertices,allowDoubleRPG FROM checkpointAreas WHERE routeName='cpc_selftest' AND mapID=" + openCJ\mapID::getMapID());
    check(isDefined(rows) && rows.size == 1 && int(rows[0][1]) == 1, "published geometry and approach allowance");
    colors = openCJ\mySQL::mysqlSyncQuery("SELECT colorRGB FROM routes r JOIN checkpointAreas a ON a.cpID=r.cpID WHERE a.routeName='cpc_selftest' AND a.mapID=" + openCJ\mapID::getMapID());
    check(isDefined(colors) && colors.size == 1 && int(colors[0][0]) == 1223663, "route stores one exact packed RGB color at its start");
    openCJ\checkpoints::onInit();
    published = undefined;
    for (i = 0; i < level.checkpoints_checkpoints.size; i++)
    {
        candidate = level.checkpoints_checkpoints[i];
        if (isDefined(candidate.ender) && candidate.ender == "cpc_selftest")
            published = candidate;
    }
    check(isDefined(published) && isDefined(published.area), "runtime loads published area");
    if (isDefined(published))
    {
        check(isDefined(published.routeInfo) && published.routeInfo.hex == "#12abef", "runtime loads route metadata with exact custom color");
        check(openCJ\checkpointArea::contains(published.area, (50, 50, 10), true), "runtime uses same area test");
        player = spawnStruct();
        player.checkpoints_checkpoint = spawnStruct();
        player.checkpoints_checkpoint.childs = [];
        player.checkpoints_checkpoint.childs[0] = published;
        check(player openCJ\checkpoints::nextAllowsDoubleRPG(), "next checkpoint grants approach allowance");
        player.checkpoints_checkpoint.childs[1] = published;
        check(!player openCJ\checkpoints::nextAllowsDoubleRPG(), "ambiguous next checkpoint does not grant allowance");
    }
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    openCJ\checkpoints::onInit();
    rows = openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName='cpc_selftest' AND mapID=" + openCJ\mapID::getMapID());
    check(isDefined(rows) && rows.size == 0, "publication rollback");
    alternativeTests(points);
    finalizationTests(points);
    gameplayTests();
    branchTests(points);
    networkTests(points);
    networkCommandTest(points);
    networkDiscoveryTest(points);
    manyAlternativeTests(points);
    discardAndFinishTests(points);
    printf("CPC SELFTEST COMPLETE failures=" + level.cpcTestFailures + "\n");
}

finalizationTests(points)
{
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.cpc.route = "cpc_selftest";
    editor.cpc.rows = [];
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    cp = openCJ\checkpointCreation::_empty();
    cp.points = points;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(cp);
    check(openCJ\checkpointPublish::validationError(editor.cpc.rows) != "", "finalization rejects missing finish");
    cp.finish = true;
    editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(cp);
    editor.cpc.rows[2] = openCJ\checkpointCreation::_encode(cp);
    check(openCJ\checkpointPublish::validationError(editor.cpc.rows) == "", "multiple terminal finishes accepted");
    editor.cpc.selected = editor.cpc.rows.size;
    check(openCJ\checkpointCreation::readyToFinalize(editor.cpc), "confirmed finish with empty next slot displays saved finish summary");
    editor.cpc.draft.points = points;
    check(!openCJ\checkpointCreation::readyToFinalize(editor.cpc), "unfinished next area is not hidden by finish summary");
    editor.cpc.draft.points = [];
    editor.cpc.draft.alternatives[0] = points;
    check(!openCJ\checkpointCreation::readyToFinalize(editor.cpc), "unfinished alternative is not hidden by finish summary");
    editor.cpc.draft.alternatives = [];
    editor.cpc.selected = 1;
    check(!openCJ\checkpointCreation::readyToFinalize(editor.cpc), "editing a confirmed finish stays editable");
    editor.cpc.selected = editor.cpc.rows.size;
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    check(editor openCJ\checkpointPublish::_writeRoute(), "write multiple finish route");
    openCJ\checkpointPublish::activate();
    finishes = 0;
    for (i=0;i<level.checkpoints_checkpoints.size;i++)
    {
        cp = level.checkpoints_checkpoints[i];
        if (isDefined(cp.ender) && cp.ender == "cpc_selftest")
        {
            finishes++;
            check(cp.childs.size == 0, "each finish is a terminal checkpoint");
            parents = openCJ\checkpoints::getCheckpointParents(cp);
            check(parents.size == 1 && parents[0].childs.size == 2, "both finishes branch from last regular checkpoint");
        }
    }
    check(finishes == 2, "both finishes immediately active without map reload");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    openCJ\checkpoints::onInit();
    editor.cpc.rows[2] = editor.cpc.rows[0];
    check(openCJ\checkpointPublish::validationError(editor.cpc.rows) != "", "ordinary checkpoint after finish rejected");
}

slopeTests()
{
    ds = []; ds[0]=60; ds[1]=40; ds[2]=60; ds[3]=40;
    points = openCJ\checkpointPlatform::rectangle((0,0,10), (0.48,0.64,0.6), (-0.8,0.6,0), ds);
    check(openCJ\checkpointArea::validate(points) == "", "tilted rotated rectangle accepted");
    check(openCJ\checkpointArea::validate(openCJ\checkpointArea::decode(openCJ\checkpointArea::encode(points))) == "", "sloped corners survive storage");
    for (i = -1; i <= 1; i++)
    {
        p = (14.4*i,19.2*i,10+18*i);
        check(openCJ\checkpointArea::contains(points,p+(0,0,3.75),true), "capsule supported at different slope heights");
        check(!openCJ\checkpointArea::contains(points,p+(0,0,10),true), "above slope rejected");
        check(!openCJ\checkpointArea::contains(points,p,false), "slope still requires ground contact");
        check(openCJ\checkpointArea::contains(points,p,false,false), "airborne flag skips ground check on slope");
    }
    reversed = []; for (i=0;i<4;i++) reversed[i]=points[3-i];
    check(openCJ\checkpointArea::contains(reversed,(0,0,13.75),true), "sloped reverse winding supported");
    points[3] += (0,0,5);
    check(openCJ\checkpointArea::validate(points) != "", "nonplanar corners rejected");
    if (getCvar("mapname") != "mp_dark")
        return;
    origin = (-1361.408569,-2009.623901,-2805.766113);
    points = openCJ\checkpointPlatform::detectAt(origin);
    check(isDefined(points), "detect actual rotated mp_dark slope");
    if (!isDefined(points))
        return;
    check(openCJ\checkpointArea::validate(points) == "", "actual slope perimeter valid");
    check(openCJ\checkpointArea::contains(points,origin,true), "actual grounded player triggers slope");
    normal = openCJ\checkpointArea::planeNormal(points);
    supported = true;
    for (x=1;x<10;x++)
    {
        for (y=1;y<10;y++)
        {
            p = points[0] + vectorScale(points[1]-points[0],x/10.0) + vectorScale(points[3]-points[0],y/10.0);
            if (!openCJ\checkpointPlatform::_sameTop(p,normal)) supported=false;
        }
    }
    check(supported, "slope rectangle has supported interior");
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.cpc.route = "cpc_selftest";
    editor.cpc.rows = [];
    editor.cpc.selected = 0;
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    editor.cpc.draft.points = points;
    editor.cpc.draft.finish = true;
    restored = openCJ\checkpointCreation::restoreOrigin(editor.cpc);
    check(openCJ\checkpointArea::contains(points,restored,true), "restored slope position is inside checkpoint volume");
    check(isDefined(openCJ\checkpointPlatform::detectAt(restored)), "slope remains detectable from restored center");
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(editor.cpc.draft);
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    check(editor openCJ\checkpointPublish::_writeRoute(), "publish sloped checkpoint transaction");
    openCJ\checkpoints::onInit();
    found = false;
    for (i=0;i<level.checkpoints_checkpoints.size;i++)
    {
        cp = level.checkpoints_checkpoints[i];
        if (isDefined(cp.ender) && cp.ender == "cpc_selftest" && isDefined(cp.area))
            found = openCJ\checkpointArea::contains(cp.area,origin,true);
    }
    check(found, "published slope reloads and triggers at actual player position");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    openCJ\checkpoints::onInit();
}

alternativeTests(points)
{
    editor = spawnStruct();
    editor.cpc = spawnStruct();
    editor.cpc.route = "cpc_selftest";
    editor.cpc.rows = [];
    cp = openCJ\checkpointCreation::_empty();
    cp.points = points;
    cp.double = true;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(cp);
    editor.cpc.selected = 1;
    editor.cpc.draft = openCJ\checkpointCreation::_empty();
    editor openCJ\checkpointCreation::_addAlternative();
    check(editor.cpc.selected == 0 && editor.cpc.draft.points.size == 0 && editor.cpc.draft.alternatives.size == 1, "alternative reopens last confirmed checkpoint without adding a step");
    pending = openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(editor.cpc.draft));
    check(isDefined(pending) && pending.points.size == 0 && pending.alternatives.size == 1, "unfinished alternative survives serialization");
    editor.cpc.path = "checkpoints/selftest";
    editor.cpc.routeHex = "#12abef";
    editor.cpc.revision = 0;
    check(editor openCJ\checkpointCreation::_save(), "save unfinished alternative draft");
    restored = openCJ\checkpointCreation::_read("checkpoints/selftest.b", "cpc_selftest");
    check(isDefined(restored) && restored.selected == 0 && restored.draft.points.size == 0 && restored.draft.alternatives.size == 1, "reopen unfinished alternative without losing original landing");
    check(openCJ\checkpointCreation::restoreOrigin(restored) == (50,50,12), "unfinished alternative restores existing sibling center");
    FS_Remove("checkpoints/selftest.b");
    other = [];
    for (i = 0; i < points.size; i++)
        other[i] = points[i] + (200,0,0);
    editor.cpc.draft.points = other;
    check(openCJ\checkpointCreation::restoreOrigin(editor.cpc) == (250,50,12), "active alternative takes precedence over confirmed checkpoint position");
    cp = editor.cpc.draft;
    check(openCJ\checkpointCreation::contains(cp,(50,50,10),true) && openCJ\checkpointCreation::contains(cp,(250,50,10),true), "either alternative completes editor test step");
    check(!openCJ\checkpointCreation::contains(cp,(150,50,10),true), "space between alternatives does not count");
    check(!openCJ\checkpointCreation::contains(cp,(250,50,10),false), "alternatives still require landing");
    third = [];
    for (i = 0; i < points.size; i++)
        third[i] = points[i] + (400,0,0);
    cp.alternatives[cp.alternatives.size] = third;
    roundtrip = openCJ\checkpointCreation::_decode(openCJ\checkpointCreation::_encode(cp));
    check(isDefined(roundtrip) && roundtrip.alternatives.size == 2 && openCJ\checkpointCreation::contains(roundtrip,(450,50,10),true), "third landing survives serialization and completes the same step");
    start = openCJ\checkpointCreation::_empty();
    start.points = points;
    editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(start);
    editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(cp);
    finish = openCJ\checkpointCreation::_empty();
    finish.points = points;
    finish.finish = true;
    editor.cpc.rows[2] = openCJ\checkpointCreation::_encode(finish);
    old = openCJ\checkpointCreation::_decode("0:1:p0,0,10;100,0,10;100,100,10;0,100,10");
    check(isDefined(old) && old.alternatives.size == 0, "legacy single-area draft remains readable");
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    ok = editor openCJ\checkpointPublish::_writeRoute();
    check(ok, "publish alternative group and shared successor");
    if (ok)
    {
        rows = openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName='cpc_selftest' AND mapID=" + openCJ\mapID::getMapID() + " ORDER BY ordinal");
        check(rows.size == 5, "three-way alternative produces five physical areas across three steps");
        check(editor openCJ\checkpointPublish::_writeRoute(), "republish preserves alternative grouping and IDs");
        openCJ\checkpoints::onInit();
        preceding = openCJ\checkpoints::getCheckpointByID(int(rows[0][0]));
        primary = openCJ\checkpoints::getCheckpointByID(int(rows[1][0]));
        alternate = openCJ\checkpoints::getCheckpointByID(int(rows[2][0]));
        thirdArea = openCJ\checkpoints::getCheckpointByID(int(rows[3][0]));
        merged = openCJ\checkpoints::getCheckpointByID(int(rows[4][0]));
        check(preceding.childs.size == 3, "preceding checkpoint connects to all three alternatives");
        check(thirdArea.bigBrother == primary && thirdArea.childs.size == 1 && thirdArea.childs[0] == merged, "third area shares checkpoint identity and successor");
        check(isDefined(alternate.bigBrother) && alternate.bigBrother == primary, "runtime alternatives share canonical checkpoint");
        check(primary.childs.size == 1 && alternate.childs.size == 1 && primary.childs[0] == merged && alternate.childs[0] == merged, "both alternatives merge into same successor");
        player = spawnStruct();
        player.checkpoints_checkpoint = spawnStruct();
        player.checkpoints_checkpoint.childs = [];
        player.checkpoints_checkpoint.childs[0] = primary;
        player.checkpoints_checkpoint.childs[1] = alternate;
        check(player openCJ\checkpoints::nextAllowsDoubleRPG(), "equivalent next areas grant shared double RPG");
        player.checkpoints_passed = [];
        player.checkpoints_passed[0] = primary;
        check(player openCJ\checkpoints::hasPassedCheckpoint(alternate), "visiting second alternative cannot score twice");
        player.checkpoints_passed[0] = alternate;
        check(player openCJ\checkpoints::hasPassedCheckpoint(primary), "either alternative marks the group passed");
        check(!player openCJ\checkpoints::_checkAnyPctTriggered(primary, preceding.childs) && !player openCJ\checkpoints::_checkAnyPctTriggered(alternate, preceding.childs), "either branch is valid without any-percent penalty");
        check(!player openCJ\checkpoints::_checkAnyPctTriggered(merged, alternate.childs), "alternate branch reconnects without any-percent penalty");
        editor.cpc.rows[0] = openCJ\checkpointCreation::_encode(cp);
        editor.cpc.rows[1] = openCJ\checkpointCreation::_encode(start);
        check(!(editor openCJ\checkpointPublish::_writeRoute()), "republish rejects changed grouping even with equal area count");
    }
    else
        printf("CPC TEST DETAIL: " + editor.cpc.status + "\n");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    openCJ\checkpoints::onInit();
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

// Real published-map traversal and transaction-only leaderboard rows.
gameplayTests()
{
    player = spawnStruct();
    player.route = "old_route";
    player openCJ\checkpoints::resetPlayerCheckpointsToStart();
    check(!isDefined(player.route), "fresh run forgets previous route selection");
    player.anyPct = false;
    next = player openCJ\checkpointPointers::nextVisibleCheckpoints();
    check(next.size == level.checkpoints_startCheckpoint.childs.size, "spawn shows first checkpoint areas of every route");
    for (i=0;i<next.size;i++)
    {
        cp=next[i];
        route=openCJ\checkpoints::getRouteNameForCheckpoint(cp);
        if (!isDefined(route)) continue;
        player.route=route;
        player.checkpoints_checkpoint=cp;
        visible=player openCJ\checkpointPointers::nextVisibleCheckpoints();
        check(visible.size == cp.childs.size, "selected route shows only its immediate successors");
        if(cp.childs.size > 0)
        {
            child=cp.childs[0];
            check(!(player openCJ\checkpoints::_checkAnyPctTriggered(child,cp.childs)), "next checkpoint preserves normal category");
            if(child.childs.size > 0)
                check(player openCJ\checkpoints::_checkAnyPctTriggered(child.childs[0],cp.childs), "skipping a checkpoint selects any-percent category");
        }
    }
    player.anyPct=true;
    ends=openCJ\checkpoints::getAllEndCheckpoints();
    visible=player openCJ\checkpointPointers::nextVisibleCheckpoints();
    check(visible.size == ends.size, "any-percent shows every route finish");
    if(ends.size == 0) return;
    owners=openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
    if(!isDefined(owners) || !isDefined(owners[0][0])) return;
    cpID=ends[0].id;
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    for (mode=0;mode<2;mode++)
    {
        row=openCJ\mySQL::mysqlSyncQuery("SELECT createRunID("+owners[0][0]+","+openCJ\mapID::getMapID()+")");
        runID=int(row[0][0]);
        row=openCJ\mySQL::mysqlSyncQuery("SELECT createRunInstance("+runID+")");
        instance=int(row[0][0]);
        fps="125"; if(mode) fps="mix";
        args="'"+fps+"',"+mode+","+mode+","+mode+","+mode;
        row=openCJ\mySQL::mysqlSyncQuery("SELECT runFinished("+runID+","+cpID+","+args+","+instance+")");
        check(!isDefined(row[0][0]), "finish cannot become visible before its statistics exist");
        row=openCJ\mySQL::mysqlSyncQuery("SELECT checkpointPassed("+runID+","+cpID+",12345,2,1,3,4,0,'"+fps+"',"+mode+","+mode+","+mode+","+instance+")");
        check(isDefined(row[0][0]), "finish statistics stored");
        row=openCJ\mySQL::mysqlSyncQuery("SELECT runFinished("+runID+","+cpID+","+args+",99999)");
        check(!isDefined(row[0][0]), "stale run instance cannot record a finish");
        row=openCJ\mySQL::mysqlSyncQuery("SELECT runFinished("+runID+","+cpID+","+args+","+instance+")");
        check(isDefined(row[0][0]), "valid finish recorded");
        row=openCJ\mySQL::mysqlSyncQuery("SELECT cs.timePlayed,pr.FPSMode,pr.ele,pr.anyPct,pr.hb,pr.hardTAS FROM checkpointStatistics cs JOIN playerRuns pr ON pr.runID=cs.runID WHERE pr.runID="+runID+" AND cs.cpID=pr.finishcpID AND pr.finishTimeStamp IS NOT NULL");
        check(isDefined(row) && row.size == 1 && int(row[0][0]) == 12345 && row[0][1] == fps && int(row[0][2]) == mode && int(row[0][3]) == mode && int(row[0][4]) == mode && int(row[0][5]) == mode, "leaderboard reads exact normal/any-percent finish settings and time");
    }
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
}
branchTests(points)
{
    source=spawnStruct();source.route="cpc_split_common";source.rows=[];
    cp=openCJ\checkpointCreation::_empty();cp.points=points;
    source.rows[0]=openCJ\checkpointCreation::_encode(cp);
    for(i=0;i<points.size;i++)cp.points[i]=points[i]+(200,0,0);
    source.rows[1]=openCJ\checkpointCreation::_encode(cp);
    easy=openCJ\checkpointBranch::makeDraft(source,"easy","checkpoints/split_easy_test");
    hard=openCJ\checkpointBranch::makeDraft(source,"hard","checkpoints/split_hard_test");
    check(easy.routeHex=="#00ff00" && hard.routeHex=="#ff7777","split branches use Easy green and Hard red");
    easy.route="cpc_split_easy";hard.route="cpc_split_hard";
    editor=spawnStruct();editor.cpc=hard;
    check(editor openCJ\checkpointCreation::_save(),"persist the untouched second branch");
    restored=openCJ\checkpointCreation::_read("checkpoints/split_hard_test.b",hard.route);
    check(isDefined(restored)&&restored.sharedRoute==source.route&&restored.sharedCount==2,"branch metadata survives draft restoration");
    check(openCJ\checkpointCreation::restoreOrigin(restored)==(250,50,12),"reopening second branch returns to last shared landing");
    hard.testing=false;hard.history=[];hard.selected=0;hard.draft=openCJ\checkpointCreation::_decode(hard.rows[0]);
    editor openCJ\checkpointCreation::_action("delete");
    check(hard.rows.size==2,"shared opening cannot be deleted from a branch");
    hard.selected=2;hard.draft=openCJ\checkpointCreation::_empty();
    for(i=0;i<points.size;i++)cp.points[i]=points[i]+(400,0,0);
    cp.finish=true;easy.rows[2]=openCJ\checkpointCreation::_encode(cp);
    for(i=0;i<points.size;i++)cp.points[i]=points[i]+(400,200,0);
    hard.rows[2]=openCJ\checkpointCreation::_encode(cp);
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    editor.cpc=easy;
    ok=editor openCJ\checkpointPublish::_writeRoute();
    check(ok,"publish first branch and shared opening");
    if(!ok)printf("CPC BRANCH DETAIL "+editor.cpc.status+"\n");
    shared=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE mapID="+openCJ\mapID::getMapID()+" AND routeName='cpc_split_common' ORDER BY ordinal");
    if(isDefined(shared)&&shared.size==2)
    {
        // Existing statistics on shared checkpoints must not block the second branch.
        player=openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
        run=openCJ\mySQL::mysqlSyncQuery("SELECT createRunID("+player[0][0]+","+openCJ\mapID::getMapID()+")");
        openCJ\mySQL::mysqlSyncQuery("INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives) VALUES("+run[0][0]+","+shared[0][0]+",1000,0,0,0,0,0)");
        editor.cpc=hard;
        ok=editor openCJ\checkpointPublish::_writeRoute();
        check(ok,"publish second branch while shared opening already has player statistics");
        if(!ok)printf("CPC BRANCH DETAIL "+editor.cpc.status+"\n");
        check(editor openCJ\checkpointPublish::_writeRoute(),"republishing branch preserves shared connections");
        edges=openCJ\mySQL::mysqlSyncQuery("SELECT childcpID FROM checkpointConnections WHERE cpID="+shared[1][0]);
        check(isDefined(edges)&&edges.size==2,"one shared fork has exactly two branches without duplicate edges");
        count=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM checkpointAreas WHERE mapID="+openCJ\mapID::getMapID()+" AND routeName IN ('cpc_split_common','cpc_split_easy','cpc_split_hard')");
        check(int(count[0][0])==4,"shared opening is stored once rather than once per route");
        openCJ\checkpoints::onInit();
        fork=openCJ\checkpoints::getCheckpointByID(int(shared[1][0]));
        check(!isDefined(openCJ\checkpoints::getRouteNameForCheckpoint(fork)),"route stays undecided at shared fork");
        check(fork.childs.size==2,"runtime exposes both successors at split");
        player=spawnStruct();player.anyPct=false;player.checkpoints_checkpoint=fork;player.route=undefined;
        children=player openCJ\checkpoints::getCurrentChildCheckpoints();
        check(!(player openCJ\checkpoints::_checkAnyPctTriggered(children[0],children)) && !(player openCJ\checkpoints::_checkAnyPctTriggered(children[1],children)),"either branch is a valid non-any-percent continuation");
        next=[];next[0]=openCJ\checkpoints::getCheckpointByID(int(shared[0][0]));
        check(player openCJ\checkpoints::_checkAnyPctTriggered(children[0],next),"skipping shared opening still marks any-percent");
        for(i=0;i<fork.childs.size;i++)
        {
            child=fork.childs[i];route=openCJ\checkpoints::getRouteNameForCheckpoint(child);
            expected="#00ff00";if(route=="cpc_split_hard")expected="#ff7777";
            check(isDefined(child.routeInfo)&&child.routeInfo.hex==expected,"branch pointers retain their route color");
        }
        // A stale/mutated snapshot must not overwrite shared checkpoint data.
        altered=openCJ\checkpointCreation::_decode(hard.rows[0]);altered.double=!altered.double;
        hard.rows[0]=openCJ\checkpointCreation::_encode(altered);
        check(!(editor openCJ\checkpointPublish::_writeRoute()),"changed shared requirements cannot overwrite existing opening");
    }
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    openCJ\checkpoints::onInit();
    hard.rows[0]=source.rows[0];
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    editor.cpc=hard;
    check(editor openCJ\checkpointPublish::_writeRoute(),"Hard can be the first finalized branch");
    editor.cpc=easy;
    check(editor openCJ\checkpointPublish::_writeRoute(),"Easy can follow Hard without duplicating opening");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    openCJ\checkpoints::onInit();
    FS_Remove("checkpoints/split_hard_test.b");
}

manyAlternativeTests(points)
{
    editor=spawnStruct();editor.cpc=spawnStruct();
    editor.cpc.rows=[];editor.cpc.selected=0;
    editor.cpc.draft=openCJ\checkpointCreation::_empty();
    editor.cpc.draft.points=points;
    for(area=1;area<8;area++)
    {
        editor.cpc.rows[0]=openCJ\checkpointCreation::_encode(editor.cpc.draft);
        editor.cpc.selected=1;editor.cpc.draft=openCJ\checkpointCreation::_empty();
        editor openCJ\checkpointCreation::_addAlternative();
        check(editor.cpc.selected==0 && editor.cpc.draft.alternatives.size==area,"adding alternative keeps the same checkpoint and previous areas");
        next=[];
        for(i=0;i<points.size;i++)next[i]=points[i]+(area*200,0,0);
        editor.cpc.draft.points=next;
    }
    editor.cpc.rows[0]=openCJ\checkpointCreation::_encode(editor.cpc.draft);
    editor.cpc.selected=1;editor.cpc.draft=openCJ\checkpointCreation::_empty();
    editor.cpc.path="checkpoints/many_alternatives_test";
    editor.cpc.route="cpc_many_areas";editor.cpc.routeHex="#00ff00";editor.cpc.revision=0;
    check(editor openCJ\checkpointCreation::_save(),"save eight-area checkpoint");
    restored=openCJ\checkpointCreation::_read("checkpoints/many_alternatives_test.b",editor.cpc.route);
    cp=openCJ\checkpointCreation::_decode(restored.rows[0]);
    check(isDefined(cp)&&cp.alternatives.size==7,"eight areas survive actual draft file roundtrip");
    for(area=0;area<8;area++)
        check(openCJ\checkpointCreation::contains(cp,(50+area*200,50,10),true),"each alternative remains a valid landing");
    editor openCJ\checkpointCreation::_addAlternative();
    check(editor.cpc.selected==1 && editor.cpc.draft.points.size==0 && isDefined(editor.cpc.alternativeBlocked),"area limit leaves selection untouched and blocks accidental replacement");
    editor.cpc.testing=false;
    editor openCJ\checkpointCreation::_action("detect");
    check(editor.cpc.selected==1 && editor.cpc.draft.points.size==0,"Detect after rejected alternative cannot overwrite a platform");
    openCJ\mySQL::mysqlSyncQuery("START TRANSACTION");
    cp.finish=true;editor.cpc.rows[0]=openCJ\checkpointCreation::_encode(cp);
    check(editor openCJ\checkpointPublish::_writeRoute(),"publish eight alternative areas as one checkpoint");
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT COUNT(*) FROM checkpointAreas WHERE routeName='cpc_many_areas' AND mapID="+openCJ\mapID::getMapID());
    check(int(rows[0][0])==8,"all eight areas stored");
    openCJ\mySQL::mysqlSyncQuery("ROLLBACK");
    FS_Remove("checkpoints/many_alternatives_test.b");
}

discardAndFinishTests(points)
{
    editor=spawnStruct();editor.cpc=spawnStruct();
    editor.cpc.rows=[];editor.cpc.history=[];editor.cpc.testing=false;
    editor.cpc.route="cpc_discard_test";editor.cpc.routeHex="#00ff00";
    editor.cpc.path="checkpoints/discard_test";editor.cpc.revision=0;
    cp=openCJ\checkpointCreation::_empty();cp.points=points;
    editor.cpc.rows[0]=openCJ\checkpointCreation::_encode(cp);
    editor.cpc.rows[1]=openCJ\checkpointCreation::_encode(cp);
    editor.cpc.selected=2;editor.cpc.draft=openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    editor openCJ\checkpointCreation::_action("discard");
    check(editor.cpc.rows.size==2 && editor.cpc.draft.points.size==0,"discard pending checkpoint leaves confirmed checkpoints intact");
    editor openCJ\checkpointCreation::_action("discard");
    check(editor.cpc.rows.size==1,"discard with no pending selection removes latest confirmed checkpoint");
    editor openCJ\checkpointCreation::_action("undo");
    check(editor.cpc.rows.size==2,"undo restores discarded confirmed checkpoint");
    editor.cpc.selected=0;editor.cpc.draft=openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    editor openCJ\checkpointCreation::_action("discard");
    check(editor.cpc.rows.size==1 && editor.cpc.selected==1,"discard targets latest checkpoint even when an older one is selected");
    editor.cpc.sharedCount=1;
    editor openCJ\checkpointCreation::_action("discard");
    check(editor.cpc.rows.size==1,"discard never deletes shared opening");
    editor.cpc.sharedCount=undefined;
    editor.cpc.selected=1;editor.cpc.draft=openCJ\checkpointCreation::_empty();
    editor openCJ\checkpointCreation::_action("previous");
    editor openCJ\checkpointCreation::_action("finish");
    editor openCJ\checkpointCreation::_action("confirm");
    edited=openCJ\checkpointCreation::_decode(editor.cpc.rows[0]);
    check(editor.cpc.rows.size==1 && edited.finish && edited.points[0]==points[0],"previous, Finish, Confirm edits existing checkpoint without adding another");
    check(openCJ\checkpointPublish::validationError(editor.cpc.rows)=="","edited finish is eligible for finalization");
    FS_Remove("checkpoints/discard_test.a");FS_Remove("checkpoints/discard_test.b");
}


networkTests(points)
{
    editor=spawnStruct();editor.login_playerID=999991;
    n=spawnStruct();n.root="net_root";n.revision=0;n.paths=[];
    names=[];names[0]="net_easy";names[1]="net_hard";names[2]="net_inter";
    root=spawnStruct();root.route="net_root";root.routeHex="#123456";root.rows=[];root.revision=0;
    root.selected=1;root.path=editor openCJ\checkpointNetwork::basePath()+root.route;root.draft=openCJ\checkpointCreation::_empty();
    cp=openCJ\checkpointCreation::_empty();cp.points=points;root.rows[0]=openCJ\checkpointCreation::_encode(cp);
    editor.cpc=root;check(editor openCJ\checkpointCreation::_save(),"network root persists");
    for(i=0;i<names.size;i++)
    {
        path=spawnStruct();path.hex=openCJ\checkpointCreation::defaultRouteColor(names[i]);path.sections=[];
        path.sections[0]=n.root;path.sections[1]=names[i];path.sections[2]="net_shared";path.sections[3]=names[i]+"_end";
        n.paths[names[i]]=path;
    }
    sections=[];sections[0]="net_easy";sections[1]="net_hard";sections[2]="net_inter";sections[3]="net_shared";sections[4]="net_easy_end";sections[5]="net_hard_end";sections[6]="net_inter_end";
    for(i=0;i<sections.size;i++)
    {
        part=spawnStruct();part.route=sections[i];part.routeHex="#123456";part.rows=[];part.revision=0;part.selected=1;
        part.path=editor openCJ\checkpointNetwork::basePath()+part.route;part.draft=openCJ\checkpointCreation::_empty();
        cp=openCJ\checkpointCreation::_empty();cp.finish=i>=4;
        for(j=0;j<points.size;j++)cp.points[j]=points[j]+(300*(i+1),0,0);
        part.rows[0]=openCJ\checkpointCreation::_encode(cp);editor.cpc=part;
        check(editor openCJ\checkpointCreation::_save(),"section draft persists");
    }
    check(editor openCJ\checkpointNetwork::save(n),"three-route split merge split manifest persists");
    restored=editor openCJ\checkpointNetwork::load();
    check(isDefined(restored)&&getArrayKeys(restored.paths).size==3,"network restores all three routes");
    check(openCJ\checkpointNetwork::members(restored,"net_shared").size==3,"merged section belongs to all three routes");
    shared=spawnStruct();shared.hasChildren=true;shared.checkpointsFromStart=2;shared.checkpointsTillEnd=4;shared.endCheckpoints=[];
    for(i=0;i<2;i++)
    {
        end=spawnStruct();end.ender=names[i];end.checkpointsFromStart=6+i*3;
        shared.endCheckpoints[i]=end;
    }
    check(!isDefined(openCJ\checkpoints::getRouteNameForCheckpoint(shared)),"shared display does not select a gameplay route");
    check(openCJ\checkpoints::getRemainingCheckpointCount(shared)==7,"shared progress uses the longest possible route");

    check((editor openCJ\checkpointNetwork::resolve("net_hard"))=="net_hard_end","start resolves original route to its latest branch");
    part=editor readNetworkSectionForTest("net_shared");
    check(openCJ\checkpointNetwork::overlap(points,points),"overlap detector catches coincident platforms");
    shifted=[];for(j=0;j<points.size;j++)shifted[j]=points[j]+(300,0,0);
    check(!openCJ\checkpointNetwork::overlap(points,shifted),"overlap detector excludes separate platforms");
    editor.cpc=part;editor.cpc.network=restored;
    check(editor openCJ\checkpointNetwork::publish(),"merged three-route network publishes atomically");
    openCJ\checkpoints::onInit();
    rows=openCJ\mySQL::mysqlSyncQuery("SELECT routeName,COUNT(*) FROM checkpointAreas WHERE routeName IN ('net_easy','net_hard','net_inter') GROUP BY routeName");
    check(isDefined(rows)&&rows.size==3,"all three routes published");
    areas=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName='net_hard' ORDER BY ordinal");
    if(isDefined(areas)&&areas.size==3)
    {
        middle=openCJ\checkpoints::getCheckpointByID(int(areas[1][0]));
        check(openCJ\checkpoints::getRouteNameForCheckpoint(middle)=="net_hard","original route survives the merged section");
        check(middle.routeInfo.hex=="#123456","shared gameplay color matches section draft");
        player=spawnStruct();player.route="net_easy";children=[];children[0]=middle;
        check(player openCJ\checkpoints::_checkAnyPctTriggered(middle,children),"wrong original route triggers any-percent even at a graph successor");
    }
    // Only synthetic fixture names on the isolated database.
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM routes WHERE routeName IN ('net_root','net_easy','net_hard','net_inter')");
    ids=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName IN ('net_root','net_easy','net_hard','net_inter')");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM checkpointAreas WHERE routeName IN ('net_root','net_easy','net_hard','net_inter')");
    for(i=0;i<ids.size;i++)openCJ\mySQL::mysqlSyncQuery("DELETE FROM checkpoints WHERE cpID="+int(ids[i][0]));
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM checkpointSectionColors WHERE sectionName LIKE 'net\\_%'");
    openCJ\checkpoints::onInit();
}

readNetworkSectionForTest(name)
{
    part=self openCJ\checkpointNetwork::readSection(name);part.route=name;
    return part;
}


networkCommandTest(points)
{
    bot=addTestClient();if(!isDefined(bot)){check(false,"spawn network editor client");return;}
    wait 1;
    player=openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
    bot.login_playerID=int(player[0][0]);bot.isFullyConnected=true;bot.startTime=getTime();bot.stopTime=undefined;bot.speedModeNow=false;bot.playerRuns_runPaused=false;
    bot thread openCJ\events\spawnPlayer::main(false);wait 1;
    bot notify("spawned");bot.sessionState="playing";bot.login_playerID=999993;
    bot openCJ\checkpointCreation::_start("cmd_root","#123456");
    lethalEditorDamageTest(bot);
    bot.cpc.draft.points=points;bot openCJ\checkpointCreation::_action("confirm");
    args=[];args[0]="split";args[1]="easy";args[2]="hard";args[3]="inter";
    check(bot openCJ\checkpointNetwork::split(args),"actual three-way split command succeeds");
    for(i=1;i<args.size;i++)
    {
        if(i>1){bot openCJ\checkpointCreation::stop(true);bot openCJ\checkpointCreation::_start(args[i]);}
        check(bot.cpc.route==args[i],"start opens the requested separate approach");
        for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(300*i,0,0);
        bot openCJ\checkpointCreation::_action("confirm");
    }
    for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(1200,0,0);
    args[0]="merge";
    check(bot openCJ\checkpointNetwork::merge(args),"actual three-route merge command succeeds");
    check(bot.cpc.route=="shared_2" && isSubStr(bot.cpc.displayRoutes,"shared"),"merged editor identifies the shared section");
    check(bot.cpc.routeHex=="#123456","merge retains original shared color");
    bot openCJ\checkpointCreation::_action("confirm");
    args[0]="split";
    check(bot openCJ\checkpointNetwork::split(args),"actual repeated split preserves original route names");
    check(bot.cpc.route=="section_3_1" && bot.cpc.displayRoutes=="easy","editor opens Easy after repeated split");
    bot openCJ\checkpointCreation::stop(true);bot openCJ\checkpointCreation::_start("hard");
    check(bot.cpc.route=="section_3_2" && bot.cpc.displayRoutes=="hard","Hard resumes at its latest split");
    check(isDefined(bot.cpc.restoreOrigin),"empty branch restores the last shared landing");
    bot openCJ\checkpointCreation::stop(true);
    bot.login_playerID=int(player[0][0]);
    kick(bot getEntityNumber());
}


networkDiscoveryTest(points)
{
    bot=addTestClient();if(!isDefined(bot)){check(false,"spawn discovery workflow client");return;}
    wait 1;
    player=openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
    bot.login_playerID=int(player[0][0]);bot.isFullyConnected=true;bot.startTime=getTime();bot.stopTime=undefined;bot.speedModeNow=false;bot.playerRuns_runPaused=false;
    bot thread openCJ\events\spawnPlayer::main(false);wait 1;
    bot notify("spawned");bot.sessionState="playing";bot.login_playerID=999994;
    bot openCJ\checkpointCreation::_start("flow_root","#123456");
    bot.cpc.draft.points=points;bot openCJ\checkpointCreation::_action("confirm");
    check(bot openCJ\checkpointNetwork::rename("flow_root","flow_start"),"standalone draft can be renamed before splitting");
    check(bot openCJ\checkpointNetwork::rename("flow_start","flow_root"),"standalone renamed draft remains editable");
    args=[];args[0]="split";args[1]="flow_easy";args[2]="flow_hard";
    check(bot openCJ\checkpointNetwork::split(args),"discovery starts with independent branches");
    for(i=1;i<=4;i++)
    {
        for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(300*i,0,0);
        if(i==4)bot.cpc.draft.finish=true;
        bot openCJ\checkpointCreation::_action("confirm");
    }
    original=bot.cpc;n=bot openCJ\checkpointNetwork::load();root=bot openCJ\checkpointNetwork::readSection(n.root);
    published=spawnStruct();published.route="flow_easy";published.routeHex="#00ff00";published.sharedRoute=n.root;published.sharedHex=root.routeHex;published.sharedCount=root.rows.size;published.rows=[];
    for(i=0;i<root.rows.size;i++)published.rows[published.rows.size]=root.rows[i];
    for(i=0;i<original.rows.size;i++)published.rows[published.rows.size]=original.rows[i];
    bot.cpc=published;check(bot openCJ\checkpointPublish::_writeRoute(),"publish Easy before discovering merge");bot.cpc=original;
    ids=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName='flow_easy' ORDER BY ordinal");
    run=openCJ\mySQL::mysqlSyncQuery("SELECT createRunID("+player[0][0]+","+openCJ\mapID::getMapID()+")");
    openCJ\mySQL::mysqlSyncQuery("INSERT INTO checkpointStatistics(runID,cpID,timePlayed,saveCount,loadCount,explosiveJumps,explosiveLaunches,doubleExplosives) VALUES("+run[0][0]+","+ids[0][0]+",123,0,0,0,0,0)");
    before=published.rows[1];changed=openCJ\checkpointCreation::_decode(before);
    for(j=0;j<changed.points.size;j++)changed.points[j]+=(0,100,0);
    published.rows[1]=openCJ\checkpointCreation::_encode(changed);bot.cpc=published;
    check(!(bot openCJ\checkpointPublish::_writeRoute()),"recorded geometry changes remain blocked");
    published.rows[1]=before;bot.cpc=original;
    bot openCJ\checkpointCreation::stop(true);bot openCJ\checkpointCreation::_start("flow_hard");
    for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(300,300,0);
    bot openCJ\checkpointCreation::_action("confirm");
    for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(600,0,0);
    bot openCJ\checkpointNetwork::checkOverlap(true);
    check(bot.cpc.overlapSection=="flow_easy"&&bot.cpc.overlapIndex==1,"detect identifies an interior checkpoint of completed Easy");
    args[0]="merge";
    check(bot openCJ\checkpointNetwork::merge(args),"Hard merges into completed published Easy");
    check(bot.cpc.rows.size==3,"merge retains the entire existing continuation");
    finish=openCJ\checkpointCreation::_decode(bot.cpc.rows[2]);check(finish.finish,"existing finish preserved by merge");
    check(bot.cpc.selected==0,"merge opens at the joining checkpoint, not the finish");
    joining = openCJ\checkpointCreation::restoreOrigin(bot.cpc);
    bot openCJ\checkpointCreation::processTravelRequests();
    check(distanceSquared(bot.origin,joining)<0.01,"merge stays at join after queued draft restoration");
    check(bot.cpc.positions[0].origin==joining,"merge load anchor is the join rather than the finish");
    mergedSection=bot.cpc.route;
    bot openCJ\checkpointCreation::stop(true);
    bot openCJ\checkpointCreation::_start("flow_hard");
    check(bot.cpc.route==mergedSection && bot.cpc.selected==0,"reopening Hard resumes the saved joining checkpoint");
    bot openCJ\checkpointCreation::processTravelRequests();
    check(distanceSquared(bot.origin,joining)<0.01,"reopening Hard teleports to join rather than inherited finish");
    editorHistoryTest(bot);
    bot openCJ\checkpointCreation::_action("confirm");
    check(bot.cpc.selected==0 && bot openCJ\checkpointNetwork::followingShared(),"confirm shared landing stays at join instead of jumping to finish");
    check(!openCJ\checkpointCreation::readyToFinalize(bot.cpc),"shared join confirmation does not signal ready to finalize");
    bot.cpc.drawCommands=0;
    bot openCJ\checkpointCreation::_draw();
    lastShared=openCJ\checkpointCreation::_decode(bot.cpc.rows[2]);
    landing=openCJ\checkpointCreation::_center(lastShared.points) + (0,0,openCJ\checkpointArea::supportOffset(lastShared.points)-10);
    bot openCJ\checkpointNetwork::trackSharedLanding(landing,false);
    check(bot.cpc.selected==0,"airborne pass does not select a shared landing");
    bot openCJ\checkpointNetwork::trackSharedLanding(landing,true);
    check(bot.cpc.selected==2 && bot.cpc.draft.finish,"landing on any existing shared checkpoint auto-selects it including finish");
    bot openCJ\checkpointNetwork::trackSharedLanding(landing+(0,500,0),true);
    check(bot.cpc.sharedPresence==-1 && bot.cpc.selected==2,"off-path landing preserves last shared selection");
    bot openCJ\checkpointNetwork::trackSharedLanding(joining,true);
    check(bot.cpc.selected==0,"returning to a shared landing automatically selects it");
    bot.cpc.drawCommands=0;bot openCJ\checkpointCreation::_draw();
    check(isSubStr(bot.cpc.huds[0].lastText,"Standing on existing #1"),"HUD identifies the recognized shared landing");

    originalRow=bot.cpc.rows[0];
    for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(600,300,0);
    check(!(bot openCJ\checkpointNetwork::selectDetectedShared()),"off-path landing is rejected during shared traversal");
    check(bot.cpc.selected==0 && openCJ\checkpointCreation::_encode(bot.cpc.draft)==originalRow && bot.cpc.rows[0]==originalRow,"off-path detection preserves last shared landing and its geometry");


    check(bot openCJ\checkpointNetwork::rename("flow_root","flow_combined"),"rename shared opening succeeds");
    n=bot openCJ\checkpointNetwork::load();check(n.root=="flow_combined"&&isDefined(n.paths["flow_easy"])&&isDefined(n.paths["flow_hard"]),"opening rename leaves separate route names unchanged");
    check(bot openCJ\checkpointNetwork::rename("flow_easy","flow_regular"),"rename recorded route succeeds");
    renamed=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName='flow_regular' ORDER BY ordinal");
    check(renamed.size==ids.size&&renamed[0][0]==ids[0][0],"rename retains published checkpoint IDs");
    // Detecting a later shared platform selects it instead of overwriting the current one.
    for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(900,0,0);
    check(bot openCJ\checkpointNetwork::selectDetectedShared(),"detect selects an existing shared landing");
    check(bot.cpc.selected==1,"detected shared landing gets its existing index");
    bot openCJ\checkpointNetwork::selectAndTeleport(0);
    args[0]="split";args[1]="flow_regular";
    check(bot openCJ\checkpointNetwork::split(args),"split at selected shared checkpoint preserves completed continuation");
    check(bot.cpc.rows.size==0&&bot.cpc.displayRoutes=="flow_hard","Hard opens as a new branch after discovered split");
    for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(900,300,0);
    bot openCJ\checkpointCreation::_action("confirm");
    for(j=0;j<points.size;j++)bot.cpc.draft.points[j]=points[j]+(1200,0,0);
    args[0]="merge";
    check(bot openCJ\checkpointNetwork::merge(args),"new Hard branch can rejoin the existing finish");
    finish=openCJ\checkpointCreation::_decode(bot.cpc.rows[0]);check(finish.finish,"rejoining a shared finish keeps Finish enabled");
    check(bot openCJ\checkpointNetwork::publish(),"publish discovered merges while retaining Easy records");
    renamed=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName='flow_regular' ORDER BY ordinal");
    same=renamed.size==ids.size;for(i=0;i<renamed.size;i++)if(renamed[i][0]!=ids[i][0])same=false;
    check(same,"merge/split publication preserves every original Easy checkpoint ID");
    stats=openCJ\mySQL::mysqlSyncQuery("SELECT timePlayed FROM checkpointStatistics WHERE runID="+run[0][0]+" AND cpID="+ids[0][0]);
    check(stats.size==1&&int(stats[0][0])==123,"published Easy statistics survive rename and merge");
    bot openCJ\checkpointCreation::stop(true);bot.login_playerID=int(player[0][0]);kick(bot getEntityNumber());
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM playerRuns WHERE runID="+run[0][0]);
    fixtures="'flow_root','flow_combined','flow_easy','flow_regular','flow_hard'";
    cleanup=openCJ\mySQL::mysqlSyncQuery("SELECT cpID FROM checkpointAreas WHERE routeName IN ("+fixtures+")");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM routes WHERE routeName IN ("+fixtures+")");
    openCJ\mySQL::mysqlSyncQuery("DELETE FROM checkpointAreas WHERE routeName IN ("+fixtures+")");
    for(i=0;i<cleanup.size;i++)openCJ\mySQL::mysqlSyncQuery("DELETE FROM checkpoints WHERE cpID="+cleanup[i][0]);
    openCJ\checkpoints::onInit();
}


ambientTest()
{
    ambientPlay("ambient_backlot_ext");
    check(isSubStr(sv_getconfigstring(821),"ambient_backlot_ext"),"test map ambient track starts");
    level thread openCJ\mapCleanup::_stopMapAmbient();
    wait 0.1;
    check(!isSubStr(sv_getconfigstring(821),"ambient_backlot_ext"),"map cleanup stops ambient track after initialization");
}

lethalEditorDamageTest(bot)
{
    bot.settingsLoaded=true;bot.noclip=false;bot.health=100;
    saved=spawnStruct();saved.origin=bot.origin;saved.angles=bot getPlayerAngles();
    bot.cpc.positions[0]=saved;
    draft=bot.cpc;
    bot setOrigin(saved.origin+(100,0,0));
    bot openCJ\events\playerDamage::main(undefined,undefined,10000,0,"MOD_FALLING","none",bot.origin,(0,0,-1),"none",0);
    check(bot.health==100 && bot.sessionState=="playing","lethal fall in CPC recovers without death or crash");
    check(distanceSquared(bot.origin,saved.origin)<0.001,"CPC lethal damage loads editor position");
    check(bot.cpc==draft,"CPC lethal damage preserves draft and editor session");
    check(!bot openCJ\playerRuns::hasRunID(),"CPC damage recovery does not start a run");
}

editorHistoryTest(bot)
{
    origin = bot.origin;
    for (i = 0; i < 4; i++)
    {
        pos = spawnStruct();pos.origin = origin + (i * 20,0,0);pos.angles = bot getPlayerAngles();
        bot openCJ\checkpointCreation::rememberPosition(pos);
    }
    for (i = 1; i < 4; i++)
    {
        bot openCJ\events\eventHandler::onLoadPositionRequest(1);
        bot openCJ\checkpointCreation::processTravelRequests();
        check(distanceSquared(bot.origin,origin+((3-i)*20,0,0))<0.01,"editor load input walks older saves beyond two slots");
    }
    bot openCJ\events\eventHandler::onLoadPositionRequest(-1);
    bot openCJ\checkpointCreation::processTravelRequests();
    check(distanceSquared(bot.origin,origin+(20,0,0))<0.01,"editor history can move forwards again");
    bot openCJ\events\eventHandler::onLoadPositionRequest(0);
    bot openCJ\checkpointCreation::processTravelRequests();
    check(distanceSquared(bot.origin,origin+(60,0,0))<0.01,"normal load resets editor history to newest save");
}
