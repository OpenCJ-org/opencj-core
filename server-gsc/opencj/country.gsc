#include openCJ\util;

onPlayerConnect()
{
    self.country_connectMessageShown = false;
    self.country = "??";
    self.country_reason = "not_logged_in";
}

// Connecting/download-only clients do not query GeoIP or announce themselves.
onPlayerConnected()
{
}

beginLogin()
{
    if(!self openCJ\login::isLoggedIn())
    {
        return false;
    }
    if(isDefined(self.country_connectMessageShown) && self.country_connectMessageShown)
    {
        return false;
    }
    self.country_connectMessageShown = true;
    return true;
}

onPlayerLogin()
{
    if(!self beginLogin())
    {
        return;
    }
    iprintln("Player " + self.name + "^7 connected");
    self.country_reason = "lookup_pending";
    self thread _countryQuery();
}

_countryQuery()
{
    self endon("disconnect");
    ip = self getIP();
    if(!isDefined(ip) || ip == "")
    {
        self lookupFailed("missing_address");
        return;
    }
    if(isSubStr(ip, ":"))
    {
        self lookupFailed("unsupported_ip_family");
        return;
    }
    escaped = openCJ\mySQL::escapeString(ip);
    query =
        "SELECT geoIPLookupCode(IF(IS_IPV4('" + escaped + "'),INET_ATON('" + escaped + "'),NULL))";
    result = self openCJ\mySQL::_request(query, 1, "", "", 5000, true);
    if(!isDefined(result))
    {
        self lookupFailed("query_unavailable");
        return;
    }
    if(result.status != 0)
    {
        self lookupFailed("query_failed outcome=" + result.status + " mysql=" + result.error);
        return;
    }
    if(!isDefined(result.rows) || !isDefined(result.rows[0]) || !isDefined(result.rows[0][0]))
    {
        self lookupFailed("empty_query_result");
        return;
    }
    self applyLookup(result.rows[0][0]);
    if(self.country_reason != "ok")
    {
        self logFailure();
    }
}

// Also used by isolated tests to exercise the actual result-to-icon path.
applyLookup(value)
{
    flag = openCJ\flagAtlas::resolve(value);
    if(flag.known)
    {
        self.country = value;
        self.country_reason = "ok";
    }
    else
    {
        self.country = "??";
        self.country_reason = "unsupported_country_code";
        if(isSubStr(
               " invalid_ip non_public_ip database_unavailable range_not_found country_not_reported ",
               " " + value + " "))
        {
            self.country_reason = value;
        }
    }
    level.scoreboardNextUpdate = 0;
}

lookupFailed(reason)
{
    self.country = "??";
    self.country_reason = reason;
    level.scoreboardNextUpdate = 0;
    self logFailure();
}

logFailure()
{
    // One attempt per authenticated connection. No raw player IP or SQL in logs.
    printf("OpenCJ GeoIP: slot=" + self getEntityNumber() + " playerID=" +
           self openCJ\login::getPlayerID() + " fallback=" + self.country_reason + "\n");
}

getCountry()
{
    if(!isDefined(self.country))
    {
        return "??";
    }
    return self.country;
}
