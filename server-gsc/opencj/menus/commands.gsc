#include openCJ\util;

onInit()
{
    precacheMenu("opencj_commands");
    level.commandMenuRows = 12; // Must match opencj_commands.menu.
    level.commandDetailRows = 11;
    level.commandHelpLineCharacters = 56; // Character budget for the existing detail panel.
}

onPlayerConnected()
{
    self.commandMenu = spawnStruct();
    self.commandMenu.page = 1;
    self.commandMenu.detailPage = 1;
    self.commandMenu.values = [];
    self thread onMenuResponse();
    self thread onSearchText();
}

onMenuResponse()
{
    self endon("disconnect");
    level endon("game_ended");
    for (;;)
    {
        self waittill("menuresponse", menu, response);
        if (menu == "opencj_commands")
        {
            self handleResponse(response);
        }
    }
}

onSearchText()
{
    self endon("disconnect");
    level endon("game_ended");
    for (;;)
    {
        self waittill("search_changed");
        if (self.currentMenu == "opencj_commands")
        {
            self refresh(true);
        }
    }
}

handleResponse(response)
{
    selectionPrefix = "select_";
    if (response == "open_commands")
    {
        self.currentMenu = "opencj_commands";
        self.searchText = "";
        self refresh(true);
        return;
    }
    if (self.currentMenu != "opencj_commands")
    {
        return;
    }
    if (response == "close_commands")
    {
        self.currentMenu = "";
        return;
    }
    if (response == "clear")
    {
        self.searchText = "";
        self refresh(true);
        return;
    }
    if (response == "prev" || response == "next")
    {
        if (response == "prev")
        {
            self.commandMenu.page--;
        }
        else
        {
            self.commandMenu.page++;
        }
        self.commandMenu.selectedName = undefined;
        self.commandMenu.detailPage = 1;
    }
    else if (response == "detail_prev" || response == "detail_next")
    {
        if (response == "detail_prev")
        {
            self.commandMenu.detailPage--;
        }
        else
        {
            self.commandMenu.detailPage++;
        }
    }
    else if (getSubStr(response, 0, selectionPrefix.size) == selectionPrefix)
    {
        selectedRowText = getSubStr(response, selectionPrefix.size);
        if (!isValidInt(selectedRowText))
        {
            return;
        }
        selectedRow = int(selectedRowText);
        if (selectedRow < 0 || selectedRow >= self.commandMenu.displayed.size)
        {
            return;
        }
        self.commandMenu.selectedName = self.commandMenu.displayed[selectedRow].name;
        self.commandMenu.detailPage = 1;
    }
    else
    {
        return;
    }
    // Re-read the registry and current permissions even for old menu responses.
    self refresh(false);
}

// Re-read permissions and registration before publishing either side of the browser.
refresh(resetSelection)
{
    state = self.commandMenu;
    if (resetSelection)
    {
        state.page = 1;
        state.detailPage = 1;
        state.selectedName = undefined;
    }
    entries = openCJ\commands_base::availableCommands(self.permissions, self.searchText);
    state.total = entries.size;
    state.maxPage = int(max(1, ceil(entries.size / float(level.commandMenuRows))));
    state.page = int(max(1, min(state.page, state.maxPage)));
    selectedRow = self publishCommandRows(entries);
    self publishCommandDetails(selectedRow);
    self publish("selected", selectedRow);
    self publish("search", self.searchText);
    self publish("page", state.page);
    self publish("maxpage", state.maxPage);
    self publish("pages", state.page + " / " + state.maxPage + "   (" + state.total + " commands)");
    self publish("detailpage", state.detailPage);
    self publish("maxdetailpage", state.maxDetailPage);
    self publish("detailpages", state.detailPage + " / " + state.maxDetailPage);
}

// Keep a visible selection when possible; otherwise start with the first permitted row.
publishCommandRows(entries)
{
    state = self.commandMenu;
    firstEntryIndex = (state.page - 1) * level.commandMenuRows;
    state.displayed = [];
    selectedRow = -1;
    for (i = 0; i < level.commandMenuRows; i++)
    {
        rowLabel = "";
        if (firstEntryIndex + i < entries.size)
        {
            entry = entries[firstEntryIndex + i];
            state.displayed[i] = entry;
            rowLabel = "!" + entry.name;
            if (isDefined(state.selectedName) && state.selectedName == entry.name)
            {
                selectedRow = i;
            }
        }
        self publish("row" + i, rowLabel);
    }
    if (selectedRow < 0 && state.displayed.size > 0)
    {
        selectedRow = 0;
        state.detailPage = 1;
    }
    return selectedRow;
}

// Clear details when search or a permission change removes the selected command.
publishCommandDetails(selectedRow)
{
    state = self.commandMenu;
    state.selectedName = undefined;
    lines = [];
    title = "No matching commands";
    if (selectedRow >= 0)
    {
        selectedEntry = state.displayed[selectedRow];
        state.selectedName = selectedEntry.name;
        title = "!" + selectedEntry.name;
        aliasText = selectedEntry.aliasText;
        if (aliasText == "")
        {
            aliasText = "None";
        }
        lines = wrapText("Aliases: " + aliasText + "\n\n" + selectedEntry.help,
                         level.commandHelpLineCharacters);
    }
    state.lines = lines;
    state.maxDetailPage = int(max(1, ceil(lines.size / float(level.commandDetailRows))));
    state.detailPage = int(max(1, min(state.detailPage, state.maxDetailPage)));
    for (i = 0; i < level.commandDetailRows; i++)
    {
        lineText = "";
        lineIndex = (state.detailPage - 1) * level.commandDetailRows + i;
        if (lineIndex < lines.size)
        {
            lineText = lines[lineIndex];
        }
        self publish("line" + i, lineText);
    }
    self publish("title", title);
}

publish(fieldName, fieldValue)
{
    // Typing normally changes only a few fields; avoid flooding reliable commands.
    fieldValue = "" + fieldValue;
    if (isDefined(self.commandMenu.values[fieldName]) && self.commandMenu.values[fieldName] == fieldValue)
    {
        return;
    }
    self.commandMenu.values[fieldName] = fieldValue;
    self setClientCvar("opencj_ui_commands_" + fieldName, fieldValue);
}

// Preserve all help text, including long words/newlines, across detail pages.
wrapText(remainingText, lineWidth)
{
    lines = [];
    while (remainingText.size > 0)
    {
        splitIndex = int(min(lineWidth, remainingText.size));
        consumedCharacters = splitIndex;
        explicitNewline = false;
        for (i = 0; i < splitIndex; i++)
        {
            if (remainingText[i] == "\n")
            {
                splitIndex = i;
                consumedCharacters = i + 1;
                explicitNewline = true;
                break;
            }
        }
        if (!explicitNewline && splitIndex < remainingText.size && remainingText[splitIndex] != " ")
        {
            for (i = splitIndex - 1; i > 0; i--)
            {
                if (remainingText[i] == " ")
                {
                    splitIndex = i;
                    consumedCharacters = i + 1;
                    break;
                }
            }
        }
        lines[lines.size] = getSubStr(remainingText, 0, splitIndex);
        remainingText = getSubStr(remainingText, consumedCharacters);
        if (!explicitNewline)
        {
            while (remainingText.size > 0 && remainingText[0] == " ")
            {
                remainingText = getSubStr(remainingText, 1);
            }
        }
    }
    return lines;
}
