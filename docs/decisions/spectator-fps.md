# Spectator FPS decisions

Detailed is the default, with Compact and Off as alternatives. Live was removed;
saved Live preferences fall back to Detailed. All views confirm a strafe after
150 ms of held input and preserve its FPS sequence from the first sample.
Demo playback measures that interval in recorded time, so pauses cannot confirm
an input that was never held long enough in the recording.

Detailed keeps six recent entries and groups release/landing adjustments with
their phase. Compact tracks FPS changes independently of strafe switches.
A repeating halfbeat pattern establishes its style; later braking does not
reclassify an already established airborne history.

Halfbeat correction uses CoD4's own acceleration routine as its reference. It
preserves existing momentum and vertical velocity rather than imposing a fixed
percentage penalty. Physics constants from other engines are not substitutes.

The [maintained reference](../reference/ui/fps-history.md) describes the current
implementation and tests.
