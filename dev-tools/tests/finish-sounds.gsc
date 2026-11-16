main()
{
    wait 2;
    level.finishSoundFailures=0;
    check(openCJ\finishSounds::soundForResult(undefined)=="opencj_route_complete","query failure fallback");
    rows=[];
    check(openCJ\finishSounds::soundForResult(rows)=="opencj_route_complete","empty result fallback");
    rows[0]=[];rows[0][0]=undefined;
    check(openCJ\finishSounds::soundForResult(rows)=="opencj_route_complete","null result fallback");
    rows[0][0]="0";
    check(openCJ\finishSounds::soundForResult(rows)=="opencj_route_complete","ordinary finish");
    rows[0][0]="1";
    check(openCJ\finishSounds::soundForResult(rows)=="opencj_route_record","top three finish");
    query=openCJ\finishSounds::recordQuery(100);
    // Shared SQL can change length; the requested run must still affect the query.
    otherQuery=openCJ\finishSounds::recordQuery(101);
    check(isDefined(query) && query.size>0 && query!=otherQuery,"ranking query uses requested run");
    printf("[FINISH_QUERY]"+query+"\n");
    printf("FINISH SOUND SELFTEST COMPLETE failures="+level.finishSoundFailures+"\n");
}
check(value,label)
{
    if(!value){level.finishSoundFailures++;printf("FINISH SOUND SELFTEST FAIL "+label+"\n");}
    else printf("FINISH SOUND SELFTEST PASS "+label+"\n");
}
