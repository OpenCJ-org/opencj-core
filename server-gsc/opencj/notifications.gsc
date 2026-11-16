#include openCJ\util;

// Modes: 0 off, 1 text (default), 2 flash, 3 both.
onInit()
{
    if(getCodVersion()!=4)return;
    precacheShader("white");
    precacheShader("opencj_notify_glow_left");
    precacheShader("opencj_notify_glow_right");
    events=[];events[0]="checkpoint";events[1]="save";events[2]="load";
    for(i=0;i<events.size;i++)
        openCJ\settings::addSettingInt("notify_"+events[i],0,3,1,"Action feedback: 0 off, 1 text, 2 flash, 3 both. See !notifications.",::_settingChanged);
    openCJ\settings::addSettingInt("notify_results",1,3,1,"Finish/record/challenge feedback: 1 text, 3 text plus flash.",::_settingChanged);
    openCJ\settings::addSettingInt("notify_strength",1,3,1,"Flash strength: 1 low, 2 medium, 3 high.",::_settingChanged);
    openCJ\commands_base::registerCommand("notifications","Feedback: !notifications [all|checkpoint|save|load] <text|flash|both|off>; results <text|both>; strength <low|medium|high>.",::command,0,2,0);
}
mode(event)
{
    value=self openCJ\settings::getSetting("notify_"+event);
    if(!isDefined(value))return 1;
    return int(value);
}
wantsText(event)
{
    value=self mode(event);
    return value==1 || value==3;
}
modeValue(name)
{
    switch(toLower(name))
    {
        case "off":return 0;
        case "text":return 1;
        case "flash":return 2;
        case "both":return 3;
    }
    return undefined;
}
modeName(value)
{
    names=[];names[0]="off";names[1]="text";names[2]="flash";names[3]="both";
    return names[value];
}
command(args)
{
    if(!self openCJ\settings::areSettingsLoaded())return;
    if(!args.size)
    {
        self iprintln("Notifications: checkpoint "+modeName(self mode("checkpoint"))+", save "+modeName(self mode("save"))+", load "+modeName(self mode("load")));
        resultName="text";if(self mode("results")>=2)resultName="both";
        self iprintln("Results: "+resultName+". !notifications results <text|both>; strength <low|medium|high>");
        return;
    }
    target="all";name=toLower(args[0]);
    if(args.size==2){target=name;name=toLower(args[1]);}
    if(target=="strength")
    {
        strength=undefined;
        if(name=="low")strength=1;
        if(name=="medium")strength=2;
        if(name=="high")strength=3;
        if(!isDefined(strength)){self iprintln("Use strength low, medium or high.");return;}
        self openCJ\settings::setSettingByScript("notify_strength",strength);
        self iprintln("Notification flash strength: "+name);
        return;
    }
    if(target=="results")
    {
        if(name!="text" && name!="both"){self iprintln("Use !notifications results <text|both>. Result messages always stay on.");return;}
        self openCJ\settings::setSettingByScript("notify_results",modeValue(name));
        self iprintln("Finish, record and challenge feedback: "+name);
        return;
    }
    value=modeValue(name);
    if(!isDefined(value) || (target!="all" && target!="checkpoint" && target!="save" && target!="load"))
    {
        self iprintln("Use !notifications [all|checkpoint|save|load] <text|flash|both|off>.");
        return;
    }
    events=[];events[0]="checkpoint";events[1]="save";events[2]="load";
    for(i=0;i<events.size;i++)
        if(target=="all" || target==events[i])
            self openCJ\settings::setSettingByScript("notify_"+events[i],value);
    if(target=="all")
    {
        results=1;if(value==2 || value==3)results=3;
        self openCJ\settings::setSettingByScript("notify_results",results);
    }
    self iprintln("Notifications ("+target+"): "+name);
    if(target=="all")self iprintln("Finish, record and challenge messages always stay on.");

}
_settingChanged(value)
{
    self cancelFlash();
    self cancelCheckpoint();
    self cancelResults();
}
action(event,text)
{
    if(self.sessionState!="playing" || self openCJ\demos::isPlayingDemo())return;
    self cancelResults();
    if(isDefined(self.notificationFlashResult) && self.notificationFlashResult)self cancelFlash();
    if(event=="load")self cancelCheckpoint();
    if(isDefined(text) && self wantsText(event))self iprintln(text);
    value=self mode(event);
    if(value==2 || value==3)self flash(event);
}
color(event)
{
    if(event=="checkpoint" || event=="record")return (.05,1,.10);
    if(event=="save" || event=="finish")return (.05,.25,1);
    if(event=="challenge")return (1,.65,.05);
    return (1,.05,.05); // Load: red, clearly separate from save's blue.
}
beginResults(runID)
{
    self cancelResults();
    if(self mode("results")<2)return;
    self.notificationResultRun=runID;
    self.notificationResultInstance=self openCJ\playerRuns::getRunInstanceNumber();
    self.notificationResultUntil=getTime()+2000;
    self.notificationResultPriority=0;
    self result("finish",runID);
}
result(event,runID)
{
    // SQL replies must not flash over a new run, a load or demo playback.
    if(!isDefined(self.notificationResultRun) || self.notificationResultRun!=runID)return;
    if(self openCJ\playerRuns::getRunID()!=runID ||
       self openCJ\playerRuns::getRunInstanceNumber()!=self.notificationResultInstance ||
       !self openCJ\playerRuns::isRunFinished() || getTime()>self.notificationResultUntil ||
       self.sessionState!="playing" || self openCJ\demos::isPlayingDemo() || self mode("results")<2)return;
    priority=1;
    if(event=="challenge")priority=2;
    if(event=="record")priority=3;
    if(priority<=self.notificationResultPriority)return;
    self.notificationResultPriority=priority;
    self flash(event,true);
}
cancelResults()
{
    self.notificationResultRun=undefined;
    self.notificationResultInstance=undefined;
    self.notificationResultUntil=undefined;
    self.notificationResultPriority=undefined;
}
_createOverlay(x,width,shader)
{
    hud=newClientHudElem(self);
    // Foreground draws independently of the stock HUD visibility gate.
    hud.archived=false;hud.hideWhenInMenu=true;hud.foreground=true;
    hud.horzAlign="fullscreen";hud.vertAlign="fullscreen";
    hud.alignX="left";hud.alignY="top";hud.x=x;hud.y=0;
    hud.sort=-1000;hud.alpha=0;
    hud setShader(shader,width,480);
    return hud;
}
flash(event,isResult)
{
    if(getCodVersion()!=4)return;
    if(!isDefined(isResult))isResult=false;
    if(isDefined(self.notificationFlash) && self.notificationFlashResult!=isResult)self cancelFlash();
    // One pair of soft edge glows, or one result overlay. Bursts do not extend it.
    if(isDefined(self.notificationFlash))
    {
        self.notificationFlash.color=color(event);
        if(isDefined(self.notificationFlashRight))self.notificationFlashRight.color=color(event);
        return;
    }
    width=64;shader="opencj_notify_glow_left";
    if(isResult){width=640;shader="white";}
    hud=self _createOverlay(0,width,shader);
    self.notificationFlash=hud;
    self.notificationFlashResult=isResult;
    right=undefined;
    if(!isResult)
    {
        right=self _createOverlay(576,64,"opencj_notify_glow_right");
        self.notificationFlashRight=right;
        right.color=color(event);
    }
    hud.color=color(event);
    strength=self openCJ\settings::getSetting("notify_strength");
    if(!isDefined(strength))strength=1;
    // HUD alpha is transmitted in multiples of 8/255.
    alpha=(40+16*strength)/255.0; // Edge glows: approximately 22%, 28%, 35%.
    hold=.15;fadeOut=.15;fadeIn=.05;
    if(isResult){alpha=(56+16*strength)/255.0;hold=.30;fadeOut=.35;fadeIn=.10;}
    self thread _fade(hud,right,alpha,fadeIn,hold,fadeOut);
}
_fade(hud,right,alpha,fadeIn,hold,fadeOut)
{
    self endon("disconnect");
    self endon("notificationFlashStop");
    hud fadeOverTime(fadeIn);hud.alpha=alpha;
    if(isDefined(right)){right fadeOverTime(fadeIn);right.alpha=alpha;}
    wait hold; // Includes fade-in, then a short peak hold.
    hud fadeOverTime(fadeOut);hud.alpha=0;
    if(isDefined(right)){right fadeOverTime(fadeOut);right.alpha=0;}
    wait fadeOut;
    self.notificationFlash=undefined;
    self.notificationFlashRight=undefined;
    self.notificationFlashResult=undefined;
    hud destroy();
    if(isDefined(right))right destroy();
}
cancelFlash()
{
    self notify("notificationFlashStop");
    if(isDefined(self.notificationFlash))self.notificationFlash destroy();
    if(isDefined(self.notificationFlashRight))self.notificationFlashRight destroy();
    self.notificationFlash=undefined;
    self.notificationFlashRight=undefined;
    self.notificationFlashResult=undefined;
}
cancelCheckpoint()
{
    self notify("notificationCheckpointStop");
}
onDisconnect()
{
    self cancelAll();
}

cancelAll()
{
    self cancelFlash();
    self cancelCheckpoint();
    self cancelResults();
}
