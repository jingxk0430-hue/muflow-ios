#import "../Source/EffectModel.hpp"
#import "../Source/EffectAnimation.hpp"
#include <cassert>
int main(){@autoreleasepool {
    IFDAdvancedText *m=[IFDAdvancedText parse:@"[0.1,0.2,\"1-0\",6,\"高级弹幕\",30,45,0.9,0.8,2000,1000,\"false\",\"\",\"1\",\"M0,0L100,0L100,300\"]" fontSize:25];
    assert(m&&m.outline&&m->spec.points.size()==3&&m->spec.duration==6&&m->spec.delay==1);
    assert(m->spec.at(2).x==100&&m->spec.at(2).y==100);
    IFDAdvancedText *fraction=[IFDAdvancedText parse:@"[0.5,0.25,\"0.2-1\",5,\"文本\"]" fontSize:25];
    assert(fraction&&fraction->spec.points[0].x==336&&fraction->spec.points[0].y==109.5);
    for(NSString *bad in @[@"{}",@"[0,0,\"1-0\",0,\"x\"]",@"[null,0,1,4,\"x\"]",@"[0,0,\"nan\",4,\"x\"]",@"[0,0,1,31,\"x\"]",@"[0,0,1,4,{}]",@"[0,0,1,4,\"x\",0,0,1,1,-1,0]",@"[0,0,1,4,\"x\",0,0,1,1,1000,0,\"\",\"\",\"\",\"M0,0C1,1\"]"])
        assert(![IFDAdvancedText parse:bad fontSize:25]);
    IFDTextStyle *style=[IFDTextStyle parse:@{@"animation":@3,@"colorInfo":@"{\"type\":1,\"details\":\"[\\\"ff0000\\\",\\\"0000ff\\\"]\",\"orientation\":\"-90deg\",\"stroke\":\"ffffff\"}"}];
    assert(style.animation==3&&style.colors.count==2&&style.angle==-90&&style.stroke.unsignedIntValue==0xffffff);
    assert(([IFDTextStyle parse:@{@"animation":@99,@"colors":@[@"bad",@"ffffff"]}].colors.count==0));
    CALayer *layer=[CALayer layer];ifd::EffectClock clock;
    CAAnimationGroup *group=ifd::advancedAnimation(m->spec,1,CGPointMake(0,0),.75);
    ifd::driveEffect(layer,group,2,1,100,false,clock);assert(clock.age==2&&clock.rate==1);
    CAAnimation *first=[layer animationForKey:ifd::effectKey];assert(first.timeOffset==2&&first.speed==1);
    ifd::driveEffect(layer,group,2.21,1,100.21,false,clock);assert(clock.wall==100); // no periodic restart
    ifd::driveEffect(layer,group,2.21,0,100.22,false,clock);assert([layer animationForKey:ifd::effectKey].speed==0);
    ifd::driveEffect(layer,group,1,2,101,true,clock);assert(clock.age==1&&clock.rate==2); // seek and rate
    ifd::driveEffect(layer,group,1.42,2,101.21,false,clock);assert(clock.wall==101);
    ifd::driveEffect(layer,group,4,2,101.5,false,clock);assert(clock.wall==101.5); // real drift
    assert(group.animations.count==2&&group.duration==6);
    for(int kind=1;kind<=3;++kind){CAKeyframeAnimation *a=ifd::styleAnimation(@"transform.scale",kind);assert(a.values.count>50&&a.repeatCount>1000);}
    puts("effect parser, bounds, paths, style metadata, pause/rate/seek and animation clocks passed");
}}
