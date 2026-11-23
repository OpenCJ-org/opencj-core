// The Python launcher substitutes validated numeric parameters in this private fixture.
main()
{
    openCJ\demoRecording::_initConstants();
    level.fpsTraceTime = 0;
    level.fpsTraceFrame = 0;
    openCJ\settings::onInit();
    openCJ\commands_base::onInit();
    openCJ\huds\infiniteHuds::onInit();
    openCJ\huds\hudFPSHistory::onInit();
    wait 1;
    player = addTestClient();
    wait .2;
    if(!isDefined(player))
    {
        failTrace("test client unavailable");
        return;
    }
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 5000), (0, 0, 0));
    player.isFirstSpawn = false;
    player openCJ\huds\base::onPlayerConnect();
    player openCJ\huds\hudFPSHistory::onPlayerConnect();
    player.playingDemo = true;
    player.fpsHistoryMode = "detailed";

    demoID = TRACE_RECORDING_ID;
    if(!isDefined(createDemo(demoID)))
    {
        failTrace("recording allocation failed");
        return;
    }
    if(!loadChunks(demoID))
    {
        destroyDemo(demoID);
        return;
    }
    completeDemo(demoID);
    player selectPlaybackDemo(demoID);
    frameCount = numberOfDemoFrames(demoID);
    if(!isDefined(frameCount) || frameCount < 1)
    {
        failTrace("recording contains no frames");
        destroyDemo(demoID);
        return;
    }
    playbackRange = player demoPlaybackStyle(TRACE_PLAYBACK_STYLE, 0, frameCount - 1);
    if(!isDefined(playbackRange) || playbackRange.size < 2)
    {
        failTrace("playback range unavailable");
        destroyDemo(demoID);
        return;
    }
    player.demoBegin = playbackRange[0];
    player.demoEnd = playbackRange[1];
    playedFrames = player replayFrames(frameCount);
    destroyDemo(demoID);
    if(isDefined(playedFrames))
    {
        printf("FPS LIVE TRACE COMPLETE failures=0 frames=" + playedFrames + "\n");
    }
}

// Python validates text structure; native decoding validates the actual recording bytes.
loadChunks(demoID)
{
    file = FS_FOpen("trace-chunks.txt", "read");
    if(!isDefined(file) || file < 0)
    {
        failTrace("chunk file unavailable");
        return false;
    }
    chunk = "";
    while(true)
    {
        line = FS_ReadLine(file);
        if(!isDefined(line))
        {
            break;
        }
        if(line == "END")
        {
            if(!isDefined(demoDecodeChunk(demoID, chunk)))
            {
                FS_FClose(file);
                failTrace("chunk decode failed");
                return false;
            }
            chunk = "";
        }
        else
        {
            chunk += line;
        }
    }
    FS_FClose(file);
    return true;
}

// Keep trace time tied to recorded samples while yielding periodically to the engine.
replayFrames(frameCount)
{
    sampleIntervalMs = 50;
    framesPerYield = 40;
    previousFrame = -2;
    for(tick = 0; tick < frameCount; tick++)
    {
        skipFrames = 1;
        if(tick == 0)
        {
            skipFrames = 0;
        }
        frame = self openCJ\demos::_getDemoFrame(skipFrames, true);
        if(!isDefined(frame))
        {
            failTrace("playback frame unavailable");
            return undefined;
        }
        level.fpsTraceFrame = frame.number;
        level.fpsTraceTime = tick * sampleIntervalMs;
        printf("FPS LIVE INPUT\t" + frame.number + "\t" + level.fpsTraceTime + "\t" +
               int(frame.forward) + "\t" + int(frame.back) + "\t" + int(frame.left) + "\t" +
               int(frame.right) + "\t" + int(frame.onGround) + "\t" + frame.FPS + "\t" +
               int(frame.bounce) + "\n");
        sequential = tick > 0 && frame.number == previousFrame + 1;
        self openCJ\huds\hudFPSHistory::applyRecordedFrame(frame, sequential, false);
        self logDisplayChanges();
        if(frame.number >= self.demoEnd)
        {
            return tick + 1;
        }
        previousFrame = frame.number;
        if((tick + 1) % framesPerYield == 0)
        {
            wait .05;
        }
    }
    failTrace("playback did not reach its end");
    return undefined;
}

logDisplayChanges()
{
    if(!isDefined(self.fpsTraceDetailed) || self.fpsTraceDetailed != self.fpsHistoryDetailedText)
    {
        printf("FPS DETAILED HUD\t" + level.fpsTraceFrame + "\t" + level.fpsTraceTime + "\t" +
               self.fpsHistoryDetailedText + "\n");
        self.fpsTraceDetailed = self.fpsHistoryDetailedText;
    }
    if(!isDefined(self.fpsTraceCompact) || self.fpsTraceCompact != self.fpsHistoryText)
    {
        printf("FPS COMPACT HUD\t" + level.fpsTraceFrame + "\t" + level.fpsTraceTime + "\t" +
               self.fpsHistoryText + "\n");
        self.fpsTraceCompact = self.fpsHistoryText;
    }
}

failTrace(reason)
{
    printf("FPS LIVE TRACE ERROR " + reason + "\n");
    printf("FPS LIVE TRACE COMPLETE failures=1\n");
}
