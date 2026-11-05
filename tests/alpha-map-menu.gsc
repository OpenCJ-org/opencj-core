// #209: installed maps must reach the correct player's menu without DB rows.
main()
{
    level.failures = 0;
    level.checks = 0;
    openCJ\menus\mapList::onInit();
    openCJ\menus\endMapVote::onInit();
    wait 1;

    rows = [];
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
        if (!openCJ\maps::isAlphaMap(level.endVote["maps"][i]) ||
            level.endVote["maps"][i] == getCvar("mapname")) approved = false;
    check(approved, "automatic end vote still offers only other alpha maps");
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
