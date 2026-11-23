// Test-only wall clock; never loaded into the normal OpenCJ runtime.
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <chrono>
#include <cstring>
#include <vector>
#include <algorithm>
extern "C"
{
    void Plugin_ScrAddFunction(char *, void (*)());
    void Plugin_Scr_AddInt(int);
    int Plugin_Cvar_VariableIntegerValue(const char *);
    void Plugin_Printf(const char *, ...);
}
static auto began = std::chrono::steady_clock::now();
static void clockMs()
{
    Plugin_Scr_AddInt(std::chrono::duration_cast<std::chrono::milliseconds>(
                          std::chrono::steady_clock::now() - began)
                          .count());
}
extern "C" int OnInit()
{
    Plugin_ScrAddFunction(const_cast<char *>("capacityClock"), clockMs);
    return 0;
}
extern "C" void OnInfoRequest(pluginInfo_t *info)
{
    memset(info, 0, sizeof(*info));
    info->handlerVersion.major = PLUGIN_HANDLER_VERSION_MAJOR;
    strcpy(info->fullName, "OpenCJ isolated SQL capacity clock");
    info->pluginVersion.major = 1;
}

extern "C" void OnFrame()
{
    static int stage = 0, last = 0;
    static std::vector<int> intervals;
    int current = Plugin_Cvar_VariableIntegerValue("capacity_stage");
    int now = std::chrono::duration_cast<std::chrono::milliseconds>(
                  std::chrono::steady_clock::now() - began)
                  .count();
    if(current != stage)
    {
        if(stage && !intervals.empty())
        {
            std::sort(intervals.begin(), intervals.end());
            int n = intervals.size(), over = 0;
            for(int x : intervals)
            {
                if(x > 75)
                {
                    over++;
                }
            }
            Plugin_Printf("CAP TICKS %d %d %d %d %d %d\n", stage, n,
                          intervals[(95 * n + 99) / 100 - 1], intervals[(99 * n + 99) / 100 - 1],
                          intervals.back(), over);
        }
        intervals.clear();
        stage = current;
        last = now;
    }
    else if(stage > 0 && stage < 5)
    {
        if(last)
        {
            intervals.push_back(now - last);
            if(now - last > 75)
            {
                Plugin_Printf("CAP HITCH %d %d %d\n", stage, now, now - last);
            }
        }
        last = now;
    }
}
