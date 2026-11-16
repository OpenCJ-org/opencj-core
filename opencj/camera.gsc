// Personal camera controls. Camera position never changes run state or input.
onInit()
{
    if(getCodVersion()!=4)return;
    cmd=openCJ\settings::addSettingBool("thirdperson",false,"Toggle third-person for playing and watching. Usage: !thirdperson [on/off]",::_onThirdPerson);
    openCJ\commands_base::addAlias(cmd,"3p");
    // Reset on each connection; ignore older saved enablement without deleting it.
    level.settings["thirdperson"].sessionOnly=true;
    cmd=openCJ\settings::addSettingInt("thirdpersondistance",40,300,120,"Camera distance in game units. Usage: !thirdpersondistance <40-300>",::_onDistance);
    openCJ\commands_base::addAlias(cmd,"3pdist");
    cmd=openCJ\settings::addSettingInt("thirdpersonangle",0,359,0,"Camera orbit angle: 0 behind, 180 in front. Usage: !thirdpersonangle <0-359>",::_onAngle);
    openCJ\commands_base::addAlias(cmd,"3pangle");
}

onPlayerConnected()
{
    self endon("disconnect");
    level endon("game_ended");
    if(getCodVersion()!=4)return;
    // Re-send current values after reliable startup acknowledgement. Login's
    // setting callbacks still apply any preferences loaded after this point.
    self openCJ\clientInit::waitUntilFinished();
    self apply();
}

apply()
{
    self _onDistance(self openCJ\settings::getSetting("thirdpersondistance"));
    self _onAngle(self openCJ\settings::getSetting("thirdpersonangle"));
    self _onThirdPerson(self openCJ\settings::getSetting("thirdperson"));
}

_onThirdPerson(value)
{
    self setClientCvar("cg_thirdPerson",int(value));
}

_onDistance(value)
{
    self setClientCvar("cg_thirdPersonRange",value);
}

_onAngle(value)
{
    self setClientCvar("cg_thirdPersonAngle",value);
}
