#pragma once
#include <algorithm>
#include <cmath>

namespace ifd {
// Smooth coarse (e.g. 24-fps) host timestamps at display refresh rate. Host time
// remains authoritative for seeks, pause and rate changes. A bounded lead stops
// the overlay from running away when playback stalls without setting isPaused.
class MediaClock {
    bool ready_ = false, running_ = false, advancing_ = false;
    double sample_ = 0, wall_ = 0, anchor_ = 0, anchorWall_ = 0, rate_ = 0;
public:
    void reset() { ready_ = false; advancing_ = false; }
    bool advancing() const { return advancing_; }
    double sample(double media, double now, double target,
                  bool stateKnown, bool paused, double rate) {
        if (!std::isfinite(media) || !std::isfinite(now)) {
            reset(); return media;
        }
        const bool running = stateKnown && !paused && std::isfinite(rate) && rate > 0 && rate <= 16;
        if (!std::isfinite(target)) target = now;
        target = std::clamp(target, now, now + .05);
        const bool discontinuity = ready_ && (now < wall_ || now - wall_ > .25 ||
            media < sample_ - .05 || std::abs((media - sample_) - (now - wall_) * rate_) > .25);
        if (!ready_ || discontinuity || running != running_ || (running && rate != rate_)) {
            anchor_ = media; anchorWall_ = now;
        } else if (!running) {
            anchor_ = media; anchorWall_ = now;
        } else if (media != sample_) {
            const double predicted = anchor_ + (now - anchorWall_) * rate;
            // Correct the phase gradually instead of snapping on every video
            // frame. Duplicated samples keep advancing smoothly between them.
            anchor_ = predicted + (media - predicted) * .12;
            anchorWall_ = now;
        }
        ready_ = true; running_ = running; rate_ = running ? rate : 0;
        sample_ = media; wall_ = now;
        const double predicted = anchor_ + (target - anchorWall_) * rate;
        advancing_ = running && predicted < media + .12 * rate;
        return running ? std::min(predicted, media + .12 * rate) : media;
    }
};
} // namespace ifd
