// Exercise native demo storage and GSC return values without a game server.
#include "../../server-ext/opencj_demo.cpp"
#include <cassert>
#include <climits>
#include <cstdio>
#include <cstdlib>

static bool returnedUndefined;
static int returnedInteger;
static float returnedVector[3];

extern "C" {
int G_GetWeaponIndexForName(const char *)
{
    return 0;
}

void Scr_AddUndefined()
{
    returnedUndefined = true;
}

void Scr_AddInt(int value)
{
    returnedUndefined = false;
    returnedInteger = value;
}

void Scr_AddBool(bool value)
{
    Scr_AddInt(value);
}

void Scr_AddVector(const float *value)
{
    returnedUndefined = false;
    std::copy(value, value + 3, returnedVector);
}

void Scr_Error(const char *message)
{
    std::fprintf(stderr, "Unexpected script error: %s\n", message);
    std::abort();
}

char *va(const char *, ...)
{
    static char message[] = "invalid client";
    return message;
}
}

static void checkFrameReaders(int client, bool expectUndefined)
{
    using FrameReader = void (*)(int);
    const FrameReader readers[] = {
        Gsc_Demo_ReadFrame_Origin,
        Gsc_Demo_ReadFrame_Angles,
        Gsc_Demo_ReadFrame_SaveNow,
        Gsc_Demo_ReadFrame_LoadNow,
        Gsc_Demo_ReadFrame_RPGNow,
        Gsc_Demo_ReadFrame_FPS,
        Gsc_Demo_ReadFrame_Flags,
        Gsc_Demo_ReadFrame_Checkpoint,
    };
    for (FrameReader read : readers)
    {
        returnedUndefined = !expectUndefined;
        read(client);
        assert(returnedUndefined == expectUndefined);
    }
}

static void emptyAndShortenedPlayback()
{
    constexpr int client = 0;
    sDemo_t *demo = createDemo(1, 4);
    assert(demo);
    opencj_playback[client] = {demo, 0};
    checkFrameReaders(client, true);
    Base_Gsc_Demo_FrameSkip(client, 1, false);
    assert(returnedUndefined);

    sDemoFrame_t frame = {};
    frame.isKeyFrame = true;
    frame.fps = 333;
    for (int index = 0; index < 4; ++index)
    {
        frame.origin[0] = index;
        assert(appendDemoFrame(demo, frame));
    }
    opencj_playback[client].selectedFrame = 3;
    checkFrameReaders(client, false);
    // Truncation can leave a viewer beyond the new end until its next seek.
    demo->size = 2;
    checkFrameReaders(client, true);
    Base_Gsc_Demo_FrameSkip(client, 0, false);
    assert(!returnedUndefined && returnedInteger == 1);
    checkFrameReaders(client, false);
    clearDemoById(1);
    checkFrameReaders(client, true);
}

static void extremeFrameSkips()
{
    constexpr int client = 0;
    sDemo_t *demo = createDemo(2, 4);
    assert(demo);
    sDemoFrame_t frame = {};
    frame.isKeyFrame = true;
    for (int index = 0; index < 4; ++index)
    {
        assert(appendDemoFrame(demo, frame));
    }
    for (bool keyFrames : {false, true})
    {
        opencj_playback[client] = {demo, 1};
        Base_Gsc_Demo_FrameSkip(client, INT_MAX, keyFrames);
        assert(!returnedUndefined && returnedInteger == 3);
        Base_Gsc_Demo_FrameSkip(client, INT_MIN, keyFrames);
        assert(!returnedUndefined && returnedInteger == 0);
    }
    demoPlaybackTimeline[client] = {0, 2, 3};
    opencj_playback[client].selectedFrame = 2;
    Base_Gsc_Demo_FrameSkip(client, INT_MAX, true);
    assert(!returnedUndefined && returnedInteger == 3);
    Base_Gsc_Demo_FrameSkip(client, INT_MIN, true);
    assert(!returnedUndefined && returnedInteger == 0);
    clearDemoById(2);
}

static std::string legacyChunk(unsigned frameCount)
{
    std::vector<unsigned char> raw(8 + frameCount * demoWireFrameSize);
    std::memcpy(raw.data(), "OCJ1", 4);
    putDemoInt(raw.data() + 4, frameCount, 4);
    std::string packed(compressBound(raw.size()), '\\0');
    uLongf packedSize = packed.size();
    assert(compress2(reinterpret_cast<unsigned char *>(packed.data()), &packedSize,
                     raw.data(), raw.size(), 6) == Z_OK);
    packed.resize(packedSize);
    return packed;
}

static void rejectedChunkLeavesRecordingUnchanged()
{
    sDemo_t *demo = createDemo(3, 4);
    assert(demo);
    sDemoFrame_t frame = {};
    frame.isKeyFrame = true;
    for (int index = 0; index < 3; ++index)
    {
        assert(appendDemoFrame(demo, frame));
    }
    const std::string packed = legacyChunk(2);
    // Reserve the remaining budget on another slot without allocating 128 MiB.
    // It participates only in accounting; no frame access uses this slot.
    sDemo_t &budgetHolder = opencj_demos[MAX_NR_DEMOS_PER_MAP - 1];
    budgetHolder.nrAllocatedFrames = (demoMemoryLimit - allocatedDemoBytes()) / sizeof(frame);
    const int decoded = decodeDemoChunk(
        demo, reinterpret_cast<const unsigned char *>(packed.data()), packed.size());
    budgetHolder.nrAllocatedFrames = 0;
    assert(decoded == 0);
    assert(demo->size == 3 && demo->currentFrame == 2 && demo->lastKeyFrame == 2);
    assert(demo->pDemoFrames[2].nextKeyFrame == 2);

    assert(decodeDemoChunk(demo, reinterpret_cast<const unsigned char *>(packed.data()),
                           packed.size()) == 2);
    assert(demo->size == 5);
    clearDemoById(3);
}

int main()
{
    emptyAndShortenedPlayback();
    extremeFrameSkips();
    rejectedChunkLeavesRecordingUnchanged();
    std::puts("DEMO STORAGE PASS empty, shortened and extreme playback seeks");
}
