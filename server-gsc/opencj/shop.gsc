#include openCJ\util;

// Preview catalogue. Stable keys will also identify ownership when sales launch.
onInit()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    // Categories match the stored catalogue and the three client tabs.
    level.shopCategoryModel = 0;
    level.shopCategoryPistol = 1;
    level.shopCategoryRPG = 2;
    precacheMenu("opencj_shop");
    precacheMenu("opencj_shop_confirm");
    precacheMenu("opencj_shop_inspect");

    level.shopItems = [];
    previewCountPerCategory = 12;
    previewPrice = 9999;
    for(i = 0; i < previewCountPerCategory; i++)
    {
        _addPreviewItem("pistol.preview" + i, level.shopCategoryPistol, "Desert Eagle " + (i + 1),
                        "weapon_desert_eagle", "deserteagle_mp", "default", previewPrice);
        _addPreviewItem("rpg.preview" + i, level.shopCategoryRPG, "RPG " + (i + 1),
                        "weapon_rpg7", "rpg_mp", "default", previewPrice);
    }
    openCJ\commands_base::registerCommand("shop", "!shop", ::command, 0, 0, 0);
}

// Keep preview records stable in SQL while purchasing remains disabled.
_addPreviewItem(itemKey, category, displayName, image, slot, resource, price)
{
    item = spawnStruct();
    item.key = itemKey;
    item.category = category;
    item.name = displayName;
    item.image = image;
    item.price = price;
    item.available = false;
    item.resource = resource;
    item.slot = slot;
    openCJ\mySQL::mysqlSyncQuery(
        "INSERT INTO shopCatalog(itemKey,category,slot,price,available)"
        + " VALUES ('" + itemKey + "'," + category + ",'" + slot + "',"
        + item.price + "," + int(item.available) + ")"
        + " ON DUPLICATE KEY UPDATE category=VALUES(category),slot=VALUES(slot),"
        + "price=VALUES(price),available=VALUES(available)");
    level.shopItems[level.shopItems.size] = item;
}

onPlayerConnected()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    self.shopTab = level.shopCategoryPistol;
    self.shopLoaded = false;
    self thread responses();
}

command(args)
{
    self openMenu("opencj_shop");
}

availablePoints(totalPoints, spentPoints)
{
    remainingPoints = totalPoints - spentPoints;
    if(remainingPoints < 0)
    {
        return 0;
    }
    return remainingPoints;
}

// Route menu actions while limiting repeated requests from the same client.
responses()
{
    self endon("disconnect");
    requestIntervalMs = 200;
    itemPrefix = "item:";
    for(;;)
    {
        self waittill("menuresponse", menu, response);
        if(menu != "opencj_shop" && menu != "opencj_shop_confirm" && menu != "opencj_shop_inspect")
        {
            continue;
        }
        if(response == "close")
        {
            self closeInGameMenu();
            self closeMenu();
            self.shopOpen = false;
            self stopInspect();
            self openCJ\mySQL::cancelMenuReads("opencj_shop");
            self.shopSelection = undefined;
            continue;
        }
        if(response == "inspect_done")
        {
            self stopInspect();
            continue;
        }
        if(isDefined(self.shopRequestAt) && getTime() - self.shopRequestAt < requestIntervalMs)
        {
            continue;
        }
        self.shopRequestAt = getTime();
        if(response == "open")
        {
            self.shopOpen = true;
            self stopInspect();
            self.shopSelection = undefined;
            self thread show();
        }
        else if(response == "0" || response == "1" || response == "2")
        {
            self.shopTab = int(response);
            self.shopSelection = undefined;
            self thread show();
        }
        else if(response == "confirm" || response == "equip")
        {
            self thread purchase(response == "equip");
        }
        else if(response == "inspect")
        {
            self inspect();
        }
        else if(getSubStr(response, 0, itemPrefix.size) == itemPrefix)
        {
            self _selectItem(getSubStr(response, itemPrefix.size));
        }
    }
}

// Validate the visible row before opening its purchase or inspection details.
_selectItem(indexText)
{
    if(!isValidInt(indexText))
    {
        return;
    }
    rowIndex = int(indexText);
    if(!isDefined(self.shopRows) || rowIndex < 0 || rowIndex >= self.shopRows.size)
    {
        return;
    }
    item = self.shopRows[rowIndex];
    purchased = isDefined(self.shopOwned[item.key]);
    equipped = self _isItemEquipped(item);
    self.shopSelection = item.key;
    self setClientCvar("ocj_shop_detail_error", "");
    self setClientCvar("ocj_shop_confirm_name", item.name);
    self setClientCvar("ocj_shop_confirm_owned", int(purchased));
    self setClientCvar("ocj_shop_confirm_equipped", int(equipped));
    self setClientCvar("ocj_shop_confirm_buy", int(item.available && !purchased));
    self setClientCvar("ocj_shop_confirm_cost", item.price + " points");
    self closeInGameMenu();
    self closeMenu();
    self openMenu("opencj_shop_confirm");
}

_isItemEquipped(item)
{
    return isDefined(self.shopEquipped) && isDefined(self.shopEquipped[item.slot]) &&
           self.shopEquipped[item.slot] == item.key;
}

// Closing or replacing this screen cancels its reads; purchases have separate ownership.
show()
{
    self endon("disconnect");
    menuToken = self openCJ\mySQL::beginMenuRead("shop");
    if(!self openCJ\mySQL::menuReadCurrent(menuToken))
    {
        return;
    }
    self setClientCvar("ocj_shop_busy", 1);
    self setClientCvar("ocj_shop_error", "");
    if(!level.challengesReady || !self openCJ\login::isLoggedIn())
    {
        self setClientCvar("ocj_shop_error",
                           "Your account is loading. Reopen the shop in a moment.");
        return;
    }
    accountID = self openCJ\login::getPlayerID();
    totals = self openCJ\mySQL::mysqlAsyncMenuQuery(
        "SELECT"
        + " (SELECT COALESCE(SUM(pointsAwarded),0)"
        + " FROM challengeCompletions WHERE playerID=" + accountID + ")"
        + ",(SELECT COALESCE(SUM(pointsSpent),0)"
        + " FROM shopPurchases WHERE playerID=" + accountID + ")", "shop");
    if(!self openCJ\mySQL::menuReadCurrent(menuToken))
    {
        return;
    }
    if(!isDefined(totals) || !totals.size)
    {
        self setClientCvar("ocj_shop_error", "Shop data is unavailable. Please try again later.");
        return;
    }

    ownedRows = self openCJ\mySQL::mysqlAsyncMenuQuery(
        "SELECT itemKey FROM shopPurchases WHERE playerID=" + accountID, "shop");
    if(!self openCJ\mySQL::menuReadCurrent(menuToken))
    {
        return;
    }
    if(!isDefined(ownedRows))
    {
        self setClientCvar("ocj_shop_error", "Shop data is unavailable. Please try again later.");
        return;
    }
    totalPoints = int(totals[0][0]);
    spentPoints = int(totals[0][1]);
    self.shopOwned = [];
    for(i = 0; i < ownedRows.size; i++)
    {
        itemKey = ownedRows[i][0];
        self.shopOwned[itemKey] = true;
    }
    self _renderCatalogue(totalPoints, spentPoints);
}

// Publish the selected category after both account reads have completed.
_renderCatalogue(totalPoints, spentPoints)
{
    self.shopRows = [];
    clientValues = [];
    clientValues["ocj_shop_tab"] = self.shopTab;
    clientValues["ocj_shop_balance"] = availablePoints(totalPoints, spentPoints) + " points available";
    clientValues["ocj_shop_totals"] = "Total earned: " + totalPoints + "  |  Spent: " + spentPoints;
    for(i = 0; i < level.shopItems.size; i++)
    {
        item = level.shopItems[i];
        if(item.category != self.shopTab)
        {
            continue;
        }
        rowIndex = self.shopRows.size;
        self.shopRows[rowIndex] = item;
        valuePrefix = "ocj_shop_" + rowIndex + "_";
        purchased = isDefined(self.shopOwned[item.key]);
        purchaseState = "Currently unavailable";
        if(purchased)
        {
            purchaseState = "Purchased";
        }
        if(self _isItemEquipped(item))
        {
            purchaseState = "Purchased / Equipped";
        }
        clientValues[valuePrefix + "name"] = item.name;
        clientValues[valuePrefix + "price"] = item.price + " points";
        clientValues[valuePrefix + "image"] = item.image;
        clientValues[valuePrefix + "state"] = purchaseState;
        clientValues[valuePrefix + "owned"] = int(purchased);
        clientValues[valuePrefix + "buy"] = int(item.available && !purchased);
    }
    clientValues["ocj_shop_rows"] = self.shopRows.size;
    self openCJ\scoreboard::sendChanged(clientValues);
    self setClientCvar("ocj_shop_busy", 0);
}

// Load before spawning so a default model is never shown while SQL is pending.
// A newer load owns the cache; an older reply cannot replace its selection.
loadEquipment(forSpawn)
{
    if(getCodVersion() != 4)
    {
        return true;
    }
    self endon("disconnect");
    if(!self openCJ\login::isLoggedIn())
    {
        return false;
    }
    accountID = self openCJ\login::getPlayerID();
    if(isDefined(self.shopLoaded) && self.shopLoaded && isDefined(self.shopEquipmentAccountID) &&
       self.shopEquipmentAccountID == accountID)
    {
        return true;
    }

    self cancelEquipmentRead();
    self.shopEquipmentForSpawn = isDefined(forSpawn) && forSpawn;
    requestVersion = self.shopEquipmentVersion;
    scope = "equipment:" + self getEntityNumber();
    // The pool's menu policy provides cancellable reads. A separate scope lets
    // equipment finish when a UI closes, while replacement and disconnect cancel it.
    result = self openCJ\mySQL::_request(
        "SELECT 'ready','ready' UNION ALL" + " SELECT e.slot,e.itemKey FROM shopEquipped e" +
            " JOIN shopPurchases p ON p.playerID=e.playerID AND p.itemKey=e.itemKey" +
            " WHERE e.playerID=" + accountID,
        level.sqlConstants.policyMenu, "", scope, level.sqlConstants.defaultQueueWaitMs, true);
    if(requestVersion != self.shopEquipmentVersion)
    {
        return false;
    }
    self.shopEquipmentForSpawn = false;
    if(!self openCJ\login::isLoggedIn() || self openCJ\login::getPlayerID() != accountID)
    {
        return false;
    }
    if(!isDefined(result) || !isDefined(result.rows))
    {
        return false;
    }
    rows = result.rows;
    if(!rows.size || rows[0][0] != "ready")
    {
        return false;
    }

    equipment = [];
    for(i = 1; i < rows.size; i++)
    {
        slot = rows[i][0];
        itemKey = rows[i][1];
        equipment[slot] = itemKey;
    }
    self.shopEquipped = equipment;
    self.shopEquipmentAccountID = accountID;
    self.shopLoaded = true;
    return true;
}

cancelEquipmentRead()
{
    if(getCodVersion() != 4)
    {
        return;
    }
    if(!isDefined(self.shopEquipmentVersion))
    {
        self.shopEquipmentVersion = 0;
    }
    self.shopEquipmentVersion++;
    self.shopEquipmentForSpawn = false;
    mysql_async_cancel("equipment:" + self getEntityNumber(), level.sqlConstants.scopeExact,
                       level.sqlConstants.retainCompletion);
}

findItem(key)
{
    for(i = 0; i < level.shopItems.size; i++)
    {
        if(level.shopItems[i].key == key)
        {
            return level.shopItems[i];
        }
    }
    return undefined;
}

resource(slot)
{
    if(getCodVersion() != 4 || !isDefined(self.shopEquipped))
    {
        return "default";
    }
    key = self.shopEquipped[slot];
    if(!isDefined(key))
    {
        return "default";
    }
    item = findItem(key);
    if(!isDefined(item) || item.slot != slot)
    {
        return "default";
    }
    return item.resource;
}

// Let the database settle the purchase before refreshing equipment and reopening the shop.
purchase(equipOnly)
{
    self endon("disconnect");
    if(isDefined(self.shopInspect) || (isDefined(self.shopPurchaseBusy) && self.shopPurchaseBusy))
    {
        return;
    }
    if(!self openCJ\login::isLoggedIn() || !isDefined(self.shopSelection))
    {
        return;
    }
    item = findItem(self.shopSelection);
    if(!isDefined(item) || (!equipOnly && !item.available))
    {
        self sendLocalChatMessage("This item is currently unavailable.");
        return;
    }
    self.shopPurchaseBusy = true;
    // Only a server-owned catalogue key and authenticated account ID reach SQL.
    rows = self openCJ\mySQL::mysqlAsyncQuery(
        "CALL shopBuyOrEquip(" + self openCJ\login::getPlayerID() + ",'" +
        openCJ\mySQL::escapeString(item.key) + "'," + int(equipOnly) + "," + item.price + ")");
    outcome = undefined;
    if(isDefined(rows) && rows.size)
    {
        outcome = rows[0][0];
    }
    if(isDefined(outcome) && outcome == "ok")
    {
        self.shopLoaded = false;
        self loadEquipment();
        self sendLocalChatMessage("Equipped " + item.name +
                                  ". Your selection applies on your next spawn.");
    }
    else
    {
        message =
            "Purchase could not be confirmed. Reopen the shop to check ownership and balance.";
        if(isDefined(outcome) && outcome == "balance")
        {
            message = "You do not have enough available points.";
        }
        if(isDefined(outcome) && outcome == "price_changed")
        {
            message = "The price has changed. Reopen the shop before purchasing.";
        }
        if(isDefined(outcome) && outcome == "owned")
        {
            message = "You already own this item.";
        }
        self sendLocalChatMessage(message);
    }
    self.shopPurchaseBusy = false;
    self.shopRequestAt = undefined;
    if(isDefined(self.shopOpen) && self.shopOpen)
    {
        self closeInGameMenu();
        self closeMenu();
        self openMenu("opencj_shop");
    }
}

// Temporarily show the selected item while retaining the exact weapon and ammo state.
inspect()
{
    if(isDefined(self.shopInspect) || !isDefined(self.shopSelection) ||
       (isDefined(self.shopPurchaseBusy) && self.shopPurchaseBusy))
    {
        return;
    }
    if(self.sessionState != "playing" || !self isOnGround() || isDefined(self.cpc) ||
       self openCJ\demos::isPlayingDemo())
    {
        self setClientCvar("ocj_shop_detail_error",
                           "Stand on a platform outside CPC/demo mode to inspect.");
        return;
    }
    item = findItem(self.shopSelection);
    if(!isDefined(item))
    {
        return;
    }
    previewWeapon = undefined;
    if(item.category == level.shopCategoryPistol)
    {
        previewWeapon = level.weapons_loadouts[item.resource];
    }
    if(item.category == level.shopCategoryRPG)
    {
        previewWeapon = level.weapons_rpgs[item.resource];
    }
    if(item.category != level.shopCategoryModel && !isDefined(previewWeapon))
    {
        return;
    }
    previewState = self _captureLoadout();
    self notify("shop_inspect_started");
    self.shopInspect = previewState;
    self freezeControls(true);
    self setVelocity((0, 0, 0));
    // Frozen controls block input; disableWeapons also hides the viewmodel.
    self enableWeapons();
    if(item.category == level.shopCategoryModel)
    {
        self openCJ\playerModels::_setModel(item.resource);
    }
    else
    {
        self takeAllWeapons();
        self giveWeapon(previewWeapon);
        self giveMaxAmmo(previewWeapon);
        self setSpawnWeapon(previewWeapon);
        self switchToWeaponSeamless(previewWeapon);
    }
    self closeInGameMenu();
    self closeMenu();
    self openMenu("opencj_shop_inspect");
    self thread watchInspect();
}

// Inspection must restore ammo as well as weapon names when the preview ends.
_captureLoadout()
{
    loadout = spawnStruct();
    loadout.weapons = [];
    loadout.current = self getCurrentWeapon();
    weaponNames = self getWeaponsList();
    for(i = 0; i < weaponNames.size; i++)
    {
        weaponState = spawnStruct();
        weaponState.name = weaponNames[i];
        weaponState.clip = self getWeaponAmmoClip(weaponNames[i]);
        weaponState.stock = self getWeaponAmmoStock(weaponNames[i]);
        loadout.weapons[loadout.weapons.size] = weaponState;
    }
    return loadout;
}

stopInspect()
{
    if(!isDefined(self.shopInspect))
    {
        return;
    }
    self notify("shop_inspect_stopped");
    loadout = self.shopInspect;
    self.shopInspect = undefined;
    self takeAllWeapons();
    for(i = 0; i < loadout.weapons.size; i++)
    {
        weaponState = loadout.weapons[i];
        self giveWeapon(weaponState.name);
        self setWeaponAmmoClip(weaponState.name, weaponState.clip);
        self setWeaponAmmoStock(weaponState.name, weaponState.stock);
    }
    if(loadout.current != "none")
    {
        self setSpawnWeapon(loadout.current);
    }
    self openCJ\playerModels::setPlayerModel();
    self freezeControls(false);
    self enableWeapons();
    self closeInGameMenu();
    self closeMenu();
}

// Restore control if the player leaves normal play or abandons the preview.
watchInspect()
{
    self endon("disconnect");
    self endon("shop_inspect_stopped");
    startedAtMs = getTime();
    maximumInspectMs = 120000;
    inspectPollSeconds = 0.1;
    while(isDefined(self.shopInspect))
    {
        if(self.sessionState != "playing" || isDefined(self.cpc) ||
           getTime() - startedAtMs > maximumInspectMs)
        {
            self thread stopInspect();
            return;
        }
        wait inspectPollSeconds;
    }
}
