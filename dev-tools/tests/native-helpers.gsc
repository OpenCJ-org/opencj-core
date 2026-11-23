#include openCJ\util;

main()
{
    if(getCvarInt("opencj_isolated_demo_test") != 1)
    {
        return;
    }
    level.helperChecks = 0;
    level.helperFailures = 0;
    checkAsciiConversions();
    checkHudRegistrations();
    checkConfigstringLookup();
    checkMapAndTextHelpers();
    checkPlayerHelpers();
    checkNonPlayerHelpers();
    printf("NATIVE HELPERS COMPLETE failures=" + level.helperFailures
           + " checks=" + level.helperChecks + "\n");
}

checkAsciiConversions()
{
    check(getAscii("A") == 65, "ASCII uppercase");
    check(getAscii("z") == 122, "ASCII lowercase");
    check(getAscii("9") == 57, "ASCII digit");
    check(getAscii("!") == 33, "ASCII punctuation");
    check(getAscii("") == 0, "empty ASCII input retains zero");
    check(getAscii("Ab") == 65, "only first byte converted");
}

// Exercise actual precaching and the production HUD lookup wrapper.
checkHudRegistrations()
{
    localizedStringBase = 309;
    localizedStringCount = 512;
    openCJ\huds\infiniteHuds::onInit();
    for(i = 0; i < 3; i++)
    {
        hudName = "helperhud" + i;
        openCJ\huds\infiniteHuds::initInfiniteHud(hudName);
        entry = level.infiniteHudStrings[hudName];
        check(entry.configstringIndex > localizedStringBase
              && entry.configstringIndex < localizedStringBase + localizedStringCount,
              "HUD absolute localized index " + i);
        check(sv_getconfigstring(entry.configstringIndex) == entry.string,
              "HUD lookup resolves its own string " + i);
        if(i > 0)
        {
            check(entry.configstringIndex
                  != level.infiniteHudStrings["helperhud0"].configstringIndex,
                  "HUD indices do not collide " + i);
        }
    }
}

// Use a scratch portion of the localized table, then restore every slot.
checkConfigstringLookup()
{
    firstScratchIndex = 789;
    lastScratchIndex = 795;
    reservedIndex = 790;
    searchLength = 5;
    engineConfigstringCount = 4883;
    savedStrings = [];
    for(index = firstScratchIndex; index <= lastScratchIndex; index++)
    {
        savedStrings[index] = sv_getconfigstring(index);
    }
    setconfigstringbyindex(789, "native_helper_duplicate");
    setconfigstringbyindex(790, "native_helper_reserved");
    setconfigstringbyindex(791, "native_helper_first");
    setconfigstringbyindex(792, "");
    setconfigstringbyindex(793, "native_helper_duplicate");
    setconfigstringbyindex(794, "native_helper_last");
    setconfigstringbyindex(795, "native_helper_outside");
    check(G_FindConfigstringIndex("native_helper_first", reservedIndex, searchLength) == 791,
          "range starts at first usable slot");
    check(G_FindConfigstringIndex("native_helper_last", reservedIndex, searchLength) == 794,
          "range includes last slot");
    check(G_FindConfigstringIndex("native_helper_duplicate", reservedIndex, searchLength) == 793,
          "matching text outside range ignored");
    check(G_FindConfigstringIndex("NATIVE_HELPER_FIRST", reservedIndex, searchLength) == 791,
          "case-insensitive compatibility");
    check(G_FindConfigstringIndex("native_helper_reserved", reservedIndex, searchLength) == 0,
          "table zero slot reserved");
    check(G_FindConfigstringIndex("native_helper_outside", reservedIndex, searchLength) == 0,
          "end bound exclusive");
    check(G_FindConfigstringIndex("", reservedIndex, searchLength) == 0,
          "empty lookup rejected");
    check(G_FindConfigstringIndex("missing", reservedIndex, searchLength) == 0,
          "missing lookup returns zero");
    check(G_FindConfigstringIndex("missing", -1, searchLength) == 0,
          "negative start rejected");
    check(G_FindConfigstringIndex("missing", engineConfigstringCount, searchLength) == 0,
          "out-of-range start rejected");
    check(G_FindConfigstringIndex("missing", reservedIndex, 0) == 0,
          "empty range rejected");
    check(G_FindConfigstringIndex("missing", reservedIndex, -1) == 0,
          "negative count rejected");
    check(G_FindConfigstringIndex("missing", reservedIndex, 2147483647) == 0,
          "overflowing count rejected");
    check(G_FindConfigstringIndex("missing", engineConfigstringCount - 1, 2) == 0,
          "range beyond table rejected");
    for(index = firstScratchIndex; index <= lastScratchIndex; index++)
    {
        setconfigstringbyindex(index, savedStrings[index]);
    }
}

checkMapAndTextHelpers()
{
    check(opencjMapExists("mp_killhouse"), "stock map fastfile is found");
    check(opencjMapExists("MP_KILLHOUSE"), "map lookup normalizes case");
    check(!opencjMapExists(""), "empty map name is rejected");
    check(!opencjMapExists("../mp_killhouse"), "map traversal is rejected");
    check(!opencjMapExists("mp_killhouse_load"), "loading fastfile is not a map");
    check(!opencjMapExists("mp_native_helper_missing"), "missing map is rejected");
    check(!isDefined(opencjScanDir("opencj_native_helper_missing")),
          "missing directory is unavailable");
    entries = opencjScanDir(".");
    check(isDefined(entries), "existing directory can be enumerated");
    hasDotEntry = false;
    for(i = 0; isDefined(entries) && i < entries.size; i++)
    {
        if(entries[i] == "." || entries[i] == "..")
        {
            hasDotEntry = true;
        }
    }
    check(!hasDotEntry, "directory enumeration omits dot entries");

    values = [];
    values[0] = 123.456;
    values[1] = -0.000012345678;
    values[2] = 0;
    for(i = 0; i < values.size; i++)
    {
        check(float(floatToPreciseString(values[i])) == values[i],
              "precise float text round-trips value " + i);
    }
}

checkPlayerHelpers()
{
    wait 1;
    player = addTestClient();
    wait 0.2;
    check(isDefined(player), "test client available");
    if(!isDefined(player))
    {
        return;
    }
    player.sessionTeam = "allies";
    player.sessionState = "playing";
    player.pers["team"] = "allies";
    player spawn((0, 0, 700), (0, 0, 0));
    player freezeControls(true);
    player setVelocity((10, -20, 30));
    check(player addVelocity((5, 8, -12)) == 1, "addVelocity succeeds");
    check(player getVelocity() == (15, -12, 18), "velocity addition preserves all axes");
    player addVelocity((-5, -8, 12));
    check(player getVelocity() == (10, -20, 30), "inverse addition restores velocity");
    check(player getIP() == "bot", "client address comes from engine without port");
    check(player isSprinting() == 0, "stationary player is not sprinting");
    check(isDefined(player getQueuedReliableMessages()), "native reliable-queue helper available");
    check(player getPingVariation() == -1, "bot has no network ping variation");
    player.isFirstSpawn = true;
    hud = player openCJ\huds\infiniteHuds::createInfiniteStringHud("helperhud0");
    hud openCJ\huds\infiniteHuds::setInfiniteHudText("Native helper HUD test", player, true);
    check(hud.configstringIndex == level.infiniteHudStrings["helperhud0"].configstringIndex,
          "HUD sends text to correct absolute index");
    hud destroy();
}

checkNonPlayerHelpers()
{
    entity = spawn("script_origin", (0, 0, 700));
    check(entity addVelocity((1, 2, 3)) == 0, "non-player velocity call rejected safely");
    check(entity getIP() == "", "non-player IP call returns empty");
    check(entity isSprinting() == 0, "non-player sprint call returns false");
    check(entity getQueuedReliableMessages() == 0, "non-player queue call returns zero");
    check(entity getPingVariation() == -1, "non-player ping variation is unavailable");
    entity delete();
}

check(passed, label)
{
    level.helperChecks++;
    if(!passed)
    {
        level.helperFailures++;
        printf("NATIVE HELPERS FAIL: " + label + "\n");
    }
}
