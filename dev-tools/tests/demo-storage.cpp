// Exercise native demo storage and GSC return values without a game server.
#include "../../server-ext/opencj_demo.cpp"
#include <cassert>
#include <climits>
#include <cstdio>
#include <cstdlib>

static bool returnedUndefined;
static int returnedInteger;
static std::vector<int> scriptArguments;
static float returnedVector[3];

static playerState_t playerState;
static gclient_t gameClient;

extern "C"
{
int Scr_GetNumParam()
{
    return scriptArguments.size();
}

int Scr_GetInt(unsigned index)
{
    return scriptArguments.at(index);
}

unsigned Scr_GetType(unsigned index)
{
    assert(index < scriptArguments.size());
    return STACK_INT;
}

    gentity_t g_entities[MAX_CLIENTS] = {};

    playerState_t *SV_GameClientNum(int client)
    {
        assert(client == 0);
        return &playerState;
    }

    void SV_GameSendServerCommand(int client, int, const char *)
    {
        assert(client == 0);
    }

    WeaponDef *BG_GetWeaponDef(int)
    {
        return nullptr;
    }

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
        Gsc_Demo_ReadFrame_Origin,  Gsc_Demo_ReadFrame_Angles,     Gsc_Demo_ReadFrame_SaveNow,
        Gsc_Demo_ReadFrame_LoadNow, Gsc_Demo_ReadFrame_RPGNow,     Gsc_Demo_ReadFrame_FPS,
        Gsc_Demo_ReadFrame_Flags,   Gsc_Demo_ReadFrame_Checkpoint,
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
    std::vector<unsigned char> raw(8 + frameCount * DemoWire::FRAME_SIZE);
    std::memcpy(raw.data(), "OCJ1", 4);
    putDemoInt(raw.data() + 4, frameCount, 4);
    std::string packed(compressBound(raw.size()), char{});
    uLongf packedSize = packed.size();
    assert(compress2(reinterpret_cast<unsigned char *>(packed.data()), &packedSize, raw.data(),
                     raw.size(), 6) == Z_OK);
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

static void repeatedPresentationKeepsOriginalState()
{
    constexpr int client = 0;
    g_entities[client].client = &gameClient;
    gameClient.bFrozen = qfalse;
    playerState.weaponTime = 123;
    playerState.velocity[0] = 25;
    playerState.commandTime = 1000;
    Gsc_Demo_BeginPresentation(client);
    assert(!returnedUndefined && returnedInteger == 1);

    playerState.weaponTime = 999;
    playerState.velocity[0] = 0;
    gameClient.bFrozen = qtrue;
    Gsc_Demo_BeginPresentation(client);
    assert(!returnedUndefined && returnedInteger == 1);
    Gsc_Demo_EndPresentation(client);
    assert(playerState.weaponTime == 123 && playerState.velocity[0] == 25);
    assert(gameClient.bFrozen == qfalse && demoReturnVisual[client] == nullptr);

    Gsc_Demo_EndPresentation(client);
    assert(playerState.weaponTime == 123);
    g_entities[client].client = nullptr;
    Gsc_Demo_BeginPresentation(client);
    assert(!returnedUndefined && returnedInteger == 0);
}

static std::string packRawChunk(const std::vector<unsigned char> &raw)
{
    std::string packed(compressBound(raw.size()), char{});
    uLongf packedSize = packed.size();
    assert(compress2(reinterpret_cast<unsigned char *>(packed.data()), &packedSize, raw.data(),
                     raw.size(), 6) == Z_OK);
    packed.resize(packedSize);
    return packed;
}

static std::vector<unsigned char> goldenModernFrame()
{
    // Literal OCJ5 bytes recorded before the codec readability cleanup.
    const char *hex = "4f434a35010000000000c03f000000c0000020410040008000c005204d0178563412ff020103"
                      "0004000506803cff0400f8ff0c00ff7f000001800700080009000a0b046e6f6e654d0c";
    std::vector<unsigned char> raw;
    for (size_t offset = 0; hex[offset]; offset += 2)
    {
        raw.push_back((demoHexDigit(hex[offset]) << 4) | demoHexDigit(hex[offset + 1]));
    }
    return raw;
}

static void storedFormatsRemainCompatible()
{
    sDemo_t *demo = createDemo(4, 4);
    assert(demo);
    sDemoFrame_t frame = {};
    const float origin[] = {1.5f, -2, 10};
    const float angles[] = {90, 180, 270};
    std::copy(origin, origin + 3, frame.origin);
    std::copy(angles, angles + 3, frame.angles);
    frame.flags = 8197;
    frame.fps = 333;
    frame.checkpointId = 0x12345678;
    frame.saveNow = true;
    frame.loadNow = true;
    frame.rpgNow = true;
    frame.eleKnown = true;
    frame.eleUsed = true;
    frame.visual = {true, 0, 258, 3,  4,  5,  6, 60.5f, 1, {4, -8, 12}, {32767, 0, -32767},
                    7,    8, 9,   10, 11, 77, 12};
    assert(appendDemoFrame(demo, frame));
    std::string encoded;
    assert(encodeDemoChunk(demo, 0, 1, encoded));
    std::vector<unsigned char> raw(8192);
    uLongf rawSize = raw.size();
    assert(uncompress(raw.data(), &rawSize, reinterpret_cast<const unsigned char *>(encoded.data()),
                      encoded.size()) == Z_OK);
    raw.resize(rawSize);
    assert(raw == goldenModernFrame());

    for (char version = '1'; version <= '5'; ++version)
    {
        raw = goldenModernFrame();
        raw[3] = version;
        if (version == '1')
        {
            raw.resize(8 + 27);
        }
        else if (version == '2')
        {
            raw.resize(raw.size() - 2);
        }
        sDemo_t *decoded = createDemo(5, 4);
        assert(decoded);
        const std::string packed = packRawChunk(raw);
        assert(decodeDemoChunk(decoded, reinterpret_cast<const unsigned char *>(packed.data()),
                               packed.size()) == 1);
        const sDemoFrame_t &restored = decoded->pDemoFrames[0];
        assert(restored.origin[0] == 1.5f && restored.origin[1] == -2);
        assert(restored.angles[0] == 90 && restored.angles[2] == 270);
        assert(restored.flags == 8197 && restored.fps == 333);
        assert(restored.checkpointId == 0x12345678);
        assert(restored.saveNow && restored.loadNow && restored.rpgNow);
        assert(restored.isKeyFrame == (version < '4'));
        assert(restored.eleKnown == (version >= '5'));
        assert(restored.eleUsed == (version >= '5'));
        assert(restored.visual.valid == (version >= '2'));
        if (version >= '2')
        {
            assert(restored.visual.weaponTime == 258 && restored.visual.weaponDelay == 3);
            assert(restored.visual.animation == 4 && restored.visual.weaponState == 5);
            assert(restored.visual.bobCycle == 6 && restored.visual.viewHeight == 60.5f);
            assert(restored.visual.ads == 1 && restored.visual.velocity[1] == -8);
            assert(restored.visual.ladder[2] == -32767 && restored.visual.sprintElapsed == 7);
            assert(restored.visual.mantleTimer == 8 && restored.visual.mantleYaw == 9);
            assert(restored.visual.mantleTransition == 10 && restored.visual.mantleFlags == 11);
            assert(restored.visual.landingEvent == (version >= '3' ? 77 : 0));
            assert(restored.visual.landingImpact == (version >= '3' ? 12 : 0));
        }
        clearDemoById(5);
    }

    const auto valid = goldenModernFrame();
    for (size_t length = 0; length < valid.size(); ++length)
    {
        raw.assign(valid.begin(), valid.begin() + length);
        const std::string packed = packRawChunk(raw);
        assert(decodeDemoChunk(demo, reinterpret_cast<const unsigned char *>(packed.data()),
                               packed.size()) == 0);
        assert(demo->size == 1);
    }
    raw = valid;
    raw.push_back(0);
    std::string packed = packRawChunk(raw);
    assert(decodeDemoChunk(demo, reinterpret_cast<const unsigned char *>(packed.data()),
                           packed.size()) == 0);
    assert(demo->size == 1);
    clearDemoById(4);
}

static void trimmedRecordingRefreshesSelectedSample()
{
    constexpr int client = 0;
    sDemo_t *demo = createDemo(6, 4);
    assert(demo);
    sDemoFrame_t frame = {};
    frame.fps = 333;
    assert(appendDemoFrame(demo, frame));
    frame.fps = 125;
    assert(appendDemoFrame(demo, frame));
    opencj_playback[client] = {demo, 0};
    demoTechnique[client] = {};
    assert(techniqueFrame(client, *demo, 0).fps == 333);

    scriptArguments = {6, 1};
    Gsc_Demo_KeepLast();
    assert(!returnedUndefined && returnedInteger == 1);
    assert(techniqueFrame(client, *demo, 0).fps == 125);
    clearDemoById(6);
}

int main()
{
    emptyAndShortenedPlayback();
    extremeFrameSkips();
    rejectedChunkLeavesRecordingUnchanged();
    repeatedPresentationKeepsOriginalState();
    storedFormatsRemainCompatible();
    trimmedRecordingRefreshesSelectedSample();
    std::puts("DEMO STORAGE PASS bounds, atomic appends, presentation and OCJ1-5 compatibility");
}
