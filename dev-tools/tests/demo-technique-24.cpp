#include <chrono>
#include "../../server-ext/opencj_demo_technique.hpp"
#include <vector>
#include <cstdio>
#include <cstdlib>
static int checks = 0;
static constexpr bool ON_GROUND = true;
static void check(bool ok, const char *label) {
    ++checks;
    if (!ok) {
        std::fprintf(stderr, "TECHNIQUE FAIL %s\n", label);
        std::exit(1);
    }
}

static void appendInputPhase(std::vector<CJ_DemoInput> &inputSamples, int forward, int right,
                             int sampleCount, bool onGround = false) {
    for (int i = 0; i < sampleCount; ++i) {
        inputSamples.push_back({forward, right, onGround, false, false, false});
    }
}

static CJ_DemoTechnique interpretSample(const std::vector<CJ_DemoInput> &inputSamples,
                                        int frameIndex, int mode) {
    return CJ_InterpretDemoTechnique(inputSamples.size(), frameIndex, mode, [&](int i) {
        return inputSamples[i];
    });
}

static void testFullbeatAndHalfbeat() {
    for (int forward : {-1, 1}) {
        for (int right : {-1, 1}) {
            std::vector<CJ_DemoInput> halfbeatSamples;
            appendInputPhase(halfbeatSamples, forward, right, 3);
            appendInputPhase(halfbeatSamples, 0, -right, 4);
            appendInputPhase(halfbeatSamples, forward, right, 3);
            for (int i = 3; i < 7; ++i) {
                auto converted = interpretSample(halfbeatSamples, i, CJ_DEMO_FULLBEAT);
                check(converted.changed && converted.forward == forward &&
                          converted.right == -right,
                      "HB to FB input");
                check(std::fabs(
                          std::remainder(converted.yawOffset +
                                             CJ_DemoInputAngle(converted.forward, converted.right) -
                                             CJ_DemoInputAngle(0, -right),
                                         360.0f)) < .001,
                      "HB conversion preserves world wish direction");
            }
            check(!interpretSample(halfbeatSamples, 4, CJ_DEMO_ORIGINAL).changed &&
                      !interpretSample(halfbeatSamples, 4, CJ_DEMO_HALFBEAT).changed,
                  "original/already HB remain source");
            std::vector<CJ_DemoInput> fullbeatSamples;
            appendInputPhase(fullbeatSamples, forward, right, 1);
            appendInputPhase(fullbeatSamples, forward, -right, 4);
            appendInputPhase(fullbeatSamples, forward, right, 3);
            auto converted = interpretSample(fullbeatSamples, 2, CJ_DEMO_HALFBEAT);
            check(converted.changed && converted.forward == 0 && converted.right == -right,
                  "FB to HB retains initial diagonal");
            check(std::fabs(std::remainder(converted.yawOffset + CJ_DemoInputAngle(0, -right) -
                                               CJ_DemoInputAngle(forward, -right),
                                           360.0f)) < .001,
                  "FB conversion preserves world wish direction");
            check(!interpretSample(fullbeatSamples, 2, CJ_DEMO_FULLBEAT).changed,
                  "already FB remains source");
        }
    }
}

static void testAmbiguousAndExcludedSections() {
    std::vector<CJ_DemoInput> inputSamples;
    appendInputPhase(inputSamples, 1, -1, 3);
    appendInputPhase(inputSamples, 0, 1, 4);
    check(interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).fallback &&
              !interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).changed,
          "single key without repeating return is ambiguous");
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 3);
    appendInputPhase(inputSamples, 0, -1, 4);
    appendInputPhase(inputSamples, 1, -1, 3);
    check(!interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).changed,
          "landing release is not halfbeat");
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 3);
    appendInputPhase(inputSamples, 0, 1, 2);
    appendInputPhase(inputSamples, 1, -1, 3);
    check(!interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).changed,
          "sub 150ms tap does not establish halfbeat");
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 3);
    appendInputPhase(inputSamples, 0, 1, 3);
    appendInputPhase(inputSamples, 1, -1, 3);
    check(interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).changed, "150ms phase accepted");
    inputSamples[4].excluded = true;
    check(interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).fallback &&
              !interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).changed,
          "RPG aim/mantle section stays original");
    inputSamples[4].excluded = false;
    inputSamples[3].cut = true;
    check(!interpretSample(inputSamples, 4, CJ_DEMO_FULLBEAT).changed,
          "cannot borrow anchor across load cut");
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 3);
    appendInputPhase(inputSamples, 1, 1, 3);
    appendInputPhase(inputSamples, 0, 1, 3);
    appendInputPhase(inputSamples, 1, -1, 3);
    check(interpretSample(inputSamples, 7, CJ_DEMO_FULLBEAT).changed &&
              !interpretSample(inputSamples, 7, CJ_DEMO_FULLBEAT).fallback,
          "mixed confirmed styles normalize to the requested fullbeat view");
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 3);
    appendInputPhase(inputSamples, 0, 1, 3);
    appendInputPhase(inputSamples, 1, -1, 3);
    appendInputPhase(inputSamples, 0, 1, 3, ON_GROUND);
    check(!interpretSample(inputSamples, 10, CJ_DEMO_FULLBEAT).changed &&
              !interpretSample(inputSamples, 10, CJ_DEMO_FULLBEAT).fallback,
          "ground movement unchanged");
}

static void testBoundedClassification() {
    std::vector<CJ_DemoInput> inputSamples;
    appendInputPhase(inputSamples, 1, -1, 600);
    appendInputPhase(inputSamples, 1, 1, 10);
    check(interpretSample(inputSamples, 550, CJ_DEMO_HALFBEAT).fallback,
          "oversized jump scan bounded");
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 128);
    appendInputPhase(inputSamples, 1, 1, 128);
    appendInputPhase(inputSamples, 1, -1, 128);
    appendInputPhase(inputSamples, 1, 1, 127);
    size_t sampleReadCount = 0;
    auto readInput = [&](int i) {
        ++sampleReadCount;
        return inputSamples[i];
    };
    const auto started = std::chrono::steady_clock::now();
    for (int viewer = 0; viewer < 32; ++viewer) {
        CJ_DemoSection cached = CJ_AnalyzeDemoTechnique(inputSamples.size(), 0, readInput);
        for (int i = 0; i < int(inputSamples.size()); ++i) {
            auto actual = CJ_ApplyDemoTechnique(i, CJ_DEMO_HALFBEAT, readInput(i), cached);
            check(actual.right == inputSamples[i].right &&
                      actual.forward == (inputSamples[i].right > 0 ? 0 : 1),
                  "cached section retains correct conversion");
        }
    }
    const auto elapsedMicroseconds = std::chrono::duration_cast<std::chrono::microseconds>(
                                         std::chrono::steady_clock::now() - started)
                                         .count();
    check(sampleReadCount < 32 * 511 * 5, "classification work grows linearly across 32 viewers");
    std::printf("DEMO TECHNIQUE PERFORMANCE viewers=32 samples=511 reads=%zu microseconds=%lld "
                "sectionBytes=%zu\n",
                sampleReadCount, (long long)elapsedMicroseconds, sizeof(CJ_DemoSection));
}

static void testCameraSmoothing() {
    std::vector<CJ_DemoCameraSample> camera;
    for (int i = 0; i < 30; ++i) {
        camera.push_back({0, (i >= 5 && i < 20) ? 45.f : 0.f, false, false, false});
    }
    auto readCamera = [&](int i) {
        return camera[i];
    };
    float previousYaw = CJ_SmoothDemoYaw(camera.size(), 0, readCamera);
    for (int i = 1; i < int(camera.size()); ++i) {
        float yaw = CJ_SmoothDemoYaw(camera.size(), i, readCamera);
        check(std::fabs(yaw - previousYaw) <= 15.01f,
              "conversion transitions have no instantaneous 45-degree camera step");
        previousYaw = yaw;
    }
    check(CJ_SmoothDemoYaw(camera.size(), 12, readCamera) == 45,
          "steady converted strafe keeps its exact angle");
    camera[12].locked = true;
    camera[12].offset = 0;
    camera[13].locked = true;
    camera[13].offset = 0;
    check(CJ_SmoothDemoYaw(camera.size(), 12, readCamera) == 0 &&
              CJ_SmoothDemoYaw(camera.size(), 13, readCamera) == 0,
          "RPG aiming samples remain exact");
    check(CJ_SmoothDemoYaw(camera.size(), 11, readCamera) < 15 &&
              CJ_SmoothDemoYaw(camera.size(), 14, readCamera) < 15,
          "camera eases into and out of protected aiming");
    camera[12].cut = true;
    float beforeCut = CJ_SmoothDemoYaw(camera.size(), 11, readCamera);
    camera[12].yaw = 120;
    camera[13].yaw = 150;
    check(CJ_SmoothDemoYaw(camera.size(), 11, readCamera) == beforeCut,
          "camera lookahead cannot cross load cuts");
    check(CJ_SmoothDemoYaw(camera.size(), 12, readCamera) == 120,
          "load cut orientation remains exact");
    std::vector<float> forwardPlaybackYaws;
    for (int i = 0; i < int(camera.size()); ++i) {
        forwardPlaybackYaws.push_back(CJ_SmoothDemoYaw(camera.size(), i, readCamera));
    }
    for (int i = int(camera.size()) - 1; i >= 0; --i) {
        check(CJ_SmoothDemoYaw(camera.size(), i, readCamera) == forwardPlaybackYaws[i],
              "camera is deterministic when reversing and seeking");
    }
    camera.clear();
    for (int i = 0; i < 10; ++i) {
        camera.push_back({i < 5 ? 179.f : -179.f, i < 5 ? 0.f : 1.f, false, false, false});
    }
    check(std::fabs(std::remainder(CJ_SmoothDemoYaw(camera.size(), 4, readCamera) - 180, 360.f)) <
              3,
          "camera smoothing crosses angle wrap by the shortest arc");
    camera.clear();
    for (int i = 0; i < 10; ++i) {
        camera.push_back({float(i * i), 0, false, false, false});
    }
    for (int i = 0; i < int(camera.size()); ++i) {
        check(CJ_SmoothDemoYaw(camera.size(), i, readCamera) == camera[i].yaw,
              "unconverted original camera is untouched");
    }
}

static void testRocketStrafeConversion() {
    std::vector<CJ_DemoInput> inputSamples;
    appendInputPhase(inputSamples, 1, -1, 5);
    appendInputPhase(inputSamples, 1, 1, 15);
    appendInputPhase(inputSamples, 1, -1, 5);
    inputSamples[10].shot = true;
    for (int i = 5; i < 20; ++i) {
        check(interpretSample(inputSamples, i, CJ_DEMO_HALFBEAT).forward == 0 &&
                  interpretSample(inputSamples, i, CJ_DEMO_HALFBEAT).right == 1,
              "RPG strafe remains the converted single key throughout");
    }
    check(interpretSample(inputSamples, 2, CJ_DEMO_HALFBEAT).forward == 1 &&
              interpretSample(inputSamples, 22, CJ_DEMO_HALFBEAT).forward == 1,
          "diagonal takeoff preserved before consistent halfbeat");
    inputSamples[2].shot = true;
    check(interpretSample(inputSamples, 15, CJ_DEMO_HALFBEAT).changed &&
              !interpretSample(inputSamples, 15, CJ_DEMO_HALFBEAT).fallback,
          "RPG on either side does not disable halfbeat");
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 5);
    appendInputPhase(inputSamples, 1, 1, 15);
    inputSamples[10].shot = true;
    for (int i = 5; i < 20; ++i) {
        check(interpretSample(inputSamples, i, CJ_DEMO_HALFBEAT).forward == 0,
              "two-phase jump converts without requiring a return strafe");
    }
}

static void testInvertConversion() {
    std::vector<CJ_DemoInput> inputSamples;
    // Invert keeps takeoff, then uses A/D on both sides for the rest of flight.
    for (int forward : {-1, 1}) {
        for (int right : {-1, 1}) {
            inputSamples.clear();
            appendInputPhase(inputSamples, forward, right, 4);
            appendInputPhase(inputSamples, forward, -right, 4);
            appendInputPhase(inputSamples, forward, right, 4);
            appendInputPhase(inputSamples, forward, -right, 4, ON_GROUND);
            check(!interpretSample(inputSamples, 2, CJ_DEMO_INVERT).changed,
                  "Invert retains the diagonal takeoff");
            for (int i = 4; i < 12; ++i) {
                auto converted = interpretSample(inputSamples, i, CJ_DEMO_INVERT);
                check(converted.forward == 0 && converted.right == inputSamples[i].right,
                      "Invert converts both airborne strafe sides");
                check(std::fabs(std::remainder(
                          converted.yawOffset +
                              CJ_DemoInputAngle(converted.forward, converted.right) -
                              CJ_DemoInputAngle(inputSamples[i].forward, inputSamples[i].right),
                          360.f)) < .001,
                      "Invert keeps intended world movement direction");
            }
            check(!interpretSample(inputSamples, 13, CJ_DEMO_INVERT).changed,
                  "Invert leaves grounded movement unchanged");
        }
    }
    inputSamples.clear();
    appendInputPhase(inputSamples, 1, -1, 4);
    appendInputPhase(inputSamples, 0, 1, 4);
    appendInputPhase(inputSamples, 0, -1, 4);
    appendInputPhase(inputSamples, 0, 1, 4);
    check(interpretSample(inputSamples, 9, CJ_DEMO_FULLBEAT).forward == 1 &&
              interpretSample(inputSamples, 5, CJ_DEMO_FULLBEAT).forward == 1,
          "native Invert converts to Fullbeat on both sides");
    check(interpretSample(inputSamples, 9, CJ_DEMO_HALFBEAT).forward == 1 &&
              interpretSample(inputSamples, 5, CJ_DEMO_HALFBEAT).forward == 0,
          "native Invert converts to Halfbeat");
    check(!interpretSample(inputSamples, 9, CJ_DEMO_INVERT).changed,
          "native Invert stays unchanged in Invert view");
    inputSamples.clear();
    appendInputPhase(inputSamples, 0, -1, 4);
    appendInputPhase(inputSamples, 0, 1, 4);
    appendInputPhase(inputSamples, 0, -1, 4);
    check(interpretSample(inputSamples, 5, CJ_DEMO_FULLBEAT).forward == 1,
          "cropped Invert section can normalize without inventing takeoff");
}

static void testRocketCamera() {
    std::vector<CJ_DemoCameraSample> camera;
    auto readCamera = [&](int i) {
        return camera[i];
    };
    for (int i = 0; i < 15; ++i) {
        camera.push_back({0, 45, false, false, i == 7});
    }
    check(CJ_SmoothDemoYaw(camera.size(), 7, readCamera) == 0,
          "quick RPG flick retains exact firing angle");
    check(CJ_SmoothDemoYaw(camera.size(), 6, readCamera) == 22.5 &&
              CJ_SmoothDemoYaw(camera.size(), 8, readCamera) == 22.5,
          "quick RPG flick has one intermediate sample each way");
    check(CJ_SmoothDemoYaw(camera.size(), 5, readCamera) == 45 &&
              CJ_SmoothDemoYaw(camera.size(), 9, readCamera) == 45,
          "RPG turn completes within 100 ms each way");
    std::vector<float> forwardPlaybackYaws;
    for (int i = 0; i < 15; ++i) {
        forwardPlaybackYaws.push_back(CJ_SmoothDemoYaw(camera.size(), i, readCamera));
    }
    for (int i = 14; i >= 0; --i) {
        check(CJ_SmoothDemoYaw(camera.size(), i, readCamera) == forwardPlaybackYaws[i],
              "RPG flick is identical in reverse");
    }
}

int main() {
    testFullbeatAndHalfbeat();
    testAmbiguousAndExcludedSections();
    testBoundedClassification();
    testCameraSmoothing();
    testRocketStrafeConversion();
    testInvertConversion();
    testRocketCamera();
    std::printf("DEMO TECHNIQUE COMPLETE checks=%d failures=0\n", checks);
}
