#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <cmath>
#import "../Core/Timeline.hpp"
#import "../Core/MediaClock.hpp"
#import "HostReader.hpp"
#import "LayerMotion.hpp"
#import "TextBitmap.hpp"

@interface IFDOnlineSourceBridge : NSObject
+ (NSProgress *)loadSourceURL:(NSString *)source completion:(void (^)(NSDictionary *, NSError *))completion;
@end
@class IFDSession;
static NSHashTable<IFDSession *> *IFDSessions;
static NSString *const IFDMenuIdentifier=@"com.muflow.infusedanmaku.controls";

@interface IFDComment : NSObject
@property double time;
@property NSInteger mode;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) UIColor *color;
@property CGFloat width;
@property(nonatomic, strong) NSNumber *renderKey;
@end
@implementation IFDComment
@end

@interface IFDXMLReader : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<IFDComment *> *comments;
@property(nonatomic, strong) IFDComment *current;
@property(nonatomic, strong) NSMutableString *content;
@property BOOL limited;
@end
@implementation IFDXMLReader
- (instancetype)init { if ((self=[super init])) _comments=[NSMutableArray array]; return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)q attributes:(NSDictionary<NSString *,NSString *> *)attrs {
    if (![name isEqualToString:@"d"]) return;
    NSArray<NSString *> *p = [attrs[@"p"] componentsSeparatedByString:@","];
    if (p.count < 4 || self.comments.count >= 30000) {
        if (self.comments.count >= 30000) { self.limited=YES; [parser abortParsing]; }
        return;
    }
    double seconds = 0; NSScanner *scanner=[NSScanner scannerWithString:p[0]];
    if (![scanner scanDouble:&seconds] || !scanner.isAtEnd || !std::isfinite(seconds) || seconds<0) return;
    NSInteger mode = [p[1] integerValue];
    if (!(mode==1 || mode==2 || mode==3 || mode==4 || mode==5)) return;
    unsigned int rgb = (unsigned int)[p[3] longLongValue] & 0xffffff;
    IFDComment *c=[IFDComment new]; c.time=seconds; c.mode=mode;
    c.color=[UIColor colorWithRed:((rgb>>16)&255)/255.0 green:((rgb>>8)&255)/255.0
                             blue:(rgb&255)/255.0 alpha:1];
    self.current=c; self.content=[NSMutableString string];
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s {
    if (self.current && self.content.length < 300) {
        [self.content appendString:[s substringToIndex:MIN(s.length,300-self.content.length)]];
    }
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)q {
    if (![name isEqualToString:@"d"] || !self.current) return;
    self.current.text=[[self.content stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (self.current.text.length) [self.comments addObject:self.current];
    self.current=nil; self.content=nil;
}
@end

// This view contains only text. The entry point lives in the native gear menu.
@interface IFDOverlay : UIView
@end
@implementation IFDOverlay
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)event {
    return nil;
}
@end

@interface IFDTextImage : NSObject
@property(nonatomic, readonly) CGImageRef image;
- (instancetype)initWithImage:(CGImageRef)image;
@end
@implementation IFDTextImage
- (instancetype)initWithImage:(CGImageRef)image {
    if ((self=[super init])) _image=CGImageRetain(image);
    return self;
}
- (void)dealloc { CGImageRelease(_image); }
@end

@interface IFDRenderLabel : UIView {
@public
    ifd::LayerMotion motion;
}
@property(nonatomic, strong) UILabel *fallback;
- (void)showImage:(IFDTextImage *)image;
- (void)showFallback:(IFDComment *)comment font:(UIFont *)font;
@end
@implementation IFDRenderLabel
- (void)showImage:(IFDTextImage *)image {
    [self.fallback removeFromSuperview]; self.fallback=nil;
    self.layer.contents=(__bridge id)image.image;
}
- (void)showFallback:(IFDComment *)comment font:(UIFont *)font {
    if (!self.fallback) {
        self.fallback=[[UILabel alloc] initWithFrame:self.bounds];
        self.fallback.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        self.fallback.numberOfLines=1; self.fallback.userInteractionEnabled=NO;
        [self addSubview:self.fallback];
    }
    self.fallback.attributedText=[[NSAttributedString alloc] initWithString:comment.text attributes:@{
        NSFontAttributeName:font,NSForegroundColorAttributeName:comment.color,
        NSStrokeColorAttributeName:[UIColor colorWithWhite:0 alpha:.9],NSStrokeWidthAttributeName:@(-2.0)}];
}
@end

@interface IFDDisplayProxy : NSObject
@property(nonatomic, weak) id target;
- (void)tick:(CADisplayLink *)link;
@end
@implementation IFDDisplayProxy
- (void)tick:(CADisplayLink *)link {
    id target=self.target;
    if (target) [target tick:link];
    else [link invalidate];
}
@end

@interface IFDSession : NSObject <UIDocumentPickerDelegate> {
    ifd::Timeline _timeline;
    ifd::MediaClock _clock;
    ifd::PlayerGetters _getters;
    std::vector<ifd::Visible> _visible;
    double _lastDrawnTime, _lastRenderRate, _nextPlayerLookup, _nextPrewarm;
}
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, weak) id cachedPlayer;
@property(nonatomic, strong) IFDOverlay *overlay;
@property(nonatomic, strong) UIMenu *controlsMenu;
@property(nonatomic, strong) NSProgress *onlineProgress;
@property NSUInteger loadGeneration;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) NSArray<IFDComment *> *comments;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *,IFDRenderLabel *> *labels;
@property(nonatomic, strong) NSMutableArray<IFDRenderLabel *> *recycledLabels;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *activeKeys;
@property(nonatomic, strong) UIFont *renderFont;
@property(nonatomic, strong) NSCache<NSNumber *,IFDTextImage *> *textImages;
@property(nonatomic, strong) NSOperationQueue *textQueue;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *pendingImages;
@property(nonatomic, weak) NSArray<IFDComment *> *preparedComments;
@property NSUInteger renderGeneration;
@property BOOL enabled;
@property BOOL importing;
@property BOOL clockAvailable;
@property CGFloat fontSize;
@property CGFloat textOpacity;
@property CGFloat area;
@property double delay;
@property CGSize preparedSize;
@property CGFloat preparedScale;
@property CGFloat measuredFontSize;
@property NSInteger laneCount;
- (instancetype)initWithController:(UIViewController *)controller;
- (void)start;
- (void)stop;
- (void)updateMenu;
- (void)cancelTextPreparation;
- (void)prepareImage:(IFDComment *)comment;
- (void)prewarmAt:(double)time;
@end

@implementation IFDSession
- (instancetype)initWithController:(UIViewController *)controller {
    if ((self=[super init])) {
        _controller=controller; _comments=@[]; _labels=[NSMutableDictionary dictionary];
        _recycledLabels=[NSMutableArray arrayWithCapacity:36];
        _activeKeys=[NSMutableSet setWithCapacity:36]; _visible.reserve(36);
        _textImages=[NSCache new]; _textImages.countLimit=128; _textImages.totalCostLimit=12*1024*1024;
        _pendingImages=[NSMutableSet setWithCapacity:72];
        _textQueue=[NSOperationQueue new]; _textQueue.maxConcurrentOperationCount=1;
        _textQueue.qualityOfService=NSQualityOfServiceUserInitiated;
        _lastDrawnTime=NAN;
        _enabled=YES; _fontSize=20; _textOpacity=1; _area=.5;
        if (!IFDSessions) IFDSessions=[NSHashTable weakObjectsHashTable];
        [IFDSessions addObject:self];
        [self updateMenu];
    }
    return self;
}
- (void)start {
    UIViewController *vc=self.controller;
    if (!vc || !vc.isViewLoaded) return;
    if (!self.overlay) {
        IFDOverlay *v=[[IFDOverlay alloc] initWithFrame:vc.view.bounds];
        v.backgroundColor=UIColor.clearColor; v.clipsToBounds=YES;
        v.userInteractionEnabled=NO;
        v.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        self.overlay=v;
    }
    if (self.overlay.superview != vc.view) [vc.view addSubview:self.overlay];
    self.overlay.hidden=NO;
    _clock.reset(); _lastDrawnTime=NAN; _nextPlayerLookup=0;
    if (!self.displayLink) {
        IFDDisplayProxy *proxy=[IFDDisplayProxy new]; proxy.target=self;
        self.displayLink=[CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
        self.displayLink.preferredFrameRateRange=CAFrameRateRangeMake(60,60,60);
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
- (void)stop {
    [self cancelTextPreparation]; [self clearLabels];
    [self.displayLink invalidate]; self.displayLink=nil; self.overlay.hidden=YES;
    self.cachedPlayer=nil; _clock.reset(); _lastDrawnTime=NAN;
}
- (void)dealloc { [_onlineProgress cancel]; [_textQueue cancelAllOperations]; [_displayLink invalidate]; [_overlay removeFromSuperview]; }
- (UIAction *)action:(NSString *)title block:(void (^)(IFDSession *))block {
    __weak IFDSession *weak=self;
    return [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *a) {
        IFDSession *s=weak; if (s) block(s);
    }];
}
- (void)updateMenu {
    NSMutableArray<UIMenuElement *> *items=[NSMutableArray array];
    UIAction *status=[UIAction actionWithTitle:(self.onlineProgress ? @"正在获取弹幕…" :
        [NSString stringWithFormat:@"扩展 0.1.3 · %lu 条 · %g 号 · 延迟 %+.1fs",(unsigned long)self.comments.count,
                                  (double)self.fontSize,self.delay]) image:nil identifier:nil handler:^(__unused UIAction *a){}];
    status.attributes=UIMenuElementAttributesDisabled;
    [items addObject:status];
    [items addObject:[self action:@"从视频网页获取弹幕" block:^(IFDSession *s){ [s enterSourceURL]; }]];
    if (self.onlineProgress) [items addObject:[self action:@"取消获取弹幕" block:^(IFDSession *s){ [s cancelOnline]; }]];
    [items addObject:[self action:@"导入 XML 弹幕" block:^(IFDSession *s){ [s importXML]; }]];
    [items addObject:[self action:(self.enabled?@"关闭弹幕":@"开启弹幕") block:^(IFDSession *s){
        s.enabled=!s.enabled; s->_clock.reset(); [s cancelTextPreparation]; [s clearLabels]; [s updateMenu];
    }]];
    [items addObject:[self action:@"字号增大" block:^(IFDSession *s){ s.fontSize=MIN(32,s.fontSize+2); [s rebuild]; }]];
    [items addObject:[self action:@"字号减小" block:^(IFDSession *s){ s.fontSize=MAX(12,s.fontSize-2); [s rebuild]; }]];
    [items addObject:[self action:@"切换显示区域" block:^(IFDSession *s){ s.area=s.area<.45?.5:s.area<.6?.75:.33; [s rebuild]; }]];
    [items addObject:[self action:@"切换透明度" block:^(IFDSession *s){ s.textOpacity=s.textOpacity>.9?.75:s.textOpacity>.6?.5:1; [s rebuild]; }]];
    [items addObject:[self action:@"弹幕推迟 0.5 秒" block:^(IFDSession *s){ s.delay+=.5; [s updateMenu]; }]];
    [items addObject:[self action:@"弹幕提前 0.5 秒" block:^(IFDSession *s){ s.delay-=.5; [s updateMenu]; }]];
    [items addObject:[self action:@"恢复默认样式和时间" block:^(IFDSession *s){
        s.fontSize=20; s.area=.5; s.textOpacity=1; s.delay=0; [s rebuild];
    }]];
    [items addObject:[self action:@"清除本次弹幕" block:^(IFDSession *s){ [s cancelOnline]; s.comments=@[]; [s rebuild]; }]];
    self.controlsMenu=[UIMenu menuWithTitle:@"弹幕" children:items];
}
- (void)clearLabels {
    for (IFDRenderLabel *l in self.labels.allValues) [self recycleLabel:l];
    [self.labels removeAllObjects];
    _lastDrawnTime=NAN;
}
- (void)recycleLabel:(IFDRenderLabel *)label {
    [label.layer removeAnimationForKey:ifd::motionKey]; label->motion={};
    label.layer.contents=nil; [label.fallback removeFromSuperview]; label.fallback=nil;
    [label removeFromSuperview];
    if (self.recycledLabels.count<36) [self.recycledLabels addObject:label];
}
- (void)rebuild {
    BOOL resetImages=self.measuredFontSize!=self.fontSize || self.preparedComments!=self.comments ||
        self.preparedScale!=(self.overlay.window.screen.scale ?: UIScreen.mainScreen.scale);
    [self cancelTextPreparation];
    if (resetImages) [self.textImages removeAllObjects];
    self.preparedComments=self.comments;
    [self clearLabels];
    CGSize size=self.overlay.bounds.size; self.preparedSize=size;
    self.preparedScale=self.overlay.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGFloat row=self.fontSize+8;
    CGFloat usableHeight=MAX(0,size.height-self.overlay.safeAreaInsets.top-self.overlay.safeAreaInsets.bottom-64);
    int lanes=MAX(1,(int)floor(usableHeight*self.area/(3*row)));
    lanes=MIN(lanes,12);
    self.laneCount=lanes;
    UIFont *font=[UIFont systemFontOfSize:self.fontSize weight:UIFontWeightRegular];
    self.renderFont=font;
    BOOL measure=self.measuredFontSize!=self.fontSize;
    self.measuredFontSize=self.fontSize;
    std::vector<ifd::Comment> comments;
    comments.reserve(self.comments.count);
    for (NSUInteger i=0;i<self.comments.count;++i) {
        IFDComment *c=self.comments[i];
        if (measure || c.width<=0) c.width=ceil([c.text sizeWithAttributes:@{NSFontAttributeName:font}].width)+4;
        c.renderKey=@(i);
        auto mode=c.mode==4?ifd::Mode::bottom:c.mode==5?ifd::Mode::top:ifd::Mode::scrolling;
        // Top and scrolling comments share a visual band split below in tick.
        comments.push_back({c.time,(double)c.width,mode,i});
    }
    _timeline.prepare(std::move(comments),size.width,lanes,90,36);
    [self updateMenu];
}
- (void)cancelTextPreparation {
    self.renderGeneration++; [self.textQueue cancelAllOperations];
    [self.pendingImages removeAllObjects]; _nextPrewarm=0;
}
- (void)prepareImage:(IFDComment *)comment {
    NSNumber *key=comment.renderKey;
    if (!key || [self.textImages objectForKey:key] || [self.pendingImages containsObject:key] ||
        self.pendingImages.count>=72) return;
    CGSize size=CGSizeMake(comment.width,self.fontSize+8); CGFloat scale=self.preparedScale;
    size_t width=0,height=0;
    if (!ifd::bitmapSize(size,scale,width,height)) return;
    [self.pendingImages addObject:key]; NSUInteger generation=self.renderGeneration;
    NSString *text=comment.text,*fontName=self.renderFont.fontName;
    CGFloat fontSize=self.fontSize; UIColor *color=comment.color;
    __weak IFDSession *weak=self;
    [self.textQueue addOperationWithBlock:^{
        @autoreleasepool {
            CGImageRef pixels=ifd::createTextBitmap((__bridge CFStringRef)text,(__bridge CFStringRef)fontName,
                fontSize,color.CGColor,size,scale);
            IFDTextImage *image=pixels?[[IFDTextImage alloc] initWithImage:pixels]:nil;
            if (pixels) CGImageRelease(pixels);
            dispatch_async(dispatch_get_main_queue(),^{
                IFDSession *s=weak; if (!s || generation!=s.renderGeneration) return;
                [s.pendingImages removeObject:key];
                if (image) {
                    [s.textImages setObject:image forKey:key cost:CGImageGetBytesPerRow(image.image)*CGImageGetHeight(image.image)];
                    [CATransaction begin]; [CATransaction setDisableActions:YES];
                    [s.labels[key] showImage:image];
                    [CATransaction commit];
                } else [s.labels[key] showFallback:comment font:s.renderFont];
            });
        }
    }];
}
- (void)prewarmAt:(double)time {
    const auto &placements=_timeline.placements();
    auto p=std::lower_bound(placements.begin(),placements.end(),time,
        [](const ifd::Placement &entry,double t){ return entry.comment.time<t; });
    NSUInteger requested=0;
    for (;p!=placements.end() && p->comment.time<=time+1.5 && requested<12;++p) {
        NSUInteger before=self.pendingImages.count;
        [self prepareImage:self.comments[p->comment.key]];
        if (self.pendingImages.count>before) ++requested;
    }
}
- (void)tick:(CADisplayLink *)link {
    if (!self.enabled || !self.comments.count) return;
    CGFloat scale=self.overlay.window.screen.scale ?: UIScreen.mainScreen.scale;
    if (!CGSizeEqualToSize(self.preparedSize,self.overlay.bounds.size) || self.preparedScale!=scale) [self rebuild];
    double now=CACurrentMediaTime();
    id player=self.cachedPlayer;
    if (!player || now>=_nextPlayerLookup) {
        id found=_getters.player.read(self.controller);
        if (!found) found=_getters.player.read(_getters.container.read(self.controller));
        if (found!=player) { _clock.reset(); _lastDrawnTime=NAN; }
        player=found; self.cachedPlayer=found; _nextPlayerLookup=now+.25;
    }
    double time=0;
    self.clockAvailable=_getters.time.read(player,time);
    if (!self.clockAvailable) {
        _clock.reset(); if (self.labels.count) [self clearLabels]; return;
    }
    double paused=0, rate=0;
    bool hasPause=_getters.paused.read(player,paused), hasRate=_getters.rate.read(player,rate);
    time=_clock.sample(time,now,link.targetTimestamp,hasPause&&hasRate,paused!=0,rate)-self.delay;
    double renderRate=_clock.advancing()?rate:0;
    if (time==_lastDrawnTime && renderRate==_lastRenderRate) return;
    BOOL jumped=std::isfinite(_lastDrawnTime) && std::abs(time-_lastDrawnTime)>.25;
    if (jumped) [self cancelTextPreparation];
    _lastDrawnTime=time; _lastRenderRate=renderRate;
    _timeline.at(time,_visible);
    NSMutableSet<NSNumber *> *active=self.activeKeys; [active removeAllObjects];
    CGFloat row=self.fontSize+8;
    CGFloat base=self.overlay.safeAreaInsets.top+8;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (auto &p:_visible) {
        IFDComment *c=self.comments[p.key]; NSNumber *key=c.renderKey;
        [active addObject:key]; IFDRenderLabel *label=self.labels[key];
        if (!label) {
            label=self.recycledLabels.lastObject;
            if (label) [self.recycledLabels removeLastObject]; else label=[IFDRenderLabel new];
            label.userInteractionEnabled=NO; label.opaque=NO;
            label.contentScaleFactor=scale; label.layer.contentsScale=scale;
            label.layer.shouldRasterize=NO;
            label.layer.anchorPoint=CGPointZero;
            label.bounds=CGRectMake(0,0,c.width,row);
            label.alpha=self.textOpacity; [self.overlay addSubview:label];
            self.labels[key]=label;
        }
        // A seek or a long callback gap can cancel a queued bitmap while its
        // view survives. Retry empty views, not only newly created ones.
        if (!label.layer.contents && !label.fallback) {
            IFDTextImage *image=[self.textImages objectForKey:key];
            if (image) [label showImage:image];
            else {
                size_t width=0,height=0;
                if (!ifd::bitmapSize(label.bounds.size,scale,width,height) ||
                    (self.pendingImages.count>=72 && ![self.pendingImages containsObject:key]))
                    [label showFallback:c font:self.renderFont];
                else [self prepareImage:c];
            }
        }
        CGFloat y=base+p.lane*row;
        if (p.mode==ifd::Mode::top) y+=self.laneCount*row;
        else if (p.mode==ifd::Mode::bottom) y=self.overlay.bounds.size.height-self.overlay.safeAreaInsets.bottom-42-row*(p.lane+1);
        CGPoint position=CGPointMake(round(p.x*scale)/scale,round(y*scale)/scale);
        double wall=std::clamp(link.targetTimestamp,now,now+.05);
        ifd::placeLayer(label.layer,position,p.mode==ifd::Mode::scrolling?renderRate:0,wall,jumped,label->motion);
    }
    for (NSNumber *key in self.labels.allKeys) {
        if (![active containsObject:key]) { [self recycleLabel:self.labels[key]]; [self.labels removeObjectForKey:key]; }
    }
    [CATransaction commit];
    // Visible comments take priority over speculative preparation.
    if (now>=_nextPrewarm) { [self prewarmAt:time]; _nextPrewarm=now+.1; }
}
- (void)message:(NSString *)message {
    UIViewController *vc=self.controller;
    if (!vc || vc.presentedViewController) return;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"弹幕" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
- (void)importXML {
    UIViewController *vc=self.controller;
    if (!vc || vc.presentedViewController || self.importing) return;
    [self cancelOnline];
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeXML,UTTypePlainText,UTTypeData] asCopy:NO];
    picker.delegate=self; picker.allowsMultipleSelection=NO;
    [vc presentViewController:picker animated:YES completion:nil];
}
- (void)cancelOnline {
    self.loadGeneration++; [self.onlineProgress cancel]; self.onlineProgress=nil; [self updateMenu];
}
- (void)enterSourceURL {
    UIViewController *vc=self.controller;
    if (!vc || vc.presentedViewController) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"从视频网页获取弹幕"
        message:@"粘贴腾讯、爱奇艺、优酷或 Bilibili 的单集网页链接。这里只获取弹幕，视频继续由 Infuse 播放。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field){
        field.placeholder=@"https://…"; field.keyboardType=UIKeyboardTypeURL;
        field.autocapitalizationType=UITextAutocapitalizationTypeNone;
        field.autocorrectionType=UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak IFDSession *weak=self;
    __weak UIAlertController *weakAlert=alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"获取弹幕" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a){
        [weak loadSourceURL:weakAlert.textFields.firstObject.text ?: @""];
    }]];
    [vc presentViewController:alert animated:YES completion:nil];
}
- (void)loadSourceURL:(NSString *)source {
    [self cancelOnline]; NSUInteger generation=self.loadGeneration;
    __weak IFDSession *weak=self;
    self.onlineProgress=[IFDOnlineSourceBridge loadSourceURL:source completion:^(NSDictionary *result, NSError *error){
        IFDSession *s=weak; if (!s || generation!=s.loadGeneration) return;
        s.onlineProgress=nil; [s updateMenu];
        if (error) { if (error.code!=-999) [s message:error.localizedDescription]; return; }
        NSMutableArray<IFDComment *> *comments=[NSMutableArray array];
        for (NSDictionary *row in result[@"comments"]) {
            IFDComment *c=[IFDComment new]; c.time=[row[@"time"] doubleValue];
            c.mode=[row[@"mode"] integerValue]; c.text=row[@"text"];
            unsigned int rgb=[row[@"color"] unsignedIntValue]&0xffffff;
            c.color=[UIColor colorWithRed:((rgb>>16)&255)/255.0 green:((rgb>>8)&255)/255.0 blue:(rgb&255)/255.0 alpha:1];
            if (c.text.length && std::isfinite(c.time) && c.time>=0) [comments addObject:c];
        }
        if (!comments.count) { [s message:@"这条链接没有返回可显示的弹幕。请确认是具体一集的播放页。 "]; return; }
        s.comments=comments; s.enabled=YES; [s rebuild];
        NSInteger failed=[result[@"failedSegments"] integerValue];
        NSString *partial=failed>0?[NSString stringWithFormat:@" 有 %ld 个片段未能获取，可稍后重试。",(long)failed]:@"";
        [s message:[NSString stringWithFormat:@"已加载 %lu 条弹幕。%@",(unsigned long)comments.count,partial]];
    }];
    [self updateMenu];
}
- (void)documentPicker:(UIDocumentPickerViewController *)p didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url=urls.firstObject; if (!url || self.importing) return;
    self.importing=YES;
    __weak IFDSession *weak=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        BOOL scoped=[url startAccessingSecurityScopedResource];
        __block NSData *data=nil; __block NSError *readError=nil;
        NSFileCoordinator *coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
        NSError *coordinationError=nil;
        [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges
            error:&coordinationError byAccessor:^(NSURL *readURL){
                NSFileHandle *file=[NSFileHandle fileHandleForReadingFromURL:readURL error:&readError];
                if (file) { data=[file readDataUpToLength:8*1024*1024+1 error:&readError]; [file closeAndReturnError:nil]; }
            }];
        if (scoped) [url stopAccessingSecurityScopedResource];
        NSString *failure=nil;
        if (coordinationError || readError || !data) failure=@"无法读取文件，请下载到“文件”后重新选择。";
        else if (data.length>8*1024*1024) failure=@"弹幕文件超过 8 MB，请先精简后导入。";
        NSString *xml=failure?nil:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!failure && !xml) failure=@"请使用 UTF-8 编码的 XML 弹幕文件。";
        if (!failure && ([xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
                         [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location!=NSNotFound))
            failure=@"该 XML 含有不支持的实体声明。";
        IFDXMLReader *reader=[IFDXMLReader new];
        if (!failure) {
            NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];
            parser.shouldResolveExternalEntities=NO; parser.delegate=reader;
            BOOL ok=[parser parse];
            if (!ok && !reader.limited) failure=@"XML 格式不正确，导入失败。";
            else if (!reader.comments.count) failure=@"文件中没有可显示的滚动、顶部或底部弹幕。";
        }
        dispatch_async(dispatch_get_main_queue(),^{
            IFDSession *s=weak; if (!s) return; s.importing=NO;
            if (failure) { [s message:failure]; return; }
            s.comments=[reader.comments copy]; s.enabled=YES; [s rebuild];
            [s message:[NSString stringWithFormat:@"已导入 %lu 条弹幕%@。%@",
                (unsigned long)s.comments.count,reader.limited?@"（已达到数量上限）":@"",
                s.clockAvailable?@"":@"若播放时仍未显示，当前播放器接口可能尚未适配。"]];
        });
    });
}
@end

static const void *IFDSessionKey=&IFDSessionKey;
static UIMenu *IFDMenuForButton(UIButton *button,UIMenu *original) {
    if (![original isKindOfClass:UIMenu.class]) return original;
    NSString *label=button.accessibilityLabel;
    NSString *settings=[NSBundle.mainBundle localizedStringForKey:@"pcVOSettings" value:@"" table:nil];
    if (!label.length || ![label isEqualToString:settings]) return original;
    IFDSession *session=nil;
    for (IFDSession *candidate in IFDSessions.allObjects) {
        UIViewController *vc=candidate.controller;
        if (vc.isViewLoaded && [button isDescendantOfView:vc.view]) { session=candidate; break; }
    }
    if (!session) return original;
    for (UIMenuElement *child in original.children)
        if ([child isKindOfClass:UIMenu.class] && [((UIMenu *)child).identifier isEqualToString:IFDMenuIdentifier]) return original;
    __weak IFDSession *weak=session;
    UIDeferredMenuElement *dynamic=[UIDeferredMenuElement elementWithUncachedProvider:^(void (^complete)(NSArray<UIMenuElement *> *)){
        IFDSession *s=weak; complete(s ? s.controlsMenu.children : @[]);
    }];
    UIMenu *group=[UIMenu menuWithTitle:@"弹幕" image:[UIImage systemImageNamed:@"text.bubble"]
        identifier:IFDMenuIdentifier options:0 children:@[dynamic]];
    return [original menuByReplacingChildren:[original.children arrayByAddingObject:group]];
}
static void IFDInstallMenuHooks(void) {
    static BOOL installed=NO; if (installed) return; installed=YES;
    Method getter=class_getInstanceMethod(UIButton.class,@selector(menu));
    IMP originalGet=method_getImplementation(getter);
    method_setImplementation(getter,imp_implementationWithBlock(^UIMenu *(UIButton *button){
        UIMenu *menu=((UIMenu *(*)(id,SEL))originalGet)(button,@selector(menu));
        return IFDMenuForButton(button,menu);
    }));
    Method setter=class_getInstanceMethod(UIButton.class,@selector(setMenu:));
    IMP originalSet=method_getImplementation(setter);
    method_setImplementation(setter,imp_implementationWithBlock(^(UIButton *button,UIMenu *menu){
        ((void(*)(id,SEL,UIMenu *))originalSet)(button,@selector(setMenu:),IFDMenuForButton(button,menu));
    }));
}
static void IFDInstallClass(Class cls) {
    static NSMutableSet<NSString *> *installed;
    if (!installed) installed=[NSMutableSet set];
    NSString *name=NSStringFromClass(cls);
    if (!cls || [installed containsObject:name] || ![cls isSubclassOfClass:UIViewController.class]) return;
    for (NSString *methodName in @[@"viewDidAppear:",@"viewDidDisappear:"]) {
        SEL selector=NSSelectorFromString(methodName);
        Method method=class_getInstanceMethod(cls,selector);
        if (!method) continue;
        IMP original=method_getImplementation(method);
        BOOL appearing=[methodName isEqualToString:@"viewDidAppear:"];
        IMP replacement=imp_implementationWithBlock(^(UIViewController *vc, BOOL animated){
            ((void(*)(id,SEL,BOOL))original)(vc,selector,animated);
            IFDSession *session=objc_getAssociatedObject(vc,IFDSessionKey);
            if (appearing) {
                if (!session) {
                    session=[[IFDSession alloc] initWithController:vc];
                    objc_setAssociatedObject(vc,IFDSessionKey,session,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                [session start];
            } else [session stop];
        });
        // Add an override when inherited, so UIViewController itself is untouched.
        if (!class_addMethod(cls,selector,replacement,method_getTypeEncoding(method)))
            method_setImplementation(class_getInstanceMethod(cls,selector),replacement);
    }
    [installed addObject:name];
}
static void IFDInstall(void) {
    IFDInstallMenuHooks();
    for (NSString *name in @[@"FCVideoViewController",@"_TtC6infuse21FCVideoViewController"])
        IFDInstallClass(NSClassFromString(name));
}
__attribute__((constructor)) static void IFDLoad(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(),^{
            IFDInstall();
            for (NSNumber *delay in @[@1,@3,@10])
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),
                               dispatch_get_main_queue(),^{ IFDInstall(); });
            [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){ IFDInstall(); }];
        });
    }
}
