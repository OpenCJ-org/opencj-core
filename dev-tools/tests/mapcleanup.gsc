// Exercise literal prose, localization keys, mixed messages, and repeated normalization.
main()
{
    wait 1;
    level.mapHintFailures = 0;
    level.mapHintChecks = 0;

    coloredText = "^1Welcome ^2to Bouncer Training";
    literalMessage = constructMessage(coloredText);
    check(openCJ\mapCleanup::_literalMapHint(coloredText) == literalMessage,
          "colored map prose receives the engine literal marker");
    check(openCJ\mapCleanup::_literalMapHint(literalMessage) == literalMessage,
          "already marked prose is unchanged");
    check(openCJ\mapCleanup::_literalMapHint("PLATFORM_USE") == "PLATFORM_USE",
          "localization keys are unchanged");

    mixedMessage = constructMessage(&"PLATFORM_USE", " the switch");
    check(openCJ\mapCleanup::_literalMapHint(mixedMessage) == mixedMessage,
          "mixed localized and literal text is unchanged");
    check(openCJ\mapCleanup::_literalMapHint("") == "", "empty hints stay empty");

    printf("MAP HINT SELFTEST COMPLETE failures=" + level.mapHintFailures +
           " checks=" + level.mapHintChecks + "\n");
}

check(passed, scenario)
{
    level.mapHintChecks++;
    if(!passed)
    {
        level.mapHintFailures++;
    }
    printf("MAP HINT SELFTEST " + scenario + ": " + passed + "\n");
}
