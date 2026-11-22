#pragma once
#import <QuartzCore/QuartzCore.h>
#include <cmath>

namespace ifd {
static NSString *const motionKey = @"com.muflow.infusedanmaku.scroll";
struct LayerMotion { double rate = 0, nextCheck = 0, anchorX = 0, anchorY = 0, anchorWall = 0; };

// A linear compositor animation advances between host callbacks, even when the
// main thread misses a display-link tick. The caller still owns media-time
// scheduling and immediately freezes/reanchors on pause, buffering and seeks.
inline void placeLayer(CALayer *layer, CGPoint position, double rate, double wall,
                       bool force, LayerMotion &motion) {
    if (!(rate > 0) || !std::isfinite(rate)) {
        if (motion.rate > 0) [layer removeAnimationForKey:motionKey];
        motion = {};
        layer.position = position;
        return;
    }
    bool restart = force || motion.rate != rate;
    if (!restart && wall >= motion.nextCheck) {
        // Both positions refer to the same future display time. Comparing a
        // targetTimestamp position with presentationLayer (an earlier frame)
        // spuriously reanchors at 2x/3x, even when the animation is on time.
        const double expected=motion.anchorX-90*motion.rate*(wall-motion.anchorWall);
        restart = wall < motion.anchorWall || std::abs(expected-position.x)>2 ||
            std::abs(motion.anchorY-position.y)>.5;
        motion.nextCheck = wall + .2;
    }
    if (!restart) return;
    const double end = -layer.bounds.size.width;
    const double duration = (position.x - end) / (90 * rate);
    if (!(duration > 0) || !std::isfinite(duration)) return;
    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position.x"];
    animation.fromValue = @(position.x); animation.toValue = @(end);
    animation.duration = duration;
    animation.beginTime = [layer convertTime:wall fromLayer:nil];
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    animation.fillMode = kCAFillModeBackwards;
    layer.position = CGPointMake(end, position.y);
    [layer addAnimation:animation forKey:motionKey];
    motion.rate = rate; motion.nextCheck = wall + .2;
    motion.anchorX=position.x; motion.anchorY=position.y; motion.anchorWall=wall;
}
} // namespace ifd
