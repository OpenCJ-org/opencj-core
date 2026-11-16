#include openCJ\util;

// Only hashes and numeric rule identifiers enter script memory. Rule data is
// separately managed server data, never literals or examples in this source.
onInit()
{
    level.nameRulesReady=false;
    loadRules(openCJ\mySQL::mysqlSyncQuery("SELECT ruleID,nameHash,normalizedLength,matchMode FROM nameModerationRules WHERE enabled=1"),
        openCJ\mySQL::mysqlSyncQuery("SELECT e.ruleID,e.nameHash FROM nameModerationExceptions e JOIN nameModerationRules r ON r.ruleID=e.ruleID WHERE r.enabled=1"));
}
loadRules(rows,exceptions)
{
    if(!isDefined(rows) || !isDefined(exceptions))return false;
    whole=[];partial=[];lengths=[];allowed=[];
    for(i=0;i<rows.size;i++)
    {
        id=int(rows[i][0]);hash=rows[i][1];size=int(rows[i][2]);
        if(rows[i][3]=="contains"){partial[hash]=id;lengths[size]=true;}
        else whole[hash]=id;
    }
    for(i=0;i<exceptions.size;i++)allowed[exceptions[i][0]+":"+exceptions[i][1]]=true;
    level.nameWholeRules=whole;level.namePartialRules=partial;
    level.namePartialLengths=lengths;level.nameRuleExceptions=allowed;
    level.nameRulesReady=true;
    return true;
}
reload()
{
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT ruleID,nameHash,normalizedLength,matchMode FROM nameModerationRules WHERE enabled=1");
    exceptions=openCJ\mySQL::mysqlAsyncRead("SELECT e.ruleID,e.nameHash FROM nameModerationExceptions e JOIN nameModerationRules r ON r.ruleID=e.ruleID WHERE r.enabled=1");
    return loadRules(rows,exceptions);
}
normalize(name)
{
    value="";last="";name=toLower(name);
    for(i=0;i<min(name.size,128);i++)
    {
        c=name[i];
        if(c=="^"){i++;continue;}
        if(c=="0")c="o";else if(c=="1" || c=="!")c="i";
        else if(c=="3")c="e";else if(c=="4" || c=="@")c="a";
        else if(c=="5" || c=="$")c="s";else if(c=="7")c="t";
        n=getAscii(c);
        if(n<97 || n>122)continue;
        if(c!=last)value+=c;
        last=c;
    }
    return value;
}
// -1 means no policy snapshot is available; keep an accepted/fallback name.
blockedRule(name)
{
    if(!isDefined(level.nameRulesReady) || !level.nameRulesReady)return -1;
    normal=normalize(name);full=sha256(normal);
    id=level.nameWholeRules[full];
    if(isDefined(id) && !isDefined(level.nameRuleExceptions[id+":"+full]))return id;
    for(size=1;size<=normal.size;size++)
    {
        if(!isDefined(level.namePartialLengths[size]))continue;
        for(start=0;start+size<=normal.size;start++)
        {
            id=level.namePartialRules[sha256(getSubStr(normal,start,start+size))];
            if(isDefined(id) && !isDefined(level.nameRuleExceptions[id+":"+full]))return id;
        }
    }
    return 0;
}
fallbackName()
{
    if(isDefined(self.nameModerationFallback))return self.nameModerationFallback;
    name="Clown#";
    for(i=0;i<4;i++)name+=randomInt(10);
    self.nameModerationFallback=name;
    return name;
}
preferredName(raw)
{
    // Match the 15-character visible engine name budget; no hidden colors.
    if(raw.size>128)return undefined;
    value="";space=false;
    for(i=0;i<raw.size;i++)
    {
        c=raw[i];n=getAscii(c);
        if(n<32 || n>126 || c=="^")return undefined;
        if(c==" "){if(value!="")space=true;continue;}
        if(space){value+=" ";space=false;}
        value+=c;
    }
    if(value.size<3 || value.size>15)return undefined;
    visible=false;
    for(i=0;i<value.size;i++)
    {
        n=getAscii(toLower(value[i]));
        if((n>=97 && n<=122) || (n>=48 && n<=57))visible=true;
    }
    if(!visible)return undefined;
    return value;
}
