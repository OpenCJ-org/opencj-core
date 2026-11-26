#include <unistd.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h> // For isalnum
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <sys/random.h>

#include "gsc_custom_utils.hpp"

#define SQL_MAX_QUERY_SIZE  (10 * 1024)

#ifdef __cplusplus
extern "C" {
#endif // __cplusplus

// Read-only directory enumeration, matching libcod's scandir contract.
void Gsc_Utils_ScanDir()
{
    char *directoryPath;
    if (!stackGetParams("s", &directoryPath))
    {
        stackPushUndefined();
        return;
    }
    DIR *directory = opendir(directoryPath);
    if (!directory)
    {
        stackPushUndefined();
        return;
    }
    stackMakeArray();
    while (dirent *entry = readdir(directory))
    {
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
        {
            continue;
        }
        stackPushString(entry->d_name);
        stackPushArrayNext();
    }
    closedir(directory);
}

#ifdef COD4
// Match SV_Map's fastfile lookup, including custom maps that are not loaded.
// The stock GSC mapExists() only searches the currently mounted BSP paths.
extern qboolean DB_FileExists(const char *filename, int ffdir);
// DB_BuildOSPath searches zone[/language] for 0 and usermaps/<map> for 2.
static const int FASTFILE_ZONE_DIRECTORY = 0;
static const int FASTFILE_USERMAP_DIRECTORY = 2;

void Gsc_Utils_MapExists()
{
    char *requestedMap;
    if (!stackGetParams("s", &requestedMap))
    {
        stackPushBool(false);
        return;
    }
    const size_t mapNameLength = strlen(requestedMap);
    if (!mapNameLength || mapNameLength >= MAX_QPATH)
    {
        stackPushBool(false);
        return;
    }
    char mapName[MAX_QPATH];
    for (size_t i = 0; i < mapNameLength; ++i)
    {
        unsigned char character = (unsigned char)requestedMap[i];
        bool isLetter = (character >= 'a' && character <= 'z') ||
                        (character >= 'A' && character <= 'Z');
        bool isDigit = character >= '0' && character <= '9';
        bool isSeparator = character == '_' || character == '-';
        if (!isLetter && !isDigit && !isSeparator)
        {
            stackPushBool(false);
            return;
        }
        mapName[i] = tolower(character);
    }
    mapName[mapNameLength] = '\0';
    // Load screens and shared zone assets are not selectable multiplayer maps.
    if (mapNameLength >= 5 && !strcmp(mapName + mapNameLength - 5, "_load"))
    {
        stackPushBool(false);
        return;
    }
    bool isUserMap = DB_FileExists(mapName, FASTFILE_USERMAP_DIRECTORY);
    bool isStockMap = !isUserMap && !strncmp(mapName, "mp_", 3) &&
                      DB_FileExists(mapName, FASTFILE_ZONE_DIRECTORY);
    stackPushBool(isUserMap || isStockMap);
}
#endif

void Gsc_Utils_Void(int entnum)
{
    (void)entnum; // Unused
}

void Gsc_Utils_constructMessage()
{
    int nrParams = Scr_GetNumParam();
    if (nrParams == 0)
    {
        Scr_Error("Usage: constructMessage(1 or more (localized) strings)\n");
        return;
    }

    /*
    int firstParmIndex
    int lastParmIndex
    const char *errorContext
    char *string
    unsigned int stringLimit
    */
   char buf[1024] = {0};
   Scr_ConstructMessageString(0, (nrParams - 1), "Combined string of constructMessage", buf, sizeof(buf));

   stackPushString(buf);
}

void Gsc_Utils_setConfigStringByIndex()
{
    int index = 0;
    stackGetParamInt(0, &index);
    char *value = NULL;
    stackGetParamString(1, &value);
    SV_SetConfigstring(index, value);
}

void Gsc_SV_GetConfigString()
{
    char buf[1024] = {0};
    int idx = 0;
    if (stackGetParamInt(0, &idx))
    {
        SV_GetConfigstring(idx, buf, sizeof(buf));
    }
    stackPushString(buf);
}

void Gsc_Utils_ZeroInt(int entnum)
{
    stackPushInt(0);
}

void Gsc_Utils_VoidFunc()
{
    stackPushUndefined();
}

// Validate the whole input before GSC converts it to a signed integer.
void Gsc_Utils_IsValidInt()
{
    char *text = NULL;
    if (!stackGetParamString(0, &text) || !text || isspace((unsigned char)text[0]))
    {
        stackPushBool(false);
        return;
    }

    errno = 0;
    char *end = NULL;
    long value = strtol(text, &end, 10);
    bool completeNumber = end != text && *end == '\0';
    bool withinIntegerRange = errno != ERANGE && value >= INT_MIN && value <= INT_MAX;
    stackPushBool(completeNumber && withinIntegerRange);
}

// Nine significant digits round-trip every finite IEEE-754 float used by GSC.
void Gsc_Utils_FloatToPreciseString()
{
    float value;
    if (!stackGetParams("f", &value))
    {
        stackPushUndefined();
        return;
    }
    char text[32];
    snprintf(text, sizeof(text), "%.9g", double(value));
    stackPushString(text);
}

// Reject incomplete input and values that cannot safely enter GSC range checks.
void Gsc_Utils_IsValidFloat()
{
    char *text = NULL;
    if (!stackGetParamString(0, &text) || !text || isspace((unsigned char)text[0]))
    {
        stackPushBool(false);
        return;
    }

    errno = 0;
    char *end = NULL;
    float value = strtof(text, &end);
    bool completeNumber = end != text && *end == '\0';
    // NaN defeats ordinary min/max checks; range errors can silently become zero or infinity.
    bool withinFloatRange = errno != ERANGE && isfinite(value);
    stackPushBool(completeNumber && withinFloatRange);
}

void Gsc_Utils_ContainsIllegalChars()
{
    bool result = false;
    char *buf = NULL;
    stackGetParamString(0, &buf);
    if (buf != NULL)
    {
        for (int i = 0; i < (int)strlen(buf); i++)
        {
            unsigned char uChar = (unsigned char)buf[i];
            if (uChar < 0x20) /* space */
            {
                result = true;
                break;
            }

            // Other things that CoD4 doesn't like as input:
            if ((uChar == 0x25) || /* percent */
                (uChar == 0x26) || /* ampersand */
                (uChar == 0x22) || /* double quote */
                (uChar == 0x5C) || /* backslash */
                (uChar == 0x7E) || /* tilde -> weird client issues as it's persistently bound to console */
                (uChar == 0x7F) || /* DEL */
                (uChar == 0xFF))   /* NBSP */
            {
                result = true;
                break;
            }
        }
    }

    stackPushBool(result);
}

void Gsc_Utils_Printf()
{
    char *message = NULL;
    stackGetParamString(0, &message);
#ifdef COD4
    // Preserve the plugin's immediate engine-console logging. libc stdout can
    // remain buffered when a dedicated server runs under Docker or a service.
    Com_Printf(CON_CHANNEL_SERVER, "%s", message);
#else
    printf("%s", message);
#endif
}

void Gsc_Utils_VectorScale()
{
	vec3_t vector;
	float scale;
	stackGetParamVector(0, vector);
	stackGetParamFloat(1, &scale);

	vector[0] *= scale;
	vector[1] *= scale;
	vector[2] *= scale;
	stackPushVector(vector);
}

void Gsc_Utils_IsEntityThinking(int entnum)
{
#ifdef COD4
    // The engine records the entity whose think function is running. Scripts must
    // not delete that entity from inside its own think, such as a grenade explosion.
    stackPushInt(level.currentEntityThink == entnum);
#else
	if(*(int*)0x864F984 == entnum)
		stackPushInt(1);
	else
		stackPushInt(0);
#endif // COD4
}

static bool isRandomSeeded = false;
void _seedRandom()
{
    if(!isRandomSeeded)
    {
        srand(time(NULL) ^ getpid());
        isRandomSeeded = true;
    }
}
// Account credentials are built from these values, so they must be unpredictable.
// Use the kernel's secure random source; when it cannot supply a value, return
// undefined so callers refuse the operation instead of using a guessable number.
void Gsc_Utils_CreateRandomInt()
{
    int randomValue = 0;
    ssize_t receivedBytes = -1;
    do
    {
        receivedBytes = getrandom(&randomValue, sizeof(randomValue), 0);
    }
    while (receivedBytes < 0 && errno == EINTR);

    if (receivedBytes != (ssize_t)sizeof(randomValue))
    {
        stackPushUndefined();
        return;
    }
    stackPushInt(randomValue);
}

void Gsc_Utils_Rand()
{
    _seedRandom();
    stackPushInt(rand());
}

void Gsc_Utils_IsAlphaNumeric()
{
    char *buf = NULL;
    stackGetParamString(0, &buf);

    if (buf == NULL)
    {
        stackPushInt(0);
        return;
    }

    stackPushInt(isalnum(buf[0]) ? 1 : 0);
}

void Gsc_Utils_HexStringToInt()
{
    char *buf = NULL;
    stackGetParamString(0, &buf);
    
    if(buf == NULL)
    {
        stackPushUndefined();
        return;
    }
    
    int result = strtoul(buf, NULL, 16);
    
    // Input wasn't 0, but function returned 0 (error)
    if(result == 0 && buf[0] != 0)
    {
        stackPushUndefined();
    }
    else
    {
        stackPushInt(result);
    }
}

void Gsc_Utils_IntToHexString()
{
    int val = 0;
    stackGetParamInt(0, &val);
    
    char buf[9];
    snprintf(buf, sizeof(buf), "%08x", val);
    
    stackPushString(buf);
}

void Gsc_Utils_GetCodVersion()
{
#ifdef COD4
    stackPushInt(4);
#else
    stackPushInt(2);
#endif
}

#ifdef __cplusplus
}
#endif // __cplusplus