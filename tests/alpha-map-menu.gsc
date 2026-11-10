// #203: database membership controls regular menus/votes; installed maps remain available to uber-admins.
main()
{
    level.failures = 0;
    level.checks = 0;
    openCJ\menus\mapList::onInit();
    openCJ\menus\endMapVote::onInit();
    wait 1;

    check(!openCJ\maps::canVoteMap("mp_dark", 0), "pool denied before catalogue initialization");
    rows = openCJ\alphaMapData::rows();
    openCJ\maps::loadMapRows(rows);
    check(isDefined(level.mapNames["mp_backlot"]) && isDefined(level.mapNames["mp_crash"]) &&
          isDefined(level.mapNames["mp_killhouse"]), "stock maps discovered without database metadata");
    check(isDefined(level.mapNames["mp_legacy"]), "non-alpha custom map discovered without database metadata");
    check(!isDefined(level.mapNames["mp_backlot_load"]) && !isDefined(level.mapNames["common_mp"]),
          "load screens and shared assets excluded");
    ranks = [];
    ranks[0] = 0; ranks[1] = 20; ranks[2] = 40; ranks[3] = 60; ranks[4] = 99;
    for (i = 0; i < ranks.size; i++)
        check(openCJ\maps::voteMaps(ranks[i]).size == 10, "approved ten maps for rank " + ranks[i]);
    check(openCJ\maps::voteMaps(100).size == level.maps.size, "uber-admin has every installed catalogue map");
    check(openCJ\maps::voteMaps(100).size > 10, "uber-admin catalogue includes non-alpha maps");

    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "menu test client connected");
    if (!isDefined(player)) { finish(); return; }
    player.mapList = [];
    player.mapList["selected"] = -1;
    player.mapList["curPage"] = 1;
    player.adminLevel = 0;
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size == 10, "regular menu shows only approved ten");
    player.searchText = "backlot";
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size == 0, "regular search hides installed stock map");
    player.adminLevel = 100;
    player openCJ\menus\mapList::_updateMapList(true);
    foundStock = false;
    for (i = 0; i < player.displayedMaps.size; i++)
        if (player.displayedMaps[i]["name"] == "mp_backlot") foundStock = true;
    check(foundStock, "uber-admin search displays stock map without DB entry");
    player.searchText = "legacy";
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size == 1 && player.displayedMaps[0]["name"] == "mp_legacy",
          "uber-admin search displays non-alpha custom map");
    player.adminLevel = 20;
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size == 0 && player.mapList["selected"] == -1,
          "role downgrade clears non-alpha menu selection");
    openCJ\menus\endMapVote::fillRandomMaps();
    approved = level.endVote["maps"].size == 9;
    for (i = 0; i < level.endVote["maps"].size; i++)
        if (!openCJ\maps::isPoolMap(level.endVote["maps"][i]) ||
            level.endVote["maps"][i] == getCvar("mapname")) approved = false;
    check(approved, "automatic end vote still offers only other alpha maps");
    check(openCJ\maps::previewImage("MP_FUTILE_FIXED") == "loadscreen_mp_futile_fixed",
          "pool map preview uses its bundled material");
    check(openCJ\maps::previewImage("mp_legacy") == "opencj_logo_nobg",
          "non-pool map preview uses OpenCJ logo");
    player.adminLevel = 0;
    check(player openCJ\vote::_findMapByName("MP_BLUE2", true) == "mp_blue2",
          "regular exact vote normalizes case");
    check(player openCJ\vote::_findMapByName("blue2", true) == "mp_blue2",
          "regular partial vote resolves a pool map");
    check(!openCJ\maps::canVoteMap("mp_legacy", undefined), "undefined rank cannot bypass pool");

    metadata = false;
    for (i = 0; i < level.maps.size; i++)
    {
        entry = level.maps[i];
        if (entry["name"] == "mp_futile_fixed")
            metadata = entry["date"] == "2013-01-24" && entry["author"] == "pcbouncer";
        if (entry["name"] == "mp_dark")
            check(entry["author"] == "kie, Second mapper", "multiple mapper credits reach menu metadata");
    }
    check(metadata, "original Futile date and author reach menu metadata");

    // Change the supplied database rows, without changing any production list.
    rows[0][2] = "0";
    rows[rows.size] = openCJ\alphaMapData::row("mp_legacy", "2000-01-01", "1", "Test author");
    rows[rows.size] = openCJ\alphaMapData::row("mp_missing_opencj_203", "2000-01-01", "1", "Test author");
    openCJ\maps::loadMapRows(rows);
    check(openCJ\maps::voteMaps(0).size == 10, "database membership replaces an approved map");
    check(!openCJ\maps::canVoteMap("mp_dark", 0) && openCJ\maps::canVoteMap("mp_dark", 100),
          "disabled former alpha map is uber-admin only");
    check(openCJ\maps::canVoteMap("MP_LEGACY", 0), "new database-enabled map is regular-votable");
    check(!openCJ\maps::canVoteMap("mp_missing_opencj_203", 0) &&
          !openCJ\maps::canVoteMap("mp_missing_opencj_203", 100),
          "database membership cannot grant access to missing assets");
    check(player openCJ\vote::_findMapByName("legacy", true) == "mp_legacy",
          "partial vote follows changed database membership");
    check(!isDefined(player openCJ\vote::_findMapByName("mp_dark", true)),
          "exact vote cannot bypass disabled database membership");
    player.searchText = "";
    player openCJ\menus\mapList::_updateMapList(true);
    foundLegacy = false;
    foundDark = false;
    for (i = 0; i < player.displayedMaps.size; i++)
    {
        if (player.displayedMaps[i]["name"] == "mp_legacy") foundLegacy = true;
        if (player.displayedMaps[i]["name"] == "mp_dark") foundDark = true;
    }
    check(foundLegacy && !foundDark, "menu follows changed database membership");
    openCJ\menus\endMapVote::fillRandomMaps();
    approved = true;
    for (i = 0; i < level.endVote["maps"].size; i++)
        if (!openCJ\maps::isPoolMap(level.endVote["maps"][i]) ||
            level.endVote["maps"][i] == "mp_dark") approved = false;
    check(approved, "end vote follows changed database membership");

    openCJ\maps::loadMapRows(undefined);
    check(openCJ\maps::previewImage("mp_dark") == "opencj_logo_nobg",
          "unavailable membership uses safe preview fallback");
    check(openCJ\maps::voteMaps(0).size == 0 && !openCJ\maps::canVoteMap("mp_dark", 0),
          "failed database read fails closed without alpha fallback");
    check(openCJ\maps::voteMaps(100).size > 10 && openCJ\maps::canVoteMap("mp_legacy", 100),
          "failed database read retains uber-admin installed-map access");
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size == 0 && player.mapList["selected"] == -1,
          "menu clears stale choices after failed database read");
    openCJ\menus\endMapVote::fillRandomMaps();
    check(level.endVote["maps"].size == 0, "failed database read gives no automatic vote choices");
    rows = [];
    openCJ\maps::loadMapRows(rows);
    check(openCJ\maps::voteMaps(0).size == 0, "empty database pool fails closed");
    rows = openCJ\alphaMapData::rows();
    openCJ\maps::loadMapRows(rows);
    check(openCJ\maps::voteMaps(0).size == 10, "successful reload restores database pool");
    finish();
}

check(passed, label)
{
    level.checks++;
    if (!passed) level.failures++;
    printf("ALPHA SELFTEST " + label + ": " + passed + "\n");
}

finish()
{
    printf("ALPHA SELFTEST COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}
