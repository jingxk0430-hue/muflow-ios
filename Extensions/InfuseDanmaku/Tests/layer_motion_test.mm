#import "../Source/LayerMotion.hpp"
#include <cassert>
#include <iostream>
@interface StalePresentationLayer : CALayer
@property(nonatomic,strong) CALayer *snapshot;
@end
@implementation StalePresentationLayer
- (instancetype)presentationLayer { return (id)self.snapshot; }
@end
int main() {
    @autoreleasepool {
        CALayer *layer=[CALayer layer];
        layer.bounds=CGRectMake(0,0,100,28); layer.anchorPoint=CGPointZero;
        ifd::LayerMotion motion;
        double now=CACurrentMediaTime();
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        ifd::placeLayer(layer,CGPointMake(350,20),1,now,false,motion);
        CABasicAnimation *animation=(CABasicAnimation *)[layer animationForKey:ifd::motionKey];
        assert(animation && [animation.keyPath isEqualToString:@"position.x"]);
        assert([animation.fromValue doubleValue]==350 && [animation.toValue doubleValue]==-100);
        assert(animation.duration==5 && layer.position.x==-100 && layer.position.y==20);
        float control[2]; [animation.timingFunction getControlPointAtIndex:1 values:control];
        assert(control[0]==control[1]); // Linear, no ease-in/ease-out on each comment.
        // An ordinary display tick must not replace the compositor animation.
        ifd::placeLayer(layer,CGPointMake(348.5,20),1,now+1./60,false,motion);
        assert(((CABasicAnimation *)[layer animationForKey:ifd::motionKey]).beginTime==animation.beginTime);
        // Pause freezes the exact media-time position and removes motion.
        ifd::placeLayer(layer,CGPointMake(260,20),0,now+1,false,motion);
        assert([layer animationForKey:ifd::motionKey]==nil && layer.position.x==260 && motion.rate==0);
        // A resumed 2x rate has half the remaining animation duration.
        ifd::placeLayer(layer,CGPointMake(260,20),2,now+2,false,motion);
        assert(((CABasicAnimation *)[layer animationForKey:ifd::motionKey]).duration==2);
        // An explicit seek must reanchor even with an unchanged playback rate.
        ifd::placeLayer(layer,CGPointMake(80,20),2,now+2.016,true,motion);
        assert([((CABasicAnimation *)[layer animationForKey:ifd::motionKey]).fromValue doubleValue]==80);
        // The presentation snapshot may be one frame older than targetTimestamp.
        // At 2x/3x this exceeds the old 2-point threshold despite perfect motion.
        for(double rate : {2.,3.}) {
            StalePresentationLayer *moving=[StalePresentationLayer layer];
            moving.bounds=CGRectMake(0,0,100,28); moving.anchorPoint=CGPointZero;
            moving.snapshot=[CALayer layer]; ifd::LayerMotion state;
            ifd::placeLayer(moving,CGPointMake(500,20),rate,now+10,false,state);
            double begin=((CABasicAnimation *)[moving animationForKey:ifd::motionKey]).beginTime;
            moving.snapshot.position=CGPointMake(500-90*rate*(.21-1./60),20);
            ifd::placeLayer(moving,CGPointMake(500-90*rate*.21,20),rate,now+10.21,false,state);
            assert(((CABasicAnimation *)[moving animationForKey:ifd::motionKey]).beginTime==begin);
            // A genuine media-time discrepancy still causes a correction.
            ifd::placeLayer(moving,CGPointMake(500-90*rate*.42-10,20),rate,now+10.42,false,state);
            assert(((CABasicAnimation *)[moving animationForKey:ifd::motionKey]).beginTime!=begin);
        }
        [CATransaction commit];
        std::cout << "layer motion: linear compositor animation, no per-frame restart, pause, rate and seek passed\n";
    }
}
