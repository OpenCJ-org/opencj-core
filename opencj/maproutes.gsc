// #109: the map browser reads the same published normal routes as gameplay.
onInit()
{
    level.mapRoutes=[];
    level.mapRoutesReady=false;
    level.mapRoutesRequest=0;
    level thread refresh();
}
query()
{
    return "SELECT m.mapname,r.routeName,COALESCE(r.colorRGB,CASE r.routeShaderColor WHEN 'blue' THEN 255 WHEN 'cyan' THEN 65535 WHEN 'green' THEN 65280 WHEN 'orange' THEN 16746496 WHEN 'purple' THEN 11163135 WHEN 'red' THEN 16711680 WHEN 'yellow' THEN 16776960 ELSE 16777215 END) " +
        "FROM routes r JOIN checkpoints c ON c.cpID=r.cpID JOIN mapids m ON m.mapID=c.mapID " +
        "WHERE c.retired=0 AND r.routeType='normal' AND r.routeName IS NOT NULL AND r.routeName<>'' " +
        "AND EXISTS(SELECT 1 FROM checkpoints e WHERE e.mapID=c.mapID AND e.retired=0 AND e.ender=r.routeName) " +
        "ORDER BY m.mapname,CASE LOWER(r.routeName) WHEN 'normal' THEN 0 WHEN 'basic' THEN 1 WHEN 'easy' THEN 2 WHEN 'inter' THEN 3 WHEN 'inter+' THEN 4 WHEN 'hard' THEN 5 WHEN 'hard+' THEN 6 WHEN 'adv' THEN 7 WHEN 'advanced' THEN 7 WHEN 'adv+' THEN 8 WHEN 'advanced+' THEN 8 ELSE 9 END,LOWER(r.routeName),r.colorRGB IS NULL,r.cpID";
}
refresh()
{
    if(!isDefined(level.mapRoutesRequest))level.mapRoutesRequest=0;
    level.mapRoutesRequest++;
    request=level.mapRoutesRequest;
    rows=openCJ\mySQL::mysqlAsyncRead(query());
    if(request!=level.mapRoutesRequest)return;
    applyRows(rows);
}
applyRows(rows)
{
    if(!loadRows(rows))return false;
    players=getEntArray("player","classname");
    for(i=0;i<players.size;i++)
        if(isDefined(players[i].currentMenu) && players[i].currentMenu=="opencj_maplist")
            players[i] openCJ\menus\mapList::_updateMapList(false);
    return true;
}
loadRows(rows)
{
    // A temporary read failure retains the last complete snapshot.
    if(!isDefined(rows))return false;
    maps=[];seen=[];
    for(i=0;i<rows.size;i++)
    {
        map=toLower(rows[i][0]);name=rows[i][1];key=map+":"+toLower(name);
        if(name=="" || isDefined(seen[key]))continue;
        seen[key]=true;
        if(!isDefined(maps[map]))maps[map]=[];
        route=spawnStruct();route.name=name;route.label=label(name);
        packed=16777215;
        if(isDefined(rows[i][2]))packed=int(rows[i][2]);
        if(packed<0 || packed>16777215)packed=16777215;
        route.color=(int(packed/65536)/255.0,(int(packed/256)%256)/255.0,(packed%256)/255.0);
        route.palette=paletteIndex(route.color);
        maps[map][maps[map].size]=route;
    }
    level.mapRoutes=maps;level.mapRoutesReady=true;
    return true;
}
label(name)
{
    text="";
    for(i=0;i<name.size;i++)
    {
        c=name[i];
        if(c=="^"){i++;continue;}
        n=getAscii(c);if(n<32 || n>126)continue;
        text+=c;
    }
    if(text.size>18)text=getSubStr(text,0,15)+"...";
    return text;
}
overview(mapName)
{
    view=spawnStruct();view.rows=[];view.total=0;view.title="";view.message="";
    if(!isDefined(mapName))return view;
    view.title="Routes";
    if(!isDefined(level.mapRoutesReady) || !level.mapRoutesReady)
    {
        view.message="Routes unavailable";
        return view;
    }
    routes=level.mapRoutes[toLower(mapName)];
    if(!isDefined(routes) || !routes.size)
    {
        view.message="No routes available";
        return view;
    }
    view.total=routes.size;view.title="Routes ("+view.total+")";
    if(view.total>10)view.title="Routes (first 10 of "+view.total+")";
    for(i=0;i<min(10,routes.size);i++)view.rows[view.rows.size]=routes[i];
    return view;
}
// CoD4 menu expressions support dynamic alpha, not dynamic RGB. Keep these
// exact standard route colors aligned with ROUTE_ROW in opencj_maplist.menu;
// custom colors use the nearest palette entry.
paletteIndex(color)
{
    packed=[];packed[0]=16777215;packed[1]=255;packed[2]=65535;
    packed[3]=65280;packed[4]=16776960;packed[5]=16746496;
    packed[6]=16742263;packed[7]=11163135;packed[8]=52479;
    packed[9]=16711680;packed[10]=11141120;packed[11]=16744652;
    best=0;distance=999;
    for(i=0;i<packed.size;i++)
    {
        value=packed[i];
        candidate=(int(value/65536)/255.0,(int(value/256)%256)/255.0,(value%256)/255.0);
        d=distanceSquared(color,candidate);
        if(d<distance){distance=d;best=i;}
    }
    return best;
}
