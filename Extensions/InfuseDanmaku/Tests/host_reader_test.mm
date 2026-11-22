#import "../Source/HostReader.hpp"
#include <cassert>
#include <iostream>
@interface IFDClockFixture : NSObject
@property double currentTime;
@property float playbackRate;
@property BOOL isPaused;
@property(nonatomic, strong) id player;
@property NSUInteger signatureQueries;
@end
@implementation IFDClockFixture
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    self.signatureQueries++;
    return [super methodSignatureForSelector:selector];
}
@end
@interface IFDWrongFixture : NSObject
- (NSString *)currentTime;
- (NSInteger)playbackRate;
- (id)broken;
@end
@implementation IFDWrongFixture
- (NSString *)currentTime { return @"wrong ABI"; }
- (NSInteger)playbackRate { return 1; }
- (id)broken { [NSException raise:@"test" format:@"host threw"]; return nil; }
@end
int main() {
    @autoreleasepool {
        IFDClockFixture *host=[IFDClockFixture new];
        host.currentTime=12.5; host.playbackRate=1.5; host.isPaused=YES; host.player=host;
        ifd::NumberGetter time("currentTime"), rate("playbackRate"), paused("isPaused");
        ifd::ObjectGetter player("player"), broken("broken"), incompatible("currentTime");
        double value=0;
        for (int i=0; i<3600; ++i) {
            assert(time.read(host,value) && value==12.5);
            assert(rate.read(host,value) && value==1.5);
            assert(paused.read(host,value) && value==1);
            assert(player.read(host)==host);
        }
        assert(host.signatureQueries==4); // Validation is not repeated per frame.
        host.currentTime=14; assert(time.read(host,value) && value==14);
        host.player=nil;
        assert(!time.read(nil,value) && player.read(nil)==nil);
        IFDWrongFixture *wrong=[IFDWrongFixture new];
        assert(!time.read(wrong,value) && !rate.read(wrong,value));
        assert(broken.read(wrong)==nil && incompatible.read(host)==nil);
        assert(time.read(host,value) && value==14); // Host class replacement revalidates.
        std::cout << "host getters: double/float/bool/object, cached ABI, replacement and failure paths passed\n";
    }
}
