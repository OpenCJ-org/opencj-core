menu(i,tick)
{
    level.capPending++;
    token=self openCJ\mySQL::beginMenuRead("board");
    if(self openCJ\mySQL::menuReadCurrent(token))
    {
        if(i%2==0)q=LBQUERY;
        else q=RNQUERY;
        rows=self openCJ\mySQL::mysqlAsyncMenuQuery(q,"board");
        if(self openCJ\mySQL::menuReadCurrent(token))check(isDefined(rows),"current menu query");
    }
    level.capPending--;
}

auditRead(i)
{
    level.capPending++;
    if(i%3==0)q=HUDQUERY;
    else if(i%3==1)q=openCJ\finishSounds::podiumQuery(10000+i);
    else q=openCJ\recordNotices::finishQuery(10000+i);
    rows=self openCJ\mySQL::mysqlAsyncRead(q);
    check(isDefined(rows),"record and finish query");
    q=openCJ\recordNotices::checkpointQuery(10000+i,1,"mix",0,0,1,0,"time");
    rows=self openCJ\mySQL::mysqlAsyncRead(q);
    check(isDefined(rows),"checkpoint notice query");
    level.capPending--;
}
