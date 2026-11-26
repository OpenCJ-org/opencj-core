// Exercise permission masks, moderation input parsing and target rules without SQL.
// The database rules themselves are covered by permissions-sql.py.
main()
{
    level.permissionChecks = 0;
    level.permissionFailures = 0;
    openCJ\mySQL::_initConstants();
    openCJ\commands_base::onInit();
    openCJ\commands::onInit();
    wait 1;

    verifyCatalogue();
    verifyMasks();
    verifyDurations();
    verifyRegistrations();

    player = addTestClient();
    otherPlayer = addTestClient();
    wait 0.2;
    check(isDefined(player) && isDefined(otherPlayer), "two isolated test clients connected");
    spawnpoints = getEntArray("mp_dm_spawn", "classname");
    check(spawnpoints.size > 0, "map provides a spawn for the test clients");
    if (isDefined(player) && isDefined(otherPlayer) && spawnpoints.size > 0)
    {
        spawnHeightUnits = 32;
        player prepareClient(1, spawnpoints[0].origin + (0, 0, spawnHeightUnits));
        otherPlayer prepareClient(2, spawnpoints[0].origin + (64, 0, spawnHeightUnits));
        player verifyReasons();
        player verifyTargets(otherPlayer);
    }
    printf("PERMISSIONS COMPLETE failures=" + level.permissionFailures + " checks=" +
           level.permissionChecks + "\n");
}

verifyCatalogue()
{
    mute = openCJ\permissions::permissionNamed("MUTE");
    check(isDefined(mute) && mute.name == "mute" && mute.flag == 8,
          "permission names ignore case and bit 3 has value 8");
    check(openCJ\permissions::permissionNamed("uber").flag == 1, "uber is bit 0");
    check(!isDefined(openCJ\permissions::permissionNamed("namerules")),
          "name rules have no permission of their own");

    moderation = openCJ\permissions::grantableNamed("Moderation");
    expectedModerationMask = 8 + 16 + 128 + 256; // mute, names, kick and tempban.
    check(isDefined(moderation) && moderation.isGroup && moderation.name == "mod" &&
              moderation.mask == expectedModerationMask && moderation.memberNames.size == 4,
          "the moderation alias resolves to the mod group and its four members");
    kick = openCJ\permissions::grantableNamed("kick");
    check(isDefined(kick) && !kick.isGroup && kick.mask == 128 && kick.memberNames[0] == "kick",
          "a single permission resolves as a one-member grant");
    check(!isDefined(openCJ\permissions::grantableNamed("admins")),
          "unknown groups resolve to nothing");
    cpeditFlag = openCJ\permissions::permissionNamed("cpedit").flag;
    check(openCJ\permissions::describeMask(expectedModerationMask) == "mod",
          "a fully held group is shown by name");
    check(openCJ\permissions::describeMask(expectedModerationMask + cpeditFlag) == "mod, cpedit",
          "permissions outside the group are listed after it");
    check(openCJ\permissions::describeMask(8 + 128) == "mute, kick",
          "a partly held group lists its members");
}

verifyMasks()
{
    muteFlag = openCJ\permissions::permissionNamed("mute").flag;
    kickFlag = openCJ\permissions::permissionNamed("kick").flag;
    uberFlag = openCJ\permissions::permissionNamed("uber").flag;
    check(!openCJ\permissions::maskHasPermission(0, "mute"), "an empty mask grants nothing");
    check(!openCJ\permissions::maskHasPermission(undefined, "mute"),
          "a player without loaded permissions has none");
    check(openCJ\permissions::maskHasPermission(muteFlag, "mute"), "a held bit is granted");
    check(!openCJ\permissions::maskHasPermission(muteFlag, "kick"), "other bits stay denied");
    check(!openCJ\permissions::maskHasPermission(muteFlag, "notapermission"),
          "unknown permission names are never granted");
    check(openCJ\permissions::maskHasPermission(uberFlag, "tempban"), "uber implies every bit");
    check(openCJ\permissions::describeMask(0) == "none", "empty mask described as none");
    check(openCJ\permissions::describeMask(muteFlag + kickFlag) == "mute, kick",
          "held permissions listed in catalogue order");
    check(openCJ\permissions::describeMask(uberFlag) == "uber (all permissions)",
          "uber described as all permissions");
}

verifyDurations()
{
    check(openCJ\moderation::parseDurationSeconds("30m") == 30 * 60, "minutes parsed");
    check(openCJ\moderation::parseDurationSeconds("12h") == 12 * 60 * 60, "hours parsed");
    check(openCJ\moderation::parseDurationSeconds("7D") == 7 * 24 * 60 * 60,
          "days parsed, unit case ignored");
    invalidDurations = [];
    invalidDurations[0] = "0m";
    invalidDurations[1] = "m";
    invalidDurations[2] = "10x";
    invalidDurations[3] = "-5m";
    invalidDurations[4] = "1.5h";
    invalidDurations[5] = "99999d";
    invalidDurations[6] = "";
    for (i = 0; i < invalidDurations.size; i++)
    {
        check(!isDefined(openCJ\moderation::parseDurationSeconds(invalidDurations[i])),
              "malformed duration rejected: '" + invalidDurations[i] + "'");
    }
    check(openCJ\moderation::formatDuration(24 * 60 * 60 + 60 * 60 + 60) == "1d 1h 1m",
          "durations format as days, hours and minutes");
    check(openCJ\moderation::formatDuration(59) == "1m", "under a minute shows as one minute");
}

verifyRegistrations()
{
    check(level.commands["sqlstats"].requiredPermission == "uber", "!sqlstats is uber-only");
    check(level.commands["setorigin"].requiredPermission == "mapdebug",
          "!setorigin needs mapdebug");
    check(!isDefined(level.commands["ban"]), "the old placeholder !ban is gone");
}

verifyReasons()
{
    commandArguments = [];
    commandArguments[0] = "target";
    commandArguments[1] = "   ";
    check(!isDefined(self openCJ\moderation::readReason(commandArguments, 1)),
          "a blank reason is refused");
    commandArguments[1] = "^1";
    check(!isDefined(self openCJ\moderation::readReason(commandArguments, 1)),
          "a reason made only of colour codes is refused");
    commandArguments = [];
    commandArguments[0] = "target";
    check(!isDefined(self openCJ\moderation::readReason(commandArguments, 1)),
          "a missing reason is refused");
    commandArguments[1] = "bad";
    commandArguments[2] = "words";
    check(self openCJ\moderation::readReason(commandArguments, 1) == "bad words",
          "reason words are joined");
    longReason = "";
    for (i = 0; i < 16; i++)
    {
        longReason += "0123456789";
    }
    commandArguments[1] = longReason;
    check(!isDefined(self openCJ\moderation::readReason(commandArguments, 1)),
          "a reason over 150 characters is refused");
}

verifyTargets(otherPlayer)
{
    offlineTarget = self openCJ\moderation::resolveTarget("12345");
    check(isDefined(offlineTarget) && offlineTarget.playerID == 12345 &&
              !isDefined(offlineTarget.player),
          "a playerID resolves without the player being online");
    onlineTarget = self openCJ\moderation::resolveTarget("2");
    check(isDefined(onlineTarget) && isDefined(onlineTarget.player) &&
              onlineTarget.player == otherPlayer,
          "a playerID finds the online player");
    exactMatches = openCJ\moderation::matchOnlinePlayers(otherPlayer.name);
    check(exactMatches.size == 1 && exactMatches[0] == otherPlayer,
          "an exact name match wins over partial matches");

    selfTarget = self openCJ\moderation::resolveTarget("1");
    check(!self openCJ\moderation::canModerate(selfTarget), "nobody moderates themselves");
    otherPlayer.permissions = openCJ\permissions::permissionNamed("uber").flag;
    check(!self openCJ\moderation::canModerate(onlineTarget),
          "a non-uber moderator cannot act on an uber-admin");
    self.permissions = openCJ\permissions::permissionNamed("uber").flag;
    check(self openCJ\moderation::canModerate(onlineTarget),
          "an uber-admin may act on another uber-admin");
    self.permissions = 0;
    otherPlayer.permissions = 0;
    check(self openCJ\moderation::canModerate(onlineTarget),
          "ordinary players can be moderated");
}

// Only spawned clients appear in the player array that target lookups search.
prepareClient(playerID, spawnOrigin)
{
    self.sessionTeam = "allies";
    self.sessionState = "playing";
    self spawn(spawnOrigin, (0, 0, 0));
    self freezeControls(true);
    self.login_playerID = playerID;
    self.permissions = 0;
}

check(condition, message)
{
    level.permissionChecks++;
    if (!condition)
    {
        level.permissionFailures++;
    }
    printf("PERMISSIONS CHECK " + int(condition) + ": " + message + "\n");
}
