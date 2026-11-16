onPlayerConnected(name)
{
    self.searchText = "";
    self.currentMenu = "";

    self thread onMenuResponse();
    self thread openCJ\menus\hudSettings::responses();
}

onMenuResponse()
{
    self endon("disconnect");
    level endon("game_ended");

    for(;;)
    {
        self waittill("menuresponse", menu, response);

        if (response=="sql_close" || response=="close" || response=="close_commands")
        {
            self openCJ\mySQL::cancelMenuReads(menu);
            if(self.currentMenu==menu)self.currentMenu="";
        }
        if (response=="open_leaderboard" || response=="open_runsboard" || response=="open_maplist" || response=="open_commands" || (response=="open" && menu!="opencj_clips" && menu!="opencj_challenges"))
            self openCJ\mySQL::cancelMenuReads();

        currentMenu = self.currentMenu;
        menuOpened = false;
        if ((menu == "opencj_leaderboard") && (response == "open_leaderboard")) // Leaderboard was opened
        {
            self.currentMenu = "opencj_leaderboard";
            menuOpened = true;
            self openCJ\menus\board_base::onBoardOpen("lb");
        }
        else if ((menu == "opencj_runsboard") && (response == "open_runsboard")) // Runsboard was opened
        {
            self.currentMenu = "opencj_runsboard";
            menuOpened = true;
            self openCJ\menus\board_base::onBoardOpen("rn");
        }
        else if ((menu == "opencj_maplist") && (response == "open_maplist")) // Maplist was opened
        {
            menuOpened = true;
            self.currentMenu = "opencj_maplist";
            self openCJ\menus\mapList::onOpen();
        }

        // Search text is used by various menus
        if (menuOpened)
        {
            self _clearSearchText();
        }
    }
}

onInputKey(keyName) // Called by playerCommand 'inputkey'
{
    keyName = toLower(keyName);
    prevSearchText = self.searchText;

    // Simple cases: _ and 0-9a-zA-Z
    text = undefined;
    removeChar = false;
    if (keyName.size == 1)
    {
        if ((keyName == "_") || isAlphaNumeric(keyName))
        {
            text = keyName;
        }
    }
    else
    {
        // Special case(s)
        switch(keyName)
        {
            case "backspace":
            {
                removeChar = true;
            } break;
            default:
            {
                // Unhandled
            }
        }
    }

    if (removeChar)
    {
        if (self.searchText.size >= 1)
        {
            self.searchText = getSubStr(self.searchText, 0, (self.searchText.size - 1));
        }
    }
    else if (self.searchText.size < 50)
    {
        self.searchText += text;
    }

    if (self.searchText != prevSearchText)
    {
        // Let any menu scripts know that search text was changed
        self notify("search_changed");
    }
}

_clearSearchText()
{
    if (self.searchText.size > 0)
    {
        self.searchText = "";
        self notify("search_changed");
    }
}