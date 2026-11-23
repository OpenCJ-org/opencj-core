#include openCJ\util;

onInit()
{
    if(getCodVersion() == 4)
    {
        _removePickups();
        _removeTurrets();
        _removeWeapons();
        setCvar("clientSideEffects", 0);
        thread _stopMapAmbient();
    }
    else
    {
        _removeTurrets();
    }
}

_removeWeapons()
{
    ents = getEntArray(); // Gets all entities
    if (ents.size <= 0)
    {
        return;
    }
    for (i = ents.size - 1; i >= 0; i--)
    {
        if (getSubStr(ents[i].classname, 0, 7) == "weapon_")
        {
            ents[i] delete();
        }
    }
}

_removePickups()
{
    pickups = getentarray("oldschool_pickup", "targetname");

    for(i = 0; i < pickups.size; i++)
    {
        if(isdefined(pickups[i].target))
        {
            getent(pickups[i].target, "targetname") delete();
        }

        pickups[i] delete();
    }
}

_removeTurrets()
{
    turrets = getentarray("misc_turret", "classname");
    mg42s = getentarray("misc_mg42", "classname");
    for(i = 0; i < turrets.size; i++)
    {
        turrets[i] delete();
    }
    for(i = 0; i < mg42s.size; i++)
    {
        mg42s[i] delete();
    }
}


// Map main() may start its ambient track after the gametype callback. Stop it
// after initialization, without muting player weapons, footsteps or UI sounds.
_stopMapAmbient()
{
    initializationDelaySeconds = 0.05;
    wait initializationDelaySeconds;
    ambientStop();
    _normalizeMapHints();
}

// BSP trigger hints may contain raw prose instead of a localization key.
// Configstrings 277..308 are CoD4's 32 hint slots (G_GetHintStringIndex).
_normalizeMapHints()
{
    firstHintConfigstring = 277;
    hintSlotCount = 32;
    repairedHintCount = 0;
    for(hintIndex = 0; hintIndex < hintSlotCount; hintIndex++)
    {
        configstringIndex = firstHintConfigstring + hintIndex;
        hintText = sv_getconfigstring(configstringIndex);
        normalizedText = _literalMapHint(hintText);
        if(normalizedText != hintText)
        {
            setConfigStringByIndex(configstringIndex, normalizedText);
            repairedHintCount++;
        }
    }
    if(repairedHintCount)
    {
        printf("OpenCJ: normalized " + repairedHintCount + " literal map hint(s).\n");
    }
}

// Add a literal-text marker to prose while preserving localization keys and already marked text.
_literalMapHint(hint)
{
    if(hint == "")
    {
        return hint;
    }
    looksLikePlainKey = !isSubStr(hint, " ") && getSubStr(hint, 0, 1) != "^";
    if(looksLikePlainKey)
    {
        return hint;
    }

    // Derive the engine's control markers from known messages instead of hard-coding bytes.
    literalProbe = constructMessage("x");
    mixedProbe = constructMessage("x", &"PLATFORM_USE");
    literalMarker = getSubStr(literalProbe, 0, 1);
    localizedMarker = getSubStr(mixedProbe, literalProbe.size, literalProbe.size + 1);
    if(isSubStr(hint, literalMarker) || isSubStr(hint, localizedMarker))
    {
        return hint;
    }
    return constructMessage(hint);
}
