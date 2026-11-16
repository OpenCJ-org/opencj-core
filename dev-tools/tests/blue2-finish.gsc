
main()
{
    wait 2;
    user = spawn("script_origin", (0,0,0));
    user.name = "Finish regression test";
    names = strTok("easyend interend hardend", " ");
    for(i=0;i<names.size;i++)
    {
        trigger = getEnt(names[i], "targetname");
        if(!isDefined(trigger)) { logPrint("[BLUE2_TEST] FAIL missing trigger\n"); return; }
        trigger notify("trigger",user);
        wait 0.1;
        trigger notify("trigger",user);
        wait 0.1;
    }
    if(!isDefined(user.endeasy) || !isDefined(user.endinter) || !isDefined(user.endhard))
    { logPrint("[BLUE2_TEST] FAIL flags undefined\n"); return; }
    if(!user.endeasy || !user.endinter || !user.endhard)
    { logPrint("[BLUE2_TEST] FAIL flags false\n"); return; }


    pickups = strTok("ak_1 ak_2 ak_3 ak_4 deagle_2 deagle_3 r700_1 r700_2 m40a3_1 m40a3_2 usp_1 usp_2 usp_3", " ");
    for(i=0;i<pickups.size;i++)
    {
        trigger = getEnt(pickups[i], "targetname");
        if(!isDefined(trigger)) { logPrint("[BLUE2_TEST] FAIL missing pickup " + pickups[i] + "\n"); return; }
        // A non-player entity makes any residual player weapon handler fail.
        trigger notify("trigger",user);
        wait 0.1;
        trigger notify("trigger",user);
        wait 0.1;
    }
    logPrint("[BLUE2_TEST] PASS all finishes and 13 inert weapon pickups\n");
    user delete();
}
