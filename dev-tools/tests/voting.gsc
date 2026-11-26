main()
{
    level.failures = 0;
    level.checks = 0;
    openCJ\menus\endMapVote::onInit();
    prepareMapPool();
    wait 1;

    player = addTestClient();
    otherPlayer = addTestClient();
    check(isDefined(player) && isDefined(otherPlayer), "two voting clients connect");
    if(isDefined(player) && isDefined(otherPlayer))
    {
        wait 0.2;
        spawnpoints = getEntArray("mp_dm_spawn", "classname");
        check(spawnpoints.size > 0, "map provides a spawn for voting clients");
        if(spawnpoints.size == 0)
        {
            return;
        }
        spawnHeightUnits = 32;
        player prepareVoter(1, spawnpoints[0].origin + (0, 0, spawnHeightUnits));
        otherPlayer prepareVoter(2, spawnpoints[0].origin + (64, 0, spawnHeightUnits));
        check(getEntArray("player", "classname").size == 2, "both clients are visible to vote counting");
        player openCJ\menus\endMapVote::onPlayerConnected();
        otherPlayer openCJ\menus\endMapVote::onPlayerConnected();

        player verifyMapLookup();
        player verifyCooldown();
        player verifyNominations(otherPlayer);
        player verifyEndMapVoteSetup();
        player verifyEndMapVoting();
        player verifyNormalVote();
        player verifyVoteListenerStops(otherPlayer);
        verifyVoteTimerOwnership();
    }

    printf("VOTING COMPLETE failures=" + level.failures + " checks=" + level.checks + "\n");
}

// Spawn clients because connected-but-unspawned entities are not in the player array.
prepareVoter(playerID, spawnOrigin)
{
    self.sessionTeam = "allies";
    self.sessionState = "playing";
    self spawn(spawnOrigin, (0, 0, 0));
    self freezeControls(true);
    self.login_playerID = playerID;
    self.permissions = 0;
    self.isAFK = false;
}

mapRow(mapName, inRotation)
{
    row = [];
    row[0] = mapName;
    row[1] = "Unknown";
    row[2] = inRotation;
    row[3] = "Fixture Author";
    return row;
}

prepareMapPool()
{
    rows = [];
    rows[0] = mapRow("mp_killhouse", 1);
    rows[1] = mapRow("mp_crossfire", 1);
    rows[2] = mapRow("mp_crash", 1);
    rows[3] = mapRow("mp_bog", 0);
    openCJ\maps::loadMapRows(rows);
    openCJ\menus\endMapVote::fillRandomMaps();

    check(level.endVote["nrMaps"] == 9, "end-vote menu retains nine client slots");
    check(level.endVote["maps"].size == 2, "end-vote choices exclude current map and non-pool maps");
    check(level.endVote["maps"][0] != level.endVote["maps"][1], "end-vote choices remain unique");
    for(i = 0; i < level.endVote["maps"].size; i++)
    {
        mapName = level.endVote["maps"][i];
        check(mapName != "mp_killhouse" && openCJ\maps::canVoteMap(mapName, 0),
              "offered map is an eligible alternative");
    }
}

verifyMapLookup()
{
    check(self openCJ\vote::_findMapByName("MP_CROSSFIRE") == "mp_crossfire",
          "exact map lookup ignores case");
    check(self openCJ\vote::_findMapByName("crash") == "mp_crash",
          "unique partial map lookup resolves");
    check(!isDefined(self openCJ\vote::_findMapByName("mp_")), "ambiguous lookup does not choose a map");
    check(!isDefined(self openCJ\vote::_findMapByName("")), "empty lookup does not choose a map");
    check(!isDefined(self openCJ\vote::_findMapByName("mp_bog")), "ordinary lookup rejects non-pool map");

    self.permissions = openCJ\permissions::permissionNamed("uber").flag;
    check(self openCJ\vote::_findMapByName("mp_bog") == "mp_bog",
          "uber-admin may choose an installed non-pool map");
    self.permissions = 0;
}

verifyCooldown()
{
    cooldownSeconds = 120;
    self openCJ\vote::_setVoteCooldown(cooldownSeconds);
    remainingSeconds = self.canVoteAt - getTime() / 1000;
    check(abs(remainingSeconds - cooldownSeconds) < 0.01, "ordinary voter receives requested cooldown");

    self.permissions = openCJ\permissions::permissionNamed("uber").flag;
    self openCJ\vote::_setVoteCooldown(cooldownSeconds);
    check(abs(self.canVoteAt - getTime() / 1000) < 0.01, "uber-admin bypasses vote cooldown");
    self.permissions = 0;
}

resetEndVote()
{
    self.endVote = -1;
    level.endVote["winning"] = undefined;
    level.endVote["status"] = 1; // The client protocol's voting phase.
    for(i = 0; i < level.endVote["nrMaps"]; i++)
    {
        level.endVote["votes"][i] = 0;
    }
}

verifyEndMapVoting()
{
    self resetEndVote();
    self notify("menuresponse", "unrelated_menu", "click_vote1");
    wait 0.05;
    check(self.endVote == -1, "unrelated menu cannot cast an end-map vote");

    self resetEndVote();
    self notify("menuresponse", level.endVote["menu"], "click_vote1junk");
    wait 0.05;
    check(self.endVote == -1, "numeric-prefix end-map vote is rejected");

    self resetEndVote();
    self notify("menuresponse", level.endVote["menu"], "click_vote1");
    wait 0.05;
    check(self.endVote == 0 && level.endVote["votes"][0] == 1, "first offered map receives one vote");

    self notify("menuresponse", level.endVote["menu"], "click_vote1");
    wait 0.05;
    check(level.endVote["votes"][0] == 1, "repeated vote does not duplicate the count");

    self notify("menuresponse", level.endVote["menu"], "click_vote2");
    wait 0.05;
    check(self.endVote == 1 && level.endVote["votes"][0] == 0 && level.endVote["votes"][1] == 1,
          "changing choice transfers one vote");

    self notify("menuresponse", level.endVote["menu"], "click_vote3");
    wait 0.05;
    check(self.endVote == 1, "empty client slot cannot receive a vote");

    level.endVote["status"] = 2; // Loading begins after voting closes.
    self notify("menuresponse", level.endVote["menu"], "click_vote1");
    wait 0.05;
    check(self.endVote == 1 && level.endVote["votes"][1] == 1,
          "loading phase rejects a late vote change");
    level.endVote["status"] = 0;
}

// Nominations are permission-checked, unique, one per player and bounded.
verifyNominations(otherPlayer)
{
    uberPermissions = openCJ\permissions::permissionNamed("uber").flag;
    self openCJ\menus\endMapVote::nominate("mp_bog");
    check(level.endVote["nominations"].size == 0, "ordinary player cannot nominate a non-pool map");
    self openCJ\menus\endMapVote::nominate("mp_killhouse");
    check(level.endVote["nominations"].size == 0, "the current map cannot be nominated");

    self openCJ\menus\endMapVote::nominate("mp_crash");
    check(level.endVote["maps"][0] == "mp_crash", "a nominated map takes the first vote slot");
    check(level.endVote["maps"].size == 2, "random maps fill the other slots without duplicates");
    otherPlayer openCJ\menus\endMapVote::nominate("mp_crash");
    check(level.endVote["nominations"].size == 1, "a map is nominated only once");
    self openCJ\menus\endMapVote::nominate("mp_crossfire");
    check(level.endVote["nominations"].size == 1 &&
          level.endVote["nominations"][0].mapName == "mp_crossfire",
          "a new nomination replaces the player's own");

    defaultMaxNominations = level.endVote["maxNominations"];
    level.endVote["maxNominations"] = 1;
    otherPlayer.permissions = uberPermissions;
    otherPlayer openCJ\menus\endMapVote::nominate("mp_bog");
    check(level.endVote["nominations"].size == 1 &&
          level.endVote["nominations"][0].mapName == "mp_bog",
          "the oldest nomination makes way when all nomination slots are taken");
    check(level.endVote["maps"][0] == "mp_bog", "vote slots follow the nominations");
    otherPlayer.permissions = 0;
    level.endVote["maxNominations"] = defaultMaxNominations;

    otherPlayer openCJ\menus\endMapVote::onPlayerDisconnect();
    check(level.endVote["nominations"].size == 1 &&
          !isDefined(level.endVote["nominations"][0].player),
          "a nomination outlives its nominator");

    level.endVote["nominations"] = [];
    level.endVote["status"] = 1; // Voting has started.
    self openCJ\menus\endMapVote::nominate("mp_crash");
    check(level.endVote["nominations"].size == 0, "nominations close when the map vote starts");
    level.endVote["status"] = 0;
    openCJ\menus\endMapVote::_rebuildSlots();
    check(level.endVote["maps"].size == 2, "clearing nominations restores the random slots");
}

// An end-map vote is its own kind and cannot start once the map is ending.
verifyEndMapVoteSetup()
{
    level.vote = undefined;
    self openCJ\vote::_setupVote(undefined, "Vote: end map now", self, "end");
    check(isDefined(level.vote) && isDefined(level.vote.endMap) && !isDefined(level.vote.extend) &&
          !isDefined(level.vote.map), "end-map vote is neither an extension nor a map change");
    openCJ\vote::_destroyVote();

    level.endVote["status"] = 1;
    self openCJ\vote::_doVoteEnd();
    check(!isDefined(level.vote), "no end-map vote while the end-of-map vote runs");
    level.endVote["status"] = 0;
}

// Construct only the state owned by the production timer; no map transition is scheduled.
voteState(durationSeconds, title)
{
    vote = spawnStruct();
    vote.str = title;
    vote.mapImage = "default";
    vote.yesCount = 0;
    vote.noCount = 0;
    vote.timeLeft = durationSeconds;
    vote.extend = true;
    return vote;
}

// Two eligible clients keep one ballot below the majority threshold.
verifyNormalVote()
{
    level.vote = undefined;
    self openCJ\vote::_setupVote("mp_crossfire", "Fixture map vote", self);
    check(isDefined(level.vote) && level.vote.map == "mp_crossfire" && level.vote.timeLeft == 30,
          "new map vote initializes its map and thirty-second duration");
    check(self.vote && level.vote.yesCount == 1 && level.vote.noCount == 0,
          "initiating player receives one affirmative ballot");
    check(abs(self.canVoteAt - getTime() / 1000 - 120) < 0.01,
          "starting a vote applies the two-minute repeat cooldown");

    self openCJ\vote::voteSingleArg("yes");
    check(level.vote.yesCount == 1, "repeating an affirmative ballot does not add a vote");
    self openCJ\vote::voteSingleArg("no");
    self openCJ\vote::voteSingleArg("no");
    check(!self.vote && level.vote.yesCount == 0 && level.vote.noCount == 1,
          "changing to no transfers the ballot without duplicate counts");

    self.login_playerID = undefined;
    self openCJ\vote::voteSingleArg("yes");
    check(!self.vote && level.vote.yesCount == 0, "logged-out player cannot change a normal ballot");
    self.login_playerID = 1;
    openCJ\vote::_destroyVote();
    check(!isDefined(level.vote), "finishing the vote clears its shared state");
}

verifyVoteListenerStops(otherPlayer)
{
    level.vote = voteState(30, "Listener fixture");
    self.vote = undefined;
    otherPlayer.vote = undefined;
    self thread openCJ\vote::menuResponse();

    self notify("disconnect");
    self notify("menuresponse", "opencj_ingame", "cjvoteyes");
    wait 0.05;
    check(!isDefined(self.vote), "disconnected player cannot keep casting menu votes");
    openCJ\vote::_destroyVote();
}

// Both cancellation and identity checks protect a newer vote from an old timer.
verifyVoteTimerOwnership()
{
    level.vote = voteState(1, "First timer");
    level thread openCJ\vote::_monitorVote();
    wait 0.1;
    openCJ\vote::_destroyVote();
    replacementVote = voteState(30, "Replacement after finish");
    level.vote = replacementVote;
    wait 1.05;
    check(isDefined(level.vote) && level.vote == replacementVote && level.vote.timeLeft == 30,
          "finished vote timer cannot expire a replacement vote");
    openCJ\vote::_destroyVote();

    level.vote = voteState(1, "Second timer");
    level thread openCJ\vote::_monitorVote();
    wait 0.1;
    replacementVote = voteState(30, "Replacement without notification");
    level.vote = replacementVote;
    wait 1.05;
    check(isDefined(level.vote) && level.vote == replacementVote && level.vote.timeLeft == 30,
          "timer identity check protects a replacement even without cancellation");
    openCJ\vote::_destroyVote();
}

check(condition, message)
{
    level.checks++;
    if(!condition)
    {
        level.failures++;
    }
    printf("VOTING CHECK " + int(condition) + ": " + message + "\n");
}
