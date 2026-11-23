#include openCJ\util;

onInit()
{
    precacheMenu("opencj_commands");
    level.commandMenuRows = 12; // Must match opencj_commands.menu.
    level.commandDetailRows = 11;
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
    for(;;)
    {
        self waittill("menuresponse", menu, response);
        if(menu == "opencj_commands")
        {
            self handleResponse(response);
        }
    }
}

onSearchText()
{
    self endon("disconnect");
    level endon("game_ended");
    for(;;)
    {
        self waittill("search_changed");
        if(self.currentMenu == "opencj_commands")
        {
            self refresh(true);
        }
    }
}

handleResponse(response)
{
    if(response == "open_commands")
    {
        self.currentMenu = "opencj_commands";
        self.searchText = "";
        self refresh(true);
        return;
    }
    if(self.currentMenu != "opencj_commands")
    {
        return;
    }
    if(response == "close_commands")
    {
        self.currentMenu = "";
        return;
    }
    if(response == "clear")
    {
        self.searchText = "";
        self refresh(true);
        return;
    }
    if(response == "prev" || response == "next")
    {
        if(response == "prev")
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
    else if(response == "detail_prev" || response == "detail_next")
    {
        if(response == "detail_prev")
        {
            self.commandMenu.detailPage--;
        }
        else
        {
            self.commandMenu.detailPage++;
        }
    }
    else if(getSubStr(response, 0, 7) == "select_")
    {
        idx = getSubStr(response, 7);
        if(!isValidInt(idx))
        {
            return;
        }
        idx = int(idx);
        if(idx < 0 || idx >= self.commandMenu.displayed.size)
        {
            return;
        }
        self.commandMenu.selectedName = self.commandMenu.displayed[idx].name;
        self.commandMenu.detailPage = 1;
    }
    else
    {
        return;
    }
    // Re-read the registry and current permissions even for old menu responses.
    self refresh(false);
}

refresh(reset)
{
    state = self.commandMenu;
    if(reset)
    {
        state.page = 1;
        state.detailPage = 1;
        state.selectedName = undefined;
    }
    entries = openCJ\commands_base::availableCommands(self.adminLevel, self.searchText);
    state.total = entries.size;
    state.maxPage = int(max(1, ceil(entries.size / float(level.commandMenuRows))));
    state.page = int(max(1, min(state.page, state.maxPage)));
    offset = (state.page - 1) * level.commandMenuRows;
    state.displayed = [];
    selected = undefined;
    selectedRow = -1;
    for(i = 0; i < level.commandMenuRows; i++)
    {
        name = "";
        if(offset + i < entries.size)
        {
            entry = entries[offset + i];
            state.displayed[i] = entry;
            name = "!" + entry.name;
            if(isDefined(state.selectedName) && state.selectedName == entry.name)
            {
                selected = entry;
                selectedRow = i;
            }
        }
        self publish("row" + i, name);
    }
    if(!isDefined(selected) && state.displayed.size > 0)
    {
        selected = state.displayed[0];
        selectedRow = 0;
        state.detailPage = 1;
    }
    state.selectedName = undefined;
    lines = [];
    title = "No matching commands";
    if(isDefined(selected))
    {
        state.selectedName = selected.name;
        title = "!" + selected.name;
        aliases = selected.aliasText;
        if(aliases == "")
        {
            aliases = "None";
        }
        lines = wrapText("Aliases: " + aliases + "\n\n" + selected.help, 56);
    }
    state.lines = lines;
    state.maxDetailPage = int(max(1, ceil(lines.size / float(level.commandDetailRows))));
    state.detailPage = int(max(1, min(state.detailPage, state.maxDetailPage)));
    for(i = 0; i < level.commandDetailRows; i++)
    {
        text = "";
        idx = (state.detailPage - 1) * level.commandDetailRows + i;
        if(idx < lines.size)
        {
            text = lines[idx];
        }
        self publish("line" + i, text);
    }
    self publish("title", title);
    self publish("selected", selectedRow);
    self publish("search", self.searchText);
    self publish("page", state.page);
    self publish("maxpage", state.maxPage);
    self publish("pages", state.page + " / " + state.maxPage + "   (" + state.total + " commands)");
    self publish("detailpage", state.detailPage);
    self publish("maxdetailpage", state.maxDetailPage);
    self publish("detailpages", state.detailPage + " / " + state.maxDetailPage);
}

publish(name, value)
{
    // Typing normally changes only a few fields; avoid flooding reliable commands.
    value = "" + value;
    if(isDefined(self.commandMenu.values[name]) && self.commandMenu.values[name] == value)
    {
        return;
    }
    self.commandMenu.values[name] = value;
    self setClientCvar("opencj_ui_commands_" + name, value);
}

// Preserve all help text, including long words/newlines, across detail pages.
wrapText(text, width)
{
    lines = [];
    while(text.size > 0)
    {
        cut = int(min(width, text.size));
        consume = cut;
        newline = false;
        for(i = 0; i < cut; i++)
        {
            if(text[i] == "\n")
            {
                cut = i;
                consume = i + 1;
                newline = true;
                break;
            }
        }
        if(!newline && cut < text.size && text[cut] != " ")
        {
            for(i = cut - 1; i > 0; i--)
            {
                if(text[i] == " ")
                {
                    cut = i;
                    consume = i + 1;
                    break;
                }
            }
        }
        lines[lines.size] = getSubStr(text, 0, cut);
        text = getSubStr(text, consume);
        if(!newline)
        {
            while(text.size > 0 && text[0] == " ")
            {
                text = getSubStr(text, 1);
            }
        }
    }
    return lines;
}
