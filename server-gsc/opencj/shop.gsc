#include openCJ\util;

// The catalogue. Stable keys identify ownership in SQL, so a key is never reused.
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
    level.shopPreviewSeconds = 7;
    precacheMenu("opencj_shop");
    precacheMenu("opencj_shop_confirm");

    level.shopItems = [];
    _addStandardItems();
    _addBetaCollection();
    _storeCatalogue();
    openCJ\commands_base::registerCommand("shop", "!shop", ::command, 0, 0, 0);
}

// Everyone owns the standard look; equipping it switches a slot back from a skin.
_addStandardItems()
{
    standardItems = [];
    standardItems[standardItems.size] = _addItem("model.default", level.shopCategoryModel, "Default",
                                                 "opencj_shop_model_dark", "player", "default", 0);
    standardItems[standardItems.size] = _addItem("pistol.default", level.shopCategoryPistol,
                                                 "Desert Eagle", "weapon_desert_eagle", "deserteagle_mp",
                                                 "default", 0);
    standardItems[standardItems.size] = _addItem("rpg.default", level.shopCategoryRPG, "RPG-7",
                                                 "weapon_rpg7", "rpg_mp", "default", 0);
    for(i = 0; i < standardItems.size; i++)
    {
        standardItems[i].standard = true;
    }
}

// The Beta collection: rank 3 players can buy it until 1 January 2027 00:00 UTC.
// Each weapon differs from its stock weapon file only in the view and world models.
_addBetaCollection()
{
    minimumRank = 3;
    saleEndsAt = 1798761600;
    saleEndText = "Until 1 Jan 2027";
    weaponPrice = 100;
    modelPrice = 200;
    skinSlugs = [];
    skinNames = [];
    skinSlugs[skinSlugs.size] = "glitch";
    skinNames[skinNames.size] = "Beta: Glitch";
    betaItems = [];
    for(i = 0; i < skinSlugs.size; i++)
    {
        resourceName = "beta_" + skinSlugs[i];
        openCJ\weapons::_registerLoadout(resourceName, "deagle_beta_" + skinSlugs[i] + "_mp");
        openCJ\weapons::_registerRPG(resourceName, "rpg_beta_" + skinSlugs[i] + "_mp");
        betaItems[betaItems.size] = _addItem("pistol.beta_" + skinSlugs[i], level.shopCategoryPistol,
            skinNames[i], "opencj_shop_deagle_beta_" + skinSlugs[i], "deserteagle_mp", resourceName,
            weaponPrice);
        betaItems[betaItems.size] = _addItem("rpg.beta_" + skinSlugs[i], level.shopCategoryRPG,
            skinNames[i], "opencj_shop_rpg_beta_" + skinSlugs[i], "rpg_mp", resourceName,
            weaponPrice);
    }
    betaItems[betaItems.size] = _addItem("model.beta", level.shopCategoryModel, "Beta: Back Mark",
                                         "opencj_shop_model_beta", "player", "beta", modelPrice);
    for(i = 0; i < betaItems.size; i++)
    {
        betaItems[i].minimumRank = minimumRank;
        betaItems[i].saleEndsAt = saleEndsAt;
        betaItems[i].saleEndText = saleEndText;
        betaItems[i].available = getRealTime() < saleEndsAt;
    }
}

_addItem(itemKey, category, displayName, image, slot, resource, price)
{
    item = spawnStruct();
    item.key = itemKey;
    item.category = category;
    item.name = displayName;
    item.image = image;
    item.price = price;
    item.available = true;
    item.resource = resource;
    item.slot = slot;
    level.shopItems[level.shopItems.size] = item;
    return item;
}

// The purchase procedure trusts only these stored prices and availability flags.
// Items no longer in the catalogue stop being sold; their owners keep them.
_storeCatalogue()
{
    soldKeys = "";
    for(i = 0; i < level.shopItems.size; i++)
    {
        item = level.shopItems[i];
        if(_isStandard(item))
        {
            continue;
        }
        if(soldKeys != "")
        {
            soldKeys += ",";
        }
        soldKeys += "'" + item.key + "'";
        openCJ\mySQL::mysqlSyncQuery(
            "INSERT INTO shopCatalog(itemKey,category,slot,price,available)"
            + " VALUES ('" + item.key + "'," + item.category + ",'" + item.slot + "',"
            + item.price + "," + int(item.available) + ")"
            + " ON DUPLICATE KEY UPDATE category=VALUES(category),slot=VALUES(slot),"
            + "price=VALUES(price),available=VALUES(available)");
    }
    openCJ\mySQL::mysqlSyncQuery(
        "UPDATE shopCatalog SET available=0 WHERE itemKey NOT IN (" + soldKeys + ")");
}

_isStandard(item)
{
    return isDefined(item.standard) && item.standard;
}

_isOwned(item)
{
    return _isStandard(item) || isDefined(self.shopOwned[item.key]);
}

// Rank and the sale window are checked here, before the purchase reaches SQL.
_purchaseBlocker(item)
{
    if(!item.available || (isDefined(item.saleEndsAt) && getRealTime() >= item.saleEndsAt))
    {
        return "Currently unavailable";
    }
    if(isDefined(item.minimumRank) &&
       (!isDefined(self.challengeRank) || self.challengeRank < item.minimumRank))
    {
        return "Requires rank " + item.minimumRank;
    }
    return undefined;
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
        if(menu != "opencj_shop" && menu != "opencj_shop_confirm")
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
    purchased = self _isOwned(item);
    equipped = self _isItemEquipped(item);
    blocker = self _purchaseBlocker(item);
    reason = "";
    if(isDefined(blocker))
    {
        reason = blocker;
    }
    self.shopSelection = item.key;
    self setClientCvar("ocj_shop_detail_error", "");
    self setClientCvar("ocj_shop_confirm_name", item.name);
    self setClientCvar("ocj_shop_confirm_owned", int(purchased));
    self setClientCvar("ocj_shop_confirm_equipped", int(equipped));
    self setClientCvar("ocj_shop_confirm_buy", int(!isDefined(blocker) && !purchased));
    self setClientCvar("ocj_shop_confirm_reason", reason);
    self setClientCvar("ocj_shop_confirm_cost", item.price + " points");
    self closeInGameMenu();
    self closeMenu();
    self openMenu("opencj_shop_confirm");
}

// A slot with no equipped skin, or one no longer sold, shows the standard item.
_isItemEquipped(item)
{
    equippedKey = undefined;
    if(isDefined(self.shopEquipped) && isDefined(self.shopEquipped[item.slot]))
    {
        equippedKey = self.shopEquipped[item.slot];
    }
    if(_isStandard(item))
    {
        return !isDefined(equippedKey) || !isDefined(findItem(equippedKey));
    }
    return isDefined(equippedKey) && equippedKey == item.key;
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
        purchased = self _isOwned(item);
        blocker = self _purchaseBlocker(item);
        purchaseState = "Available";
        if(isDefined(item.saleEndText))
        {
            purchaseState = item.saleEndText;
        }
        if(isDefined(blocker))
        {
            purchaseState = blocker;
        }
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
        clientValues[valuePrefix + "buy"] = int(!isDefined(blocker) && !purchased);
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
    if(!isDefined(item))
    {
        return;
    }
    if(!equipOnly)
    {
        blocker = self _purchaseBlocker(item);
        if(isDefined(blocker))
        {
            self sendLocalChatMessage(blocker + ".");
            return;
        }
    }
    self.shopPurchaseBusy = true;
    outcome = undefined;
    if(_isStandard(item))
    {
        // Equipping the standard item clears the slot; the reload shows what SQL now holds.
        self openCJ\mySQL::mysqlAsyncQueryNosave("DELETE FROM shopEquipped WHERE playerID=" +
            self openCJ\login::getPlayerID() + " AND slot='" + item.slot + "'");
        outcome = "ok";
    }
    else
    {
        // Only a server-owned catalogue key and authenticated account ID reach SQL.
        rows = self openCJ\mySQL::mysqlAsyncQuery(
            "CALL shopBuyOrEquip(" + self openCJ\login::getPlayerID() + ",'" +
            openCJ\mySQL::escapeString(item.key) + "'," + int(equipOnly) + "," + item.price + ")");
        if(isDefined(rows) && rows.size)
        {
            outcome = rows[0][0];
        }
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

// Let the player move and fire with the selected item for a few seconds. The preview
// weapon carries the ammo of the weapon it stands in for, so it gives nothing extra:
// an RPG skin cannot fire on a map where the player has no RPG.
inspect()
{
    if(!isDefined(self.shopSelection) || (isDefined(self.shopPurchaseBusy) && self.shopPurchaseBusy))
    {
        return;
    }
    if(self.sessionState != "playing" || isDefined(self.cpc) || self openCJ\demos::isPlayingDemo())
    {
        self setClientCvar("ocj_shop_detail_error", "Leave CPC/demo mode to preview.");
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
    // A new preview replaces a running one, so skins can be compared back to back.
    self stopInspect();
    preview = spawnStruct();
    preview.loadout = self _captureLoadout();
    self notify("shop_inspect_started");
    self.shopInspect = preview;
    self closeInGameMenu();
    self closeMenu();
    self.shopOpen = false;
    if(item.category == level.shopCategoryModel)
    {
        self detachAll();
        self openCJ\playerModels::_setModel(item.resource);
        preview.mannequin = self _spawnMannequin(item.resource);
    }
    else
    {
        preview.weapon = previewWeapon;
        preview.replaced = _replacedWeapon(preview.loadout, item.category == level.shopCategoryRPG);
        self takeAllWeapons();
        self giveWeapon(previewWeapon);
        clip = 0;
        stock = 0;
        if(isDefined(preview.replaced))
        {
            clip = preview.replaced.clip;
            stock = preview.replaced.stock;
        }
        self setWeaponAmmoClip(previewWeapon, clip);
        self setWeaponAmmoStock(previewWeapon, stock);
        self setSpawnWeapon(previewWeapon);
        self switchToWeaponSeamless(previewWeapon);
    }
    self iPrintLn("Previewing " + item.name + " for " + level.shopPreviewSeconds + " seconds");
    self thread watchInspect();
}

// The carried weapon the preview stands in for: the RPG for RPG skins, else the pistol.
_replacedWeapon(loadout, isRPGSkin)
{
    for(i = 0; i < loadout.weapons.size; i++)
    {
        weaponName = loadout.weapons[i].name;
        if(openCJ\weapons::isGrenade(weaponName))
        {
            continue;
        }
        if(openCJ\weapons::isRPG(weaponName) == isRPGSkin)
        {
            return loadout.weapons[i];
        }
    }
    return undefined;
}

// The player cannot see their own body, so a turning copy stands in front of them.
_spawnMannequin(modelName)
{
    mannequinDistance = 80;
    facing = (0, self.angles[1], 0);
    mannequin = spawn("script_model", self.origin + anglesToForward(facing) * mannequinDistance);
    mannequin.angles = facing + (0, 180, 0);
    mannequin openCJ\playerModels::_setModel(modelName);
    mannequin rotateYaw(360, level.shopPreviewSeconds);
    return mannequin;
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

// Give back the carried weapons; ammo spent with the preview weapon stays spent.
stopInspect()
{
    if(!isDefined(self.shopInspect))
    {
        return;
    }
    self notify("shop_inspect_stopped");
    preview = self.shopInspect;
    self.shopInspect = undefined;
    if(isDefined(preview.mannequin))
    {
        preview.mannequin delete();
    }
    if(isDefined(preview.replaced) && self hasWeapon(preview.weapon))
    {
        preview.replaced.clip = self getWeaponAmmoClip(preview.weapon);
        preview.replaced.stock = self getWeaponAmmoStock(preview.weapon);
    }
    self takeAllWeapons();
    loadout = preview.loadout;
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
}

// End the preview when its time is up or the player leaves normal play.
watchInspect()
{
    self endon("disconnect");
    self endon("shop_inspect_stopped");
    previewEndsAt = getTime() + level.shopPreviewSeconds * 1000;
    while(isDefined(self.shopInspect))
    {
        if(self.sessionState != "playing" || isDefined(self.cpc) || getTime() >= previewEndsAt)
        {
            self thread stopInspect();
            return;
        }
        wait 0.05;
    }
}
