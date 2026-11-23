// Read-only counters for a disposable engine fixture. Never load into live play.
#include "../../cod4x-server/src/cscr_variable.h"
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <cstring>
#include <set>
extern "C"
{
    void Plugin_ScrAddFunction(char *, void (*)());
    void Plugin_Printf(const char *, ...);
    const char *Plugin_Scr_GetString(unsigned);
    const char *SL_ConvertToString(unsigned);
}
struct Counts
{
    unsigned children = 0, objects = 0, stringBytes = 0;
    std::set<unsigned> seen, strings;
};
static void walk(unsigned object, Counts &c, bool root = false)
{
    unsigned type = Scr_GetObjectType(object);
    if (!root && type != VAR_ARRAY && type != VAR_OBJECT)
    {
        return;
    }
    if (!c.seen.insert(object).second)
    {
        return;
    }
    ++c.objects;
    for (unsigned v = FindFirstSibling(object); v; v = FindNextSibling(v))
    {
        ++c.children;
        unsigned t = GetValueType(v);
        if (t == VAR_UNDEFINED)
        {
            continue;
        }
        VariableUnion u = *GetVariableValueAddress(v);
        if (t == VAR_POINTER)
        {
            walk(u.pointerValue, c);
        }
        if ((t == VAR_STRING || t == VAR_ISTRING) && c.strings.insert(u.stringValue).second)
        {
            c.stringBytes += std::strlen(SL_ConvertToString(u.stringValue)) + 1;
        }
    }
}
static void audit()
{
    const char *label = Plugin_Scr_GetString(0);
    unsigned object = Scr_GetObject(1);
    Counts c;
    walk(object, c, true);
    int huds = 0;
    for (int i = 0; i < MAX_HUDELEMS; ++i)
    {
        if (g_hudelems[i].elem.type)
        {
            ++huds;
        }
    }
    Plugin_Printf(
        "MEM %s values=%d objects=%d threads=%d huds=%d reachableChildren=%u reachableObjects=%u uniqueStringBytes=%u\n",
        label, gScrVarPub.numScriptValues, gScrVarPub.numScriptObjects, gScrVarPub.numScriptThreads,
        huds, c.children, c.objects, c.stringBytes);
}
extern "C" int OnInit()
{
    Plugin_ScrAddFunction(const_cast<char *>("memoryAudit"), audit);
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
