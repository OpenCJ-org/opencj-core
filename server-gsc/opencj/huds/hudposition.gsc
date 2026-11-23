#include openCJ\util;

onInit()
{
    openCJ\settings::addSettingBool(
        "poshud", false, "Turn on/off position hud. Usage: !poshud [on/off]", undefined);
}

onPlayerConnect()
{
}

// Allocate coordinate elements only when the setting is enabled.
_createPositionHud()
{
    if(isDefined(self.hudPos))
    {
        return;
    }
    self.hudPos = [];

    textColor = (0.8, 0.8, 0.8);
    rowSpacing = 20;
    firstRowY = 6;
    if(getCodVersion() == 4)
    {
        rowSpacing = 16;
        firstRowY = 8;
    }
    self _initPosHud("x", textColor, firstRowY);
    self _initPosHud("y", textColor, firstRowY + rowSpacing);
    self _initPosHud("z", textColor, firstRowY + (2 * rowSpacing));
    self _initPosHud("angle", textColor, firstRowY + (3 * rowSpacing));
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

_setPosHudAlpha(alpha)
{
    if(!isDefined(self.hudPos))
    {
        return;
    }
    self.hudPos["x"].alpha = alpha;
    self.hudPos["y"].alpha = alpha;
    self.hudPos["z"].alpha = alpha;
    self.hudPos["angle"].alpha = alpha;
}

_initPosHud(fieldName, textColor, yOffset)
{
    if(!isDefined(self.hudPos[fieldName]))
    {
        self.hudPos[fieldName] = newClientHudElem(self);
        self.hudPos[fieldName].alpha = 0;
        self.hudPos[fieldName].foreground = true;
        self.hudPos[fieldName].alignx = "left";
        self.hudPos[fieldName].aligny = "top";
        self.hudPos[fieldName].x = 115; // To the right of minimap
        self.hudPos[fieldName].y = yOffset;
        self.hudPos[fieldName].horzalign = "left";
        self.hudPos[fieldName].vertalign = "top";
        self.hudPos[fieldName].color = textColor;
        self.hudPos[fieldName].fontscale = 1.4;
        if(getCodVersion() == 4)
        {
            // Minimap occupies x=5..73.3 and y=5..73.3 in the same HUD space.
            self.hudPos[fieldName].x = 80;
            // Keep the original readable face; compact the rows instead of the glyphs.
            self.hudPos[fieldName].font = "default";
        }
        self.hudPos[fieldName].archived = false;
        self.hudPos[fieldName].hideWhenInMenu = true;
    }
}

_destroyPositionHud()
{
    if(!isDefined(self.hudPos))
    {
        return;
    }
    fieldNames = getArrayKeys(self.hudPos);
    for(i = 0; i < fieldNames.size; i++)
    {
        self.hudPos[fieldNames[i]] destroy();
    }
    self.hudPos = undefined;
}
