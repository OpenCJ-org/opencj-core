// Exercises the actual map browser against production read-only route metadata.
run(player)
{
    player.sessionTeam="allies";player.sessionState="playing";player.pers["team"]="allies";
    player spawn((0,0,5000),(0,0,0));
    rows=openCJ\mapRouteCatalogueData::rows();
    check(openCJ\mapRoutes::loadRows(rows),"published route snapshot accepted");
    page=openCJ\mapRoutes::overview("mp_galaxy");
    check(page.total==4 && page.rows.size==4,"Galaxy exposes all four normal routes");
    check(page.rows[0].name=="easy" && page.rows[1].name=="inter" && page.rows[2].name=="inter+" && page.rows[3].name=="hard","routes follow familiar route-label order");
    check(page.rows[0].color==(0,1,0) && page.rows[2].color==(1,136/255.0,0),"exact database colors decoded");
    page=openCJ\mapRoutes::overview("MP_TO_THE_MOON");
    check(page.rows[0].name=="basic" && page.rows[1].name=="inter" && page.rows[2].name=="advanced","route lookup is case insensitive");
    player.adminLevel=0;player.searchText="galaxy";
    player openCJ\menus\mapList::_updateMapList(true);
    player openCJ\menus\mapList::_handleSelectionChange("0");
    check(player.mapListRouteView.total==4 && player.mapListRouteMap=="mp_galaxy","selected map populates route panel");
    player.searchText="dark";
    player openCJ\menus\mapList::_updateMapList(true);
    check(player.mapListRouteView.rows.size==0 && player.mapListRouteView.title=="","search clears previous route panel");
    player openCJ\menus\mapList::_handleSelectionChange("0");
    check(player.mapListRouteView.total==2,"new selection shows its routes without stale rows");
    check(!openCJ\mapRoutes::loadRows(undefined) && openCJ\mapRoutes::overview("mp_dark").total==2,"read failure retains last valid snapshot");
    rows=[];
    for(i=0;i<10;i++){row=[];row[0]="mp_dark";row[1]="route"+i;row[2]="16777215";rows[rows.size]=row;}
    rows[rows.size]=rows[0];
    rows[9][1]="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    player.currentMenu="opencj_maplist";
    openCJ\mapRoutes::applyRows(rows);
    check(player.mapListRouteView.total==10 && player.mapListRouteView.rows.size==10,
        "freshly published routes immediately refresh the open selected map");
    check(player.mapListRouteView.rows[9].name=="ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
        "all ten routes fit the overview without paging");
    check(player.mapListRouteView.rows[9].label.size==18 && getSubStr(player.mapListRouteView.rows[9].label,15)=="...",
        "long route names have visible truncation within their column");
    row=[];row[0]="mp_dark";row[1]="extra";row[2]="16777215";rows[rows.size]=row;
    openCJ\mapRoutes::applyRows(rows);
    check(player.mapListRouteView.total==11 && player.mapListRouteView.rows.size==10 &&
        player.mapListRouteView.title=="Routes (first 10 of 11)","overflow is disclosed without adding page controls");
    check(openCJ\mapRoutes::paletteIndex((1,136/255.0,0))==5 &&
        openCJ\mapRoutes::paletteIndex((1,119/255.0,119/255.0))==6,
        "standard checkpoint colors select exact menu palette entries");
    player.searchText="backlot";player.adminLevel=100;
    player openCJ\menus\mapList::_updateMapList(true);
    player openCJ\menus\mapList::_handleSelectionChange("0");
    check(player.mapListRouteView.message=="No routes available","uber-admin installed map without routes has explicit empty state");
    player.adminLevel=0;player openCJ\menus\mapList::_updateMapList(true);
    check(player.displayedMaps.size==0 && player.mapListRouteView.rows.size==0,"role restriction clears route details too");
    level.mapRoutesReady=false;
    check(openCJ\mapRoutes::overview("mp_dark").message=="Routes unavailable","missing initial snapshot is distinguishable from an empty route list");
    check(openCJ\mapRoutes::label("^1safe\nname")=="safename","route labels cannot inject text color or newlines");
    openCJ\mapRoutes::loadRows(openCJ\mapRouteCatalogueData::rows());
}
check(passed,label)
{
    level.checks++;if(!passed)level.failures++;
    printf("ALPHA SELFTEST route overview: "+label+": "+passed+"\n");
}
