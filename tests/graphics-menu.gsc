
main()
{
    wait 2;
    if(getCvar("db_base") != "opencj_demo_test_20260924_cod") return;
    level.graphicsTestFailures = 0;
    bot = addTestClient();
    if(!isDefined(bot)) { printf("GRAPHICS TEST FAIL: no bot\n"); return; }
    wait 1;
    row = openCJ\mySQL::mysqlSyncQuery("SELECT MIN(playerID) FROM playerInformation");
    bot.login_playerID = int(row[0][0]);
    bot.settingsLoaded = true;
    bot.settingValues["fov"] = 90;
    bot send("begin");
    bot send("fov:100");
    check(bot.settingValues["fov"] == 90, "staging does not apply");
    bot send("cancel");
    bot send("apply");
    check(bot.settingValues["fov"] == 90, "cancel discards changes");
    bot send("begin");
    bot send("fov:100");
    bot send("fov:999");
    bot send("apply");
    check(bot.settingValues["fov"] == 100, "Apply uses valid selection and rejects out-of-range value");
    bot send("fov:110");
    bot send("begin");
    bot send("apply");
    check(bot.settingValues["fov"] == 100, "reopening clears stale changes");
    bot send("gfx_lod:2");
    bot send("gfx_lod:3");
    bot send("apply");
    check(bot.settingValues["gfx_lod"] == -1, "Current LOD preserves original settings");

    bot send("hideradius:4096");
    bot send("hideradius:4097");
    bot send("apply");
    check(bot.settingValues["hideradius"] == 4096, "4096 radius accepted; larger value rejected");
    bot send("gfx_hidemode:2");
    bot send("apply");
    check(bot.settingValues["hideall"], "Everyone uses existing hide-all setting");
    bot send("gfx_hidemode:1");
    bot send("hideradius:0");
    bot send("apply");
    check(!bot.settingValues["hideall"] && bot.settingValues["hidenear"], "Nearby restores radius-based hiding");
    check(bot.settingValues["hideradius"] == 4096, "zero radius rejected; existing radius preserved");
    bot send("gfx_specular:2");
    bot send("gfx_shadows:2");
    bot send("gfx_normal:1");
    bot send("gfx_detail:1");
    bot send("gfx_blur:0");
    bot send("gfx_entities:0");
    bot send("gfx_distance:8192");
    bot send("apply");
    check(bot.settingValues["gfx_specular"] == 2 && bot.settingValues["gfx_shadows"] == 2, "forced effects apply");
    check(bot.settingValues["gfx_distance"] == 8192 && bot.settingValues["gfx_entities"] == 0, "new rendering settings apply");
    bot send("gfx_specular:1");
    bot send("gfx_shadows:1");
    bot send("gfx_blur:1");
    bot send("gfx_distance:0");
    bot send("apply");
    check(bot.settingValues["gfx_specular"] == 1 && bot.settingValues["gfx_shadows"] == 1, "effects return to map mode");
    check(bot.settingValues["gfx_distance"] == 0, "infinite removes far-clip override");
    printf("GRAPHICS TEST COMPLETE failures=" + level.graphicsTestFailures + "\n");
}
send(response)
{
    self notify("menuresponse", "opencj_graphics", response);
    wait 0.1;
}
check(ok, label)
{
    if(!ok) level.graphicsTestFailures++;
    printf("GRAPHICS TEST " + ok + ": " + label + "\n");
}
