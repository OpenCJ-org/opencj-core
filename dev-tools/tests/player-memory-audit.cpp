// Read-only counters for a disposable engine fixture. Never load into live play.
#include "../../cod4x-server/src/cscr_variable.h"
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <cstring>
#include <set>
extern "C"
{
    void Plugin_ScrAddFunction(char *name, void (*function)());
    void Plugin_Printf(const char *format, ...);
    const char *Plugin_Scr_GetString(unsigned parameterIndex);
    const char *SL_ConvertToString(unsigned stringID);
}
struct ReachableCounts
{
    unsigned childCount = 0;
    unsigned objectCount = 0;
    unsigned uniqueStringBytes = 0;
    std::set<unsigned> visitedObjects;
    std::set<unsigned> visitedStrings;
};
// Called synchronously from the VM. Values cannot change during this traversal.
// Shared objects and cycles are counted once; strings include their terminator.
static void countReachableValues(unsigned objectID, ReachableCounts &counts, bool isRoot = false)
{
    unsigned objectType = Scr_GetObjectType(objectID);
    if (!isRoot && objectType != VAR_ARRAY && objectType != VAR_OBJECT)
    {
        return;
    }
    if (!counts.visitedObjects.insert(objectID).second)
    {
        return;
    }
    ++counts.objectCount;
    for (unsigned childID = FindFirstSibling(objectID); childID; childID = FindNextSibling(childID))
    {
        ++counts.childCount;
        unsigned valueType = GetValueType(childID);
        if (valueType == VAR_UNDEFINED)
        {
            continue;
        }
        VariableUnion value = *GetVariableValueAddress(childID);
        if (valueType == VAR_POINTER)
        {
            countReachableValues(value.pointerValue, counts);
        }
        if ((valueType == VAR_STRING || valueType == VAR_ISTRING) &&
            counts.visitedStrings.insert(value.stringValue).second)
        {
            counts.uniqueStringBytes += std::strlen(SL_ConvertToString(value.stringValue)) + 1;
        }
    }
}
static void auditScriptMemory()
{
    const char *label = Plugin_Scr_GetString(0);
    unsigned objectID = Scr_GetObject(1);
    ReachableCounts counts;
    countReachableValues(objectID, counts, true);
    int hudCount = 0;
    for (int i = 0; i < MAX_HUDELEMS; ++i)
    {
        if (g_hudelems[i].elem.type)
        {
            ++hudCount;
        }
    }
    Plugin_Printf(
        "MEM %s values=%d objects=%d threads=%d huds=%d reachableChildren=%u reachableObjects=%u uniqueStringBytes=%u\n",
        label, gScrVarPub.numScriptValues, gScrVarPub.numScriptObjects, gScrVarPub.numScriptThreads,
        hudCount, counts.childCount, counts.objectCount, counts.uniqueStringBytes);
}
extern "C" int OnInit()
{
    Plugin_ScrAddFunction(const_cast<char *>("memoryAudit"), auditScriptMemory);
    Plugin_Printf("MEM SIZES variable=%u playerState=%u hud=%u\n",
                  unsigned(sizeof(VariableValueInternal)), unsigned(sizeof(playerState_t)),
                  unsigned(sizeof(game_hudelem_t)));
    return 0;
}
extern "C" void OnInfoRequest(pluginInfo_t *info)
{
    memset(info, 0, sizeof(*info));
    info->handlerVersion.major = PLUGIN_HANDLER_VERSION_MAJOR;
    strcpy(info->fullName, "OpenCJ isolated memory audit");
    info->pluginVersion.major = 1;
}
