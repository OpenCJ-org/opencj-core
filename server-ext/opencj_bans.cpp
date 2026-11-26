// Connection bans: a bounded in-memory list of banned IP addresses and CoD4x player
// IDs. The engine checks it while a player connects (sv_client.c), before the game
// sees the player's name, so a banned player never shows up in game. GSC refills the
// list from the playerBans table; see server-gsc/opencj/moderation.gsc.

#include "shared.hpp"

#ifdef COD4

#include "opencj_bans.hpp"

extern "C" {
    #include "../cod4x-server/src/qcommon.h"
    #include "../cod4x-server/src/sys_net.h"
    #include "../cod4x-server/src/sapi.h"
}

#include <stdio.h>
#include <string.h>
#include <time.h>

// Matches connectionBanCapacity() in moderation.gsc, which never sends more.
#define CONNECTION_BAN_CAPACITY         1024
// playerBans.bannedClientID and playerBans.reason, plus the terminating NUL.
#define CONNECTION_BAN_CLIENT_ID_BYTES  33
#define CONNECTION_BAN_REASON_BYTES     151
// Longest dotted IPv4 address "255.255.255.255" plus the terminating NUL.
#define IPV4_TEXT_BYTES                 16
// moderation.gsc sends this instead of a number of seconds for permanent bans.
#define PERMANENT_BAN_SECONDS_LEFT      -1
// Room for any 64-bit player ID as text.
#define CLIENT_ID_TEXT_BYTES            64

typedef struct
{
    int banID;
    bool hasAddress;
    netadr_t address;
    char clientID[CONNECTION_BAN_CLIENT_ID_BYTES];
    bool isPermanent;
    time_t expiresAt;
    char reason[CONNECTION_BAN_REASON_BYTES];
} connectionBan_t;

static connectionBan_t connectionBans[CONNECTION_BAN_CAPACITY];
static int connectionBanCount = 0;

// Only plain dotted IPv4 text is accepted, so parsing can never start a DNS lookup.
static bool parseIPv4Address(const char *addressText, netadr_t *address)
{
    size_t textLength = strlen(addressText);
    if (textLength == 0 || textLength >= IPV4_TEXT_BYTES)
    {
        return false;
    }
    for (size_t i = 0; i < textLength; i++)
    {
        bool isDigit = addressText[i] >= '0' && addressText[i] <= '9';
        if (!isDigit && addressText[i] != '.')
        {
            return false;
        }
    }
    return NET_StringToAdr(addressText, address, NA_IP) != 0;
}

static bool isBanActive(const connectionBan_t *ban, time_t now)
{
    return ban->isPermanent || ban->expiresAt > now;
}

// The text the refused player sees, including how long the ban still lasts.
static void describeBan(const connectionBan_t *ban, time_t now, char *message, int messageLength)
{
    if (ban->isPermanent)
    {
        snprintf(message, messageLength, "You are permanently banned: %s", ban->reason);
        return;
    }
    const long secondsPerDay = 24 * 60 * 60;
    const long secondsPerHour = 60 * 60;
    const long secondsPerMinute = 60;
    long secondsLeft = (long)(ban->expiresAt - now);
    long days = secondsLeft / secondsPerDay;
    long hours = (secondsLeft % secondsPerDay) / secondsPerHour;
    // Round minutes up so the last minute of a ban does not read as zero.
    long minutes = ((secondsLeft % secondsPerHour) + secondsPerMinute - 1) / secondsPerMinute;
    snprintf(message, messageLength, "You are banned for another %ldd %ldh %ldm: %s", days, hours,
             minutes, ban->reason);
}

// clearConnectionBans(): empty the list before GSC refills it.
void Gsc_Bans_Clear()
{
    connectionBanCount = 0;
}

// setConnectionBan(banID, ip, clientID, secondsLeft, reason): add one active ban.
// ip and clientID may be empty, but not both. secondsLeft is -1 for a permanent ban.
// Returns false, without changing the list, for invalid input or a full list.
void Gsc_Bans_Set()
{
    int banID;
    char *addressText;
    char *clientID;
    int secondsLeft;
    char *reason;
    if (!stackGetParams("issis", &banID, &addressText, &clientID, &secondsLeft, &reason))
    {
        stackPushBool(false);
        return;
    }
    if (connectionBanCount >= CONNECTION_BAN_CAPACITY)
    {
        stackPushBool(false);
        return;
    }
    bool isPermanent = secondsLeft == PERMANENT_BAN_SECONDS_LEFT;
    if (!isPermanent && secondsLeft <= 0)
    {
        stackPushBool(false);
        return;
    }

    connectionBan_t ban;
    memset(&ban, 0, sizeof(ban));
    ban.banID = banID;
    ban.hasAddress = addressText[0] != '\0' && parseIPv4Address(addressText, &ban.address);
    bool hasClientID = clientID[0] != '\0' && strlen(clientID) < sizeof(ban.clientID);
    if (hasClientID)
    {
        strncpy(ban.clientID, clientID, sizeof(ban.clientID) - 1);
    }
    if (!ban.hasAddress && !hasClientID)
    {
        stackPushBool(false);
        return;
    }
    ban.isPermanent = isPermanent;
    ban.expiresAt = Com_GetRealtime() + secondsLeft;
    strncpy(ban.reason, reason, sizeof(ban.reason) - 1);

    connectionBans[connectionBanCount] = ban;
    connectionBanCount++;
    stackPushBool(true);
}

extern "C" int opencj_getAddressBanMessage(struct netadr_s *address, char *message,
                                           int messageLength)
{
    time_t now = Com_GetRealtime();
    for (int i = 0; i < connectionBanCount; i++)
    {
        const connectionBan_t *ban = &connectionBans[i];
        if (ban->hasAddress && isBanActive(ban, now) &&
            NET_CompareBaseAdr(address, (netadr_t *)&ban->address))
        {
            describeBan(ban, now, message, messageLength);
            return 1;
        }
    }
    return 0;
}

// GSC records getPlayerID(), which formats the engine's player ID with
// SV_SApiSteamIDToString; compare in that same text form.
extern "C" int opencj_getClientBanMessage(uint64_t playerID, uint64_t steamID, char *message,
                                          int messageLength)
{
    char playerIDText[CLIENT_ID_TEXT_BYTES];
    char steamIDText[CLIENT_ID_TEXT_BYTES];
    SV_SApiSteamIDToString(playerID, playerIDText, sizeof(playerIDText));
    SV_SApiSteamIDToString(steamID, steamIDText, sizeof(steamIDText));
    bool hasPlayerID = playerID != 0;
    bool hasSteamID = steamID != 0;

    time_t now = Com_GetRealtime();
    for (int i = 0; i < connectionBanCount; i++)
    {
        const connectionBan_t *ban = &connectionBans[i];
        if (ban->clientID[0] == '\0' || !isBanActive(ban, now))
        {
            continue;
        }
        bool matchesPlayerID = hasPlayerID && strcmp(ban->clientID, playerIDText) == 0;
        bool matchesSteamID = hasSteamID && strcmp(ban->clientID, steamIDText) == 0;
        if (matchesPlayerID || matchesSteamID)
        {
            describeBan(ban, now, message, messageLength);
            return 1;
        }
    }
    return 0;
}

#endif // COD4
