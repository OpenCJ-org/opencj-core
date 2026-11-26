// TODO this class is currently Linux-specific. A Windows port needs to be added

#include "shared.hpp"

#include <stdlib.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <errno.h>

// The bridge creates this socket. Without the variable this server does not use Discord,
// so several servers on one host each need their own bridge and socket.
#define DISCORD_SOCKET_ENVIRONMENT_VARIABLE "OPENCJ_DISCORD_SOCKET"

// Both directions send one event per line. Lines are at most this long, including the
// line break; discord-integration/opencj_listener.py relies on the same limit.
#define DISCORD_LINE_MAX_BYTES      512
// Fields of a game event are separated by the ASCII unit separator (see opencj_events.py).
#define DISCORD_FIELD_SEPARATOR     '\x1f'
// Room for any 32-bit int in decimal: "-2147483648" plus the terminating NUL.
#define INT_DECIMAL_TEXT_BYTES      12

// These events are from the game to Discord
typedef enum
{
    PLAYER_MESSAGE          = 0,
    MAP_STARTED             = 1,
    PLAYER_COUNT_CHANGED    = 2,
    PLAYER_JOINED           = 3,
    PLAYER_LEFT             = 4,
    RUN_FINISHED            = 5,
    PLAYER_RENAMED          = 6,
} eGameEvent_t;

static int g_fileDescriptor = -1;
static bool g_hasLogged = false;

// Discord lines can arrive in pieces or several at once; keep bytes until a line is complete.
static char g_receiveBuffer[DISCORD_LINE_MAX_BYTES * 2];
static size_t g_receiveLength = 0;
// Set after an overlong line, so the rest of it is skipped up to the next line break.
static bool g_isDiscardingLine = false;

static void closeConnection()
{
    close(g_fileDescriptor);
    g_fileDescriptor = -1;
    g_receiveLength = 0;
    g_isDiscardingLine = false;
}

// Returns the socket path, or NULL when this server should not use Discord.
static const char *getSocketPath()
{
    const char *socketPath = getenv(DISCORD_SOCKET_ENVIRONMENT_VARIABLE);
    if ((socketPath == NULL) || (socketPath[0] == '\0'))
    {
        return NULL;
    }

    if (strlen(socketPath) >= sizeof(((struct sockaddr_un *)0)->sun_path))
    {
        if (!g_hasLogged)
        {
            Com_PrintError(CON_CHANNEL_ERROR, DISCORD_SOCKET_ENVIRONMENT_VARIABLE " is too long for a socket path\n");
            g_hasLogged = true;
        }
        return NULL;
    }

    return socketPath;
}

static int setupAndConnect()
{
    const char *socketPath = getSocketPath();
    if (socketPath == NULL)
    {
        return -1;
    }

    // Check if we need to close the socket first
    if (g_fileDescriptor != -1)
    {
        // Socket error, disconnect
        closeConnection();
        Com_PrintError(CON_CHANNEL_ERROR, "Lost connection with Discord socket\n");
        g_hasLogged = false;
    }

    g_fileDescriptor = socket(PF_UNIX, SOCK_STREAM | SOCK_NONBLOCK, 0);
    if (g_fileDescriptor >= 0)
    {
        struct sockaddr_un server;
        memset(&server, 0, sizeof(server));
        server.sun_family = AF_UNIX;
        strncpy(server.sun_path, socketPath, sizeof(server.sun_path) - 1);
        if (connect(g_fileDescriptor, (struct sockaddr *)&server, sizeof(struct sockaddr_un)) >= 0)
        {
            Com_Printf(CON_CHANNEL_SYSTEM, "Successfully connected to Discord socket\n");
            g_hasLogged = false;
        }
        else
        {
            closeConnection();
            if (!g_hasLogged)
            {
                Com_PrintWarning(CON_CHANNEL_SYSTEM, "Could not connect to Discord socket\n");
                g_hasLogged = true;
            }
        }
    }
    else
    {
        g_fileDescriptor = -1;
        Com_PrintError(CON_CHANNEL_ERROR, "Could not setup Discord socket\n");
    }

    return g_fileDescriptor;
}

void Gsc_Discord_Connect()
{
    if (g_fileDescriptor == -1)
    {
        (void)setupAndConnect();
    }
    else
    {
        // getsockopt succeeds on a broken socket too; the pending error is in socketError.
        int socketError = 0;
        socklen_t socketErrorLength = sizeof(socketError);
        int result = getsockopt(g_fileDescriptor, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength);
        if ((result == 0) && (socketError == 0))
        {
            stackPushInt(g_fileDescriptor);
            return;
        }
        else
        {
            // Try to re-connect
            (void)setupAndConnect();
        }
    }

    if (g_fileDescriptor == -1)
    {
        stackPushUndefined();
    }
    else
    {
        stackPushInt(g_fileDescriptor);
    }
}

// Moves the first complete line out of the receive buffer into line (without its line break).
// Returns false when no complete line is buffered yet.
static bool takeBufferedLine(char *line, size_t lineSize)
{
    while (true)
    {
        char *lineEnd = (char *)memchr(g_receiveBuffer, '\n', g_receiveLength);
        if (lineEnd == NULL)
        {
            if (g_receiveLength == sizeof(g_receiveBuffer))
            {
                // No line break in a full buffer: the stream is out of step. Skip to the next line.
                Com_PrintWarning(CON_CHANNEL_SYSTEM, "Dropping overlong Discord message\n");
                g_receiveLength = 0;
                g_isDiscardingLine = true;
            }
            return false;
        }

        size_t lineLength = (size_t)(lineEnd - g_receiveBuffer);
        size_t consumedLength = lineLength + 1;
        bool isDiscardedLine = g_isDiscardingLine;
        g_isDiscardingLine = false;
        if (!isDiscardedLine)
        {
            size_t copiedLength = lineLength;
            if (copiedLength > lineSize - 1)
            {
                copiedLength = lineSize - 1;
            }
            memcpy(line, g_receiveBuffer, copiedLength);
            line[copiedLength] = '\0';
        }
        memmove(g_receiveBuffer, g_receiveBuffer + consumedLength, g_receiveLength - consumedLength);
        g_receiveLength -= consumedLength;
        if (!isDiscardedLine)
        {
            return true;
        }
    }
}

// Returns the next Discord chat line, or undefined when none is waiting.
// GSC calls this repeatedly, so one call returns at most one line.
void Gsc_Discord_GetEvent()
{
    char line[DISCORD_LINE_MAX_BYTES];
    if (g_fileDescriptor == -1)
    {
        stackPushUndefined();
        return;
    }

    if (takeBufferedLine(line, sizeof(line)))
    {
        stackPushString(line);
        return;
    }

    ssize_t result = read(g_fileDescriptor, g_receiveBuffer + g_receiveLength,
                          sizeof(g_receiveBuffer) - g_receiveLength);
    int error = errno;
    if (result > 0)
    {
        g_receiveLength += (size_t)result;
        if (takeBufferedLine(line, sizeof(line)))
        {
            stackPushString(line);
            return;
        }
    }
    else if ((result == 0) || ((error != EAGAIN) && (error != EWOULDBLOCK)))
    {
        // Read returned EOF or another error
        // Connection lost. Try to re-connect
        (void)setupAndConnect();
    }

    stackPushUndefined();
}

// Copies a field into the event line, replacing characters that would break the line framing.
static void appendField(char *eventLine, size_t eventLineSize, size_t *eventLength, const char *field)
{
    if (*eventLength < eventLineSize - 1)
    {
        eventLine[*eventLength] = DISCORD_FIELD_SEPARATOR;
        (*eventLength)++;
    }

    for (const char *character = field; *character != '\0'; character++)
    {
        if (*eventLength >= eventLineSize - 1)
        {
            break;
        }

        char safeCharacter = *character;
        if ((safeCharacter == '\n') || (safeCharacter == '\r') || (safeCharacter == DISCORD_FIELD_SEPARATOR))
        {
            safeCharacter = ' ';
        }
        eventLine[*eventLength] = safeCharacter;
        (*eventLength)++;
    }
    eventLine[*eventLength] = '\0';
}

static void appendIntField(char *eventLine, size_t eventLineSize, size_t *eventLength, int value)
{
    char valueText[INT_DECIMAL_TEXT_BYTES];
    snprintf(valueText, sizeof(valueText), "%d", value);
    appendField(eventLine, eventLineSize, eventLength, valueText);
}

// Checks that parameters 1..expectedTypeCount have the expected types.
static bool hasParamTypes(const int *expectedTypes, int expectedTypeCount)
{
    if (Scr_GetNumParam() != (expectedTypeCount + 1))
    {
        return false;
    }

    for (int paramIndex = 0; paramIndex < expectedTypeCount; paramIndex++)
    {
        int paramType = (int)stackGetParamType(paramIndex + 1);
        if (paramType != expectedTypes[paramIndex])
        {
            return false;
        }
    }
    return true;
}

static const char *getStringParam(int paramIndex)
{
    char *value = NULL;
    stackGetParamString(paramIndex, &value);
    return value;
}

// Builds the event line for gameEventType from the GSC parameters.
// Returns false (after reporting a script error where useful) when nothing should be sent.
static bool buildEventLine(int gameEventType, char *eventLine, size_t eventLineSize)
{
    // The trailing line break is added by the caller, so keep one byte free for it.
    size_t fieldSpace = eventLineSize - 1;
    size_t eventLength = 0;
    eventLine[0] = '\0';
    eventLength = (size_t)snprintf(eventLine, fieldSpace, "%d", gameEventType);

    switch (gameEventType)
    {
        case PLAYER_MESSAGE:
        case PLAYER_RENAMED:
        {
            const int expectedTypes[] = {STACK_STRING, STACK_STRING};
            if (!hasParamTypes(expectedTypes, 2))
            {
                stackError("Expected 3 arguments: eventType (int), two strings (name and message, or old and new name)");
                return false;
            }

            const char *firstText = getStringParam(1);
            const char *secondText = getStringParam(2);
            if ((firstText == NULL) || (secondText == NULL))
            {
                return false;
            }
            appendField(eventLine, fieldSpace, &eventLength, firstText);
            appendField(eventLine, fieldSpace, &eventLength, secondText);
        } break;

        case MAP_STARTED:
        case PLAYER_JOINED:
        case PLAYER_LEFT:
        {
            const int expectedTypes[] = {STACK_STRING};
            if (!hasParamTypes(expectedTypes, 1))
            {
                stackError("Expected 2 arguments: eventType (int), name (string)");
                return false;
            }

            const char *text = getStringParam(1);
            if (text == NULL)
            {
                return false;
            }
            appendField(eventLine, fieldSpace, &eventLength, text);
        } break;

        case PLAYER_COUNT_CHANGED:
        {
            const int expectedTypes[] = {STACK_INT};
            if (!hasParamTypes(expectedTypes, 1))
            {
                stackError("Expected 2 arguments: eventType (int), playerCount (int)");
                return false;
            }

            int playerCount = 0;
            stackGetParamInt(1, &playerCount);
            appendIntField(eventLine, fieldSpace, &eventLength, playerCount);
        } break;

        case RUN_FINISHED:
        {
            const int expectedTypes[] = {STACK_STRING, STACK_INT, STACK_STRING, STACK_STRING, STACK_STRING};
            if (!hasParamTypes(expectedTypes, 5))
            {
                stackError("Expected 6 arguments: event (int), name (string), runID (int), time (string), mapName (string), route (string)");
                return false;
            }

            const char *playerName = getStringParam(1);
            int runID = -1;
            stackGetParamInt(2, &runID);
            const char *timeStr = getStringParam(3);
            const char *mapName = getStringParam(4);
            const char *routeName = getStringParam(5);
            bool hasEveryText = (playerName != NULL) && (timeStr != NULL) && (mapName != NULL) && (routeName != NULL);
            // runID starts at -1 above, so -1 here means no run ID was read (kept from the old check).
            bool hasRun = (runID != -1);
            if (!hasEveryText || !hasRun)
            {
                return false;
            }
            appendField(eventLine, fieldSpace, &eventLength, playerName);
            appendIntField(eventLine, fieldSpace, &eventLength, runID);
            appendField(eventLine, fieldSpace, &eventLength, timeStr);
            appendField(eventLine, fieldSpace, &eventLength, mapName);
            appendField(eventLine, fieldSpace, &eventLength, routeName);
        } break;

        default:
        {
            stackError("Unknown Discord event type");
            return false;
        }
    }

    eventLine[eventLength] = '\n';
    eventLine[eventLength + 1] = '\0';
    return true;
}

void Gsc_Discord_OnEvent() // Push an event to Discord
{
    // Only process game events if Discord socket is connected
    if (g_fileDescriptor == -1)
    {
        return;
    }

    if ((Scr_GetNumParam() < 1) || (stackGetParamType(0) != STACK_INT))
    {
        stackError("Expected at least 1 argument: eventType (int)");
        return;
    }

    int gameEventType = -1;
    stackGetParamInt(0, &gameEventType);

    char eventLine[DISCORD_LINE_MAX_BYTES];
    if (!buildEventLine(gameEventType, eventLine, sizeof(eventLine)))
    {
        return;
    }

    size_t eventLength = strlen(eventLine);
    ssize_t result = write(g_fileDescriptor, eventLine, eventLength);
    int error = errno;
    if (result == (ssize_t)eventLength)
    {
        return;
    }

    if ((result == -1) && ((error == EAGAIN) || (error == EWOULDBLOCK)))
    {
        // Nothing was written, so the stream is still in step; this event is lost.
        Com_PrintWarning(CON_CHANNEL_SYSTEM, "Could not transmit event (full)\n");
        return;
    }

    // An error, or only part of the line was written. A partial line would make the bridge
    // misread the next event, so start a fresh connection (the bridge drops partial lines).
    (void)setupAndConnect();
}
