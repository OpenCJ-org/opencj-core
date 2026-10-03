
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
    logPrint("[BLUE2_TEST] PASS all three finishes, first and repeated trigger\n");
    user delete();
}
