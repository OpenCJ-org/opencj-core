main()
{
    wait 1;
    failures = 0;
    raw = "^1Welcome ^2to Bouncer Training";
    fixed = openCJ\mapCleanup::_literalMapHint(raw);
    if(fixed != constructMessage(raw))
    {
        failures++;
    }
    if(openCJ\mapCleanup::_literalMapHint(fixed) != fixed)
    {
        failures++;
    }
    if(openCJ\mapCleanup::_literalMapHint("PLATFORM_USE") != "PLATFORM_USE")
    {
        failures++;
    }
    mixed = constructMessage(&"PLATFORM_USE", " the switch");
    if(openCJ\mapCleanup::_literalMapHint(mixed) != mixed)
    {
        failures++;
    }
    if(openCJ\mapCleanup::_literalMapHint("") != "")
    {
        failures++;
    }
    printf("MAP HINT SELFTEST COMPLETE failures=" + failures + "\n");
}
