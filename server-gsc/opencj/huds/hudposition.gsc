#include openCJ\util;

onInit()
{
    underlyingCmd = openCJ\settings::addSettingBool(
        "poshud", false, "Turn on/off position hud. Usage: !poshud [on/off]", undefined);
}

onPlayerConnect()
{
}

_createPositionHud()
{
    if(!isDefined(self.hudPos))
    {
        self.hudPos = [];

        rgb = (0.8, 0.8, 0.8);
        spaceBetween = 20;
        startY = 6;
        if(getCodVersion() == 4)
        {
            spaceBetween = 16;
            startY = 8;
        }
        self _initPosHud("x", rgb, startY);
        self _initPosHud("y", rgb, startY + spaceBetween);
        self _initPosHud("z", rgb, startY + (2 * spaceBetween));
        self _initPosHud("angle", rgb, startY + (3 * spaceBetween));
    }
}

onSpawnPlayer()
{
    if(self openCJ\settings::getSetting("poshud"))
    {
        self _createPositionHud();
        self _setPosHudAlpha(1);
    }
}

onSpawnSpectator()
{
    self _setPosHudAlpha(0);
}

whileAlive()
{
    if(self openCJ\settings::getSetting("poshud"))
    {
        self _createPositionHud();
        self _updatePosHudValues();
        self _setPosHudAlpha(1);
    }
    else
    {
        self _destroyPositionHud();
    }
}

_updatePosHudValues()
{
    org = self getOrigin();
    if(getCodVersion() == 4) // For CoD4 elevators we want a more accurate position
    {
        // Remove the actual coordinates, for elevating just need the decimals
        // If we don't do this, then the decimals don't always show up when calling setValue
        org = fixDecimals(org, 7, false);
    }
    else
    {
        org = (int(org[0]), int(org[1]), int(org[2]));
    }
    self.hudPos["x"] setValue(org[0]);
    self.hudPos["y"] setValue(org[1]);
    self.hudPos["z"] setValue(org[2]);
    self.hudPos["angle"] setValue(self getPlayerAngles()[1]);
}

_setPosHudAlpha(val)
{
    if(!isDefined(self.hudPos))
    {
        return;
    }
    self.hudPos["x"].alpha = val;
    self.hudPos["y"].alpha = val;
    self.hudPos["z"].alpha = val;
    self.hudPos["angle"].alpha = val;
}

_initPosHud(name, colors, yOffset)
{
    if(!isDefined(self.hudPos[name]))
    {
        self.hudPos[name] = newClientHudElem(self);
        self.hudPos[name].alpha = 0;
        self.hudPos[name].foreground = true;
        self.hudPos[name].alignx = "left";
        self.hudPos[name].aligny = "top";
        self.hudPos[name].x = 115; // To the right of minimap
        self.hudPos[name].y = yOffset;
        self.hudPos[name].horzalign = "left";
        self.hudPos[name].vertalign = "top";
        self.hudPos[name].color = colors;
        self.hudPos[name].fontscale = 1.4;
        if(getCodVersion() == 4)
        {
            // Minimap occupies x=5..73.3 and y=5..73.3 in the same HUD space.
            self.hudPos[name].x = 80;
            // Keep the original readable face; compact the rows instead of the glyphs.
            self.hudPos[name].font = "default";
        }
        self.hudPos[name].archived = false;
        self.hudPos[name].hideWhenInMenu = true;
    }
}

_destroyPositionHud()
{
    if(!isDefined(self.hudPos))
    {
        return;
    }
    keys = getArrayKeys(self.hudPos);
    for(i = 0; i < keys.size; i++)
    {
        self.hudPos[keys[i]] destroy();
    }
    self.hudPos = undefined;
}
