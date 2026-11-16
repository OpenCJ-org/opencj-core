#include openCJ\util;
main()
{
    level.nameTestChecks=0;level.nameTestFailures=0;
    openCJ\mySQL::onInit();openCJ\commands_base::onInit();openCJ\playerNames::onInit();
    openCJ\showRecords::onInit();openCJ\statistics::onInit();
    check(level.nameRulesReady,"private policy snapshot loads");
    wait 1;
    a=addTestClient();b=addTestClient();wait .2;
    a.login_playerID=1;b.login_playerID=2;a.adminLevel=0;b.adminLevel=0;
    a.sessionTeam="allies";a.sessionState="playing";a.pers["team"]="allies";
    b.sessionTeam="allies";b.sessionState="playing";b.pers["team"]="allies";
    a spawn((0,0,5000),(0,0,0));b spawn((30,0,5000),(0,0,0));
    a.nameAccountKey="p:1";b.nameAccountKey="p:2";
    a.nameAccepted=undefined;a.nameLastChange=undefined;
    a openCJ\playerNames::_rename("FirstName");
    check(a.nameAccepted=="FirstName" && !isDefined(a.nameLastChange),"initial connection name does not start cooldown");
    original=a.name;
    candidate=cleanPlayerName("Candidate");
    check(a.name==original && candidate=="Candidate","native cleanup does not publish a candidate");
    check(cleanPlayerName("  Spaced")=="Spaced","native cleanup trims leading spaces without mutating input");
    a openCJ\playerNames::_rename("FirstChange");
    check(a.nameAccepted=="FirstChange" && isDefined(a.nameLastChange),"first regular rename is immediately allowed");
    stamp=a.nameLastChange;
    a openCJ\playerNames::_rename("TooQuick");
    check(a.nameAccepted=="FirstChange" && a.name=="FirstChange" && a.nameLastChange==stamp,"regular cooldown preserves published name and timestamp");
    a.nameLastChange=getRealTime()-60;
    a openCJ\playerNames::_rename("AfterMinute");
    check(a.nameAccepted=="AfterMinute","regular rename allowed at sixty-second boundary");
    check(openCJ\namePolicy::normalize("^1F1x.tuure Token")=="fixturetoken","normalization strips colors, substitutes digits and collapses repeats");
    check(openCJ\namePolicy::blockedRule("xF1x.tuureTokenx")>0,"private hash rules catch obfuscated contained terms");
    check(openCJ\namePolicy::blockedRule("OkFixtureToken")==0,"rule-specific exception avoids false positive");
    check(openCJ\namePolicy::blockedRule("OrdinaryName")==0,"ordinary name passes");
    a.nameLastChange=getRealTime()-60;
    a openCJ\playerNames::_rename("FixtureToken");
    check(getSubStr(a.nameAccepted,0,6)=="Clown#" && a.nameAccepted.size==10 &&
        openCJ\playerNames::digits(getSubStr(a.nameAccepted,6)),"blocked regular name becomes Clown plus four digits");
    check(a.name==a.nameAccepted,"replacement is the publicly visible engine name");
    fallback=a.nameAccepted;
    a.nameLastChange=getRealTime()-60;
    a openCJ\playerNames::_rename("FixtureToken");
    check(a.nameAccepted==fallback,"repeated rejected request does not churn random replacements");
    a openCJ\playerNames::setForcedName("ForcedFixture");
    a openCJ\playerNames::onUserInfoChanged();
    check(a.name=="ForcedFixture","moderator forced name survives userinfo updates");
    a openCJ\playerNames::setForcedName();
    check(!isDefined(a.forcedName),"moderator can release forced name");
    check(!isDefined(openCJ\namePolicy::preferredName("^1Colored")) &&
        !isDefined(openCJ\namePolicy::preferredName("ab")) &&
        !isDefined(openCJ\namePolicy::preferredName("1234567890123456")),"preferred name rejects colors and invalid lengths");
    check(openCJ\namePolicy::preferredName("  First   Last  ")=="First Last","preferred name trims and normalizes whitespace");
    cmd=level.commands["prefname"];
    check(isDefined(cmd) && isDefined(cmd.redactArgs) && cmd.redactArgs &&
        openCJ\commands_base::availableCommands(0,"prefname").size==1,"preferred-name command is discoverable and redacts arguments");
    check(level.commands["frename"].minAdminLevel==40 && level.commands["resetprefname"].minAdminLevel==40,"moderator commands require moderator rank");
    args=[];args[0]="RecordName";
    a openCJ\playerNames::_onPreferredName(args);
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(hasResult(rows) && rows[0][0]=="RecordName","preferred command persists name");
    args[0]="recordname";b openCJ\playerNames::_onPreferredName(args);
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT COUNT(*) FROM playerNamePreferences WHERE playerID=2 AND preferredName IS NOT NULL");
    check(hasResult(rows) && int(rows[0][0])==0,"case-insensitive uniqueness enforced through command path");
    args[0]="AnotherName";a openCJ\playerNames::_onPreferredName(args);
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(rows[0][0]=="RecordName","preferred cooldown blocks a second change");
    args[0]="reset";a openCJ\playerNames::_onPreferredName(args);
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(rows[0][0]=="RecordName","reset cannot bypass preferred cooldown");
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT playerName FROM playerDisplayNames WHERE playerID=1");
    check(rows[0][0]=="RecordName","records resolve the persistent account name");
    check(a.name=="ForcedFixture","preferred name does not rename the live player");
    args[0]="FixtureToken";b openCJ\playerNames::_onPreferredName(args);
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT COUNT(*) FROM playerNamePreferences WHERE playerID=2 AND preferredName IS NOT NULL");
    check(hasResult(rows) && int(rows[0][0])==0,"blocked preferred name never becomes persistent");
    args=[];a openCJ\playerNames::_onPreferredName(args);
    check(!a.preferredNameBusy,"query completes without leaving the command busy");

    // Exercise the real checkpoint renderer for the highlighted current run,
    // cached other-player rows, spectator rendering and immediate name refresh.
    a openCJ\showRecords::onPlayerConnect();b openCJ\showRecords::onPlayerConnect();
    a openCJ\statistics::onPlayerConnect();b openCJ\statistics::onPlayerConnect();
    a.settingValues=[];a.settingValues["lbsort"]="time:asc";
    b.settingValues=[];b.settingValues["lbsort"]="time:asc";
    a.startTime=getTime()-2000;b.startTime=getTime()-3000;
    rows=[];rows[0]=[];rows[0][0]=1;rows[0][1]="OldOther";rows[0][2]=1000;rows[0][3]=0;rows[0][4]=0;rows[0][5]=2;
    a openCJ\showRecords::_updateRecords(a,rows,2000,true);
    check(isSubStr(a.showRecords_nameString,"ForcedFixture") && !isSubStr(a.showRecords_nameString,"RecordName"),
        "highlighted checkpoint row retains the live player name");
    b openCJ\showRecords::_updateRecords(a,rows,2000,true);
    check(b.showRecords_nameString==a.showRecords_nameString,"spectator checkpoint panel keeps the watched player live name");
    ownHistory=rows;ownHistory[0][5]=1;ownHistory[0][1]="OldOwnName";
    a openCJ\showRecords::_updateRecords(a,ownHistory,2000,true);
    check(isSubStr(a.showRecords_nameString,"RecordName") && isSubStr(a.showRecords_nameString,"ForcedFixture"),
        "same account historical row uses preferred name while current row keeps live name");
    a openCJ\showRecords::_updateRecords(a,rows,2000,true);
    openCJ\playerNames::_publishPreferredName(2,"OtherRecord");
    check(isSubStr(a.showRecords_nameString,"OtherRecord") && !isSubStr(a.showRecords_nameString,"OldOther"),
        "already visible checkpoint names refresh without a new checkpoint query");
    check(a.showRecords_nameString==b.showRecords_nameString && rows.size==1,
        "refresh preserves cached row counts and spectator output");
    check(isSubStr(a.showRecords_nameString,"ForcedFixture") && !isSubStr(a.showRecords_nameString,"RecordName"),
        "preferred-name refresh leaves the live current-run row unchanged");
    openCJ\playerNames::_publishPreferredName(2,undefined,"RegularOther");
    check(isSubStr(a.showRecords_nameString,"RegularOther"),"reset refreshes cached record-name fallback");
    a openCJ\showRecords::_hideRecords(true);
    openCJ\playerNames::_publishPreferredName(2,"OtherAgain");
    check(a.showRecords_nameString=="","name refresh does not reopen hidden panels");
    b openCJ\showRecords::_hideRecords(true);

    // Real entity disconnect/recreation, retaining only server identity memory.
    a.nameLastChange=getRealTime()-60;
    a openCJ\playerNames::_rename("ReconnectKeep");
    stamp=a.nameLastChange;
    slot=a getEntityNumber();kick(slot);wait .3;
    a=addTestClient();wait .2;
    a.login_playerID=1;a.adminLevel=0;a.sessionTeam="allies";a.sessionState="playing";a.pers["team"]="allies";
    a spawn((0,0,5000),(0,0,0));
    a openCJ\playerNames::onAccountIdentified();
    check(a.nameAccepted=="ReconnectKeep" && a.nameLastChange==stamp,
        "account login restores regular cooldown after a real disconnect and reconnect");
    a openCJ\playerNames::_rename("ReconnectSkip");
    check(a.name=="ReconnectKeep","reconnected player cannot change regular name during existing cooldown");
    a openCJ\playerNames::_loadPreferredName();
    check(a openCJ\playerNames::getRecordName()=="RecordName",
        "preferred record name reloads after reconnect without changing live name");
    args=[];args[0]="BypassPreferred";a openCJ\playerNames::_onPreferredName(args);
    rows=openCJ\mySQL::mysqlAsyncRead("SELECT preferredName FROM playerNamePreferences WHERE playerID=1");
    check(rows[0][0]=="RecordName","preferred-name database cooldown survives a real reconnect");
    a.nameLastChange=getRealTime()-60;
    a openCJ\playerNames::_rename("ReconnectAfter");
    check(a.name=="ReconnectAfter","regular cooldown expires normally after reconnect");
    check(!isDefined(b.nameLastChange),"another account does not inherit the reconnect cooldown");
    a.nameLastChange=getRealTime()-60;a openCJ\playerNames::_rememberRegularName();
    // Reinitialization must preserve game memory; it must not reset the timer.
    openCJ\playerNames::onInit();
    check(isDefined(openCJ\playerNames::_cachedRegularName("p:1")),"map initialization preserves reconnect memory");
    a openCJ\playerNames::_loadPreferredName();

    wait .2;
    printf("NAME SELFTEST COMPLETE failures="+level.nameTestFailures+" checks="+level.nameTestChecks+"\n");
}
check(value,label)
{
    level.nameTestChecks++;if(!value)level.nameTestFailures++;
    printf("NAME SELFTEST "+int(value)+": "+label+"\n");
}
