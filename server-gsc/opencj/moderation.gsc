#include openCJ\util;

// Kicks, temporary and permanent bans, and the target rules shared by moderation
// commands. Read docs/reference/permissions.md before changing who may use them.
//
// A ban covers the account plus the IP address and CoD4x player ID it last used.
// The engine refuses banned addresses and player IDs before the player appears in
// game; the account itself is checked again when it logs in.

onInit()
{
    maximumPermissionArguments = 3; // Action, player and permission name.
    permissionsCommand = registerModerationCommand(
        "permissions",
        "Show or change permissions. Usage: !permissions [help | <player> | grant <player> " +
        "<permission|group> | revoke <player> <permission|group>]. Use a playerID if a name " +
        "is ambiguous.",
        ::onPermissionsCommand, 0, maximumPermissionArguments, undefined);
    openCJ\commands_base::addAlias(permissionsCommand, "perms");
    registerModerationCommand(
        "kick", "Kick an online player. Usage: !kick <player> <reason>",
        ::onKickCommand, 2, undefined, "kick");
    registerModerationCommand(
        "tempban", "Ban for up to 7 days. Usage: !tempban <player> <30m|12h|7d> <reason>",
        ::onTempBanCommand, 3, undefined, "tempban");
    registerModerationCommand(
        "untempban", "Lift a temporary ban. Usage: !untempban <playerID>",
        ::onUntempBanCommand, 1, 1, "tempban");
    registerModerationCommand(
        "permban", "Ban permanently. Usage: !permban <player> <reason>",
        ::onPermBanCommand, 2, undefined, "uber");
    registerModerationCommand(
        "unpermban", "Lift a permanent ban. Usage: !unpermban <playerID>",
        ::onUnpermBanCommand, 1, 1, "uber");
    registerModerationCommand(
        "bans", "List the newest active bans with their playerIDs.",
        ::onBansCommand, 0, 0, "tempban");

    level thread reloadConnectionBans();
}

// ---------------------------------------------------------------------------
// Limits
// ---------------------------------------------------------------------------

// Functions rather than level variables, so they hold before onInit runs too.
maximumTempBanSeconds()
{
    return 7 * 24 * 60 * 60; // Agreed limit for temporary bans; banPlayer enforces it too.
}

maximumReasonLength()
{
    return 150; // Matches playerBans.reason.
}

connectionBanCapacity()
{
    return 1024; // Matches CONNECTION_BAN_CAPACITY in server-ext/opencj_bans.cpp.
}

banListLines()
{
    return 10; // Keeps !bans readable in chat.
}

// ---------------------------------------------------------------------------
// Targets
// ---------------------------------------------------------------------------

// Logged-in online players whose name matches exactly, or else contains the text.
matchOnlinePlayers(searchText)
{
    searchName = toLower(stripColors(searchText));
    exactMatches = [];
    partialMatches = [];
    players = getEntArray("player", "classname");
    for (i = 0; i < players.size; i++)
    {
        if (!players[i] openCJ\login::isLoggedIn())
        {
            continue;
        }
        playerName = toLower(stripColors(players[i].name));
        if (playerName == searchName)
        {
            exactMatches[exactMatches.size] = players[i];
        }
        else if (isSubStr(playerName, searchName))
        {
            partialMatches[partialMatches.size] = players[i];
        }
    }
    if (exactMatches.size > 0)
    {
        return exactMatches;
    }
    return partialMatches;
}

// "Name (#12), Other (#57)" for at most a few players, so a chat line stays short.
describePlayers(players)
{
    maximumListedPlayers = 5;
    description = "";
    for (i = 0; i < players.size && i < maximumListedPlayers; i++)
    {
        if (description != "")
        {
            description += ", ";
        }
        description += players[i].name + "^7 (#" + accountID(players[i]) + ")";
    }
    if (players.size > maximumListedPlayers)
    {
        description += ", ...";
    }
    return description;
}

// Accept a playerID (online or offline) or part of an online player's name. A name
// must match exactly or match one player only, so an action never lands on a
// similarly named player by a guess. Returns undefined after telling the caller why.
resolveTarget(targetText)
{
    playerID = parsePlayerID(targetText);
    if (isDefined(playerID))
    {
        target = spawnStruct();
        target.playerID = playerID;
        target.player = getPlayerByPlayerID(playerID);
        target.displayName = "#" + playerID;
        if (isDefined(target.player))
        {
            target.displayName = target.player.name + "^7 (#" + playerID + ")";
        }
        return target;
    }

    matches = matchOnlinePlayers(targetText);
    if (matches.size == 0)
    {
        self sendLocalChatMessage("No online player matches '" + targetText +
                                  "'. Offline players need their playerID.", true);
        return undefined;
    }
    if (matches.size > 1)
    {
        self sendLocalChatMessage("Several players match; use a playerID: " +
                                  describePlayers(matches), true);
        return undefined;
    }
    target = spawnStruct();
    target.player = matches[0];
    target.playerID = accountID(target.player);
    target.displayName = target.player.name + "^7 (#" + target.playerID + ")";
    return target;
}

// Nobody acts on themselves, and only an uber-admin may act on an uber-admin.
// Offline uber-admins are protected again by the database functions.
canModerate(target)
{
    if (target.playerID == accountID(self))
    {
        self sendLocalChatMessage("You cannot do that to yourself.", true);
        return false;
    }
    isTargetUber = isDefined(target.player) && isUber(target.player);
    if (isTargetUber && !isUber(self))
    {
        self sendLocalChatMessage("Uber-admins cannot be moderated.", true);
        return false;
    }
    return true;
}

// The remaining arguments joined as a reason, or undefined (with a message) when
// it is empty or too long. Every kick and ban needs a reason.
readReason(commandArguments, firstReasonIndex)
{
    reason = arrayConcat(subArray(commandArguments, firstReasonIndex));
    visibleReason = stripColors(reason);
    hasVisibleText = false;
    for (i = 0; i < visibleReason.size; i++)
    {
        if (visibleReason[i] != " ")
        {
            hasVisibleText = true;
            break;
        }
    }
    if (!hasVisibleText)
    {
        self sendLocalChatMessage("A reason is required.", true);
        return undefined;
    }
    if (reason.size > maximumReasonLength())
    {
        self sendLocalChatMessage("Keep the reason under " + maximumReasonLength() +
                                  " characters.", true);
        return undefined;
    }
    return reason;
}

// "30m", "12h" or "7d" in seconds; undefined when malformed or not positive.
parseDurationSeconds(durationText)
{
    // Four digits keeps even "9999d" inside a 32-bit integer.
    maximumAmountDigits = 4;
    if (!isDefined(durationText) || durationText.size < 2)
    {
        return undefined;
    }
    amountText = getSubStr(durationText, 0, durationText.size - 1);
    unit = toLower(durationText[durationText.size - 1]);
    if (amountText.size > maximumAmountDigits || !digits(amountText))
    {
        return undefined;
    }
    secondsPerUnit = undefined;
    if (unit == "m")
    {
        secondsPerUnit = 60;
    }
    else if (unit == "h")
    {
        secondsPerUnit = 60 * 60;
    }
    else if (unit == "d")
    {
        secondsPerUnit = 24 * 60 * 60;
    }
    if (!isDefined(secondsPerUnit))
    {
        return undefined;
    }
    durationSeconds = int(amountText) * secondsPerUnit;
    if (durationSeconds <= 0)
    {
        return undefined;
    }
    return durationSeconds;
}

// "3d 4h 5m" for a positive number of seconds.
formatDuration(totalSeconds)
{
    secondsPerDay = 24 * 60 * 60;
    secondsPerHour = 60 * 60;
    days = int(totalSeconds / secondsPerDay);
    hours = int((totalSeconds % secondsPerDay) / secondsPerHour);
    minutes = int((totalSeconds % secondsPerHour) / 60);
    if (days > 0)
    {
        return days + "d " + hours + "h " + minutes + "m";
    }
    if (hours > 0)
    {
        return hours + "h " + minutes + "m";
    }
    return max(1, minutes) + "m";
}

// One database-backed moderation request per player at a time, so a repeated
// command cannot race the first one's result.
beginRequest()
{
    if (isDefined(self.moderationRequestBusy) && self.moderationRequestBusy)
    {
        self sendLocalChatMessage("A moderation request is already being processed.", true);
        return false;
    }
    self.moderationRequestBusy = true;
    return true;
}

endRequest()
{
    self.moderationRequestBusy = false;
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

onKickCommand(commandArguments)
{
    target = self resolveTarget(commandArguments[0]);
    if (!isDefined(target))
    {
        return;
    }
    if (!isDefined(target.player))
    {
        self sendLocalChatMessage("Only online players can be kicked.", true);
        return;
    }
    if (!self canModerate(target))
    {
        return;
    }
    reason = self readReason(commandArguments, 1);
    if (!isDefined(reason))
    {
        return;
    }
    printf("Moderation: player " + accountID(self) + " kicked player " +
           target.playerID + "\n");
    targetName = target.displayName;
    kick(target.player getEntityNumber(), "Kicked: " + reason);
    self sendLocalChatMessage("Kicked " + targetName + ".");
}

onTempBanCommand(commandArguments)
{
    durationSeconds = parseDurationSeconds(commandArguments[1]);
    if (!isDefined(durationSeconds) || durationSeconds > maximumTempBanSeconds())
    {
        self sendLocalChatMessage("Use a duration like 30m, 12h or 7d (at most 7 days).", true);
        return;
    }
    self runBan(commandArguments, 2, durationSeconds);
}

onPermBanCommand(commandArguments)
{
    self runBan(commandArguments, 1, undefined);
}

// Ban the first argument's account; durationSeconds undefined means permanent.
runBan(commandArguments, firstReasonIndex, durationSeconds)
{
    target = self resolveTarget(commandArguments[0]);
    if (!isDefined(target) || !self canModerate(target))
    {
        return;
    }
    reason = self readReason(commandArguments, firstReasonIndex);
    if (!isDefined(reason) || !self beginRequest())
    {
        return;
    }

    durationValue = "NULL";
    if (isDefined(durationSeconds))
    {
        durationValue = "" + durationSeconds;
    }
    rows = self writeRows(
        "SELECT banPlayer(" + accountID(self) + ", " + target.playerID + ", " +
        durationValue + ", '" + sqlText(reason) + "')",
        "ban:" + target.playerID);
    self endRequest();
    if (!hasResult(rows))
    {
        self sendLocalChatMessage("Could not ban; try again later.", true);
        return;
    }
    result = int(rows[0][0]);
    if (result < 0)
    {
        self sendLocalChatMessage(banFailureText(result), true);
        return;
    }

    level thread reloadConnectionBans();
    lengthText = "permanently";
    if (isDefined(durationSeconds))
    {
        lengthText = "for " + formatDuration(durationSeconds);
    }
    // Look the target up again: they may have left while the database answered.
    onlineTarget = getPlayerByPlayerID(target.playerID);
    if (isDefined(onlineTarget))
    {
        kick(onlineTarget getEntityNumber(), "Banned " + lengthText + ": " + reason);
    }
    self sendLocalChatMessage("Banned " + target.displayName + " " + lengthText + ".");
}

onUntempBanCommand(commandArguments)
{
    self runLift(commandArguments[0], false);
}

onUnpermBanCommand(commandArguments)
{
    self runLift(commandArguments[0], true);
}

runLift(targetText, isPermanent)
{
    target = self resolveTarget(targetText);
    if (!isDefined(target) || !self beginRequest())
    {
        return;
    }
    permanentValue = 0;
    if (isPermanent)
    {
        permanentValue = 1;
    }
    rows = self writeRows(
        "SELECT liftPlayerBan(" + accountID(self) + ", " + target.playerID +
        ", " + permanentValue + ")",
        "ban:" + target.playerID);
    self endRequest();
    if (!hasResult(rows))
    {
        self sendLocalChatMessage("Could not lift the ban; try again later.", true);
        return;
    }
    result = int(rows[0][0]);
    if (result < 0)
    {
        self sendLocalChatMessage(liftFailureText(result, isPermanent), true);
        return;
    }
    level thread reloadConnectionBans();
    self sendLocalChatMessage("Lifted the ban on " + target.displayName + ".");
}

onBansCommand(commandArguments)
{
    if (!self beginRequest())
    {
        return;
    }
    rows = self readRows(
        "SELECT b.bannedPlayerID, d.playerName, b.expiresAt IS NULL," +
        " TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), b.expiresAt), b.reason" +
        " FROM playerBans b" +
        " JOIN playerDisplayNames d ON d.playerID = b.bannedPlayerID" +
        " WHERE b.liftedAt IS NULL" +
        " AND (b.expiresAt IS NULL OR b.expiresAt > UTC_TIMESTAMP())" +
        " ORDER BY b.createdAt DESC" +
        " LIMIT " + banListLines());
    self endRequest();
    if (!isDefined(rows))
    {
        self sendLocalChatMessage("Could not read bans; try again later.", true);
        return;
    }
    if (rows.size == 0)
    {
        self sendLocalChatMessage("There are no active bans.");
        return;
    }
    self sendLocalChatMessage("Newest active bans:");
    for (i = 0; i < rows.size; i++)
    {
        bannedPlayerID = rows[i][0];
        bannedName = rows[i][1];
        isPermanent = int(rows[i][2]) != 0;
        reason = rows[i][4];
        lengthText = "permanent";
        if (!isPermanent)
        {
            lengthText = formatDuration(int(rows[i][3])) + " left";
        }
        self sendLocalChatMessage(bannedName + "^7 (#" + bannedPlayerID + "): " + lengthText +
                                  " - " + reason);
    }
}

// Translate banPlayer's negative result codes.
banFailureText(resultCode)
{
    actorNotAllowed = -1;
    invalidDuration = -2;
    invalidReason = -3;
    targetMissing = -4;
    targetIsUber = -5;
    targetIsActor = -6;
    permanentBanStands = -7;

    if (resultCode == actorNotAllowed)
    {
        return "You are not allowed to ban like that.";
    }
    if (resultCode == invalidDuration)
    {
        return "Temporary bans last from one minute to 7 days.";
    }
    if (resultCode == invalidReason)
    {
        return "A reason of at most " + maximumReasonLength() +
               " characters is required.";
    }
    if (resultCode == targetMissing)
    {
        return "No account has that playerID.";
    }
    if (resultCode == targetIsUber)
    {
        return "Uber-admins cannot be moderated.";
    }
    if (resultCode == targetIsActor)
    {
        return "You cannot do that to yourself.";
    }
    if (resultCode == permanentBanStands)
    {
        return "That player is permanently banned; a temporary ban cannot replace it.";
    }
    return "Could not ban (code " + resultCode + ").";
}

// Translate liftPlayerBan's negative result codes.
liftFailureText(resultCode, isPermanent)
{
    actorNotAllowed = -1;
    targetMissing = -4;
    noActiveBan = -8;

    if (resultCode == actorNotAllowed)
    {
        return "You are not allowed to lift that ban.";
    }
    if (resultCode == targetMissing)
    {
        return "No account has that playerID.";
    }
    if (resultCode == noActiveBan)
    {
        if (isPermanent)
        {
            return "That player has no active permanent ban.";
        }
        return "That player has no active temporary ban.";
    }
    return "Could not lift the ban (code " + resultCode + ").";
}

// ---------------------------------------------------------------------------
// Enforcement
// ---------------------------------------------------------------------------

// Replace the engine's connection ban table with the active bans in the database.
// Runs at map start and after every ban change. Map starts also pick up bans made
// on another server that shares the database.
reloadConnectionBans()
{
    if (getCodVersion() != 4)
    {
        return;
    }
    level notify("reloadConnectionBans");
    level endon("reloadConnectionBans");
    rows = readRows(
        "SELECT banID, COALESCE(bannedIP, ''), COALESCE(bannedClientID, '')," +
        " IF(expiresAt IS NULL, -1, TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), expiresAt)), reason" +
        " FROM playerBans" +
        " WHERE liftedAt IS NULL" +
        " AND (expiresAt IS NULL OR expiresAt > UTC_TIMESTAMP())" +
        " AND (bannedIP IS NOT NULL OR bannedClientID IS NOT NULL)" +
        " ORDER BY expiresAt IS NULL DESC, expiresAt DESC" +
        " LIMIT " + connectionBanCapacity());
    // Keep the previous table when the database does not answer; login checks
    // still apply to the account.
    if (!isDefined(rows))
    {
        printf("WARN: connection bans not reloaded; database did not answer\n");
        return;
    }
    clearConnectionBans();
    for (i = 0; i < rows.size; i++)
    {
        banID = int(rows[i][0]);
        bannedIP = rows[i][1];
        bannedClientID = rows[i][2];
        secondsLeft = int(rows[i][3]);
        reason = rows[i][4];
        setConnectionBan(banID, bannedIP, bannedClientID, secondsLeft, reason);
    }
}

// Called when a connecting player's account is identified, before anything about
// the login is published. Records the address and CoD4x player ID that future bans
// will cover, then refuses the player if the account, address or player ID is
// banned. Returns true after kicking a banned player.
enforceBanAtLogin(accountPlayerID)
{
    currentIP = self getIp();
    currentClientID = "";
    if (getCodVersion() == 4)
    {
        currentClientID = self getPlayerID();
    }
    escapedIP = sqlText(currentIP);
    escapedClientID = sqlText(currentClientID);
    self openCJ\mySQL::mysqlAsyncQueryNosave(
        "UPDATE playerInformation" +
        " SET lastIP = '" + escapedIP + "', lastClientID = NULLIF('" + escapedClientID + "', '')" +
        " WHERE playerID = " + accountPlayerID);

    rows = self readRows(
        "SELECT expiresAt IS NULL, TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), expiresAt), reason" +
        " FROM playerBans" +
        " WHERE liftedAt IS NULL" +
        " AND (expiresAt IS NULL OR expiresAt > UTC_TIMESTAMP())" +
        " AND (bannedPlayerID = " + accountPlayerID +
        " OR bannedIP = '" + escapedIP + "'" +
        " OR bannedClientID = NULLIF('" + escapedClientID + "', ''))" +
        " ORDER BY expiresAt IS NULL DESC, expiresAt DESC" +
        " LIMIT 1");
    // An unavailable database lets the login continue: the engine table still
    // refuses known addresses and player IDs, and blocking every login would be worse.
    if (!hasResult(rows))
    {
        return false;
    }
    isPermanent = int(rows[0][0]) != 0;
    reason = rows[0][2];
    lengthText = "permanently";
    if (!isPermanent)
    {
        lengthText = "for another " + formatDuration(int(rows[0][1]));
    }
    printf("Moderation: refused banned account " + accountPlayerID + "\n");
    kick(self getEntityNumber(), "You are banned " + lengthText + ": " + reason);
    return true;
}

// ---------------------------------------------------------------------------
// !permissions
// ---------------------------------------------------------------------------

// !permissions: show your own, list all, show another player's, or grant/revoke one.
onPermissionsCommand(commandArguments)
{
    if (!self openCJ\login::isLoggedIn())
    {
        self sendLocalChatMessage("Your account is still loading; try again shortly.", true);
        return;
    }
    if (commandArguments.size == 0)
    {
        self sendLocalChatMessage("Your permissions: " + openCJ\permissions::describeMask(self.permissions));
        return;
    }

    action = toLower(commandArguments[0]);
    if (action == "help" || action == "list")
    {
        self showCatalogue();
        return;
    }

    isGrant = action == "grant" || action == "add";
    isRevoke = action == "revoke" || action == "remove";
    isChange = isGrant || isRevoke;
    if (isChange && commandArguments.size != 3)
    {
        self sendLocalChatMessage("Usage: !permissions " + action + " <player> <permission|group>",
                                  true);
        return;
    }
    if (!isChange && commandArguments.size != 1)
    {
        self sendLocalChatMessage(level.commands["permissions"].help, true);
        return;
    }

    // Lookups and changes wait for the database. One request per player at a time
    // prevents a second command from racing the first one's result.
    if (isDefined(self.permissionRequestBusy) && self.permissionRequestBusy)
    {
        self sendLocalChatMessage("A permission request is already being processed.", true);
        return;
    }
    self.permissionRequestBusy = true;
    if (isChange)
    {
        self changePermission(commandArguments[1], commandArguments[2], isGrant);
    }
    else
    {
        self showPlayerPermissions(commandArguments[0]);
    }
    self.permissionRequestBusy = false;
}

showCatalogue()
{
    self sendLocalChatMessage("Permissions and groups (!permissions grant <player> <name>):");
    permissionNames = openCJ\permissions::permissionNames();
    for (i = 0; i < permissionNames.size; i++)
    {
        permission = openCJ\permissions::permissionNamed(permissionNames[i]);
        self sendLocalChatMessage("^3" + permission.name + "^7: " + permission.description);
    }
    groupNames = openCJ\permissions::groupNames();
    for (i = 0; i < groupNames.size; i++)
    {
        group = openCJ\permissions::groupNamed(groupNames[i]);
        self sendLocalChatMessage("^3" + group.name + "^7 (group): " + group.description);
    }
}

showPlayerPermissions(targetText)
{
    target = self resolveTarget(targetText);
    if (!isDefined(target))
    {
        return;
    }
    isSelf = target.playerID == accountID(self);
    if (!isSelf && !self openCJ\permissions::hasPermission("perms"))
    {
        self sendLocalChatMessage("Viewing other players' permissions requires perms.", true);
        return;
    }
    // Online players show the permissions in effect now; offline ones show the stored value.
    if (isDefined(target.player))
    {
        self sendLocalChatMessage(target.displayName + ": " +
                                  openCJ\permissions::describeMask(target.player.permissions));
        return;
    }
    rows = self readRows(
        "SELECT p.permissions, d.playerName" +
        " FROM playerInformation p" +
        " JOIN playerDisplayNames d ON d.playerID = p.playerID" +
        " WHERE p.playerID = " + target.playerID);
    if (!isDefined(rows))
    {
        self sendLocalChatMessage("Could not read permissions; try again later.", true);
        return;
    }
    if (!hasResult(rows))
    {
        self sendLocalChatMessage("No account has playerID " + target.playerID + ".", true);
        return;
    }
    storedMask = int(rows[0][0]);
    storedName = rows[0][1];
    self sendLocalChatMessage(storedName + " (#" + target.playerID + ", offline): " +
                              openCJ\permissions::describeMask(storedMask));
}

// Validate here for clear messages; setPlayerPermissions repeats every rule in the
// database, under row locks, and records each changed bit. A group changes all its
// member permissions together, or none of them.
changePermission(targetText, permissionText, isGrant)
{
    if (!self openCJ\permissions::hasPermission("perms"))
    {
        self sendLocalChatMessage("Granting or revoking permissions requires perms.", true);
        return;
    }
    grantable = openCJ\permissions::grantableNamed(permissionText);
    if (!isDefined(grantable))
    {
        self sendLocalChatMessage("Unknown permission or group '" + permissionText +
                                  "'. See !permissions help.", true);
        return;
    }
    if (isInArray("uber", grantable.memberNames))
    {
        self sendLocalChatMessage("The uber permission can only be changed in the database.",
                                  true);
        return;
    }
    if (!self openCJ\permissions::isUberAdmin())
    {
        if (isInArray("perms", grantable.memberNames))
        {
            self sendLocalChatMessage("Only uber-admins can grant or revoke perms.", true);
            return;
        }
        for (i = 0; i < grantable.memberNames.size; i++)
        {
            if (!self openCJ\permissions::hasPermission(grantable.memberNames[i]))
            {
                self sendLocalChatMessage("You can only grant or revoke permissions you hold" +
                                          " (missing " + grantable.memberNames[i] + ").", true);
                return;
            }
        }
    }
    target = self resolveTarget(targetText);
    if (!isDefined(target))
    {
        return;
    }

    grantValue = 0;
    if (isGrant)
    {
        grantValue = 1;
    }
    rows = self writeRows(
        "SELECT setPlayerPermissions(" + accountID(self) + ", " +
        target.playerID + ", " + grantable.mask + ", " + grantValue + ")",
        "permissions:" + target.playerID);
    if (!hasResult(rows))
    {
        self sendLocalChatMessage("Could not change permissions; try again later.", true);
        return;
    }
    result = int(rows[0][0]);
    if (result < 0)
    {
        self sendLocalChatMessage(changeFailureText(result, isGrant), true);
        return;
    }

    // Look the target up again: they may have left while the database answered.
    onlineTarget = getPlayerByPlayerID(target.playerID);
    actionText = "Revoked";
    if (isGrant)
    {
        actionText = "Granted";
    }
    if (isDefined(onlineTarget))
    {
        onlineTarget openCJ\permissions::setPermissions(result);
        onlineTarget sendLocalChatMessage(self.name + "^7 " + toLower(actionText) + " " +
                                          grantable.name + ". Your permissions: " +
                                          openCJ\permissions::describeMask(result));
    }
    self sendLocalChatMessage(actionText + " " + grantable.name + " for " + target.displayName +
                              ". Now: " + openCJ\permissions::describeMask(result));
}

// Translate setPlayerPermissions' negative result codes.
changeFailureText(resultCode, isGrant)
{
    invalidPermission = -1;
    uberIsDatabaseOnly = -2;
    actorLacksPerms = -3;
    actorLacksPermission = -4;
    permsNeedsUber = -5;
    targetMissing = -6;
    targetIsUber = -7;
    alreadyInState = -8;

    if (resultCode == invalidPermission)
    {
        return "That permission is not valid.";
    }
    if (resultCode == uberIsDatabaseOnly)
    {
        return "The uber permission can only be changed in the database.";
    }
    if (resultCode == actorLacksPerms)
    {
        return "Granting or revoking permissions requires perms.";
    }
    if (resultCode == actorLacksPermission)
    {
        return "You can only grant or revoke permissions you hold.";
    }
    if (resultCode == permsNeedsUber)
    {
        return "Only uber-admins can grant or revoke perms.";
    }
    if (resultCode == targetMissing)
    {
        return "No account has that playerID.";
    }
    if (resultCode == targetIsUber)
    {
        return "Uber-admins' permissions can only be changed in the database.";
    }
    if (resultCode == alreadyInState)
    {
        if (isGrant)
        {
            return "They already have all of that.";
        }
        return "They have none of that to revoke.";
    }
    return "Could not change permissions (code " + resultCode + ").";
}

// ---------------------------------------------------------------------------
// Local wrappers
// ---------------------------------------------------------------------------

// Each wrapper is this file's only reference to its target. The engine counts
// cross-file function references while it loads a chain of scripts, and that count
// is capped (MAX_PRECACHE_ENTRIES), so repeated direct calls here would crowd it.

registerModerationCommand(commandName, description, callback, minArgs, maxArgs, permissionName)
{
    return openCJ\commands_base::registerCommand(commandName, description, callback, minArgs,
                                                  maxArgs, permissionName);
}

accountID(player)
{
    return player openCJ\login::getPlayerID();
}

isUber(player)
{
    return player openCJ\permissions::isUberAdmin();
}

sqlText(text)
{
    return openCJ\mySQL::escapeString(text);
}

readRows(query)
{
    return self openCJ\mySQL::mysqlAsyncRead(query);
}

writeRows(query, orderingKey)
{
    return self openCJ\mySQL::mysqlAsyncWrite(query, orderingKey);
}
