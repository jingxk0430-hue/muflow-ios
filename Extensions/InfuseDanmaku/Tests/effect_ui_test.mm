// Exercise the actual UIKit composition, parser and asynchronous bitmap path.
#import "../Source/InfuseDanmaku.mm"
#include <cassert>
@implementation IFDOnlineSourceBridge
+ (NSProgress *)loadSourceURL:(NSString *)source completion:(void (^)(NSDictionary *,NSError *))completion {
    (void)source;(void)completion;return nil;
}
@end
@interface IFDTestPlayer : NSObject
@property double currentTime;
@property BOOL isPaused;
@property float playbackRate;
@end
@implementation IFDTestPlayer
@end
@interface IFDTestController : UIViewController
@property(nonatomic,strong) IFDTestPlayer *player;
@end
@implementation IFDTestController
@end
@interface IFDTestApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) IFDSession *session;
@end
@implementation IFDTestApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)app;(void)options;
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    IFDTestController *vc=[IFDTestController new];vc.player=[IFDTestPlayer new];
    vc.player.currentTime=7.25;vc.player.isPaused=YES;vc.player.playbackRate=1;
    self.window.rootViewController=vc;[self.window makeKeyAndVisible];vc.view.backgroundColor=[UIColor colorWithWhite:.08 alpha:1];
    self.session=[[IFDSession alloc] initWithController:vc];[self.session start];
    NSData *data=[NSData dataWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"effects-demo" ofType:@"xml"]];
    IFDXMLReader *reader=[IFDXMLReader new];NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];parser.delegate=reader;
    assert([parser parse]&&reader.comments.count==6);self.session.comments=reader.comments;[self.session rebuild];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self verify];});
    return YES;
}
- (void)verify {
    assert(self.session.clockAvailable&&self.session.labels.count>=3&&self.session.pendingImages.count==0);
    NSUInteger advanced=0,styled=0;
    for(IFDRenderLabel *label in self.session.labels.allValues) {
        assert(label.ink&&label.fallback==nil);
        if(label.advancedAnimation){++advanced;assert([label.layer animationForKey:ifd::effectKey].speed==0);}
        if(label.styleActive){++styled;assert(label.animatedLayers.count>0);}
    }
    assert(advanced==2&&styled>=1);
    NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
    UIImage *image=[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *c){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
    [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"effect-ui-preview.png"] atomically:YES];
    // Seek backwards through the real session; old advanced layers must leave.
    IFDTestController *vc=(IFDTestController *)self.window.rootViewController;vc.player.currentTime=3.25;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
        for(IFDRenderLabel *label in self.session.labels.allValues)assert(!label.advancedAnimation);
        self.session.effectsEnabled=NO;[self.session rebuild];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            for(IFDRenderLabel *label in self.session.labels.allValues)assert(!label.styleActive&&label.animatedLayers.count==0);
            [self.session stop];assert(self.session.labels.count==0&&self.session.displayLink==nil);
            NSData *result=[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES,@"advancedLayers":@(advanced),@"styledLayers":@(styled),@"checks":@[@"XML",@"background bitmap delivery",@"paused layer composition",@"backward seek",@"effect disable",@"stop cleanup"]} options:NSJSONWritingPrettyPrinted error:nil];
            [result writeToFile:[directory stringByAppendingPathComponent:@"effect-ui-result.json"] atomically:YES];
        });
    });
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(IFDTestApp.class));}}
