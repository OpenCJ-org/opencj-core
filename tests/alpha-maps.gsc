main()
{
    level.failures = 0;
    level.checks = 0;
    level.remainingTimeSeconds = 3600;
    openCJ\commands_base::onInit();
    openCJ\checkpointCreation::onInit();
    openCJ\menus\mapList::onInit();
    openCJ\menus\endMapVote::onInit();
    openCJ\vote::onInit();
    wait 1;
    check(getCvarInt("g_allowVote") == 0, "stock callvote cannot bypass alpha policy");
    check(openCJ\commands_base::maxAdminLevel() == 100, "uber-admin is maximum role 100");
    check(level.commands["checkpoint"].minAdminLevel == 20, "CPC command requires editor rank 20");
    check(level.commands["maprestart"].minAdminLevel == 60, "editor rank does not grant map restart");
    names = openCJ\maps::alphaMapNames();
    check(names.size == 10, "exactly ten approved maps");
    for (i = 0; i < names.size; i++)
        check(openCJ\maps::canVoteMap(names[i], 0), "approved map installed and regular-votable: " + names[i]);
    check(opencjMapExists("mp_dark") && opencjMapExists("mp_blue2"), "loaded and unloaded custom maps detected");
    check(opencjMapExists("MP_DARK") && opencjMapExists("mp_killhouse"), "case normalization and stock map detection");
    check(!opencjMapExists("mp_dark_load") && !opencjMapExists("common_mp") && !opencjMapExists("ui_mp"), "load screens and shared assets are not maps");
    check(!opencjMapExists("mp_missing_opencj_209"), "missing map rejected");
    check(!opencjMapExists("../mp_dark") && !opencjMapExists("mp_dark;quit") && !opencjMapExists(""), "unsafe and empty names rejected");
    check(!openCJ\maps::canVoteMap("mp_legacy", 0) && !openCJ\maps::canVoteMap("mp_legacy", 20) && !openCJ\maps::canVoteMap("mp_legacy", 60) && !openCJ\maps::canVoteMap("mp_legacy", 99), "every rank below uber-admin restricted");
    check(!openCJ\maps::canVoteMap("mp_legacy", undefined), "undefined rank cannot bypass");
    check(openCJ\maps::canVoteMap("mp_legacy", 100), "uber-admin can vote installed non-alpha map");
    check(!openCJ\maps::canVoteMap("mp_missing_opencj_209", 100), "uber-admin cannot vote a missing map");

    rows = [];
    rows[0] = []; rows[0][0] = "mp_legacy"; rows[0][1] = "2000-01-01";
    rows[1] = []; rows[1][0] = "mp_missing_opencj_209"; rows[1][1] = undefined;
    rows[2] = []; rows[2][0] = "mp_killhouse"; rows[2][1] = undefined;
    openCJ\maps::loadMapRows(rows);
    normalMaps = openCJ\maps::voteMaps(0);
    adminMaps = openCJ\maps::voteMaps(100);
    check(normalMaps.size == 10 && adminMaps.size > 10, "catalogue provides ten regular choices and broader admin access");
    check(!isDefined(level.mapNames["mp_missing_opencj_209"]), "database-only missing map excluded");
    check(isDefined(level.mapNames["mp_blue2"]), "installed map discovered without database metadata");
    openCJ\menus\endMapVote::fillRandomMaps();
    approved = level.endVote["maps"].size == 9;
    for (i = 0; i < level.endVote["maps"].size; i++)
        if (!openCJ\maps::isAlphaMap(level.endVote["maps"][i]) || level.endVote["maps"][i] == "mp_dark") approved = false;
    check(approved, "automatic end vote contains nine other approved maps only");

    player = addTestClient();
    other = addTestClient();
    check(isDefined(player) && isDefined(other), "two real engine test clients");
    if (!isDefined(player) || !isDefined(other)) { finish(); return; }
    wait 0.2;
    setupPlayer(player, 69);
    setupPlayer(other, 70);
    setCvar("opencj_checkpoint_editor_playerid", 69);
    setCvar("opencj_checkpoint_editor_playerids", "70");
    check(!(player openCJ\checkpointCreation::hasEditorAccess()) && !(other openCJ\checkpointCreation::hasEditorAccess()), "legacy ID exceptions no longer grant access");
    player.adminLevel = 19;
    check(!(player openCJ\checkpointCreation::hasEditorAccess()), "rank below editor denied");
    player.adminLevel = 20;
    check(player openCJ\checkpointCreation::hasEditorAccess(), "editor-only rank 20 accepted");
    player.login_playerID = undefined;
    check(!(player openCJ\checkpointCreation::hasEditorAccess()), "login still required for editor");
    player.login_playerID = 69;
    player.adminLevel = 100;
    check(player openCJ\checkpointCreation::hasEditorAccess(), "uber-admin can edit checkpoints");

    player.adminLevel = 0;
    player.mapList = [];
    player.mapList["selected"] = -1;
    player.mapList["curPage"] = 1;
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size == 10 && player.mapList["maxPage"] == 1, "regular menu shows only ten approved maps");
    player.searchText = "legacy";
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size == 0, "regular menu search cannot reveal non-alpha choices");
    check(!isDefined(player openCJ\vote::_findMapByName("mp_legacy", true)), "direct non-alpha vote name rejected");
    check(player openCJ\vote::_findMapByName("blue2", true) == "mp_blue2", "regular partial match resolves within approved maps");
    player.adminLevel = 100;
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size > 0 && player.displayedMaps[0]["name"] == "mp_legacy", "uber-admin menu includes non-alpha search result");
    check(player openCJ\vote::_findMapByName("MP_LEGACY", true) == "mp_legacy", "uber-admin exact map vote normalizes case");
    player.searchText = "";
    player.mapList["curPage"] = 5;
    player.mapList["selected"] = 19;
    player.adminLevel = 0;
    player openCJ\menus\mapList::_updateMapList(false);
    check(player.mapList["curPage"] == 1 && player.mapList["selected"] == -1, "rank change clamps stale menu page and selection");
    player openCJ\menus\mapList::_handleSelectionChange("-1");
    player openCJ\menus\mapList::_handleSelectionChange("19");
    check(player.mapList["selected"] == -1, "invalid displayed map indices rejected");

    args = []; args[0] = "map"; args[1] = "mp_legacy";
    player openCJ\vote::vote(args);
    check(!isDefined(level.vote), "regular chat vote cannot start non-alpha vote");
    args[1] = "mp_blue2";
    player openCJ\vote::vote(args);
    check(isDefined(level.vote) && level.vote.map == "mp_blue2", "regular chat vote starts approved map vote");
    openCJ\vote::_destroyVote();
    player.canVoteAt = 0;
    player.adminLevel = 100;
    args[1] = "mp_legacy";
    player openCJ\vote::vote(args);
    check(isDefined(level.vote) && level.vote.map == "mp_legacy", "uber-admin chat vote starts non-alpha map vote");
    openCJ\vote::_destroyVote();
    player.canVoteAt = 0;
    args[1] = "mp_missing_opencj_209";
    player openCJ\vote::vote(args);
    check(!isDefined(level.vote), "uber-admin missing-map vote does not start");
    args[1] = "MP_DARK";
    player openCJ\vote::vote(args);
    check(!isDefined(level.vote), "current map rejected after case normalization");

    check(!isDefined(getEnt("give_gravity_trig", "targetname")), "map weapon reward removed");
    hints = getEntArray("trigger_use_touch", "classname");
    prompt = false; credits = false;
    for (i = 0; i < hints.size; i++)
    {
        if (distanceSquared(hints[i].origin, (-4162,12660,87)) < 1) prompt = true;
        if (distanceSquared(hints[i].origin, (-3952,12696,-424)) < 1) credits = true;
    }
    check(!prompt && credits, "obsolete weapon prompt removed and finish credits retained");
    triggers = getEntArray("enter", "targetname");
    check(triggers.size == 3, "both route entrances and post-finish teleport preserved");
    for (i = 0; i < triggers.size; i++)
    {
        target = getEnt(triggers[i].target, "targetname");
        player setOriginAndAngles(triggers[i].origin, (0,0,0));
        player setVelocity((800, 200, 100));
        ok = triggers[i] maps\mp\mp_dark::teleportPlayer(player);
        check(ok && distanceSquared(player.origin, target.origin) < 1, "original teleport destination preserved " + i);
        check(length(player getVelocity()) < 1, "teleport clears carried speed " + i);
    }
    fake = spawn("script_origin", (0,0,0));
    fake.target = "missing_destination_209";
    check(!(fake maps\mp\mp_dark::teleportPlayer(player)), "missing teleport destination safely ignored");
    check(!(triggers[0] maps\mp\mp_dark::teleportPlayer(undefined)), "undefined trigger player safely ignored");
    check(!(triggers[0] maps\mp\mp_dark::teleportPlayer(fake)), "non-player trigger safely ignored");
    away = (-587,-927,239);
    player setOriginAndAngles(away, (0,0,0));
    check(!(triggers[0] maps\mp\mp_dark::teleportPlayer(player)), "player who loaded away cannot use a stale trigger");
    player setOriginAndAngles(triggers[0].origin, (0,0,0));
    triggers[0] notify("trigger", player);
    player setOriginAndAngles(away, (0,0,0));
    wait 0.25;
    check(distanceSquared(player.origin, away) < 100, "trigger followed by load cannot teleport player back later");
    fake delete();

    auditPublishedAreas(player);
    finish();
}

setupPlayer(player, id)
{
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((-587, -927, 239), (0, 0, 0));
    player.maxHealth = 100;
    player.health = 100;
    player.login_playerID = id;
    player.adminLevel = 0;
    player.isAFK = false;
    player.canVoteAt = 0;
    player.isFirstSpawn = false;
}

auditPublishedAreas(player)
{
    data = openCJ\alphaAuditData::areas();
    valid = 0; supported = 0; contact = 0;
    for (i = 0; i < data.size; i++)
    {
        cp = data[i];
        cp.area = openCJ\checkpointArea::decode(cp.encoded);
        if (!isDefined(cp.area) || openCJ\checkpointArea::validate(cp.area) != "")
        {
            printf("ALPHA SELFTEST AREA INVALID id=" + cp.id + "\n");
            continue;
        }
        valid++;
        center = (0,0,0);
        for (j = 0; j < cp.area.size; j++) center += cp.area[j];
        center = vectorScale(center, 1.0 / cp.area.size);
        normal = openCJ\checkpointArea::planeNormal(cp.area);
        hit = bulletTrace(center + vectorScale(normal, 2) + (0,0,cp.heightAbove), center - vectorScale(normal, 2), false, undefined);
        if (hit["fraction"] < 1 && hit["normal"][2] >= 0.7 && openCJ\checkpointArea::contains(cp.area, hit["position"], true, true, cp.heightAbove))
        {
            supported++;
            // A polygon centre can be under the next stair or beside a wall.
            // Check actual capsule contact at representative landing positions.
            landed = player tryLanding(cp, center);
            for (sample = 0; !landed && sample < cp.area.size * 2; sample++)
            {
                point = cp.area[int(sample / 2)];
                if (sample % 2) point = vectorScale(point + cp.area[(int(sample / 2) + 1) % cp.area.size], 0.5);
                weights = []; weights[0] = 0.75; weights[1] = 1.0; weights[2] = 1.15;
                for (w = 0; !landed && w < weights.size; w++)
                    landed = player tryLanding(cp, center + vectorScale(point - center, weights[w]));
            }
            if (landed) contact++;
            else printf("ALPHA SELFTEST CONTACT MISS id=" + cp.id + "\n");
        }
        else printf("ALPHA SELFTEST SUPPORT MISS id=" + cp.id + " center=" + center + " height=" + cp.heightAbove + "\n");
        if (i % 20 == 0) wait 0.05;
    }
    check(data.size == 167 && valid == data.size, "all 167 published checkpoint polygons validate");
    check(supported == data.size, "all published checkpoint centres have walkable collision within their volume");
    check(contact == data.size, "every published checkpoint accepts a physically grounded test landing");
    printf("ALPHA SELFTEST AREA TOTALS valid=" + valid + " supported=" + supported + " contact=" + contact + "\n");
}

tryLanding(cp, point)
{
    z = openCJ\checkpointHeight::planeZ(cp.area, point) + openCJ\checkpointArea::supportOffset(cp.area) + 0.125;
    self setOriginAndAngles((point[0], point[1], z), (0,0,0));
    wait 0.05;
    return self openCJ\checkpoints::touchesArea(cp, self isOnGround(), undefined);
}

check(ok, message)
{
    level.checks++;
    if (!ok) level.failures++;
    printf("ALPHA SELFTEST " + message + ": " + ok + "\n");
}

finish()
{
    printf("ALPHA SELFTEST COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}
