#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <queue>
#include <vector>

namespace ifd {
enum class Mode { scrolling, top, bottom };
struct Comment { double time; double width; Mode mode; std::size_t key; };
struct Placement { Comment comment; int lane; double end; };
struct Visible { std::size_t key; Mode mode; int lane; double x; };

// All scrolling comments have the same velocity, so a later comment cannot
// overtake an earlier one. Fixed top/bottom comments use separate lane pools.
class Timeline {
    double viewport_ = 1, speed_ = 90, maxLifetime_ = 0;
    std::vector<Placement> planned_;
public:
    void prepare(std::vector<Comment> comments, double viewport, int lanes,
                 double pixelsPerSecond = 90, std::size_t maxVisible = 36) {
        planned_.clear(); maxLifetime_ = 0;
        viewport_ = std::max(1.0, viewport);
        speed_ = std::max(1.0, pixelsPerSecond);
        if (lanes <= 0 || maxVisible == 0) return;
        comments.erase(std::remove_if(comments.begin(), comments.end(), [](const Comment &c) {
            return !std::isfinite(c.time) || c.time < 0 || !std::isfinite(c.width) || c.width <= 0;
        }), comments.end());
        std::stable_sort(comments.begin(), comments.end(), [](const Comment &a, const Comment &b) {
            return a.time < b.time;
        });
        std::vector<double> available[3] = {
            std::vector<double>(lanes, -1), std::vector<double>(lanes, -1),
            std::vector<double>(lanes, -1)};
        std::priority_queue<double, std::vector<double>, std::greater<double>> active;
        for (const auto &c : comments) {
            while (!active.empty() && active.top() <= c.time) active.pop();
            if (active.size() >= maxVisible) continue;
            const int pool = c.mode == Mode::scrolling ? 0 : c.mode == Mode::top ? 1 : 2;
            auto &slots = available[pool];
            auto slot = std::find_if(slots.begin(), slots.end(), [&](double freeAt) { return freeAt <= c.time; });
            if (slot == slots.end()) continue; // Never delay comments away from their source timestamp.
            const double lifetime = c.mode == Mode::scrolling ? (viewport_ + c.width) / speed_ : 4;
            const double end = c.time + lifetime;
            *slot = c.mode == Mode::scrolling ? c.time + (c.width + 16) / speed_ : end;
            planned_.push_back({c, static_cast<int>(slot - slots.begin()), end});
            maxLifetime_ = std::max(maxLifetime_, lifetime);
            active.push(end);
        }
    }
    void at(double mediaTime, std::vector<Visible> &result) const {
        result.clear();
        if (!std::isfinite(mediaTime) || mediaTime < 0) return;
        auto first = std::lower_bound(planned_.begin(), planned_.end(), mediaTime - maxLifetime_,
            [](const Placement &p, double t) { return p.comment.time < t; });
        for (auto p = first; p != planned_.end() && p->comment.time <= mediaTime; ++p) {
            if (mediaTime >= p->end) continue;
            const double x = p->comment.mode == Mode::scrolling
                ? viewport_ - speed_ * (mediaTime - p->comment.time)
                : (viewport_ - p->comment.width) / 2;
            result.push_back({p->comment.key, p->comment.mode, p->lane, x});
        }
    }
    std::vector<Visible> at(double mediaTime) const {
        std::vector<Visible> result;
        at(mediaTime, result);
        return result;
    }
    const std::vector<Placement> &placements() const { return planned_; }
};
} // namespace ifd
