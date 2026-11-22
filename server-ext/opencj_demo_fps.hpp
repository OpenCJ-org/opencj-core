#ifndef OPENCJ_DEMO_FPS_HPP
#define OPENCJ_DEMO_FPS_HPP
#include <deque>
#include <string>
// One selected renderer per viewer. Unchanged text extends its existing span.
// Samples preserve the previous 512-sample rewind window, including edited demos.
struct DemoFPSText {
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

    void put(int frame, const char *text) {
        if (!samples.empty() && frame <= samples.back()) {
            clear();
        }
        samples.push_back(frame);
        if (changes.empty() || changes.back().text != text) {
            changes.push_back({frame, text});
        }
        if (samples.size() > 512) {
            samples.pop_front();
        }
        while (changes.size() > 1 && changes[1].frame <= samples.front()) {
            changes.pop_front();
        }
    }

    const char *get(int frame) const {
        if (samples.empty() || frame < samples.front() || frame > samples.back()) {
            return nullptr;
        }
        for (auto i = changes.rbegin(); i != changes.rend(); ++i) {
            if (i->frame <= frame) {
                return i->text.c_str();
            }
        }
        return nullptr;
    }
};
#endif
