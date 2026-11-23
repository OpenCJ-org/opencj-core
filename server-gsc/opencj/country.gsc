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

// Claim the single announcement and lookup attempt for this authenticated connection.
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

// Keep raw addresses inside the lookup; expose only the country or a fallback reason.
_countryQuery()
{
    self endon("disconnect");
    ipv4Address = self getIP();
    if(!isDefined(ipv4Address) || ipv4Address == "")
    {
        self lookupFailed("missing_address");
        return;
    }
    if(isSubStr(ipv4Address, ":"))
    {
        self lookupFailed("unsupported_ip_family");
        return;
    }
    escapedIPv4 = openCJ\mySQL::escapeString(ipv4Address);
    lookupQuery = "SELECT geoIPLookupCode(" + "IF(IS_IPV4('" + escapedIPv4 + "'), INET_ATON('" +
                  escapedIPv4 + "'), NULL))";
    queueWaitMs = 5000;
    retainRows = true;
    lookupResult = self openCJ\mySQL::_request(lookupQuery, level.sqlConstants.policyRead, "", "",
                                               queueWaitMs, retainRows);
    if(!isDefined(lookupResult))
    {
        self lookupFailed("query_unavailable");
        return;
    }
    if(lookupResult.status != level.sqlConstants.outcomeOK)
    {
        self lookupFailed("query_failed outcome=" + lookupResult.status +
                          " mysql=" + lookupResult.error);
        return;
    }
    if(!isDefined(lookupResult.rows) || !isDefined(lookupResult.rows[0]) ||
       !isDefined(lookupResult.rows[0][0]))
    {
        self lookupFailed("empty_query_result");
        return;
    }
    countryCodeOrReason = lookupResult.rows[0][0];
    self applyLookup(countryCodeOrReason);
    if(self.country_reason != "ok")
    {
        self logFailure();
    }
}

// Apply a country code or database fallback reason and refresh the scoreboard.
applyLookup(lookupValue)
{
    countryFlag = openCJ\flagAtlas::resolve(lookupValue);
    if(countryFlag.known)
    {
        self.country = lookupValue;
        self.country_reason = "ok";
    }
    else
    {
        self.country = "??";
        self.country_reason = "unsupported_country_code";
        if(isSubStr(
               " invalid_ip non_public_ip database_unavailable range_not_found country_not_reported ",
               " " + lookupValue + " "))
        {
            self.country_reason = lookupValue;
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
