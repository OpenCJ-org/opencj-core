#include openCJ\util;

onInit()
{
    level.commands = [];
    cmd = registerCommand("help", "Browse commands, or show help for a command or alias. Usage: !help [command]", ::_showHelp, 0, 1, 0);
    addAlias(cmd, "commands");
}

registerCommand(name, help, func, minArgs, maxArgs, minAdminLevel, settingName)
{
    name = toLower(name);
    cmd = spawnStruct();
    cmd.name = name;
    cmd.help = help;
    cmd.func = func;
    cmd.minArgs = minArgs;
    cmd.maxArgs = maxArgs;
    cmd.minAdminLevel = minAdminLevel;
    cmd.settingName = settingName;
    level.commands[name] = cmd;

    return level.commands[name];
}

addAlias(cmd, alias)
{
    // Just register a new command with the same variables. Can't re-use command, because any changes we do in here..
    // ..such as setting a flag that this is an alias, would apply to the original command as well
    aliasCmd = spawnStruct();
    aliasCmd.cmd = cmd;
    level.commands[toLower(alias)] = aliasCmd;
}

// Permission levels: editor 20, moderator 40, admin 60, uber-admin 100.
checkpointEditorLevel()
{
    return 20;
}

maxAdminLevel()
{
    return 100;
}

isUberAdminLevel(value)
{
    return isDefined(value) && value >= maxAdminLevel();
}

setAdminLevel(value)
{
    self.adminLevel = value;
    if (isDefined(self.currentMenu) && self.currentMenu == "opencj_commands")
        self openCJ\menus\commands::refresh(false);
}

onPlayerCommand(fullArgs)
{
    if(!self isPlayerReady())
    {
        return;
    }
    // fullArgs will contain the player command, such as say or say_team as well
    // "say !command" is the minimum
    if(fullArgs.size < 2)
    {
        return false;
    }

    // If first argument is say or say_team, it means there is possibly a command afterwards
    if((fullArgs[0] != "say") && (fullArgs[0] != "say_team"))
    {
        return false;
    }

    if((fullArgs[1][0] != "!") && (fullArgs[1][0] != ".") && (fullArgs[1][0] != "/") && (fullArgs[1][0] != "$"))
    {
        return false;
    }
    fullArgs[1] = getsubstr(tolower(fullArgs[1]), 1);

    fullMsg = arrayConcat(subArray(fullArgs, 1));


    //self sendLocalChatMessage(fullMsg);

    // Is it even a command we support?
    cmd = level.commands[fullArgs[1]];
    if(!isDefined(cmd))
    {
        return false;
    }
    if(isDefined(cmd.cmd))
    {
        cmd = cmd.cmd; // Redirect alias commands to their real command counterpart
    }

    if(isDefined(cmd.redactArgs) && cmd.redactArgs)printf("Player "+self openCJ\login::getPlayerID()+" used !"+cmd.name+" (arguments withheld)\n");
    else printf(self.name+" is executing command: "+fullMsg+"\n");

    // Does the player have sufficient permissions?
    if(self.adminLevel < cmd.minAdminLevel)
    {
        self sendLocalChatMessage("You do not have sufficient permissions to execute this command", true);
        return true; // It was a command, but permissions were incorrect. Don't interpret this as a chat message anymore.
    }

    // Get rid of say/say_team and the command itself
    args = subArray(fullArgs, 2);

    // Check the number of arguments is correct for this command
    if (isDefined(cmd.minArgs) && (args.size < cmd.minArgs))
    {
        self sendLocalChatMessage(cmd.help);
        return true; // It was a command, but arguments were incorrect. Don't interpret this as a chat message anymore.
    }
    if (isDefined(cmd.maxArgs) && (args.size > cmd.maxArgs))
    {
        return true; // It was a command, but arguments were incorrect. Don't interpret this as a chat message anymore.
    }

    // Command might be a setting, if so, let the settings handler deal with it
    if(isDefined(cmd.settingName))
    {
        self openCJ\settings::onSetting(cmd.settingName, args); // Name of setting and the arguments
    }
    if(isDefined(cmd.func))
    {
        // Execute the command with any arguments that may have been passed
        self [[cmd.func]](args);
    }

    return true;
}

// Read the live registry, including aliases registered after initialization.
availableCommands(adminLevel, search)
{
    if (!isDefined(adminLevel)) adminLevel = 0;
    if (!isDefined(search)) search = "";
    search = toLower(search);
    names = sortedNames(getArrayKeys(level.commands));
    entries = [];
    partialEntries = [];
    for (i = 0; i < names.size; i++)
    {
        cmd = level.commands[names[i]];
        if (isDefined(cmd.cmd) || adminLevel < cmd.minAdminLevel) continue;
        entry = spawnStruct();
        entry.name = names[i];
        entry.help = cmd.help;
        if (!isDefined(entry.help) || entry.help == "") entry.help = "No description provided.";
        entry.aliases = [];
        entry.aliasText = "";
        exactMatch = search == entry.name;
        for (a = 0; a < names.size; a++)
        {
            alias = level.commands[names[a]];
            if (!isDefined(alias.cmd) || alias.cmd != cmd) continue;
            if (search == names[a]) exactMatch = true;
            entry.aliases[entry.aliases.size] = names[a];
            if (entry.aliasText != "") entry.aliasText += ", ";
            entry.aliasText += "!" + names[a];
        }
        haystack = toLower(entry.name + " " + entry.aliasText);
        if (exactMatch)
            entries[entries.size] = entry;
        else if (search == "" || isSubStr(haystack, search))
            partialEntries[partialEntries.size] = entry;
    }
    // Stable groups: exact command/alias first, then alphabetical partial matches.
    for (i = 0; i < partialEntries.size; i++)
        entries[entries.size] = partialEntries[i];
    return entries;
}

helpText(name, adminLevel)
{
    name = toLower(name);
    cmd = level.commands[name];
    if (!isDefined(cmd)) return "Command not found.";
    heading = "!" + name;
    if (isDefined(cmd.cmd))
    {
        cmd = cmd.cmd;
        heading += " (alias for !" + cmd.name + ")";
    }
    if (!isDefined(adminLevel) || adminLevel < cmd.minAdminLevel)
        return "You do not have sufficient permissions to use this command.";
    help = cmd.help;
    if (!isDefined(help) || help == "") help = "No description provided.";
    return heading + ": " + help;
}

sortedNames(names)
{
    // GSC does not compare strings with <; use the runtime's character codes.
    for (i = 1; i < names.size; i++)
    {
        value = names[i];
        j = i;
        while (j > 0 && nameBefore(value, names[j - 1]))
        {
            names[j] = names[j - 1];
            j--;
        }
        names[j] = value;
    }
    return names;
}

nameBefore(a, b)
{
    a = toLower(a);
    b = toLower(b);
    for (i = 0; i < min(a.size, b.size); i++)
    {
        if (a[i] != b[i]) return getAscii(a[i]) < getAscii(b[i]);
    }
    return a.size < b.size;
}

_showHelp(args)
{
    if (isDefined(args) && args.size > 0)
        self sendLocalChatMessage(helpText(args[0], self.adminLevel));
    else
        self openMenu("opencj_commands");
}
