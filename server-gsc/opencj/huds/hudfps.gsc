#include openCJ\util;

onInit()
{
    // Keep saved 0/1 preferences compatible: 0 off, 1 OpenCJ, 2 standard.
    underlyingCmd = openCJ\settings::addSettingInt(
        "fpshud", 0, 2, 1,
        "FPS overlay: 0 off, 1 OpenCJ, 2 standard (cg_drawfps). Usage: !fpshud [0-2]",
        ::_onFPSHudSetting);
    openCJ\huds\infiniteHuds::initInfiniteHud("fps");
}

onPlayerConnect()
{
    self.fpsHudName = "fps";
    //                                     name             x        y    alignX         alignY    hAlign        vAlign
    self openCJ\huds\base::initInfiniteHUD(self.fpsHudName, -5,     0,    "right",    "top",    "right",    "top",
    //    foreground    font        hideInMenu   color            glowColor                        glowAlpha  fontScale  archived alpha
        undefined,    "default",    true,        (1.0, 1.0, 1.0), ((20/255), (33/255), (125/255)), 0.1,       1.4,       false,   0);
}

onFPSChanged(newFPS)
{
    newFPSText = "" + newFPS;
    if (self.sessionState == "playing")
    {
        specsAndSelf = self getSpectatorList(true);
        for(i = 0; i < specsAndSelf.size; i++)
        {
            specsAndSelf[i].hud[specsAndSelf[i].fpsHudName] openCJ\huds\infiniteHuds::setInfiniteHudText(newFPSText, specsAndSelf[i], false);
        }
    }
    else if ((self.spectatorClient == -1) && (self.classname == "player")) // Gets called early, need to check before setting the text otherwise it won't show by the time you spawn in
    {
        self.hud[self.fpsHudName] openCJ\huds\infiniteHuds::setInfiniteHudText(newFPSText, self, false);
    }
}

onSpectatorClientChanged(newClient)
{
    if(isDefined(newClient))
    {
        currentFPSText = "" + newClient openCJ\fps::getCurrentFPS();
    }
    else //free spec
    {
        currentFPSText = "" + self openCJ\fps::getCurrentFPS();
    }
    self.hud[self.fpsHudName] openCJ\huds\infiniteHuds::setInfiniteHudText(currentFPSText, self, false);
}

onSpawnPlayer()
{
    currentFPSText = "" + self openCJ\fps::getCurrentFPS();
    self.hud[self.fpsHudName] openCJ\huds\infiniteHuds::setInfiniteHudText(currentFPSText, self, false);
}

_onFPSHudSetting(newVal)
{
    shouldEnable = (newVal == 1);
    self setClientCvar("cg_drawfps", int(newVal == 2));

    if(shouldEnable)
    {
        currentFPSText = "" + self openCJ\fps::getCurrentFPS();
        self.hud[self.fpsHudName] openCJ\huds\infiniteHuds::setInfiniteHudText(currentFPSText, self, false);
        self openCJ\huds\base::enableHUD(self.fpsHudName);
    }
    else
    {
        self openCJ\huds\base::disableHUD(self.fpsHudName);
    }
}
