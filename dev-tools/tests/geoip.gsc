main()
{
    wait 1;
    level.geoFailures = 0;
    level.geoChecks = 0;
    atlasMappingChecks();
    authenticatedConnectionChecks();
    lookupFallbackChecks();
    connectingRowChecks();
    printf("GEOIP SELFTEST COMPLETE failures=" + level.geoFailures + " checks=" + level.geoChecks +
           "\n");
}

// The expected order is a fixture for the atlas protocol, independent of its generator.
atlasMappingChecks()
{
    unknownFlag = openCJ\flagAtlas::resolve("??");
    check(!unknownFlag.known && unknownFlag.material == "default" && unknownFlag.selector == 0,
          "unknown flag reuses the existing default material");
    britishFlag = openCJ\flagAtlas::resolve("GB");
    britishAlias = openCJ\flagAtlas::resolve("uk");
    check(britishFlag.known && britishFlag.material == britishAlias.material &&
              britishFlag.selector == britishAlias.selector,
          "country case and UK alias");
    countryCodes = strTok(
        "ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn " +
            "bo bq br bs bt bv bw by bz ca cc cd cf cg ch ci ck cl cm cn co cp cr cu cv cw cx cy " +
            "cz de dg dj dk dm do dz ec ee eg eh er es et eu fi fj fk fm fo fr ga gb gd ge gf gg " +
            "gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu ic id ie il im in io iq ir " +
            "is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly " +
            "ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng " +
            "ni nl no np nr nu nz om pa pc pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru " +
            "rw sa sb sc sd se sg sh si sj sk sl sm sn so sr ss st sv sx sy sz tc td tf tg th tj " +
            "tk tl tm tn to tr tt tv tw tz ua ug um un us uy uz va vc ve vg vi vn vu wf ws xk ye " +
            "yt za zm zw",
        " ");
    tilesPerPage = 36;
    for(i = 0; i < countryCodes.size; i++)
    {
        countryFlag = openCJ\flagAtlas::resolve(countryCodes[i]);
        pageIndex = int(i / tilesPerPage);
        // Selector zero means no atlas tile; country tiles start at one.
        expectedSelector = i - pageIndex * tilesPerPage + 1;
        check(countryFlag.material == "opencj_flag_atlas_" + pageIndex &&
                  countryFlag.selector == expectedSelector,
              "mapping " + countryCodes[i]);
    }
    invalidFlag = openCJ\flagAtlas::resolve("bad");
    check(!invalidFlag.known, "invalid country uses fallback");
}

authenticatedConnectionChecks()
{
    player = spawnStruct();
    player.name = "GeoIP fixture";
    player openCJ\country::onPlayerConnect();
    check(!player openCJ\country::beginLogin(), "unauthenticated client not announced");
    player.login_playerID = 123;
    check(player openCJ\country::beginLogin(), "authenticated client announced once");
    check(!player openCJ\country::beginLogin(), "duplicate login event suppressed");
}

lookupFallbackChecks()
{
    player = spawnStruct();
    player openCJ\country::applyLookup("ZA");
    check(player openCJ\country::getCountry() == "ZA" && player.country_reason == "ok",
          "valid lookup accepted");
    player openCJ\country::applyLookup("range_not_found");
    check(player openCJ\country::getCountry() == "??" && player.country_reason == "range_not_found",
          "lookup gap explained and old country cleared");
    player openCJ\country::applyLookup("ZZ");
    check(player.country_reason == "unsupported_country_code", "unmapped country explained");
}

connectingRowChecks()
{
    unknownFlag = openCJ\flagAtlas::resolve("??");
    connectingRow = openCJ\scoreboard::connectingRow("Downloading");
    check(connectingRow["flag"] == unknownFlag.material &&
              connectingRow["flagSelector"] == unknownFlag.selector && connectingRow["rank"] == "",
          "connecting row has neutral flag and no invented rank");
}

check(passed, label)
{
    level.geoChecks++;
    if(!passed)
    {
        level.geoFailures++;
        printf("GEOIP SELFTEST FAIL " + label + "\n");
    }
}
