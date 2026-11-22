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
            [self verifyBASWithAdvanced:advanced styled:styled];
        });
    });
}
- (void)verifyBASWithAdvanced:(NSUInteger)advanced styled:(NSUInteger)styled {
    NSString *source=[NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"bas-native-demo" ofType:@"bas"] encoding:NSUTF8StringEncoding error:nil];
    IFDBASDocument *document=[IFDBASDocument parse:source];assert(document.error==nil&&document->scene.nodes.size()==4);
    IFDComment *comment=[IFDComment new];comment.bas=document;comment.mode=9;comment.time=0;comment.text=@"BAS";
    IFDTestController *vc=(IFDTestController *)self.window.rootViewController;vc.player.currentTime=3;vc.player.isPaused=YES;
    self.session.comments=@[comment];self.session.effectsEnabled=YES;[self.session rebuild];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        assert(self.session.labels.count==0&&self.session.sceneLayers.count==1&&self.session.pendingScenes.count==0);
        IFDBASLayer *scene=self.session.sceneLayers[@0];assert(scene.root.sublayers.count==3); // caption is nested under title
        for(CALayer *layer in scene.layers)assert([layer animationForKey:ifd::effectKey].speed==0);
        CALayer *title=scene.root.sublayers[0];assert(title.sublayers.count==2); // ink + child caption
        CGPoint p=((CALayer *)title.presentationLayer).position;assert(fabs(p.x-self.window.bounds.size.width*.5)<1);
        NSString *directory=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
        UIImage *image=[renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *c){[self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];}];
        [UIImagePNGRepresentation(image) writeToFile:[directory stringByAppendingPathComponent:@"bas-ui-preview.png"] atomically:YES];
        vc.player.currentTime=10;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
            assert(self.session.sceneLayers.count==0);vc.player.currentTime=3;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                assert(self.session.sceneLayers.count==1);self.session.effectsEnabled=NO;[self.session rebuild];assert(self.session.sceneLayers.count==0);
                [self.session stop];assert(self.session.labels.count==0&&self.session.sceneLayers.count==0&&self.session.displayLink==nil);
            NSData *result=[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES,@"advancedLayers":@(advanced),@"styledLayers":@(styled),@"checks":@[@"XML",@"background bitmap delivery",@"paused layer composition",@"backward seek",@"effect disable",@"BAS native text/path/button",@"BAS parent bounds",@"BAS paused compositor",@"BAS expired and backward seek",@"stop cleanup"]} options:NSJSONWritingPrettyPrinted error:nil];
            [result writeToFile:[directory stringByAppendingPathComponent:@"effect-ui-result.json"] atomically:YES];
            });
        });
    });
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(IFDTestApp.class));}}
