// Run on an isolated smoke server after OpenCJ init; never on the live map.
main()
{
    wait 1;
    level.cpcTestFailures = 0;
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