#include openCJ\util;

onInit()
{
    level.commands = [];
    helpCommand = registerCommand(
        "help", "Browse commands, or show help for a command or alias. Usage: !help [command]",
        ::_showHelp, 0, 1, 0);
    addAlias(helpCommand, "commands");
}

registerCommand(commandName, description, callback, minArgs, maxArgs, minAdminLevel, settingName)
{
    commandName = toLower(commandName);
    command = spawnStruct();
    command.name = commandName;
    command.help = description;
    command.func = callback;
    command.minArgs = minArgs;
    command.maxArgs = maxArgs;
    command.minAdminLevel = minAdminLevel;
    command.settingName = settingName;
    level.commands[commandName] = command;

    return level.commands[commandName];
}

addAlias(command, aliasName)
{
    // Keep alias metadata separate so registering an alias cannot modify its primary command.
    aliasCommand = spawnStruct();
    aliasCommand.cmd = command;
    level.commands[toLower(aliasName)] = aliasCommand;
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
    {
        self openCJ\menus\commands::refresh(false);
    }
}

// Return true for recognized commands, including permission/argument failures, to suppress chat.
onPlayerCommand(chatArguments)
{
    if(!self isPlayerReady())
    {
        return;
    }
    // The chat verb precedes the command token, for example: say !help.
    if(chatArguments.size < 2)
    {
        return false;
    }

    chatVerb = chatArguments[0];
    commandToken = chatArguments[1];
    if((chatVerb != "say" && chatVerb != "say_team") || commandToken.size == 0)
    {
        return false;
    }

    commandPrefix = commandToken[0];
    if(commandPrefix != "!" && commandPrefix != "." && commandPrefix != "/" && commandPrefix != "$")
    {
        return false;
    }
    chatArguments[1] = getsubstr(tolower(commandToken), 1);

    commandText = arrayConcat(subArray(chatArguments, 1));

    // Is it even a command we support?
    command = level.commands[chatArguments[1]];
    if(!isDefined(command))
    {
        return false;
    }
    if(isDefined(command.cmd))
    {
        command = command.cmd; // Redirect alias commands to their real command counterpart
    }

    if(isDefined(command.redactArgs) && command.redactArgs)
    {
        printf("Player " + self openCJ\login::getPlayerID() + " used !" + command.name +
               " (arguments withheld)\n");
    }
    else
    {
        printf(self.name + " is executing command: " + commandText + "\n");
    }

    // Does the player have sufficient permissions?
    if(self.adminLevel < command.minAdminLevel)
    {
        self sendLocalChatMessage("You do not have sufficient permissions to execute this command",
                                  true);
        return true;
    }

    // Get rid of say/say_team and the command itself
    commandArguments = subArray(chatArguments, 2);

    // Check the number of arguments is correct for this command
    if(isDefined(command.minArgs) && (commandArguments.size < command.minArgs))
    {
        self sendLocalChatMessage(command.help);
        return true;
    }
    if(isDefined(command.maxArgs) && (commandArguments.size > command.maxArgs))
    {
        return true;
    }

    // Command might be a setting, if so, let the settings handler deal with it
    if(isDefined(command.settingName))
    {
        self openCJ\settings::onSetting(command.settingName, commandArguments); // Name of setting and the arguments
    }
    if(isDefined(command.func))
    {
        // Execute the command with any arguments that may have been passed
        self [[command.func]] (commandArguments);
    }

    return true;
}

// Read the live registry, including aliases registered after initialization.
availableCommands(adminLevel, search)
{
    if (!isDefined(adminLevel))
    {
        adminLevel = 0;
    }
    if (!isDefined(search))
    {
        search = "";
    }
    search = toLower(search);
    commandNames = sortedNames(getArrayKeys(level.commands));
    exactEntries = [];
    partialEntries = [];
    for (i = 0; i < commandNames.size; i++)
    {
        command = level.commands[commandNames[i]];
        if (isDefined(command.cmd) || adminLevel < command.minAdminLevel)
        {
            continue;
        }
        entry = describeCommand(commandNames[i], command, commandNames);
        exactMatch = search == entry.name || isInArray(search, entry.aliases);
        searchableNames = toLower(entry.name + " " + entry.aliasText);
        if (exactMatch)
        {
            exactEntries[exactEntries.size] = entry;
        }
        else if (search == "" || isSubStr(searchableNames, search))
        {
            partialEntries[partialEntries.size] = entry;
        }
    }
    // Exact command/alias matches come first; each group keeps alphabetical order.
    for (i = 0; i < partialEntries.size; i++)
    {
        exactEntries[exactEntries.size] = partialEntries[i];
    }
    return exactEntries;
}

// Describe one primary command and its aliases without exposing a second menu entry per alias.
describeCommand(commandName, command, registeredNames)
{
    entry = spawnStruct();
    entry.name = commandName;
    entry.help = command.help;
    if (!isDefined(entry.help) || entry.help == "")
    {
        entry.help = "No description provided.";
    }
    entry.aliases = [];
    entry.aliasText = "";
    for (i = 0; i < registeredNames.size; i++)
    {
        aliasCommand = level.commands[registeredNames[i]];
        if (!isDefined(aliasCommand.cmd) || aliasCommand.cmd != command)
        {
            continue;
        }
        entry.aliases[entry.aliases.size] = registeredNames[i];
        if (entry.aliasText != "")
        {
            entry.aliasText += ", ";
        }
        entry.aliasText += "!" + registeredNames[i];
    }
    return entry;
}

helpText(commandName, adminLevel)
{
    commandName = toLower(commandName);
    command = level.commands[commandName];
    if (!isDefined(command))
    {
        return "Command not found.";
    }
    heading = "!" + commandName;
    if (isDefined(command.cmd))
    {
        command = command.cmd;
        heading += " (alias for !" + command.name + ")";
    }
    if (!isDefined(adminLevel) || adminLevel < command.minAdminLevel)
    {
        return "You do not have sufficient permissions to use this command.";
    }
    description = command.help;
    if (!isDefined(description) || description == "")
    {
        description = "No description provided.";
    }
    return heading + ": " + description;
}

sortedNames(commandNames)
{
    // GSC does not compare strings with <; use the runtime's character codes.
    for (i = 1; i < commandNames.size; i++)
    {
        commandName = commandNames[i];
        j = i;
        while (j > 0 && nameBefore(commandName, commandNames[j - 1]))
        {
            commandNames[j] = commandNames[j - 1];
            j--;
        }
        commandNames[j] = commandName;
    }
    return commandNames;
}

nameBefore(firstName, secondName)
{
    firstName = toLower(firstName);
    secondName = toLower(secondName);
    for (i = 0; i < min(firstName.size, secondName.size); i++)
    {
        if (firstName[i] != secondName[i])
        {
            return getAscii(firstName[i]) < getAscii(secondName[i]);
        }
    }
    return firstName.size < secondName.size;
}

_showHelp(commandArguments)
{
    if (isDefined(commandArguments) && commandArguments.size > 0)
    {
        self sendLocalChatMessage(helpText(commandArguments[0], self.adminLevel));
    }
    else
    {
        self openMenu("opencj_commands");
    }
}
