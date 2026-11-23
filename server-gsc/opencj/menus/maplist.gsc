#include openCJ\util;

onInit()
{
    precacheMenu("opencj_maplist");
    level.mapListDvarPrefix = "opencj_ui_maplist_";
    // Keep the row count aligned with opencj_maplist.menu.
    level.mapListMaxEntriesPerPage = 20;
    level.mapListNoSelection = -1;
}

onPlayerConnected()
{
    self.mapList = [];
    self.mapList["selected"] = level.mapListNoSelection;
    self.mapList["curPage"] = 1;

    // Counts depend on this player's permissions and the latest map catalogue.
    eligibleMaps = openCJ\maps::voteMaps(self.adminLevel);
    self.mapList["maxEntries"] = eligibleMaps.size;
    self.mapList["maxPage"] = max(1, ceil(eligibleMaps.size / level.mapListMaxEntriesPerPage));
    self thread _updateMapList(false);

    self thread onMenuResponse();
    self thread onSearchText();
}

onOpen() // Map list menu is opened
{
    self thread _updateMapList(true);
}

// Search notifications belong only to this player session and map.
onSearchText()
{
    self endon("disconnect");
    level endon("game_ended");

    self setClientCvar(level.mapListDvarPrefix + "textfield", "");
    for(;;)
    {
        self waittill("search_changed");
        self setClientCvar(level.mapListDvarPrefix + "textfield", self.searchText);
        self _updateMapList(true);
    }
}

onMenuResponse()
{
    self endon("disconnect");
    level endon("game_ended");

    for(;;)
    {
        self waittill("menuresponse", menu, response);

        if (self.currentMenu != "opencj_maplist")
        {
            continue;
        }

        button = undefined;
        if (isSubStr(response, "click_"))
        {
            button = getSubStr(response, 6); 
        }
        if (isDefined(button)) // A button on the current board was clicked
        {
            if (button == "maplist_extendtime") // Vote for more time for current map
            {
                self _handleVote("extend");
            }
            else if (button == "maplist_vote") // Vote for a new map
            {
                self _handleVote("map");
            }
            else if (button == "maplist_end") // Vote for ending current map and going to end map vote
            {
                self _handleVote("end");
            }
            else if (button == "maplist_nominate")
            {
                // Not implemented yet
            }
            else if (button == "maplist_showrecords")
            {
                // Not implemented yet
            }
            else if (isSubStr(button, "page")) // Route or board previous/next page
            {
                self _handlePageChange(button);
            }
            else if (isSubStr(button, "map")) // Should be last check, because this string overlaps with some others
            {
                self _handleSelectionChange(getSubStr(button, 3));
            }
        }
    }
}

_handleSelectionChange(selectedIndexText)
{
    if (!isValidInt(selectedIndexText))
    {
        return;
    }
    selectedIndex = int(selectedIndexText);
    if (selectedIndex < 0 || selectedIndex >= self.displayedMaps.size)
    {
        return;
    }

    self.mapList["selected"] = selectedIndex;
    self _updateMapList(false);
}

_handleVote(voteType)
{
    args = [];
    if (voteType == "extend")
    {
        args[0] = "extend";
    }
    else if (voteType == "map")
    {
        selectedIndex = self.mapList["selected"];
        if (!isDefined(selectedIndex) || selectedIndex < 0 ||
            selectedIndex >= self.displayedMaps.size)
        {
            return;
        }

        args[0] = "map";
        args[1] = self.displayedMaps[selectedIndex]["name"];
    }
    else
    {
        if (voteType == "end")
        {
            // Not implemented yet
        }
        return;
    }

    self closeMenu();
    self openCJ\vote::vote(args);
}

_handlePageChange(button)
{
    isPrevPage = isSubStr(button, "prev");
    page = self.mapList["curPage"];
    if (isPrevPage)
    {
        if (self.mapList["curPage"] > 1)
        {
            self.mapList["curPage"]--;
        }
    }
    else // Next page
    {
        if (self.mapList["curPage"] < self.mapList["maxPage"])
        {
            self.mapList["curPage"]++;
        }
    }

    if (page != self.mapList["curPage"])
    {
        self.mapList["selected"] = level.mapListNoSelection; // Reset selection if page changed
        self _updateMapList(false);
    }
}

// Rebuild the visible page from current permissions, search and selection.
_updateMapList(searchChanged)
{
    eligibleMaps = openCJ\maps::voteMaps(self.adminLevel);
    if (isDefined(searchChanged) && searchChanged)
    {
        self.mapList["selected"] = level.mapListNoSelection;
        self.mapList["curPage"] = 1;
    }

    pageOffset = (self.mapList["curPage"] - 1) * level.mapListMaxEntriesPerPage;
    mapPage = _buildMapPage(eligibleMaps, self.searchText, pageOffset);
    if (pageOffset >= mapPage.totalEntries && self.mapList["curPage"] > 1)
    {
        // A catalogue or filter change can remove the page the player was viewing.
        self.mapList["selected"] = level.mapListNoSelection;
        self.mapList["curPage"] = 1;
        mapPage = _buildMapPage(eligibleMaps, self.searchText, 0);
    }

    self.mapList["maxEntries"] = mapPage.totalEntries;
    self.mapList["maxPage"] = max(1, ceil(mapPage.totalEntries / level.mapListMaxEntriesPerPage));
    self.displayedMaps = mapPage.entries;
    self _publishMapPage();

    selectedIndex = self.mapList["selected"];
    if (selectedIndex >= 0 && selectedIndex < self.displayedMaps.size)
    {
        self _updateSelectionDvars(self.displayedMaps[selectedIndex]);
    }
    else
    {
        self _updateSelectionDvars(undefined);
    }
}

// Count every match, but retain only the bounded page that will be sent to the client.
_buildMapPage(eligibleMaps, searchText, pageOffset)
{
    mapPage = spawnStruct();
    mapPage.entries = [];
    mapPage.totalEntries = 0;

    if (!isDefined(searchText) || searchText.size == 0)
    {
        // Permissions are already checked; an unfiltered page needs no second full scan.
        mapPage.totalEntries = eligibleMaps.size;
        pageEnd = min(eligibleMaps.size, pageOffset + level.mapListMaxEntriesPerPage);
        for (i = pageOffset; i < pageEnd; i++)
        {
            mapPage.entries[mapPage.entries.size] = eligibleMaps[i];
        }
        return mapPage;
    }

    normalizedSearchText = toLower(searchText);
    for (i = 0; i < eligibleMaps.size; i++)
    {
        mapEntry = eligibleMaps[i];
        if (!isSubStr(toLower(mapEntry["name"]), normalizedSearchText))
        {
            continue;
        }
        if (mapPage.totalEntries >= pageOffset &&
            mapPage.entries.size < level.mapListMaxEntriesPerPage)
        {
            mapPage.entries[mapPage.entries.size] = mapEntry;
        }
        mapPage.totalEntries++;
    }
    return mapPage;
}

// Publish pagination and clear every unused row after a shorter result replaces a page.
_publishMapPage()
{
    prefix = level.mapListDvarPrefix;
    self setClientCvar(prefix + "pagetxt",
                       self.mapList["curPage"] + "/" + self.mapList["maxPage"]);
    self setClientCvar(prefix + "page", self.mapList["curPage"]);
    self setClientCvar(prefix + "pagemax", self.mapList["maxPage"]);

    for (i = 0; i < level.mapListMaxEntriesPerPage; i++)
    {
        mapName = "";
        if (i < self.displayedMaps.size)
        {
            mapName = self.displayedMaps[i]["name"];
        }
        self setClientCvar(prefix + "map" + i, mapName);
    }
}

_updateSelectionDvars(mapEntry)
{
    if (isDefined(mapEntry))
    {
        self setClientCvar(level.mapListDvarPrefix + "selected", self.mapList["selected"]);
        self setClientCvar(level.mapListDvarPrefix + "selectedname", mapEntry["name"]);
        self setClientCvar(level.mapListDvarPrefix + "date", mapEntry["date"]);
        self setClientCvar(level.mapListDvarPrefix + "author", mapEntry["author"]);
        self _updateRouteDvars(mapEntry["name"]);
        self setClientCvar(level.mapListDvarPrefix + "loadimage",
                           openCJ\maps::previewImage(mapEntry["name"]));
    }
    else
    {
        self setClientCvar(level.mapListDvarPrefix + "selected", "");
        self setClientCvar(level.mapListDvarPrefix + "selectedname", "");
        self setClientCvar(level.mapListDvarPrefix + "date", "");
        self setClientCvar(level.mapListDvarPrefix + "author", "");
        self _updateRouteDvars(undefined);
        self setClientCvar(level.mapListDvarPrefix + "loadimage", "");
    }
}

_updateRouteDvars(mapName)
{
    self.mapListRouteMap = mapName;
    routeOverview = openCJ\mapRoutes::overview(mapName);
    self.mapListRouteView = routeOverview;
    prefix = level.mapListDvarPrefix;
    self setClientCvar(prefix + "routetitle", routeOverview.title);
    self setClientCvar(prefix + "routemessage", routeOverview.message);
    self setClientCvar(prefix + "routecount", routeOverview.rows.size);

    // Clear all ten client rows when another selection has fewer routes.
    maximumRouteRows = 10;
    for(i = 0; i < maximumRouteRows; i++)
    {
        routeLabel = "";
        paletteIndex = 0;
        if(i < routeOverview.rows.size)
        {
            routeLabel = routeOverview.rows[i].label;
            paletteIndex = routeOverview.rows[i].palette;
        }
        routeCvar = prefix + "route" + i;
        self setClientCvar(routeCvar, routeLabel);
        self setClientCvar(routeCvar + "_color", paletteIndex);
    }
}
