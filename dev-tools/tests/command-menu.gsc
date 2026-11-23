// Exercise the real registry, permission checks and menu handlers.
main()
{
    level.commandChecks = 0;
    level.commandFailures = 0;
    // Menu notifications cancel reads; initialize their constants without opening SQL.
    openCJ\mySQL::_initConstants();
    openCJ\commands_base::onInit();
    openCJ\commands::onInit();
    openCJ\scoreboard::onInit();
    openCJ\menus\commands::onInit();
    wait 1;
    checkProductionCommands();
    checkSearchRanking();
    checkRegistryDescriptions();
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "isolated menu test client connected");
    if (!isDefined(player))
    {
        finish();
        return;
    }
    player.adminLevel = 0;
    player openCJ\menus\helper::onPlayerConnected();
    player openCJ\menus\commands::onPlayerConnected();
    checkCommandPages(player);
    checkPermissionChanges(player);
    checkHelpPages(player);
    checkExactAliasSelection(player);
    checkTeleportInputs(player);
    checkChatNotifications(player);
    finish();
}

checkProductionCommands()
{
    check(!isDefined(level.commands["scoreboard"]),
          "obsolete scoreboard setup command not registered");
    check(openCJ\commands_base::availableCommands(0, "ban").size == 0,
          "restricted production command hidden");
    check(openCJ\commands_base::availableCommands(70, "ban").size > 0,
          "production command visible at exact permission level");
    check(openCJ\commands_base::helpText("RP", 0) ==
              "!rp (alias for !restoreposition): Restore your last used run",
          "production alias help resolves case and canonical name");
}

checkSearchRanking()
{
    // Reported regression: an exact alias must beat an earlier substring.
    openCJ\commands_base::registerCommand("doublerpgsstring", "Partial match fixture.", undefined,
                                          0, 0, 0);
    openCJ\commands_base::registerCommand("arptest", "Partial match fixture.", undefined, 0, 0, 0);
    openCJ\commands_base::registerCommand("zzrpcheck", "Partial match fixture.", undefined, 0, 0,
                                          0);
    openCJ\commands_base::registerCommand("rpg", "Exact-name fixture.", undefined, 0, 0, 0);
    matches = openCJ\commands_base::availableCommands(0, "RP");
    check(matches[0].name == "restoreposition",
          "exact rp alias ranks restoreposition before partial matches, case-insensitively");
    alphabetical = true;
    for (i = 2; i < matches.size; i++)
    {
        if (openCJ\commands_base::nameBefore(matches[i].name, matches[i - 1].name))
        {
            alphabetical = false;
        }
    }
    check(alphabetical && matches.size >= 5,
          "partial matches remain present and alphabetically ordered");
    matches = openCJ\commands_base::availableCommands(0, "rpg");
    check(matches[0].name == "rpg", "exact command name ranks before an earlier partial match");
    openCJ\commands_base::registerCommand("banner", "Permitted partial fixture.", undefined, 0, 0,
                                          0);
    matches = openCJ\commands_base::availableCommands(0, "ban");
    check(matches.size == 1 && matches[0].name == "banner",
          "restricted exact match does not bypass permission filtering");
    matches = openCJ\commands_base::availableCommands(70, "ban");
    check(matches[0].name == "ban" && matches[1].name == "banner",
          "permitted exact match precedes partial match");
}

checkRegistryDescriptions()
{
    // Deterministic registry covers ordering independently of registration order.
    level.commands = [];
    openCJ\commands_base::registerCommand(
        "zulu", "Last command. Mentions rp in its description.", undefined, 0, 0, 0);
    alphaCommand = openCJ\commands_base::registerCommand("alpha", "First command. Usage: !alpha", undefined, 0,
                                              0, 0);
    openCJ\commands_base::addAlias(alphaCommand, "ZAlias");
    openCJ\commands_base::addAlias(alphaCommand, "aAlias");
    openCJ\commands_base::registerCommand("alphabet", "Prefix ordering.", undefined, 0, 0, 0);
    adminCommand = openCJ\commands_base::registerCommand("admin", "Restricted description.", undefined, 0,
                                                  0, 60);
    openCJ\commands_base::addAlias(adminCommand, "secret");
    entries = openCJ\commands_base::availableCommands(0, "");
    check(entries.size == 3, "one entry per primary command; aliases and restricted commands omitted");
    check(entries[0].name == "alpha" && entries[1].name == "alphabet" && entries[2].name == "zulu",
          "alphabetical order including prefixes");
    check(entries[0].aliasText == "!aalias, !zalias", "aliases sorted and shown once");
    check(openCJ\commands_base::availableCommands(0, "ZALIAS").size == 1,
          "case-insensitive alias search");
    check(openCJ\commands_base::availableCommands(0, "rp").size == 0,
          "rp does not match unrelated help text");
    check(openCJ\commands_base::availableCommands(0, "alp").size == 2,
          "command-name substring search remains available");
    check(openCJ\commands_base::availableCommands(0, "prefix").size == 0,
          "description-only matches excluded");
    check(openCJ\commands_base::availableCommands(59, "secret").size == 0,
          "alias search respects required rank");
    check(openCJ\commands_base::availableCommands(60, "secret").size == 1,
          "alias search at exact required rank");
    check(openCJ\commands_base::availableCommands(100, "").size == 4,
          "uber-admin sees all commands");
    check(isSubStr(openCJ\commands_base::helpText("ZALIAS", 0), "!zalias (alias for !alpha):"),
          "quick alias help retains requested alias");
    check(!isSubStr(openCJ\commands_base::helpText("secret", 0), "Restricted description"),
          "quick alias help does not reveal restricted details");
    check(openCJ\commands_base::helpText("missing", 0) == "Command not found.",
          "unknown quick-help command");
    lateCommand = openCJ\commands_base::registerCommand("late", "Added after first listing.", undefined, 0,
                                                 0, 0);
    openCJ\commands_base::addAlias(lateCommand, "newalias");
    check(openCJ\commands_base::availableCommands(0, "").size == 4,
          "new registration appears without a menu catalogue change");
    check(openCJ\commands_base::availableCommands(0, "newalias").size == 1,
          "late alias immediately searchable");
    openCJ\settings::onInit();
    openCJ\settings::addSettingBool("fixture", false, "Fixture setting.", ::noop);
    check(openCJ\commands_base::availableCommands(0, "fixture").size == 1,
          "command-backed settings automatically listed");
}

checkCommandPages(player)
{
    player openCJ\menus\commands::handleResponse("open_commands");
    check(player.commandMenu.total == 5 && player.commandMenu.selectedName == "alpha",
          "opening builds live registry and selects first command");
    for (i = 0; i < 25; i++)
    {
        openCJ\commands_base::registerCommand("fixture" + i, "Page fixture.", undefined, 0, 0, 0);
    }
    player openCJ\menus\commands::refresh(false);
    check(player.commandMenu.total == 30 && player.commandMenu.maxPage == 3 &&
              player.commandMenu.displayed.size == 12,
          "late registrations grow paginated menu");
    player openCJ\menus\commands::handleResponse("next");
    check(player.commandMenu.page == 2 && player.commandMenu.displayed.size == 12, "next page");
    player openCJ\menus\commands::handleResponse("next");
    check(player.commandMenu.page == 3 && player.commandMenu.displayed.size == 6,
          "last partial page");
    check(player.commandMenu.values["row6"] == "", "unused rows cleared");
    player openCJ\menus\commands::handleResponse("next");
    check(player.commandMenu.page == 3, "next page clamped");
    player openCJ\menus\commands::handleResponse("prev");
    check(player.commandMenu.page == 2, "previous page");
    player.searchText = "newalias";
    player openCJ\menus\commands::refresh(true);
    check(player.commandMenu.page == 1 && player.commandMenu.total == 1 &&
              player.commandMenu.selectedName == "late",
          "search resets page and selects matching canonical command");
    player.searchText = "no_match";
    player openCJ\menus\commands::refresh(true);
    check(player.commandMenu.total == 0 && !isDefined(player.commandMenu.selectedName) &&
              player.commandMenu.values["line0"] == "",
          "empty search clears stale command details");
    player openCJ\menus\commands::handleResponse("select_0");
    player openCJ\menus\commands::handleResponse("select_-1");
    player openCJ\menus\commands::handleResponse("select_no");
    check(player.commandMenu.total == 0, "invalid or empty selection ignored");
    player openCJ\menus\commands::handleResponse("clear");
    check(player.searchText == "" && player.commandMenu.total == 30,
          "clear search restores all permitted entries");
    player openCJ\menus\commands::handleResponse("select_1");
    check(player.commandMenu.selectedName == "alphabet", "row selection opens matching details");
}

checkPermissionChanges(player)
{
    player openCJ\commands_base::setAdminLevel(60);
    player.searchText = "secret";
    player openCJ\menus\commands::refresh(true);
    check(player.commandMenu.selectedName == "admin", "admin command selected by alias");
    player openCJ\commands_base::setAdminLevel(0);
    check(player.commandMenu.total == 0 && !isDefined(player.commandMenu.selectedName),
          "rank downgrade immediately removes restricted selection");
    player openCJ\commands_base::setAdminLevel(60);
    player.adminLevel = 0; // A response created before a rank change is also rechecked.
    player openCJ\menus\commands::handleResponse("select_0");
    check(player.commandMenu.total == 0 && !isDefined(player.commandMenu.selectedName),
          "stale selection rechecks current permissions");
}

checkHelpPages(player)
{
    longHelpText = "";
    for (i = 0; i < 100; i++)
    {
        longHelpText += "word" + i + " ";
    }
    openCJ\commands_base::registerCommand("long", longHelpText, undefined, 0, 0, 0);
    player.searchText = "long";
    player openCJ\menus\commands::refresh(true);
    check(player.commandMenu.maxDetailPage > 1, "long help gets extra detail pages");
    player openCJ\menus\commands::handleResponse("detail_next");
    check(player.commandMenu.detailPage == 2, "detail next page");
    check(isSubStr(player.commandMenu.lines[player.commandMenu.lines.size - 1], "word99"),
          "end of long help retained");
    player openCJ\menus\commands::handleResponse("detail_prev");
    check(player.commandMenu.detailPage == 1, "detail previous page");
    wrappedLines = openCJ\menus\commands::wrapText("abcd efgh\n\nijklmnopqrstuvwxyz", 5);
    check(wrappedLines.size == 7 && wrappedLines[0] == "abcd" && wrappedLines[1] == "efgh" && wrappedLines[2] == "" &&
              wrappedLines[6] == "xyz",
          "wrapping preserves blank lines and splits long words");
    player openCJ\menus\commands::handleResponse("close_commands");
    player openCJ\menus\commands::handleResponse("next");
    check(player.currentMenu == "" && player.commandMenu.page == 1,
          "closed menu ignores navigation");
}

checkExactAliasSelection(player)
{
    level.commands = [];
    openCJ\commands_base::registerCommand("doublerpgsstring", "Partial match fixture.", undefined,
                                          0, 0, 0);
    restoreCommand = openCJ\commands_base::registerCommand("restoreposition", "Exact-alias fixture.",
                                                    undefined, 0, 0, 0);
    openCJ\commands_base::addAlias(restoreCommand, "rp");
    player openCJ\menus\commands::handleResponse("open_commands");
    player.searchText = "rp";
    player openCJ\menus\commands::refresh(true);
    check(player.commandMenu.displayed[0].name == "restoreposition" &&
              player.commandMenu.selectedName == "restoreposition",
          "rp search selects exact alias result first in menu");
    player openCJ\menus\commands::handleResponse("close_commands");
}

checkChatNotifications(player)
{
    // Exercise chat dispatch and the same menu/search notifications as the client.
    openCJ\commands_base::onInit();
    player.login_playerID = 1;
    player.settingsLoaded = true;
    player.sessionState = "spectator";
    chatArgs = [];
    chatArgs[0] = "say";
    chatArgs[1] = "";
    check(!player openCJ\commands_base::onPlayerCommand(chatArgs),
          "empty chat text is not treated as a command");
    chatArgs[1] = "!commands";
    check(player openCJ\commands_base::onPlayerCommand(chatArgs),
          "!commands resolves through the registered help alias");
    chatArgs[1] = "!help";
    check(player openCJ\commands_base::onPlayerCommand(chatArgs),
          "!help opens through normal chat dispatch");
    chatArgs[1] = "!help";
    chatArgs[2] = "COMMANDS";
    check(player openCJ\commands_base::onPlayerCommand(chatArgs),
          "specific alias help runs through normal chat dispatch");
    player notify("menuresponse", "opencj_commands", "open_commands");
    wait 0.05;
    check(player.currentMenu == "opencj_commands" && player.commandMenu.total == 1,
          "client menu-open notification rebuilds registry");
    player openCJ\menus\helper::onInputKey("h");
    player openCJ\menus\helper::onInputKey("e");
    wait 0.05;
    check(player.commandMenu.values["search"] == "he" && player.commandMenu.total == 1,
          "keyboard input notifies live search");
    player openCJ\menus\helper::onInputKey("backspace");
    wait 0.05;
    check(player.commandMenu.values["search"] == "h", "backspace updates live search");
    player notify("menuresponse", "opencj_commands", "close_commands");
    wait 0.05;
    check(player.currentMenu == "", "client close notification ends command-menu handling");
}


noop()
{
}

check(ok, label)
{
    level.commandChecks++;
    if (!ok)
    {
        level.commandFailures++;
    }
    printf("COMMAND TEST " + ok + ": " + label + "\n");
}

finish()
{
    printf("COMMAND TEST COMPLETE failures=" + level.commandFailures +
           " checks=" + level.commandChecks + "\n");
}

// Invalid debug input must preserve position and competitive state; valid movement marks assistance.
checkTeleportInputs(player)
{
    previousOrigin = player getOrigin();
    previousSessionState = player.sessionState;
    player.sessionState = "playing";
    player.cheating = false;
    player.playerRuns_runID = undefined;

    coordinates = [];
    coordinates[0] = "12junk";
    coordinates[1] = "20";
    coordinates[2] = "30";
    player openCJ\commands::_onCmdSetOrigin(coordinates);
    check(player getOrigin() == previousOrigin && !player.cheating,
          "invalid coordinate preserves position and competitive state");
    coordinates[0] = "2147483648";
    player openCJ\commands::_onCmdSetOrigin(coordinates);
    check(player getOrigin() == previousOrigin && !player.cheating,
          "overflowing coordinate cannot move the player");
    // CoD4 PlayerCmd_setOrigin raises the supplied Z by one unit.
    teleportLift = (0, 0, 1);
    expectedPosition = (-10, 20, 30) + teleportLift;
    coordinates[0] = "-10";
    player openCJ\commands::_onCmdSetOrigin(coordinates);
    check(player getOrigin() == expectedPosition && player.cheating,
          "valid signed coordinates move the player and mark assistance");

    target = spawn("script_origin", (30, 40, 50));
    target.targetname = "command_test_target";
    entityArgs = [];
    entityArgs[0] = target.targetname;
    invalidIndices = [];
    invalidIndices[0] = "-1";
    invalidIndices[1] = "1";
    invalidIndices[2] = "junk";
    invalidIndices[3] = "4294967296";
    for (i = 0; i < invalidIndices.size; i++)
    {
        player.cheating = false;
        entityArgs[1] = invalidIndices[i];
        player openCJ\commands::_onCmdEntTele(entityArgs);
        check(player getOrigin() == expectedPosition && !player.cheating,
              "invalid entity index preserves position and state: " + invalidIndices[i]);
    }
    entityArgs[1] = "0";
    player openCJ\commands::_onCmdEntTele(entityArgs);
    check(player getOrigin() == target.origin + teleportLift && player.cheating,
          "valid entity index moves the player and marks assistance");
    target delete();
    player setOrigin(previousOrigin - teleportLift);
    player.sessionState = previousSessionState;
    player.cheating = false;
}
