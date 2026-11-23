#include openCJ\util;

// Only hashes and numeric rule identifiers enter script memory. Rule data is
// separately managed server data, never literals or examples in this source.
onInit()
{
    level.nameRulesReady = false;
    loadRules(openCJ\mySQL::mysqlSyncQuery(rulesQuery()),
              openCJ\mySQL::mysqlSyncQuery(exceptionsQuery()));
}

// Build every lookup index before replacing the active policy.
loadRules(ruleRows, exceptionRows)
{
    if(!isDefined(ruleRows) || !isDefined(exceptionRows))
    {
        return false;
    }
    wholeRules = [];
    containedRules = [];
    containedLengths = [];
    ruleExceptions = [];
    for(i = 0; i < ruleRows.size; i++)
    {
        ruleID = int(ruleRows[i][0]);
        nameHash = ruleRows[i][1];
        normalizedLength = int(ruleRows[i][2]);
        if(ruleRows[i][3] == "contains")
        {
            containedRules[nameHash] = ruleID;
            containedLengths[normalizedLength] = true;
        }
        else
        {
            wholeRules[nameHash] = ruleID;
        }
    }
    for(i = 0; i < exceptionRows.size; i++)
    {
        ruleExceptions[exceptionRows[i][0] + ":" + exceptionRows[i][1]] = true;
    }
    level.nameWholeRules = wholeRules;
    level.namePartialRules = containedRules;
    level.namePartialLengths = containedLengths;
    level.nameRuleExceptions = ruleExceptions;
    level.nameRulesReady = true;
    return true;
}

// Keep the previous policy if either database read fails.
reload()
{
    ruleRows = openCJ\mySQL::mysqlAsyncRead(rulesQuery());
    exceptionRows = openCJ\mySQL::mysqlAsyncRead(exceptionsQuery());
    return loadRules(ruleRows, exceptionRows);
}

// Match the SQL normalizer so stored hashes and live names use the same alphabet.
normalize(name)
{
    normalizedName = "";
    previousLetter = "";
    name = toLower(name);
    maximumInputCharacters = 128;
    lowercaseStart = getAscii("a");
    lowercaseEnd = getAscii("z");
    for(i = 0; i < min(name.size, maximumInputCharacters); i++)
    {
        character = name[i];
        if(character == "^")
        {
            i++;
            continue;
        }
        if(character == "0")
        {
            character = "o";
        }
        else if(character == "1" || character == "!")
        {
            character = "i";
        }
        else if(character == "3")
        {
            character = "e";
        }
        else if(character == "4" || character == "@")
        {
            character = "a";
        }
        else if(character == "5" || character == "$")
        {
            character = "s";
        }
        else if(character == "7")
        {
            character = "t";
        }
        characterCode = getAscii(character);
        if(characterCode < lowercaseStart || characterCode > lowercaseEnd)
        {
            continue;
        }
        if(character != previousLetter)
        {
            normalizedName += character;
        }
        previousLetter = character;
    }
    return normalizedName;
}

// Return a matching rule ID, 0 for an allowed name, or -1 when no policy is available.
blockedRule(name)
{
    if(!isDefined(level.nameRulesReady) || !level.nameRulesReady)
    {
        return -1;
    }
    normalizedName = normalize(name);
    fullNameHash = sha256(normalizedName);
    ruleID = level.nameWholeRules[fullNameHash];
    if(isDefined(ruleID) && !isDefined(level.nameRuleExceptions[ruleID + ":" + fullNameHash]))
    {
        return ruleID;
    }
    for(substringLength = 1; substringLength <= normalizedName.size; substringLength++)
    {
        if(!isDefined(level.namePartialLengths[substringLength]))
        {
            continue;
        }
        for(start = 0; start + substringLength <= normalizedName.size; start++)
        {
            ruleID = level.namePartialRules[sha256(
                getSubStr(normalizedName, start, start + substringLength))];
            if(isDefined(ruleID) &&
               !isDefined(level.nameRuleExceptions[ruleID + ":" + fullNameHash]))
            {
                return ruleID;
            }
        }
    }
    return 0;
}

fallbackName()
{
    if(isDefined(self.nameModerationFallback))
    {
        return self.nameModerationFallback;
    }
    fallback = "Clown#";
    suffixDigits = 4;
    for(i = 0; i < suffixDigits; i++)
    {
        fallback += randomInt(10);
    }
    self.nameModerationFallback = fallback;
    return fallback;
}

preferredName(raw)
{
    // Match the 15-character visible engine name budget; no hidden colors.
    maximumInputCharacters = 128;
    minimumVisibleCharacters = 3;
    maximumVisibleCharacters = 15;
    minimumPrintableCode = 32;
    maximumPrintableCode = 126;
    if(raw.size > maximumInputCharacters)
    {
        return undefined;
    }
    preferred = "";
    pendingSpace = false;
    for(i = 0; i < raw.size; i++)
    {
        character = raw[i];
        characterCode = getAscii(character);
        if(characterCode < minimumPrintableCode || characterCode > maximumPrintableCode ||
           character == "^")
        {
            return undefined;
        }
        if(character == " ")
        {
            if(preferred != "")
            {
                pendingSpace = true;
            }
            continue;
        }
        if(pendingSpace)
        {
            preferred += " ";
            pendingSpace = false;
        }
        preferred += character;
    }
    if(preferred.size < minimumVisibleCharacters || preferred.size > maximumVisibleCharacters)
    {
        return undefined;
    }
    hasLetterOrDigit = false;
    for(i = 0; i < preferred.size; i++)
    {
        characterCode = getAscii(toLower(preferred[i]));
        isLetter = characterCode >= getAscii("a") && characterCode <= getAscii("z");
        isDigit = characterCode >= getAscii("0") && characterCode <= getAscii("9");
        if(isLetter || isDigit)
        {
            hasLetterOrDigit = true;
        }
    }
    if(!hasLetterOrDigit)
    {
        return undefined;
    }
    return preferred;
}

// These queries return hashes and numeric IDs; private submitted terms stay out of script memory.
rulesQuery()
{
    return "SELECT ruleID,nameHash,normalizedLength,matchMode" +
           " FROM nameModerationRules WHERE enabled=1";
}

exceptionsQuery()
{
    return "SELECT e.ruleID,e.nameHash FROM nameModerationExceptions e" +
           " JOIN nameModerationRules r ON r.ruleID=e.ruleID WHERE r.enabled=1";
}
