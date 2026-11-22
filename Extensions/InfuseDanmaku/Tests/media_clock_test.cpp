#include "../Core/MediaClock.hpp"
#include <cassert>
#include <cmath>
#include <iostream>
#include <limits>
using ifd::MediaClock;
int main() {
    // A 24-fps host clock must still advance on every 60-Hz display refresh.
    for (double fps : {23.976, 24., 25., 30., 60.}) for (double rate : {.5, 1., 2.}) {
        MediaClock clock;
        double previous = -1;
        for (int frame = 0; frame < 600; ++frame) {
            double wall = frame / 60.;
            double host = std::floor(wall * rate * fps + 1e-8) / fps;
            double rendered = clock.sample(host, wall, wall + 1 / 60., true, false, rate);
            assert(std::abs(rendered - (wall + 1 / 60.) * rate) < .045);
            if (frame > 60) {
                double step = rendered - previous;
                assert(step > .65 * rate / 60 && step < 1.35 * rate / 60);
            }
            previous = rendered;
        }
    }
    MediaClock c;
    c.sample(10, 1, 1.016, true, false, 1);
    assert(c.sample(10.01, 1.01, 1.026, true, true, 1) == 10.01);
    assert(c.sample(10.01, 2, 2.016, true, true, 1) == 10.01);
    // Paused seeks and running forward/backward seeks follow the new position.
    assert(c.sample(50, 2.1, 2.116, true, true, 1) == 50);
    assert(std::abs(c.sample(50, 2.2, 2.216, true, false, 2) - 50.032) < 1e-8);
    assert(std::abs(c.sample(100, 2.216, 2.232, true, false, 2) - 100.032) < 1e-8);
    assert(std::abs(c.sample(5, 2.232, 2.248, true, false, 1) - 5.016) < 1e-8);
    // Buffering must not move comments indefinitely on a frozen host clock.
    c.reset();
    for (int i = 0; i < 120; ++i)
        assert(c.sample(1, i / 60., (i + 1) / 60., true, false, 1) <= 1.120001);
    // Unavailable pause/rate ABI uses exact host time, never assumes playback.
    assert(c.sample(7, 4, 4.016, false, false, 1) == 7);
    assert(c.sample(8, 5, 5.016, true, false, 0) == 8);
    assert(std::isnan(c.sample(std::numeric_limits<double>::quiet_NaN(), 6, 6.016, true, false, 1)));
    assert(std::abs(c.sample(9, 7, 7.016, true, false, 1) - 9.016) < 1e-8);
    std::cout << "media clock: 23.976/24/25/30/60fps to 60Hz, 0.5x/1x/2x, pause, seeks, buffering and ABI fallback passed\n";
}
