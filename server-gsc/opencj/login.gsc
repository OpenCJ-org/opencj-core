#include openCJ\util;

onPlayerConnected()
{
    self thread _tryLogin();
}

onPlayerCommand(args)
{
    return self openCJ\loginHelper::onPlayerCommand(args);
}

isLoggedIn()
{
    return isDefined(self.login_playerID);
}

getPlayerID()
{
    return self.login_playerID;
}

_tryLogin()
{
    self endon("disconnect");
    // Saved graphics settings can open command menus; startup owns that channel
    // until it has captured map defaults and completed FPS/scoreboard setup.
    self openCJ\clientInit::waitUntilFinished();

    uid = self openCJ\loginHelper::requestUID();
    if(!isDefined(uid))
    {
        // This client has no usable stored credential, so it has no account to lose.
        self createNewAccount();
        return;
    }

    lookup = self _lookUpAccountUntilAnswered(uid);
    if(lookup == "found")
    {
        self thread openCJ\playerNames::_storeNewName(self.name);
        self openCJ\settings::loadSettingsFromDatabase();
    }
    else
    {
        // The database answered that this credential belongs to no account.
        self createNewAccount();
    }
}

// Repeat the account lookup until the database answers "found" or "unknown".
// An unavailable database must never lead to a new account: storing the new
// credential would overwrite the player's existing one in their config file.
// Each attempt is one bounded read; waiting ends when the player disconnects.
_lookUpAccountUntilAnswered(uid)
{
    self endon("disconnect");
    retryDelaysSeconds = [];
    retryDelaysSeconds[0] = 2;
    retryDelaysSeconds[1] = 5;
    retryDelaysSeconds[2] = 10;
    steadyRetryDelaySeconds = 30;

    for(attempt = 0; true; attempt++)
    {
        lookup = self _getPlayerInformation(uid);
        if(lookup != "unavailable")
        {
            if(attempt > 0 && lookup == "found")
            {
                self iprintlnbold("Account database reached. Welcome back!");
            }
            return lookup;
        }
        if(attempt == 0)
        {
            printf("Login: account database unavailable, retrying for player " +
                   self getEntityNumber() + "\n");
            self iprintlnbold(
                "Cannot reach the account database. Retrying; until then nothing is saved.");
        }
        delaySeconds = steadyRetryDelaySeconds;
        if(attempt < retryDelaysSeconds.size)
        {
            delaySeconds = retryDelaysSeconds[attempt];
        }
        wait delaySeconds;
    }
}

// Identify the account for a stored credential and apply its login state.
// Returns "found", "unknown" (the database answered without a match) or
// "unavailable" (no answer, so nothing may be concluded about the account).
_getPlayerInformation(uid)
{
    self endon("disconnect");
    query = "SELECT playerID, permissions, IF(mutedUntil < NOW(), NULL, TIMESTAMPDIFF(SECOND, NOW(), mutedUntil)) FROM playerInformation WHERE playerID = (SELECT getPlayerID(" + int(uid[0]) + ", " + int(uid[1])  + ", " + int(uid[2]) + ", " + int(uid[3]) + "))";
    result = openCJ\mySQL::_request(query, level.sqlConstants.policyRead, "", "",
                                    level.sqlConstants.defaultQueueWaitMs, true);
    if(!isDefined(result) || result.status != level.sqlConstants.outcomeOK ||
       !isDefined(result.rows))
    {
        return "unavailable";
    }
    rows = result.rows;
    if(hasResult(rows))
    {
        // Check bans before the account is marked logged in, so a banned player never
        // triggers the connect message or any other login side effect.
        if(self openCJ\moderation::enforceBanAtLogin(int(rows[0][0])))
        {
            self waittill("disconnect");
        }
        self.login_playerID = int(rows[0][0]);
        self openCJ\playerNames::onAccountIdentified();
        self openCJ\mapPlays::onAccountIdentified();
        self openCJ\permissions::setPermissions(int(rows[0][1]));
        if(isDefined(rows[0][2])) //muted until [seconds] into future
        {
            self openCJ\chat::applyMute(true);
            self openCJ\chat::unmuteAfterTime(int(rows[0][2]));
        }
        return "found";
    }
    return "unknown";
}

createNewAccount()
{
    self endon("disconnect");

    for(i = 0; i < 10; i++)
    {
        uid = [];
        for(j = 0; j < 4; j++)
        {
            uid[j] = createRandomInt();
            if(!isDefined(uid[j]))
            {
                // Never fall back to a guessable credential.
                printf("ERROR: secure random source unavailable; account not created\n");
                self iprintlnbold("Cannot create an account right now. Please try reconnecting");
                return;
            }
        }

        query = "SELECT createNewAccount(" + uid[0] + ", " + uid[1] + ", " + uid[2] + ", " + uid[3] + ", '" + openCJ\mySQL::escapeString(self.name) + "')";
        rows = self openCJ\mySQL::mysqlAsyncQuery(query);
        if(hasResult(rows))
        {
            if(self _getPlayerInformation(uid) == "found")
            {
                self openCJ\loginHelper::storeUID(uid);
                // Before settings report the login, so the first spawn sees the introduction
                self openCJ\tutorial::onNewAccount();
                self openCJ\settings::onNewAccount();
                self iprintlnbold("Welcome to OpenCJ!");
            }
            else
            {
                //this should not happen unless mysql server dies during these queries.
                self iprintlnbold("Cannot create an account right now. Please try reconnecting");
            }
            return;
        }
        else
        {
            printf("ERROR: Failed to create account\n");
        }
    }
    self iprintlnbold("Cannot create an account right now. Please try reconnecting");
}
