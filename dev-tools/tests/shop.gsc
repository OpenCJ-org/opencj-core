main()
{
    openCJ\mysql::onInit();
    openCJ\commands_base::onInit();
    openCJ\shop::onInit();
    ok=level.shopItems.size==24;
    keys=[];
    for(i=0;i<level.shopItems.size;i++)
    {
        item=level.shopItems[i];
        if(item.available || item.price!=9999 || isDefined(keys[item.key]))ok=false;
        keys[item.key]=true;
    }
    if(openCJ\shop::availablePoints(40,0)!=40)ok=false;
    if(openCJ\shop::availablePoints(100,40)!=60)ok=false;
    if(openCJ\shop::availablePoints(20,40)!=0)ok=false;
    // Exercise CALL and a subsequent query through the real native SQL wrapper.
    rows=openCJ\mysql::mysqlSyncQuery("CALL shopBuyOrEquip(69,'pistol.preview0',0,9999)");
    if(!isDefined(rows) || rows.size!=1 || rows[0][0]!="unavailable")ok=false;
    rows=openCJ\mysql::mysqlSyncQuery("SELECT 1");
    if(!isDefined(rows) || rows.size!=1 || rows[0][0]!="1")ok=false;
    if(ok)printf("SHOP_V2_TEST_PASS\n");
    else printf("SHOP_V2_TEST_FAIL\n");
}
