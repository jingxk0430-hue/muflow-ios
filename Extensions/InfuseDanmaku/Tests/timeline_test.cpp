#include "../Core/Timeline.hpp"
#include <cassert>
#include <limits>
#include <iostream>
using namespace ifd;
int main() {
    Timeline t;
    // A wide leading comment blocks the same lane until its tail clears.
    t.prepare({{0,200,Mode::scrolling,0},{1,30,Mode::scrolling,1},
               {2.2,30,Mode::scrolling,2}}, 400, 1, 100);
    assert(t.placements().size() == 2);
    assert(t.placements()[1].comment.key == 2);
    const auto together = t.at(3);
    assert(together.size() == 2);
    assert(together[0].x + 200 + 16 <= together[1].x + 0.0001);
    // Repeated media time freezes exactly; seeking backwards reconstructs.
    const auto before = t.at(1);
    assert(t.at(1)[0].x == before[0].x);
    assert(t.at(100).empty());
    assert(t.at(1)[0].x == before[0].x);
    // Fixed comments are centered and top/bottom occupy independent pools.
    t.prepare({{0,100,Mode::top,0},{0,100,Mode::bottom,1},
               {1,100,Mode::top,2},{4,100,Mode::top,3}},400,1);
    assert(t.placements().size()==3);
    assert(t.at(2).size()==2 && t.at(2)[0].x==150);
    assert(t.at(4).size()==1 && t.at(4)[0].key==3);
    // Dense input cannot exceed the global simultaneous display cap.
    std::vector<Comment> dense;
    for (std::size_t i=0;i<1000;++i) dense.push_back({0,30,Mode::scrolling,i});
    t.prepare(dense,400,1000,100,12);
    assert(t.at(0).size()==12);
    // Invalid timestamps/widths and zero lanes never enter the scheduler.
    t.prepare({{std::numeric_limits<double>::quiet_NaN(),30,Mode::top,0},
               {0,-1,Mode::top,1},{-2,30,Mode::top,2}},400,2);
    assert(t.placements().empty());
    t.prepare(dense,400,0);
    assert(t.at(0).empty());
    assert(t.at(std::numeric_limits<double>::infinity()).empty());
    // Rendering is driven by media time: a 2x media advance doubles movement.
    t.prepare({{0,100,Mode::scrolling,0}},400,1,100);
    assert(t.at(0)[0].x-t.at(2)[0].x == 2*(t.at(0)[0].x-t.at(1)[0].x));
    // Viewport changes regenerate coordinates without retaining old geometry.
    t.prepare({{0,100,Mode::top,0}},800,1);
    assert(t.at(0)[0].x==350);
    std::cout << "timeline: collision, pause, seek, modes, cap, validation, rate and resize passed\n";
}
