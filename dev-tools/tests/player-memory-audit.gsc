// No account callbacks or database access. Measure production initializers/functions.
main()
{
    initializeFeatures();
    wait 1;
    player = addTestClient();
    wait 0.1;
    if(!isDefined(player))
    {
        printf("MEM COMPLETE failures=1\n");
        return;
    }
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 500), (0, 0, 0));
    player freezeControls(true);
    player.FPS = 333;
    player.isFirstSpawn = false;
    memoryAudit("entity", player);

    player measureConnectedHuds();
    player measureUnchangedHistory();
    player measurePlaybackSeek();
    printf("MEM COMPLETE failures=0\n");
}

// Register the same features as gameplay, without starting account or recording SQL.
initializeFeatures()
{
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\huds\infiniteHuds::onInit();
    openCJ\huds\hudOnScreenKeyboard::onInit();
    openCJ\huds\hudFps::onInit();
    openCJ\huds\hudFPSHistory::onInit();
    openCJ\huds\hudProgressBar::onInit();
    openCJ\huds\hudRunInfo::onInit();
    openCJ\huds\hudSpeedometer::onInit();
    openCJ\huds\hudPosition::onInit();
    openCJ\showRecords::onInit();
    openCJ\demoRecording::_initConstants();
    level.weapons_rpgs = [];
    level.weapons_rpgs["default"] = "rpg_mp";
}

// Measure each HUD group, including duplicate initialization and optional position text.
measureConnectedHuds()
{
    self openCJ\settings::onPlayerConnect();
    self openCJ\huds\base::onPlayerConnect();
    memoryAudit("settings", self);
    self openCJ\huds\hudOnScreenKeyboard::onPlayerConnect();
    memoryAudit("keyboard", self);
    self openCJ\huds\hudGrenadeTimers::onPlayerConnect();
    self openCJ\huds\hudFps::onPlayerConnect();
    self openCJ\huds\hudFPSHistory::onPlayerConnect();
    memoryAudit("fps_initial", self);
    self openCJ\huds\hudJumpSlowdown::onPlayerConnect();
    self openCJ\huds\hudSpeedometer::onPlayerConnect();
    memoryAudit("speed_first", self);
    self openCJ\huds\hudProgressBar::onPlayerConnect();
    memoryAudit("progress", self);
    self openCJ\huds\hudSpeedometer::onPlayerConnect();
    memoryAudit("speed_duplicate", self);
    self openCJ\huds\hudPosition::onPlayerConnect();
    self openCJ\huds\hudTimeLimit::onPlayerConnect();
    self openCJ\huds\hudRunInfo::onPlayerConnect();
    self openCJ\showRecords::onPlayerConnect();
    memoryAudit("connect_huds", self);

    self.settingValues["poshud"] = true;
    self openCJ\huds\hudPosition::whileAlive();
    memoryAudit("position_enabled", self);
    self.settingValues["poshud"] = false;
    self openCJ\huds\hudPosition::whileAlive();
    memoryAudit("position_disabled", self);
}

// Repeated identical history must stay native instead of allocating script rows.
measureUnchangedHistory()
{
    repeatedSampleCount = 512;
    self demoFPSReset();
    self.fpsHistoryText = "32-323";
    self.fpsHistoryDetailedText = "WA 32 > BOUNCE > WD 3 > WA 2 > WD 3";
    memoryAudit("cache_empty", self);
    for(i = 0; i < repeatedSampleCount; i++)
    {
        self openCJ\demos::cacheDemoFPS(i);
    }
    memoryAudit("cache_512_unchanged", self);
    statistics = self demoFPSStats();
    changeCountColumn = 0;
    sampleCountColumn = 1;
    printf("MEM NATIVE changes=" + statistics[changeCountColumn] +
           " samples=" + statistics[sampleCountColumn] + "\n");
    self demoFPSReset();
    memoryAudit("cache_cleared", self);
}

// A seek reconstructs a bounded rendered history from a recording longer than its cache.
measurePlaybackSeek()
{
    demoID = 770001; // Reserved for this disposable engine.
    frameCount = 600;
    lastFrame = frameCount - 1;
    weaponID = 1;
    checkpointID = 1;
    forwardLeftStanding = level.demoFlags.forward | level.demoFlags.left | level.demoFlags.standing;
    createDemo(demoID);
    for(i = 0; i < frameCount; i++)
    {
        addFrameToDemo(demoID, (i * 0.5, 0, 500), (0, i, 0), weaponID,
                       forwardLeftStanding, 0, 0, 0, 333, checkpointID, self getEntityNumber());
    }
    completeDemo(demoID);
    self selectPlaybackDemo(demoID);
    self.demoID = demoID;
    self.demoBegin = 0;
    self.demoEnd = lastFrame;
    self.demoStyle = 0;
    self.playingDemo = true;
    self skipPlaybackFrames(lastFrame);
    memoryAudit("before_seek", self);
    self openCJ\demos::syncDemoFPSHistory(lastFrame);
    memoryAudit("after_seek", self);
    self demoFPSReset();
    memoryAudit("seek_cleared", self);
    destroyDemo(demoID);
}
