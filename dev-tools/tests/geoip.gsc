main()
{
    wait 1;
    level.geoFailures = 0;
    unknown = openCJ\flagAtlas::resolve("??");
    check(!unknown.known && unknown.material == "default" && unknown.selector == 0,
          "unknown flag reuses the existing default material");
    gb = openCJ\flagAtlas::resolve("GB");
    uk = openCJ\flagAtlas::resolve("uk");
    check(gb.known && gb.material == uk.material && gb.selector == uk.selector,
          "country case and UK alias");
    codes = strTok(
        "ad ae af ag ai al am ao aq ar as at au aw ax az ba bb bd be bf bg bh bi bj bl bm bn bo bq br bs bt bv bw by bz ca cc cd cf cg ch ci ck cl cm cn co cp cr cu cv cw cx cy cz de dg dj dk dm do dz ec ee eg eh er es et eu fi fj fk fm fo fr ga gb gd ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu ic id ie il im in io iq ir is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc md me mf mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pc pe pf pg ph pk pl pm pn pr ps pt pw py qa re ro rs ru rw sa sb sc sd se sg sh si sj sk sl sm sn so sr ss st sv sx sy sz tc td tf tg th tj tk tl tm tn to tr tt tv tw tz ua ug um un us uy uz va vc ve vg vi vn vu wf ws xk ye yt za zm zw",
        " ");
    for(i = 0; i < codes.size; i++)
    {
        f = openCJ\flagAtlas::resolve(codes[i]);
        page = int(i / 36);
        check(f.material == "opencj_flag_atlas_" + page && f.selector == i - page * 36 + 1,
              "mapping " + codes[i]);
    }
    bad = openCJ\flagAtlas::resolve("bad");
    check(!bad.known, "invalid country uses fallback");
    p = spawnStruct();
    p.name = "GeoIP fixture";
    p openCJ\country::onPlayerConnect();
    check(!p openCJ\country::beginLogin(), "unauthenticated client not announced");
    p.login_playerID = 123;
    check(p openCJ\country::beginLogin(), "authenticated client announced once");
    check(!p openCJ\country::beginLogin(), "duplicate login event suppressed");
    p openCJ\country::applyLookup("ZA");
    check(p openCJ\country::getCountry() == "ZA" && p.country_reason == "ok",
          "valid lookup accepted");
    p openCJ\country::applyLookup("range_not_found");
    check(p openCJ\country::getCountry() == "??" && p.country_reason == "range_not_found",
          "lookup gap explained and old country cleared");
    p openCJ\country::applyLookup("ZZ");
    check(p.country_reason == "unsupported_country_code", "unmapped country explained");
    row = openCJ\scoreboard::connectingRow("Downloading");
    check(row["flag"] == unknown.material && row["flagSelector"] == unknown.selector &&
              row["rank"] == "",
          "connecting row has neutral flag and no invented rank");
    printf("GEOIP SELFTEST COMPLETE failures=" + level.geoFailures + "\n");
}
check(ok, label)
{
    if(!ok)
    {
        level.geoFailures++;
        printf("GEOIP SELFTEST FAIL " + label + "\n");
    }
}
