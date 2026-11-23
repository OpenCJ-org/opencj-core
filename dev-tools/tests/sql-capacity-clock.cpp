// Test-only wall clock; never loaded into the normal OpenCJ runtime.
#include "../../cod4x-server/plugins/plugin_declarations.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <vector>

extern "C"
{
    void Plugin_ScrAddFunction(char *name, void (*function)());
    void Plugin_Scr_AddInt(int value);
    int Plugin_Cvar_VariableIntegerValue(const char *name);
    void Plugin_Printf(const char *format, ...);
}

static const auto startedAt = std::chrono::steady_clock::now();
constexpr int HitchThresholdMs = 75;
constexpr int FinishedStage = 5;

static int elapsedMs()
{
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - startedAt).count();
}

static void scriptClockMs()
{
    Plugin_Scr_AddInt(elapsedMs());
}

// Nearest-rank percentiles use a one-based rank, then index the sorted samples.
static int percentile(const std::vector<int> &sortedIntervals, int percentage)
{
    int sampleCount = sortedIntervals.size();
    int rank = (percentage * sampleCount + 99) / 100;
    return sortedIntervals[rank - 1];
}

static void reportStage(int stage, std::vector<int> &intervals)
{
    if(stage == 0 || intervals.empty())
    {
        return;
    }
    std::sort(intervals.begin(), intervals.end());
    int hitchCount = 0;
    for(int intervalMs : intervals)
    {
        if(intervalMs > HitchThresholdMs)
        {
            hitchCount++;
        }
    }
    Plugin_Printf("CAP TICKS %d %d %d %d %d %d\n", stage, int(intervals.size()),
                  percentile(intervals, 95), percentile(intervals, 99),
                  intervals.back(), hitchCount);
}

extern "C" int OnInit()
{
    Plugin_ScrAddFunction(const_cast<char *>("capacityClock"), scriptClockMs);
    return 0;
}

extern "C" void OnInfoRequest(pluginInfo_t *info)
{
    std::memset(info, 0, sizeof(*info));
    info->handlerVersion.major = PLUGIN_HANDLER_VERSION_MAJOR;
    std::strcpy(info->fullName, "OpenCJ isolated SQL capacity clock");
    info->pluginVersion.major = 1;
}

// Flush the old stage before recording frames for the next workload.
extern "C" void OnFrame()
{
    static int previousStage;
    static int previousFrameMs;
    static std::vector<int> intervals;
    int currentStage = Plugin_Cvar_VariableIntegerValue("capacity_stage");
    int currentFrameMs = elapsedMs();
    if(currentStage != previousStage)
    {
        reportStage(previousStage, intervals);
        intervals.clear();
        previousStage = currentStage;
        previousFrameMs = currentFrameMs;
        return;
    }
    if(currentStage > 0 && currentStage < FinishedStage)
    {
        if(previousFrameMs != 0)
        {
            int intervalMs = currentFrameMs - previousFrameMs;
            intervals.push_back(intervalMs);
            if(intervalMs > HitchThresholdMs)
            {
                Plugin_Printf("CAP HITCH %d %d %d\n", currentStage, currentFrameMs, intervalMs);
            }
        }
        previousFrameMs = currentFrameMs;
    }
}
