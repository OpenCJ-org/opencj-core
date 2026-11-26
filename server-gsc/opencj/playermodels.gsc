#include openCJ\util;

onInit()
{
    level.playerModels_models = [];
    level.playerModels_deadBodies = [];

    if(getCodVersion() == 2)
    {
        _registerModel("default", "xmodel/playerbody_american_normandy01", "xmodel/viewmodel_hands_cloth");
        _registerAttach("default", "xmodel/head_us_ranger_braeburn", "");
    }
    else
    {
        // The dark model is everyone's default; the shop sells the beta-marked one.
        // Each model has first-person hands with matching gloves.
        _registerModel("default", "body_opencj_dark", "viewhands_opencj_dark");
        _registerAttach("default", "head_opencj_dark", "");
        _registerModel("beta", "body_opencj_beta", "viewhands_opencj_black");
        _registerAttach("beta", "head_opencj_black", "");
    }
}

_registerModel(name, model, viewModel)
{
    modelStruct = spawnStruct();
    modelStruct.model = model;
    modelStruct.viewModel = viewModel;

    precacheModel(model);
    precacheModel(viewModel);

    modelStruct.attach = [];

    level.playerModels_models[name] = modelStruct;
}

_registerAttach(name, model, point)
{
    if(!isDefined(level.playerModels_models[name]))
    {
        return;
    }

    attachStruct = spawnStruct();
    attachStruct.model = model;
    attachStruct.point = point;

    precacheModel(model);

    level.playerModels_models[name].attach[level.playerModels_models[name].attach.size] = attachStruct;
}

setPlayerModel()
{
    self detachAll();

    self notify("deleteBody");

    self _setModel(self openCJ\shop::resource("player"));
}

_setModel(name)
{
    if(!isDefined(level.playerModels_models[name]))
    {
        return;
    }

    self setModel(level.playerModels_models[name].model);
    // Shop mannequins are script models, which have no first-person hands.
    if(isPlayer(self))
    {
        self setViewModel(level.playerModels_models[name].viewModel);
    }

    for(i = 0; i < level.playerModels_models[name].attach.size; i++)
    {
        self attach(level.playerModels_models[name].attach[i].model, level.playerModels_models[name].attach[i].point);
    }
}

onPlayerKilled(inflictor, attacker, damage, meansOfDeath, weapon, vDir, hitLoc, psOffsetTime, deathAnimDuration)
{
    body = self clonePlayer(deathAnimDuration);

    body thread _deleteOnEvent(self, "deleteBody");

    body thread _deleteAfterTime(10);

    level.playerModels_deadBodies[level.playerModels_deadBodies.size] = body;
}

_deleteOnEvent(player, event)
{
    self endon("deleted");

    player waittill(event);

    if(isDefined(self))
    {
        self _cleanupBody();
        self delete();
    }
}

_deleteAfterTime(time)
{
    wait time;

    if(isDefined(self))
    {
        self _cleanupBody();
        self notify("deleted");
        self delete();
    }
}

_cleanupBody()
{
    for(i = 0; i < level.playerModels_deadBodies.size; i++)
    {
        if(level.playerModels_deadBodies[i] == self)
        {
            level.playerModels_deadBodies[i] = level.playerModels_deadBodies[level.playerModels_deadBodies.size - 1];
            level.playerModels_deadBodies[level.playerModels_deadBodies.size - 1] = undefined;
            break;
        }
    }
}