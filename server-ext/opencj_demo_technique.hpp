#ifndef OPENCJ_DEMO_TECHNIQUE_HPP
#define OPENCJ_DEMO_TECHNIQUE_HPP
#include <cmath>

// Mode values are shared with GSC menus; style flags can contain several techniques.
enum CJ_DemoTechniqueMode {
    CJ_DEMO_ORIGINAL = 0,
    CJ_DEMO_FULLBEAT = 1,
    CJ_DEMO_HALFBEAT = 2,
    CJ_DEMO_INVERT = 3
};

enum CJ_DemoStyleFlags {
    CJ_DEMO_STYLE_FULLBEAT = 1,
    CJ_DEMO_STYLE_HALFBEAT = 2,
    CJ_DEMO_STYLE_INVERT = 4
};

// Limit rescans of one jump and ignore key taps shorter than 150 ms.
static constexpr int CJ_DEMO_MAX_SECTION_FRAMES = 512;
static constexpr int CJ_DEMO_MIN_PHASE_SAMPLES = 3;
static constexpr int CJ_DEMO_INVERT_SWITCHES = 2;
static constexpr float CJ_DEMO_PI = 3.14159265358979323846f;

// Playback interpretation only. The original recording and game physics never
// receive these transformed inputs. Samples are 50 ms apart.
struct CJ_DemoInput {
    int forward;
    int right;
    bool ground;
    bool cut;
    bool excluded;
    bool shot;
};

struct CJ_DemoTechnique {
    int forward;
    int right;
    float yawOffset;
    bool changed;
    bool fallback;
};

inline float CJ_DemoInputAngle(int forward, int right)
{
    return std::atan2(float(-right), float(forward)) * 180.0f / CJ_DEMO_PI;
}

// Cache only the classification for one airborne section.
// This avoids rescanning the same jump for every sample during an FPS rebuild.
struct CJ_DemoSection {
    int beginFrame;
    int endFrame;
    int anchorForward;
    int anchorRight;
    int style;
    int takeoffEndFrame;
};

// Find a complete airborne section within the scan limit. The caller supplies
// a valid frame index and a reader for [0, frameCount).
template <class Read>
bool CJ_FindDemoAirborneSection(int frameCount, int frameIndex, Read readInput,
                                CJ_DemoSection &section)
{
    const CJ_DemoInput input = readInput(frameIndex);
    if (input.ground || input.cut) {
        return false;
    }
    int beginFrame = frameIndex;
    int endFrame = frameIndex + 1;
    while (beginFrame > 0 && frameIndex - beginFrame < CJ_DEMO_MAX_SECTION_FRAMES) {
        const CJ_DemoInput previous = readInput(beginFrame - 1);
        const CJ_DemoInput current = readInput(beginFrame);
        if (previous.ground || current.cut) {
            break;
        }
        --beginFrame;
    }
    if (beginFrame > 0 && frameIndex - beginFrame == CJ_DEMO_MAX_SECTION_FRAMES) {
        return false;
    }
    while (endFrame < frameCount && endFrame - beginFrame < CJ_DEMO_MAX_SECTION_FRAMES) {
        const CJ_DemoInput next = readInput(endFrame);
        if (next.ground || next.cut) {
            break;
        }
        ++endFrame;
    }
    if (endFrame < frameCount && endFrame - beginFrame == CJ_DEMO_MAX_SECTION_FRAMES) {
        return false;
    }
    section.beginFrame = beginFrame;
    section.endFrame = endFrame;
    return true;
}

// Classify stable key phases in one jump. Brief releases do not establish a
// technique, and changing W/S direction makes the section ambiguous.
template <class Read>
CJ_DemoSection CJ_AnalyzeDemoTechnique(int frameCount, int frameIndex, Read readInput)
{
    CJ_DemoSection section = {};
    section.beginFrame = frameIndex;
    section.endFrame = frameIndex + 1;
    if (!CJ_FindDemoAirborneSection(frameCount, frameIndex, readInput, section)) {
        return section;
    }
    const int beginFrame = section.beginFrame;
    const int endFrame = section.endFrame;
    int anchorForward = 0;
    int anchorRight = 0;
    int previousForward = 0;
    int previousRight = 0;
    bool hasPreviousPhase = false;
    bool hasFullbeat = false;
    bool hasHalfbeat = false;
    bool hasInvert = false;
    bool hasMixedForward = false;
    int previousSingleRight = 0;
    int singleKeySwitchCount = 0;
    int firstSingleRight = 0;
    for (int phaseBegin = beginFrame; phaseBegin < endFrame;) {
        CJ_DemoInput phase = readInput(phaseBegin);
        int phaseEnd = phaseBegin + 1;
        while (phaseEnd < endFrame) {
            const CJ_DemoInput next = readInput(phaseEnd);
            if (next.forward != phase.forward || next.right != phase.right ||
                next.excluded != phase.excluded) {
                break;
            }
            ++phaseEnd;
        }
        const bool stablePhase = phaseEnd - phaseBegin >= CJ_DEMO_MIN_PHASE_SAMPLES ||
                                 (phaseBegin == beginFrame && phase.forward && phase.right);
        phaseBegin = phaseEnd;
        if (!stablePhase || phase.excluded || !phase.right) {
            continue;
        }
        if (phase.forward) {
            previousSingleRight = 0;
            singleKeySwitchCount = 0;
            if (!anchorForward) {
                anchorForward = phase.forward;
                anchorRight = phase.right;
                section.takeoffEndFrame = phaseEnd;
            } else if (phase.forward != anchorForward) {
                hasMixedForward = true;
            } else if (phase.right == -anchorRight) {
                hasFullbeat = true;
            }
            const bool returningToAnchor =
                phase.forward == anchorForward && phase.right == anchorRight;
            const bool followsOppositeSingleKey =
                hasPreviousPhase && !previousForward && previousRight == -phase.right;
            if (returningToAnchor && followsOppositeSingleKey) {
                hasHalfbeat = true;
            }
            previousForward = phase.forward;
            previousRight = phase.right;
            hasPreviousPhase = true;
        } else {
            // A repeated A/D/A pattern establishes Invert, rather than
            // interpreting one released diagonal as another technique.
            if (!firstSingleRight) {
                firstSingleRight = phase.right;
            }
            if (previousSingleRight && previousSingleRight == -phase.right) {
                ++singleKeySwitchCount;
            }
            previousSingleRight = phase.right;
            if (singleKeySwitchCount >= CJ_DEMO_INVERT_SWITCHES) {
                hasInvert = true;
            }
            if (anchorForward && phase.right == -anchorRight) {
                previousForward = 0;
                previousRight = phase.right;
                hasPreviousPhase = true;
            }
        }
    }
    // Anchor the viewing pattern to the original takeoff. Re-anchoring to an
    // opposite-side RPG leaves a two-phase WA -> WD jump entirely unconverted.
    // Shot aiming is handled by the camera, independently of converted keys.
    if (!anchorForward && hasInvert) {
        anchorForward = 1;
        anchorRight = firstSingleRight;
        section.takeoffEndFrame = beginFrame;
    }
    section.anchorForward = anchorForward;
    section.anchorRight = anchorRight;
    if (anchorForward && !hasMixedForward && (hasFullbeat || hasHalfbeat || hasInvert)) {
        section.style = (hasFullbeat ? CJ_DEMO_STYLE_FULLBEAT : 0) |
                        (hasHalfbeat ? CJ_DEMO_STYLE_HALFBEAT : 0) |
                        (hasInvert ? CJ_DEMO_STYLE_INVERT : 0);
    }
    return section;
}

// Change viewing keys within the classified section while keeping world movement direction.
inline CJ_DemoTechnique CJ_ApplyDemoTechnique(int frameIndex, int mode, const CJ_DemoInput &input,
                                              const CJ_DemoSection &section)
{
    CJ_DemoTechnique result = {input.forward, input.right, 0, false, false};
    if (mode == CJ_DEMO_ORIGINAL || input.ground) {
        return result;
    }
    if (input.cut || input.excluded || !section.style) {
        result.fallback = true;
        return result;
    }
    if (frameIndex < section.beginFrame || frameIndex >= section.endFrame) {
        return result;
    }
    // Preserve the original diagonal takeoff; the opposing phase converts
    // from its first recorded sample, including bounce and RPG samples.
    if ((mode == CJ_DEMO_HALFBEAT || mode == CJ_DEMO_INVERT) &&
        frameIndex < section.takeoffEndFrame && input.forward && input.right) {
        return result;
    }
    if (mode == CJ_DEMO_FULLBEAT && !input.forward && input.right &&
        (input.right == -section.anchorRight || (section.style & CJ_DEMO_STYLE_INVERT))) {
        result.forward = section.anchorForward;
    } else if (mode == CJ_DEMO_HALFBEAT && input.forward == section.anchorForward &&
               input.right == -section.anchorRight) {
        result.forward = 0;
    } else if (mode == CJ_DEMO_HALFBEAT && (section.style & CJ_DEMO_STYLE_INVERT) &&
               !input.forward && input.right == section.anchorRight) {
        result.forward = section.anchorForward;
    } else if (mode == CJ_DEMO_INVERT && input.right && input.forward == section.anchorForward) {
        result.forward = 0;
    }
    result.changed = result.forward != input.forward;
    if (result.changed) {
        result.yawOffset = std::remainder(CJ_DemoInputAngle(input.forward, input.right) -
                                              CJ_DemoInputAngle(result.forward, result.right),
                                          360.0f);
    }
    return result;
}

template <class Read>
CJ_DemoTechnique CJ_InterpretDemoTechnique(int frameCount, int frameIndex, int mode, Read readInput)
{
    return CJ_ApplyDemoTechnique(frameIndex, mode, readInput(frameIndex),
                                 CJ_AnalyzeDemoTechnique(frameCount, frameIndex, readInput));
}

struct CJ_DemoCameraSample {
    float yaw;
    float offset;
    bool cut;
    bool locked;
    bool shot;
};

// Ease only camera changes introduced by conversion. Recorded RPG aim, ground
// frames and load cuts remain exact. Position, velocity and FPS never enter here.
template <class Sample>
float CJ_SmoothDemoYaw(int frameCount, int frameIndex, Sample readCameraSample)
{
    // Samples are 50 ms apart: the two-sample kernel spans 100 ms each way.
    static constexpr int KERNEL_RADIUS_FRAMES = 2;
    static constexpr int PROTECTED_RADIUS_FRAMES = 3;
    static constexpr int CENTER_WEIGHT = 3;
    static constexpr float SHOT_APPROACH_FRAMES = 2.0f;
    static constexpr float LOCKED_APPROACH_FRAMES = 3.0f;
    static constexpr float OFFSET_TOLERANCE_DEGREES = .01f;

    const CJ_DemoCameraSample center = readCameraSample(frameIndex);
    if (center.locked || center.cut || center.shot) {
        return center.yaw;
    }
    const float targetYaw = center.yaw + center.offset;
    float weightedOffset = CENTER_WEIGHT * center.offset;
    float totalWeight = CENTER_WEIGHT;
    float lockedFrameScale = 1;
    float shotScale = 1;
    bool hasTransition = false;
    for (int direction = -1; direction <= 1; direction += 2) {
        CJ_DemoCameraSample previous = center;
        for (int distance = 1; distance <= PROTECTED_RADIUS_FRAMES; ++distance) {
            int neighborFrame = frameIndex + direction * distance;
            if (neighborFrame < 0 || neighborFrame >= frameCount) {
                break;
            }
            const CJ_DemoCameraSample next = readCameraSample(neighborFrame);
            if (direction > 0 ? next.cut : previous.cut) {
                break;
            }
            // A shot uses a short 100 ms approach and departure. Keep it out
            // of the ordinary smoothing kernel, which otherwise adds a second
            // slow dip on top of the aiming turn.
            if (next.shot) {
                shotScale = std::fmin(shotScale, distance / SHOT_APPROACH_FRAMES);
            }
            if (next.locked) {
                lockedFrameScale = std::fmin(lockedFrameScale, distance / LOCKED_APPROACH_FRAMES);
            }
            if (std::fabs(std::remainder(next.offset - center.offset, 360.0f)) >
                OFFSET_TOLERANCE_DEGREES) {
                hasTransition = true;
            }
            if (distance <= KERNEL_RADIUS_FRAMES) {
                const float neighborWeight = CENTER_WEIGHT - distance;
                weightedOffset +=
                    neighborWeight *
                    (center.offset + std::remainder(next.offset - center.offset, 360.0f));
                totalWeight += neighborWeight;
            }
            previous = next;
        }
    }
    if (!hasTransition) {
        return center.yaw + shotScale * (targetYaw - center.yaw);
    }
    return center.yaw + shotScale * lockedFrameScale * weightedOffset / totalWeight;
}

#endif
