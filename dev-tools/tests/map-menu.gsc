main()
{
    level.failures = 0;
    level.checks = 0;
    openCJ\menus\mapList::onInit();
    check(level.mapListMaxEntriesPerPage == 20, "map menu retains its 20-row contract");
    prepareCatalogue();
    wait 1;

    player = addTestClient();
    check(isDefined(player), "map menu test client connects");
    if(isDefined(player))
    {
        wait 0.2;
        player.adminLevel = 0;
        player.currentMenu = "opencj_maplist";
        player.searchText = "";
        player openCJ\menus\mapList::onPlayerConnected();
        player verifyPagesAndSelection();
        player verifySearch();
        player verifySearchListenerStops();
        player verifyGameEndListenerStops();
    }

    printf("MAP MENU COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}

mapRow(mapName)
{
    row = [];
    row[0] = mapName;
    row[1] = "2020-01-01";
    row[2] = 1;
    row[3] = "Fixture Author";
    return row;
}

prepareCatalogue()
{
    rows = [];
    rows[0] = mapRow("mp_killhouse");
    rows[1] = mapRow("mp_crossfire");
    rows[2] = mapRow("mp_crash");
    openCJ\maps::loadMapRows(rows);

    routeRow = [];
    routeRow[0] = "mp_crossfire";
    routeRow[1] = "Fixture route";
    routeRow[2] = 16777215;
    routeRows = [];
    routeRows[0] = routeRow;
    openCJ\mapRoutes::loadRows(routeRows);
}

verifyPagesAndSelection()
{
    check(self.mapList["maxEntries"] == 3, "menu lists only fixture pool maps");
    // Small pages exercise the same bounds without requiring 21 installed maps.
    level.mapListMaxEntriesPerPage = 2;
    self openCJ\menus\mapList::_updateMapList(true);
    check(self.mapList["curPage"] == 1 && self.mapList["maxPage"] == 2,
          "three maps span two small pages");
    check(self.displayedMaps.size == 2, "first page respects row limit");

    self openCJ\menus\mapList::_handleSelectionChange("1junk");
    check(self.mapList["selected"] == -1, "numeric-prefix selection is rejected");
    self openCJ\menus\mapList::_handleSelectionChange("2");
    check(self.mapList["selected"] == -1, "selection outside displayed page is rejected");
    self openCJ\menus\mapList::_handleSelectionChange("1");
    check(self.mapListRouteMap == "mp_crossfire", "selection uses displayed map index");
    check(self.mapListRouteView.rows.size == 1, "selection includes its route overview");

    self openCJ\menus\mapList::_handlePageChange("page_next");
    check(self.mapList["curPage"] == 2 && self.displayedMaps.size == 1,
          "last page contains the remaining map");
    check(self.displayedMaps[0]["name"] == "mp_crash", "paging keeps catalogue order");
    check(self.mapList["selected"] == -1 && !isDefined(self.mapListRouteMap),
          "page change clears selection and route overview");
}

verifySearch()
{
    self.searchText = "CROSS";
    self openCJ\menus\mapList::_updateMapList(true);
    check(self.mapList["curPage"] == 1 && self.mapList["maxPage"] == 1,
          "search resets and recalculates pages");
    check(self.displayedMaps.size == 1 && self.displayedMaps[0]["name"] == "mp_crossfire",
          "search is case-insensitive");

    self.searchText = "";
    self openCJ\menus\mapList::_updateMapList(true);
    check(self.mapList["maxEntries"] == 3 && self.displayedMaps.size == 2,
          "clearing search restores the pool");

    self openCJ\menus\mapList::_handlePageChange("page_next");
    self.searchText = "crash";
    self openCJ\menus\mapList::_updateMapList(false);
    check(self.mapList["curPage"] == 1 && self.displayedMaps[0]["name"] == "mp_crash",
          "shrinking results resets an out-of-range page");

    self.searchText = "no_such_fixture_map";
    self openCJ\menus\mapList::_updateMapList(true);
    check(self.mapList["maxEntries"] == 0 && self.displayedMaps.size == 0 &&
              self.mapList["maxPage"] == 1,
          "empty search remains a valid empty page");
}

// A synthetic disconnect leaves the entity observable while exercising listener ownership.
verifySearchListenerStops()
{
    self.searchText = "cross";
    self notify("search_changed");
    wait 0.05;
    check(self.mapList["maxEntries"] == 1, "search listener updates the current session");

    self notify("disconnect");
    self.searchText = "";
    self notify("search_changed");
    wait 0.05;
    check(self.mapList["maxEntries"] == 1, "disconnected search listener cannot update the menu");
}

verifyGameEndListenerStops()
{
    self thread openCJ\menus\mapList::onSearchText();
    self.searchText = "cross";
    self notify("search_changed");
    wait 0.05;
    check(self.mapList["maxEntries"] == 1, "new search listener is active before map end");

    level notify("game_ended");
    self.searchText = "";
    self notify("search_changed");
    wait 0.05;
    check(self.mapList["maxEntries"] == 1, "ended map cannot receive further search updates");
}

check(condition, message)
{
    level.checks++;
    if(!condition)
    {
        level.failures++;
    }
    printf("MAP MENU CHECK " + int(condition) + ": " + message + "\n");
}
