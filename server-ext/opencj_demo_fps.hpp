#ifndef OPENCJ_DEMO_FPS_HPP
#define OPENCJ_DEMO_FPS_HPP
#include <deque>
#include <string>
// One selected renderer per viewer. Unchanged text extends its existing span.
// Samples preserve the previous 512-sample rewind window, including edited demos.
struct DemoFPSText {
    static constexpr unsigned MAX_REWIND_SAMPLES = 512;
    struct Change {
        int frame;
        std::string text;
    };
    std::deque<Change> changes;
    std::deque<int> samples;

    void clear() {
        std::deque<Change>().swap(changes);
        std::deque<int>().swap(samples);
    }

    // Rewinds start a new text history; old spans expire with the sample window.
    void put(int frame, const char *text) {
        if (!samples.empty() && frame <= samples.back()) {
            clear();
        }
        samples.push_back(frame);
        if (changes.empty() || changes.back().text != text) {
            changes.push_back({frame, text});
        }
        if (samples.size() > MAX_REWIND_SAMPLES) {
            samples.pop_front();
        }
        while (changes.size() > 1 && changes[1].frame <= samples.front()) {
            changes.pop_front();
        }
    }

    // The returned text belongs to this history and is valid until its next update.
    // A frame outside the retained window has no result.
    const char *get(int frame) const {
        if (samples.empty() || frame < samples.front() || frame > samples.back()) {
            return nullptr;
        }
        for (auto change = changes.rbegin(); change != changes.rend(); ++change) {
            if (change->frame <= frame) {
                return change->text.c_str();
            }
        }
        return nullptr;
    }
};
#endif
