#pragma once
#import <QuartzCore/QuartzCore.h>
#import "../Core/Effects.hpp"
namespace ifd {
static NSString *const effectKey=@"com.muflow.infusedanmaku.effect";
struct EffectClock { double age=0,wall=0,rate=-1,nextCheck=0; };
// Compare analytic times in the same clock domain, never presentation snapshots.
inline void driveEffect(CALayer *layer,CAAnimation *animation,double age,double rate,double wall,bool force,EffectClock &clock) {
    rate=std::isfinite(rate)&&rate>0?rate:0;
    bool reset=force||clock.rate!=rate||![layer animationForKey:effectKey];
    if(!reset&&wall>=clock.nextCheck){reset=std::abs(clock.age+(wall-clock.wall)*rate-age)>.04;clock.nextCheck=wall+.2;}
    if(!reset)return;
    animation.beginTime=[layer convertTime:wall fromLayer:nil];animation.timeOffset=std::max(0.0,age);
    animation.speed=rate;animation.removedOnCompletion=NO;animation.fillMode=kCAFillModeBoth;
    [layer addAnimation:animation forKey:effectKey];clock={age,wall,rate,wall+.2};
}
inline CAKeyframeAnimation *styleAnimation(NSString *key,int kind,double fontSize=20) {
    double period=kind==1?.8:kind==2?1.2:2.75;
    CAKeyframeAnimation *a=[CAKeyframeAnimation animationWithKeyPath:key];
    NSMutableArray *values=[NSMutableArray new];
    int count=(int)std::ceil(period*120);
    for(int i=0;i<=count;++i){double t=period*i/count;
        double v=kind==1?heartbeat(t):kind==2?.12*fontSize*trail(t):wiggle(t);
        if(i==count)v=kind==1?1:0;
        [values addObject:@(v)];}
    a.values=values;a.duration=period;a.repeatCount=HUGE_VALF;a.calculationMode=kCAAnimationLinear;
    return a;
}
inline CAAnimationGroup *advancedAnimation(const AdvancedSpec &s,double scale,CGPoint origin,double opacity) {
    CAKeyframeAnimation *position=[CAKeyframeAnimation animationWithKeyPath:@"position"];
    CAKeyframeAnimation *alpha=[CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    NSMutableArray *times=[NSMutableArray new],*positions=[NSMutableArray new],*alphas=[NSMutableArray new];
    // Include every path corner and delay boundary in addition to easing samples.
    std::vector<double> stamps={0,s.duration,std::clamp(s.delay,0.0,s.duration),std::clamp(s.delay+s.moveDuration,0.0,s.duration)};
    if(s.easeOut){for(int i=1;i<61;++i)stamps.push_back(std::clamp(s.delay+s.moveDuration*i/61,0.0,s.duration));}
    double total=0,walked=0;
    for(size_t i=1;i<s.points.size();++i)total+=std::hypot(s.points[i].x-s.points[i-1].x,s.points[i].y-s.points[i-1].y);
    for(size_t i=1;i<s.points.size()&&total>0;++i){walked+=std::hypot(s.points[i].x-s.points[i-1].x,s.points[i].y-s.points[i-1].y);
        stamps.push_back(std::clamp(s.delay+s.moveDuration*walked/total,0.0,s.duration));}
    std::sort(stamps.begin(),stamps.end());stamps.erase(std::unique(stamps.begin(),stamps.end()),stamps.end());
    for(double t:stamps){auto p=s.at(t);[times addObject:@(t/s.duration)];
        CGPoint point=CGPointMake(origin.x+p.x*scale,origin.y+p.y*scale);
        [positions addObject:[NSValue value:&point withObjCType:@encode(CGPoint)]];
        [alphas addObject:@(s.alpha(t)*opacity)];}
    position.values=positions;position.keyTimes=times;position.duration=s.duration;position.calculationMode=kCAAnimationLinear;
    alpha.values=alphas;alpha.keyTimes=times;alpha.duration=s.duration;alpha.calculationMode=kCAAnimationLinear;
    CAAnimationGroup *group=[CAAnimationGroup animation];group.animations=@[position,alpha];group.duration=s.duration;return group;
}
} // namespace ifd
