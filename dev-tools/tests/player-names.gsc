#include openCJ\util;
// Run policy, persistence, rendering and reconnect scenarios in order.
main()
{
    level.nameTestChecks = 0;
    level.nameTestFailures = 0;
    openCJ\mySQL::onInit();
    openCJ\commands_base::onInit();
    openCJ\playerNames::onInit();
    openCJ\showRecords::onInit();
    openCJ\statistics::onInit();
    check(level.nameRulesReady, "private policy snapshot loads");
    wait 1;
    player = addTestClient();
    otherPlayer = addTestClient();
    wait .2;
    player.login_playerID = 1;
    otherPlayer.login_playerID = 2;
    player.permissions = 0;
    otherPlayer.permissions = 0;
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    otherPlayer.sessionTeam = "allies";
    otherPlayer.sessionState = "playing";
    otherPlayer.pers["team"] = "allies";
    player spawn((0, 0, 5000), (0, 0, 0));
    otherPlayer spawn((30, 0, 5000), (0, 0, 0));
    player.nameAccountKey = "p:1";
    otherPlayer.nameAccountKey = "p:2";
    verifyRegularNames(player);
    verifyPreferredNameCommands(player, otherPlayer);
    verifyRecordNamePanels(player, otherPlayer);
    verifyRecordQueryLifetime(player);
    player = verifyReconnectCooldowns(player, otherPlayer);
    wait .2;
    verifyInvalidModeratorTargets(player);
    printf("NAME SELFTEST COMPLETE failures=" + level.nameTestFailures +
           " checks=" + level.nameTestChecks + "\n");
}
// Regular names stay public while private policy and cooldowns reject changes.
verifyRegularNames(player)
{
    player.nameAccepted = undefined;
    player.nameLastChange = undefined;
    player openCJ\playerNames::_rename("FirstName");
    check(player.nameAccepted == "FirstName" && !isDefined(player.nameLastChange),
          "initial connection name does not start cooldown");
    originalName = player.name;
    cleanedCandidate = cleanPlayerName("Candidate");
    check(player.name == originalName && cleanedCandidate == "Candidate",
          "native cleanup does not publish a candidate");
    check(cleanPlayerName("  Spaced") == "Spaced",
          "native cleanup trims leading spaces without mutating input");
    player openCJ\playerNames::_rename("FirstChange");
    check(player.nameAccepted == "FirstChange" && isDefined(player.nameLastChange),
          "first regular rename is immediately allowed");
    acceptedChangeSeconds = player.nameLastChange;
    player openCJ\playerNames::_rename("TooQuick");
    check(player.nameAccepted == "FirstChange" && player.name == "FirstChange" &&
              player.nameLastChange == acceptedChangeSeconds,
          "regular cooldown preserves published name and timestamp");
    player.nameLastChange = getRealTime() - 60;
    player openCJ\playerNames::_rename("AfterMinute");
    check(player.nameAccepted == "AfterMinute", "regular rename allowed at sixty-second boundary");
    check(openCJ\namePolicy::normalize("^1F1x.tuure Token") == "fixturetoken",
          "normalization strips colors, substitutes digits and collapses repeats");
    check(openCJ\namePolicy::blockedRule("xF1x.tuureTokenx") > 0,
          "private hash rules catch obfuscated contained terms");
    check(openCJ\namePolicy::blockedRule("OkFixtureToken") == 0,
          "rule-specific exception avoids false positive");
    check(openCJ\namePolicy::blockedRule("OrdinaryName") == 0, "ordinary name passes");
    player.nameLastChange = getRealTime() - 60;
    player openCJ\playerNames::_rename("FixtureToken");
    check(getSubStr(player.nameAccepted, 0, 6) == "Clown#" && player.nameAccepted.size == 10 &&
              openCJ\util::digits(getSubStr(player.nameAccepted, 6)),
          "blocked regular name becomes Clown plus four digits");
    check(player.name == player.nameAccepted, "replacement is the publicly visible engine name");
    replacementName = player.nameAccepted;
    player.nameLastChange = getRealTime() - 60;
    player openCJ\playerNames::_rename("FixtureToken");
    check(player.nameAccepted == replacementName,
          "repeated rejected request does not churn random replacements");
    player openCJ\playerNames::setForcedName("ForcedFixture");
    player openCJ\playerNames::onUserInfoChanged();
    check(player.name == "ForcedFixture", "moderator forced name survives userinfo updates");
    player openCJ\playerNames::setForcedName();
    check(!isDefined(player.forcedName), "moderator can release forced name");
    check(!isDefined(openCJ\namePolicy::preferredName("^1Colored")) &&
              !isDefined(openCJ\namePolicy::preferredName("ab")) &&
              !isDefined(openCJ\namePolicy::preferredName("1234567890123456")),
          "preferred name rejects colors and invalid lengths");
    check(openCJ\namePolicy::preferredName("  First   Last  ") == "First Last",
          "preferred name trims and normalizes whitespace");
}

// Exercise preferred-name commands through their real SQL procedures.
verifyPreferredNameCommands(player, otherPlayer)
{
    preferredNameCommand = level.commands["prefname"];
    check(isDefined(preferredNameCommand) && isDefined(preferredNameCommand.redactArgs) &&
              preferredNameCommand.redactArgs &&
              openCJ\commands_base::availableCommands(0, "prefname").size == 1,
          "preferred-name command is discoverable and redacts arguments");
    check(level.commands["frename"].requiredPermission == "names" &&
              level.commands["resetprefname"].requiredPermission == "names",
          "moderator commands require the names permission");
    commandArgs = [];
    commandArgs[0] = "RecordName";
    player openCJ\playerNames::_onPreferredName(commandArgs);
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(hasResult(rows) && rows[0][0] == "RecordName", "preferred command persists name");
    commandArgs[0] = "recordname";
    otherPlayer openCJ\playerNames::_onPreferredName(commandArgs);
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT COUNT(*) FROM playerNamePreferences WHERE playerID=2 AND preferredName IS NOT NULL");
    check(hasResult(rows) && int(rows[0][0]) == 0,
          "case-insensitive uniqueness enforced through command path");
    commandArgs[0] = "AnotherName";
    player openCJ\playerNames::_onPreferredName(commandArgs);
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(rows[0][0] == "RecordName", "preferred cooldown blocks a second change");
    commandArgs[0] = "reset";
    player openCJ\playerNames::_onPreferredName(commandArgs);
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(rows[0][0] == "RecordName", "reset cannot bypass preferred cooldown");
    rows =
        openCJ\mySQL::mysqlAsyncRead("SELECT playerName FROM playerDisplayNames WHERE playerID=1");
    check(rows[0][0] == "RecordName", "records resolve the persistent account name");
    check(player.name == "ForcedFixture", "preferred name does not rename the live player");
    commandArgs[0] = "FixtureToken";
    otherPlayer openCJ\playerNames::_onPreferredName(commandArgs);
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT COUNT(*) FROM playerNamePreferences WHERE playerID=2 AND preferredName IS NOT NULL");
    check(hasResult(rows) && int(rows[0][0]) == 0,
          "blocked preferred name never becomes persistent");
    commandArgs = [];
    player openCJ\playerNames::_onPreferredName(commandArgs);
    check(!player.preferredNameBusy, "query completes without leaving the command busy");
}

// Cached panels distinguish stored account names from the live player.
verifyRecordNamePanels(player, otherPlayer)
{
    // Exercise the real checkpoint renderer for the highlighted current run,
    // cached other-player rows, spectator rendering and immediate name refresh.
    player openCJ\showRecords::onPlayerConnect();
    otherPlayer openCJ\showRecords::onPlayerConnect();
    player openCJ\statistics::onPlayerConnect();
    otherPlayer openCJ\statistics::onPlayerConnect();
    player.settingValues = [];
    player.settingValues["lbsort"] = "time:asc";
    otherPlayer.settingValues = [];
    otherPlayer.settingValues["lbsort"] = "time:asc";
    player.startTime = getTime() - 2000;
    otherPlayer.startTime = getTime() - 3000;
    rows = [];
    rows[0] = [];
    rows[0][0] = 1;
    rows[0][1] = "OldOther";
    rows[0][2] = 1000;
    rows[0][3] = 0;
    rows[0][4] = 0;
    rows[0][5] = 2;
    player openCJ\showRecords::_updateRecords(player, rows, 2000, true);
    check(isSubStr(player.showRecords_nameString, "ForcedFixture") &&
              !isSubStr(player.showRecords_nameString, "RecordName"),
          "highlighted checkpoint row retains the live player name");
    otherPlayer openCJ\showRecords::_updateRecords(player, rows, 2000, true);
    check(otherPlayer.showRecords_nameString == player.showRecords_nameString,
          "spectator checkpoint panel keeps the watched player live name");
    ownHistoricalRows = rows;
    ownHistoricalRows[0][5] = 1;
    ownHistoricalRows[0][1] = "OldOwnName";
    player openCJ\showRecords::_updateRecords(player, ownHistoricalRows, 2000, true);
    check(isSubStr(player.showRecords_nameString, "RecordName") &&
              isSubStr(player.showRecords_nameString, "ForcedFixture"),
          "same account historical row uses preferred name while current row keeps live name");
    player openCJ\showRecords::_updateRecords(player, rows, 2000, true);
    openCJ\playerNames::_publishPreferredName(2, "OtherRecord");
    check(isSubStr(player.showRecords_nameString, "OtherRecord") &&
              !isSubStr(player.showRecords_nameString, "OldOther"),
          "already visible checkpoint names refresh without a new checkpoint query");
    check(player.showRecords_nameString == otherPlayer.showRecords_nameString && rows.size == 1,
          "refresh preserves cached row counts and spectator output");
    check(isSubStr(player.showRecords_nameString, "ForcedFixture") &&
              !isSubStr(player.showRecords_nameString, "RecordName"),
          "preferred-name refresh leaves the live current-run row unchanged");
    openCJ\playerNames::_publishPreferredName(2, undefined, "RegularOther");
    check(isSubStr(player.showRecords_nameString, "RegularOther"),
          "reset refreshes cached record-name fallback");
    player openCJ\showRecords::_hideRecords(true);
    openCJ\playerNames::_publishPreferredName(2, "OtherAgain");
    check(player.showRecords_nameString == "", "name refresh does not reopen hidden panels");
    otherPlayer openCJ\showRecords::_hideRecords(true);
}

// Recreate an entity and check that account cooldowns survive the old connection.
verifyReconnectCooldowns(player, otherPlayer)
{
    // Real entity disconnect/recreation, retaining only server identity memory.
    player.nameLastChange = getRealTime() - 60;
    player openCJ\playerNames::_rename("ReconnectKeep");
    acceptedChangeSeconds = player.nameLastChange;
    playerSlot = player getEntityNumber();
    kick(playerSlot);
    wait .3;
    player = addTestClient();
    wait .2;
    player.login_playerID = 1;
    player.permissions = 0;
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 5000), (0, 0, 0));
    player openCJ\playerNames::onAccountIdentified();
    check(player.nameAccepted == "ReconnectKeep" && player.nameLastChange == acceptedChangeSeconds,
          "account login restores regular cooldown after a real disconnect and reconnect");
    player openCJ\playerNames::_rename("ReconnectSkip");
    check(player.name == "ReconnectKeep",
          "reconnected player cannot change regular name during existing cooldown");
    player openCJ\playerNames::_loadPreferredName();
    check(player openCJ\playerNames::getRecordName() == "RecordName",
          "preferred record name reloads after reconnect without changing live name");
    commandArgs = [];
    commandArgs[0] = "BypassPreferred";
    player openCJ\playerNames::_onPreferredName(commandArgs);
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(rows[0][0] == "RecordName", "preferred-name database cooldown survives a real reconnect");
    player.nameLastChange = getRealTime() - 60;
    player openCJ\playerNames::_rename("ReconnectAfter");
    check(player.name == "ReconnectAfter", "regular cooldown expires normally after reconnect");
    check(!isDefined(otherPlayer.nameLastChange),
          "another account does not inherit the reconnect cooldown");
    player.nameLastChange = getRealTime() - 60;
    player openCJ\playerNames::_rememberRegularName();
    // Reinitialization must preserve game memory; it must not reset the timer.
    openCJ\playerNames::onInit();
    check(isDefined(openCJ\playerNames::_cachedRegularName("p:1")),
          "map initialization preserves reconnect memory");
    player openCJ\playerNames::_loadPreferredName();

    return player;
}

check(value, label)
{
    level.nameTestChecks++;
    if(!value)
    {
        level.nameTestFailures++;
    }
    printf("NAME SELFTEST " + int(value) + ": " + label + "\n");
}

// Reject overflowing or nonpositive account IDs before issuing any moderation write.
verifyInvalidModeratorTargets(player)
{
    check(openCJ\util::parsePlayerID("1") == 1, "smallest player ID is accepted");
    check(openCJ\util::parsePlayerID("0000000001") == 1,
          "leading zeros retain the intended player ID");
    check(openCJ\util::parsePlayerID("2147483647") == 2147483647,
          "largest signed database player ID is accepted");
    player.login_playerID = 3;
    player.permissions = openCJ\permissions::permissionNamed("names").flag;
    invalidTargets = [];
    invalidTargets[0] = "0";
    invalidTargets[1] = "2147483648";
    invalidTargets[2] = "4294967297";
    invalidTargets[3] = "9999999999";
    for(i = 0; i < invalidTargets.size; i++)
    {
        stats = mysql_async_stats();
        acceptedBefore = stats[8];
        args = [];
        args[0] = invalidTargets[i];
        player openCJ\playerNames::_onResetPreferredName(args);
        stats = mysql_async_stats();
        check(stats[8] == acceptedBefore,
              "invalid moderator account ID submits no SQL: " + invalidTargets[i]);
    }
    rows = openCJ\mySQL::mysqlAsyncRead(
        "SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(hasResult(rows) && isDefined(rows[0][0]) && rows[0][0] == "RecordName",
          "overflowing moderator input cannot reset another account");
    player.login_playerID = 1;
    player.permissions = 0;
}

// Real SQL runs first; the fixture copy holds its reply until the run identity changes.
verifyRecordQueryLifetime(player)
{
    player.playerRuns_runID = 901;
    player.runInstanceNumber = 1;
    player.playerRuns_runFinished = false;
    player.allowHalfBeat = false;
    verifyObsoleteRecordReply(player, "run");
    verifyObsoleteRecordReply(player, "instance");

    verifySupersededRecordReply(player);
    level.nameTestHoldRecordReplies = false;
    player.nameTestRecordRequestDone = false;
    player thread requestCheckpointRecords();
    waitForRecordRequest(player);
    check(isDefined(player.showRecords_persistTime),
          "current checkpoint reply still starts the normal record flash");

    verifyQueuedRecordCancellation(player);
}

// A completed reply must still belong to the same run and its restored instance.
verifyObsoleteRecordReply(player, identityPart)
{
    player.showRecords_persistTime = undefined;
    player.nameTestRecordReplyReady = false;
    player.nameTestRecordRequestDone = false;
    level.nameTestHoldRecordReplies = true;
    level.nameTestReleaseRecordReply = false;
    player thread requestCheckpointRecords();
    deadlineMs = getTime() + 5000;
    while(!player.nameTestRecordReplyReady && getTime() < deadlineMs)
    {
        wait .05;
    }
    check(player.nameTestRecordReplyReady, "real record SQL reply is ready before changing run");
    if(identityPart == "run")
    {
        player.playerRuns_runID++;
    }
    else
    {
        player.runInstanceNumber++;
    }
    level.nameTestReleaseRecordReply = true;
    waitForRecordRequest(player);
    check(!isDefined(player.showRecords_persistTime),
          "obsolete run or instance reply cannot flash old checkpoint records");
}

verifyQueuedRecordCancellation(player)
{
    // Occupy every native worker so the record request is provably still queued.
    stats = mysql_async_stats();
    cancelledBefore = stats[11];
    workerCount = stats[0];
    for(i = 0; i < workerCount; i++)
    {
        // Progress jobs reserve all workers; read jobs deliberately leave write capacity free.
        blockerID = mysql_async_submit("SELECT SLEEP(1)", level.sqlConstants.policyProgress, "", "",
                                       level.sqlConstants.defaultQueueWaitMs, 1);
        check(isDefined(blockerID) && blockerID > 0, "native worker blocker is admitted");
    }
    deadlineMs = getTime() + 2000;
    stats = mysql_async_stats();
    while(stats[2] != workerCount && getTime() < deadlineMs)
    {
        wait .05;
        stats = mysql_async_stats();
    }
    check(stats[2] == workerCount, "native workers are occupied before queuing record read");
    player.nameTestRecordRequestDone = false;
    player thread requestCheckpointRecords();
    wait .05;
    stats = mysql_async_stats();
    check(stats[1] == 1, "obsolete record read is queued before stopping its run");
    player.playerRuns_runID = undefined;
    player.runInstanceNumber = undefined;
    player openCJ\showRecords::onRunStopped();
    wait .15;
    stats = mysql_async_stats();
    check(stats[1] == 0 && stats[11] == cancelledBefore + 1,
          "stopping the run cancels its queued record read before execution");
    waitForRecordRequest(player);
    deadlineMs = getTime() + 3000;
    stats = mysql_async_stats();
    while(stats[4] != 0 && getTime() < deadlineMs)
    {
        wait .05;
        stats = mysql_async_stats();
    }
    check(stats[4] == 0, "record queue scenario releases all native results");
    check(player.nameTestRecordOutcome == level.sqlConstants.outcomeCancelled,
          "cancelled record request settles with the native cancelled outcome");
    player.showRecords_persistTime = undefined;
    player openCJ\showRecords::_hideRecords(true);
}

requestCheckpointRecords(timePlayedMs)
{
    if(!isDefined(timePlayedMs))
    {
        timePlayedMs = 1234;
    }
    self openCJ\showRecords::_getRecords([], level.showRecordsCheckpointFlash, timePlayedMs);
    self.nameTestRecordRequestDone = true;
}

waitForRecordRequest(player)
{
    deadlineMs = getTime() + 5000;
    while(!player.nameTestRecordRequestDone && getTime() < deadlineMs)
    {
        wait .05;
    }
    check(player.nameTestRecordRequestDone, "record request settles within the fixture deadline");
}

// A new checkpoint may finish reading before an older, already completed callback resumes.
verifySupersededRecordReply(player)
{
    level.nameTestHoldRecordReplies = true;
    level.nameTestReleaseRecordReply = false;
    player.nameTestRecordReplyReady = false;
    player.nameTestRecordRequestDone = false;
    player thread requestCheckpointRecords(1111);
    deadlineMs = getTime() + 5000;
    while(!player.nameTestRecordReplyReady && getTime() < deadlineMs)
    {
        wait .05;
    }
    check(player.nameTestRecordReplyReady, "older checkpoint result is held before replacement");
    level.nameTestHoldRecordReplies = false;
    player thread requestCheckpointRecords(2222);
    waitForRecordRequest(player);
    check(player.showRecords_visibleTime == 2222, "newest checkpoint time is displayed");
    level.nameTestReleaseRecordReply = true;
    wait .15;
    check(player.showRecords_visibleTime == 2222,
          "older completed checkpoint reply cannot overwrite the newer panel");
}
