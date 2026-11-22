#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <cmath>
#import "../Core/Timeline.hpp"
#import "../Core/MediaClock.hpp"
#import "HostReader.hpp"
#import "LayerMotion.hpp"
#import "TextBitmap.hpp"
#import "EffectModel.hpp"
#import "EffectAnimation.hpp"
#import "BASScene.hpp"
#import "BiliMaskPipeline.hpp"

@interface IFDOnlineSourceBridge : NSObject
+ (NSProgress *)loadSourceURL:(NSString *)source completion:(void (^)(NSDictionary *, NSError *))completion;
@end
@class IFDSession;
static NSHashTable<IFDSession *> *IFDSessions;
static NSString *const IFDMenuIdentifier=@"com.muflow.infusedanmaku.controls";

@interface IFDComment : NSObject
@property(nonatomic,strong) IFDAdvancedText *advanced;
@property(nonatomic,strong) IFDBASDocument *bas;
@property(nonatomic,strong) IFDTextStyle *style;
@property CGFloat textSize;
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
@property NSUInteger unsupported;
@end
@implementation IFDXMLReader
- (instancetype)init { if ((self=[super init])) _comments=[NSMutableArray array]; return self; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri
 qualifiedName:(NSString *)q attributes:(NSDictionary<NSString *,NSString *> *)attrs {
    if (![name isEqualToString:@"d"]) return;
    self.current=nil;self.content=nil;
    NSArray<NSString *> *p = [attrs[@"p"] componentsSeparatedByString:@","];
    if (p.count < 4 || self.comments.count >= 30000) {
        if (self.comments.count >= 30000) { self.limited=YES; [parser abortParsing]; }
        return;
    }
    double seconds = 0; NSScanner *scanner=[NSScanner scannerWithString:p[0]];
    if (![scanner scanDouble:&seconds] || !scanner.isAtEnd || !std::isfinite(seconds) || seconds<0) return;
    NSInteger mode = [p[1] integerValue];
    if (!(mode==1 || mode==2 || mode==3 || mode==4 || mode==5 || mode==7 || mode==9)) {self.unsupported++;return;}
    unsigned int rgb = (unsigned int)[p[3] longLongValue] & 0xffffff;
    IFDComment *c=[IFDComment new]; c.time=seconds; c.mode=mode; c.textSize=[p[2] doubleValue];
    c.style=[IFDTextStyle parse:@{@"animation":attrs[@"ifd-effect"]?:@"0",
        @"colors":[(attrs[@"ifd-colors"]?:@"") componentsSeparatedByString:@","],
        @"orientation":attrs[@"ifd-angle"]?:@"90deg"}];
    c.color=[UIColor colorWithRed:((rgb>>16)&255)/255.0 green:((rgb>>8)&255)/255.0
                             blue:(rgb&255)/255.0 alpha:1];
    self.current=c; self.content=[NSMutableString string];
}
- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)s {
    NSUInteger limit=self.current.mode==9?131073:(self.current.mode==7?16384:300);
    if (self.current && self.content.length < limit) {
        [self.content appendString:[s substringToIndex:MIN(s.length,limit-self.content.length)]];
    }
}
- (void)parser:(NSXMLParser *)p foundCDATA:(NSData *)data {
    NSString *value=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];if(value)[self parser:p foundCharacters:value];
}
- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)q {
    if (![name isEqualToString:@"d"] || !self.current) return;
    self.current.text=[[self.content stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(self.current.mode==7) {
        self.current.advanced=[IFDAdvancedText parse:self.content fontSize:self.current.textSize];
        self.current.text=self.current.advanced.text;if(!self.current.advanced)self.unsupported++;
    }
    if(self.current.mode==9) {
        self.current.bas=[IFDBASDocument parse:self.content];
        self.current.text=self.current.bas.error?nil:@"BAS";if(self.current.bas.error)self.unsupported++;
    }
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
@property(nonatomic,copy) NSArray<NSValue *> *glyphRects;
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
    ifd::EffectClock advancedClock;
    std::vector<ifd::EffectClock> styleClocks;
}
@property(nonatomic, strong) UILabel *fallback;
@property(nonatomic, strong) CALayer *ink;
@property(nonatomic, strong) IFDTextStyle *style;
@property BOOL styleActive;
@property(nonatomic, strong) NSArray<CALayer *> *animatedLayers;
@property(nonatomic, strong) NSArray<CAAnimation *> *styleAnimations;
@property(nonatomic, strong) CAAnimation *advancedAnimation;
- (void)showImage:(IFDTextImage *)image;
- (void)showFallback:(IFDComment *)comment font:(UIFont *)font;
- (void)driveStyleAt:(double)age rate:(double)rate wall:(double)wall force:(BOOL)force;
@end
@implementation IFDRenderLabel
- (void)showImage:(IFDTextImage *)image {
    [self.fallback removeFromSuperview]; self.fallback=nil;
    [self.ink removeFromSuperlayer];
    self.ink=[CALayer layer];self.ink.frame=self.bounds;[self.layer addSublayer:self.ink];
    CALayer *text=[CALayer layer];text.frame=self.bounds;text.contents=(__bridge id)image.image;
    text.contentsScale=self.layer.contentsScale;
    NSMutableArray *layers=[NSMutableArray new],*animations=[NSMutableArray new];
    NSInteger kind=self.styleActive?self.style.animation:0;
    if(kind==2) {
        for(int side=-1;side<=1;side+=2) {
            CALayer *tint=[CALayer layer];tint.frame=self.bounds;
            tint.backgroundColor=(side<0?[UIColor colorWithRed:.961 green:.165 blue:.6 alpha:1]:
                [UIColor colorWithRed:.153 green:.867 blue:1 alpha:1]).CGColor;
            CALayer *mask=[CALayer layer];mask.frame=self.bounds;mask.contents=(__bridge id)image.image;
            tint.mask=mask;[self.ink addSublayer:tint];
            CAKeyframeAnimation *x=ifd::styleAnimation(@"transform.translation.x",2,self.bounds.size.height-8);
            NSMutableArray *xs=[NSMutableArray new],*ys=[NSMutableArray new];
            for(NSNumber *v in x.values){[xs addObject:@(v.doubleValue*side)];[ys addObject:@(v.doubleValue*side*.26)];}
            x.values=xs;CAKeyframeAnimation *y=[x copy];y.keyPath=@"transform.translation.y";y.values=ys;
            CAAnimationGroup *g=[CAAnimationGroup animation];g.animations=@[x,y];g.duration=x.duration;g.repeatCount=HUGE_VALF;
            [layers addObject:tint];[animations addObject:g];
        }
    }
    if(kind==3 && image.glyphRects.count>0 && image.glyphRects.count<=64) {
        CAKeyframeAnimation *rotation=ifd::styleAnimation(@"transform.rotation.z",3);
        for(NSValue *value in image.glyphRects) {
            CGRect rect=value.CGRectValue;if(rect.size.width<=0)continue;
            CALayer *glyph=[CALayer layer];glyph.frame=rect;glyph.contents=(__bridge id)image.image;
            glyph.contentsScale=self.layer.contentsScale;
            glyph.contentsRect=CGRectMake(rect.origin.x/self.bounds.size.width,0,rect.size.width/self.bounds.size.width,1);
            [self.ink addSublayer:glyph];[layers addObject:glyph];
            [animations addObject:rotation];
        }
    } else [self.ink addSublayer:text];
    if(kind==1){[layers addObject:self.ink];[animations addObject:ifd::styleAnimation(@"transform.scale",1)];}
    self.animatedLayers=layers;self.styleAnimations=animations;styleClocks.assign(layers.count,{});
}
- (void)driveStyleAt:(double)age rate:(double)rate wall:(double)wall force:(BOOL)force {
    for(NSUInteger i=0;i<self.animatedLayers.count;++i)
        ifd::driveEffect(self.animatedLayers[i],self.styleAnimations[i],age,rate,wall,force,styleClocks[i]);
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
    ifd::EffectTimeline _effects, _scenes;
    std::vector<size_t> _activeScenes;
    std::vector<size_t> _activeEffects;
    ifd::MediaClock _clock;
    ifd::PlayerGetters _getters;
    std::vector<ifd::Visible> _visible;
    double _lastDrawnTime, _lastEffectWall, _lastRenderRate, _nextPlayerLookup, _nextPrewarm;
}
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, weak) id cachedPlayer;
@property(nonatomic, strong) IFDOverlay *overlay;
@property(nonatomic, strong) UIMenu *controlsMenu;
@property(nonatomic, strong) NSProgress *onlineProgress;
@property NSUInteger loadGeneration;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) NSArray<IFDComment *> *comments;
@property(nonatomic,strong) NSCache<NSNumber *,IFDBASPrepared *> *sceneCache;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,IFDBASLayer *> *sceneLayers;
@property(nonatomic,strong) NSMutableSet<NSNumber *> *pendingScenes;
@property(nonatomic,strong) NSMutableSet<NSNumber *> *failedScenes;
@property(nonatomic,copy) NSDictionary *sourceReport;
@property(nonatomic,strong) IFDBiliMask *biliMask;
@property(nonatomic,strong) IFDBiliMaskImage *maskImage;
@property(nonatomic,strong) CALayer *maskLayer;
@property(nonatomic,copy) NSString *maskError;
@property double maskBucket;
@property double maskAspect;
@property BOOL masksEnabled;
@property NSUInteger maskGeneration;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *,IFDRenderLabel *> *labels;
@property(nonatomic, strong) NSMutableArray<IFDRenderLabel *> *recycledLabels;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *activeKeys;
@property(nonatomic, strong) UIFont *renderFont;
@property(nonatomic, strong) NSCache<NSNumber *,IFDTextImage *> *textImages;
@property(nonatomic, strong) NSOperationQueue *textQueue;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *pendingImages;
@property(nonatomic, weak) NSArray<IFDComment *> *preparedComments;
@property NSUInteger renderGeneration;
@property BOOL effectsEnabled;
@property BOOL measuredEffects;
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
- (void)prepareScene:(IFDComment *)comment;
- (void)resetMask;
- (void)updateMaskAt:(double)time jumped:(BOOL)jumped;
- (void)showSourceReport;
@end

@implementation IFDSession
- (instancetype)initWithController:(UIViewController *)controller {
    if ((self=[super init])) {
        _controller=controller; _comments=@[]; _labels=[NSMutableDictionary dictionary];
        _sceneCache=[NSCache new];_sceneCache.countLimit=4;_sceneCache.totalCostLimit=32*1024*1024;
        _sceneLayers=[NSMutableDictionary new];_pendingScenes=[NSMutableSet new];_failedScenes=[NSMutableSet new];
        _maskBucket=NAN;_maskAspect=16./9;_masksEnabled=YES;
        _recycledLabels=[NSMutableArray arrayWithCapacity:36];
        _activeKeys=[NSMutableSet setWithCapacity:36]; _visible.reserve(36);
        _textImages=[NSCache new]; _textImages.countLimit=128; _textImages.totalCostLimit=12*1024*1024;
        _pendingImages=[NSMutableSet setWithCapacity:72];
        _textQueue=[NSOperationQueue new]; _textQueue.maxConcurrentOperationCount=1;
        _textQueue.qualityOfService=NSQualityOfServiceUserInitiated;
        _lastDrawnTime=NAN;
        _enabled=YES; _effectsEnabled=YES; _fontSize=20; _textOpacity=1; _area=.5;
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
        [NSString stringWithFormat:@"扩展 0.3.0 · %lu 条 · %g 号 · 延迟 %+.1fs",(unsigned long)self.comments.count,
                                  (double)self.fontSize,self.delay]) image:nil identifier:nil handler:^(__unused UIAction *a){}];
    status.attributes=UIMenuElementAttributesDisabled;
    [items addObject:status];
    [items addObject:[self action:@"查看加载结果与支持范围" block:^(IFDSession *s){[s showSourceReport];}]];
    if(self.biliMask){
        [items addObject:[self action:(self.masksEnabled?@"关闭人物遮挡":@"开启人物遮挡") block:^(IFDSession *s){s.masksEnabled=!s.masksEnabled;[s resetMask];[s updateMenu];}]];
        [items addObject:[self action:[NSString stringWithFormat:@"遮挡画幅 %.2f:1（点击切换）",self.maskAspect] block:^(IFDSession *s){s.maskAspect=s.maskAspect<1.5?16./9:s.maskAspect<2?2.35:4./3;[s resetMask];[s updateMenu];}]];
    }
    [items addObject:[self action:@"从视频网页获取弹幕" block:^(IFDSession *s){ [s enterSourceURL]; }]];
    if (self.onlineProgress) [items addObject:[self action:@"取消获取弹幕" block:^(IFDSession *s){ [s cancelOnline]; }]];
    [items addObject:[self action:@"导入 XML / BAS 弹幕" block:^(IFDSession *s){ [s importXML]; }]];
    [items addObject:[self action:(self.enabled?@"关闭弹幕":@"开启弹幕") block:^(IFDSession *s){
        s.enabled=!s.enabled; s->_clock.reset(); [s cancelTextPreparation]; [s clearLabels]; [s updateMenu];
    }]];
    [items addObject:[self action:(self.effectsEnabled?@"关闭特效（保留普通弹幕）":@"开启特效弹幕") block:^(IFDSession *s){s.effectsEnabled=!s.effectsEnabled;[s rebuild];}]];
    [items addObject:[self action:@"字号增大" block:^(IFDSession *s){ s.fontSize=MIN(32,s.fontSize+2); [s rebuild]; }]];
    [items addObject:[self action:@"字号减小" block:^(IFDSession *s){ s.fontSize=MAX(12,s.fontSize-2); [s rebuild]; }]];
    [items addObject:[self action:@"切换显示区域" block:^(IFDSession *s){ s.area=s.area<.45?.5:s.area<.6?.75:.33; [s rebuild]; }]];
    [items addObject:[self action:@"切换透明度" block:^(IFDSession *s){ s.textOpacity=s.textOpacity>.9?.75:s.textOpacity>.6?.5:1; [s rebuild]; }]];
    [items addObject:[self action:@"弹幕推迟 0.5 秒" block:^(IFDSession *s){ s.delay+=.5; [s updateMenu]; }]];
    [items addObject:[self action:@"弹幕提前 0.5 秒" block:^(IFDSession *s){ s.delay-=.5; [s updateMenu]; }]];
    [items addObject:[self action:@"恢复默认样式和时间" block:^(IFDSession *s){
        s.effectsEnabled=YES;s.fontSize=20; s.area=.5; s.textOpacity=1; s.delay=0; [s rebuild];
    }]];
    [items addObject:[self action:@"清除本次弹幕" block:^(IFDSession *s){ [s cancelOnline]; s.comments=@[];s.sourceReport=nil;s.biliMask=nil;[s resetMask]; [s rebuild]; }]];
    self.controlsMenu=[UIMenu menuWithTitle:@"弹幕" children:items];
}
- (void)resetMask {
    self.maskGeneration++;self.maskBucket=NAN;self.maskImage=nil;self.overlay.layer.mask=nil;
    [self.biliMask.queue cancelAllOperations];_lastDrawnTime=NAN;
}
- (void)clearLabels {
    [self resetMask];
    for(IFDBASLayer *scene in self.sceneLayers.allValues)[scene.root removeFromSuperlayer];
    [self.sceneLayers removeAllObjects];
    for (IFDRenderLabel *l in self.labels.allValues) [self recycleLabel:l];
    [self.labels removeAllObjects];
    _lastDrawnTime=NAN;
}
- (void)recycleLabel:(IFDRenderLabel *)label {
    [label.layer removeAnimationForKey:ifd::motionKey]; label->motion={};
    [label.layer removeAllAnimations];label->advancedClock={};label.advancedAnimation=nil;
    [label.ink removeFromSuperlayer];label.ink=nil;label.animatedLayers=nil;label.styleAnimations=nil;label.style=nil;label->styleClocks.clear();
    label.layer.transform=CATransform3DIdentity;label.layer.opacity=1;
    label.layer.contents=nil; [label.fallback removeFromSuperview]; label.fallback=nil;
    [label removeFromSuperview];
    if (self.recycledLabels.count<36) [self.recycledLabels addObject:label];
}
- (void)rebuild {
    BOOL resetImages=!CGSizeEqualToSize(self.preparedSize,self.overlay.bounds.size) || self.measuredEffects!=self.effectsEnabled || self.measuredFontSize!=self.fontSize || self.preparedComments!=self.comments ||
        self.preparedScale!=(self.overlay.window.screen.scale ?: UIScreen.mainScreen.scale);
    [self cancelTextPreparation];
    if (resetImages) {[self.textImages removeAllObjects];[self.sceneCache removeAllObjects];[self.failedScenes removeAllObjects];}
    self.preparedComments=self.comments;self.measuredEffects=self.effectsEnabled;
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
    comments.reserve(self.comments.count);std::vector<ifd::EffectEvent> effects,scenes;
    for (NSUInteger i=0;i<self.comments.count;++i) {
        IFDComment *c=self.comments[i];
        c.renderKey=@(i);
        if(c.bas){if(self.effectsEnabled)scenes.push_back({c.time,c.bas->scene.duration,i});continue;}
        c.textSize=c.advanced?std::clamp(c.advanced.fontSize*MIN(size.width/672.,size.height/438.),8.0,96.0):self.fontSize;
        UIFont *itemFont=[UIFont systemFontOfSize:c.textSize weight:UIFontWeightRegular];
        if (measure || c.width<=0 || c.advanced) c.width=ceil([c.text sizeWithAttributes:@{NSFontAttributeName:itemFont}].width)+4;
        if(c.advanced){if(self.effectsEnabled)effects.push_back({c.time,c.advanced->spec.duration,i});continue;}
        auto mode=c.mode==4?ifd::Mode::bottom:c.mode==5?ifd::Mode::top:ifd::Mode::scrolling;
        // Top and scrolling comments share a visual band split below in tick.
        comments.push_back({c.time,(double)c.width,mode,i});
    }
    _timeline.prepare(std::move(comments),size.width,lanes,90,36);
    _effects.prepare(std::move(effects));
    _scenes.prepare(std::move(scenes),120,2);
    [self updateMenu];
}
- (void)cancelTextPreparation {
    self.renderGeneration++; [self.textQueue cancelAllOperations];
    [self.pendingImages removeAllObjects];[self.pendingScenes removeAllObjects]; _nextPrewarm=0;
}
- (void)prepareScene:(IFDComment *)comment {
    NSNumber *key=comment.renderKey;
    if(!comment.bas||[self.sceneCache objectForKey:key]||[self.failedScenes containsObject:key]||
       [self.pendingScenes containsObject:key]||self.pendingScenes.count>=2)return;
    [self.pendingScenes addObject:key];NSUInteger generation=self.renderGeneration;
    CGSize size=self.preparedSize;double scale=self.preparedScale;
    __weak IFDSession *weak=self;
    [self.textQueue addOperationWithBlock:^{@autoreleasepool{
        IFDBASPrepared *prepared=[IFDBASPrepared prepare:comment.bas size:size scale:scale];
        dispatch_async(dispatch_get_main_queue(),^{
            IFDSession *s=weak;if(!s||s.renderGeneration!=generation)return;
            [s.pendingScenes removeObject:key];
            if(prepared.error)[s.failedScenes addObject:key];
            else [s.sceneCache setObject:prepared forKey:key cost:prepared.bytes+prepared.nodes.count*65536];
            // A paused host has no advancing tick. Wake composition after the
            // worker supplies the scene, without changing the host clock.
            s->_lastDrawnTime=NAN;
        });
    }}];
}
- (void)updateMaskAt:(double)time jumped:(BOOL)jumped {
    if(!self.biliMask||!self.masksEnabled||!self.effectsEnabled){self.overlay.layer.mask=nil;return;}
    if(jumped)[self resetMask];
    double interval=floor(1000/self.biliMask.fps),ms=time*1000;
    if(self.maskImage&&self.maskImage.timeMs>=ms+interval&&self.maskImage.timeMs<ms+3*interval){
        if(!self.maskLayer)self.maskLayer=[CALayer layer];self.maskLayer.frame=self.overlay.bounds;
        self.maskLayer.contents=(__bridge id)self.maskImage.image;self.overlay.layer.mask=self.maskLayer;
    }else self.overlay.layer.mask=nil;
    double bucket=floor(time*self.biliMask.fps);
    if(bucket==self.maskBucket)return;self.maskBucket=bucket;
    CGSize size=self.overlay.bounds.size;
    double width=MIN(size.width,size.height*self.maskAspect),height=width/self.maskAspect;
    CGRect rect=CGRectMake((size.width-width)/2,(size.height-height)/2,width,height);
    NSUInteger generation=self.maskGeneration;__weak IFDSession *weak=self;
    [self.biliMask prepareAt:time canvas:size contentRect:rect completion:^(IFDBiliMaskImage *image,NSString *error){
        IFDSession *s=weak;if(!s||s.maskGeneration!=generation)return;
        s.maskImage=image;s.maskError=error;s->_lastDrawnTime=NAN;
    }];
}
- (void)showSourceReport {
    NSUInteger bas=0,advanced=0;for(IFDComment *c in self.comments){if(c.bas)++bas;else if(c.advanced)++advanced;}
    NSMutableString *report=[NSMutableString stringWithFormat:@"普通/高级弹幕 %lu 条，高级定位 %lu 条，BAS 场景 %lu 个。\n本地 BAS：文字、矢量路径、父子层级、串并行时间线、颜色与旋转缩放；按钮仅显示，暂不响应跳转。\n不支持模板、apply、脚本和动态描边宽度。\n",(unsigned long)self.comments.count,(unsigned long)advanced,(unsigned long)bas];
    if(self.failedScenes.count)[report appendFormat:@"%lu 个 BAS 场景因超限或未支持属性跳过。\n",(unsigned long)self.failedScenes.count];
    NSArray *activities=self.sourceReport[@"activities"];
    if(activities.count)[report appendFormat:@"收到 %lu 个活动配置；活动着色器（含黑洞/粒子）尚未接入，不以普通动画替代。\n",(unsigned long)activities.count];
    NSDictionary *mask=self.sourceReport[@"mask"];
    if(self.biliMask)[report appendFormat:@"人物遮挡：已下载蒙版，按 %.2f:1 画幅映射（齿轮菜单可切换）。%@\n",self.maskAspect,self.maskError?:@"仅受支持的 SVG 帧可显示；尚未核实宿主的实际视频画幅。"];
    else if(mask)[report appendFormat:@"人物遮挡来源状态：%@。\n",mask[@"status"]?:@"未提供"];
    NSDictionary *acquisition=self.sourceReport[@"acquisition"];
    if([acquisition[@"status"] isEqual:@"partial"])[report appendString:@"本次仅获取部分数据；匿名接口受限或某些资源缺失。\n"];
    for(NSDictionary *issue in acquisition[@"issues"])[report appendFormat:@"%@：%@\n",issue[@"stage"]?:@"来源",issue[@"status"]?:@"未知"];
    [self message:report];
}
- (void)prepareImage:(IFDComment *)comment {
    if(comment.bas)return;
    NSNumber *key=comment.renderKey;
    if (!key || [self.textImages objectForKey:key] || [self.pendingImages containsObject:key] ||
        self.pendingImages.count>=72) return;
    CGSize size=CGSizeMake(comment.width,comment.textSize+8); CGFloat scale=self.preparedScale;
    size_t width=0,height=0;
    if (!ifd::bitmapSize(size,scale,width,height)) return;
    [self.pendingImages addObject:key]; NSUInteger generation=self.renderGeneration;
    NSString *text=comment.text,*fontName=self.renderFont.fontName;
    CGFloat fontSize=comment.textSize; UIColor *color=comment.color;
    IFDTextStyle *style=self.effectsEnabled?comment.style:nil;
    BOOL outline=comment.advanced?comment.advanced.outline:YES;
    UIColor *stroke=style.stroke?[UIColor colorWithRed:((style.stroke.unsignedIntValue>>16)&255)/255.
        green:((style.stroke.unsignedIntValue>>8)&255)/255. blue:(style.stroke.unsignedIntValue&255)/255. alpha:1]:nil;
    if(style.colors.count==1){unsigned rgb=style.colors.firstObject.unsignedIntValue;
        color=[UIColor colorWithRed:((rgb>>16)&255)/255. green:((rgb>>8)&255)/255. blue:(rgb&255)/255. alpha:1];}
    __weak IFDSession *weak=self;
    [self.textQueue addOperationWithBlock:^{
        @autoreleasepool {
            CGImageRef pixels=ifd::createTextBitmap((__bridge CFStringRef)text,(__bridge CFStringRef)fontName,
                fontSize,color.CGColor,size,scale,style.colors,style.angle,stroke.CGColor,outline);
            IFDTextImage *image=pixels?[[IFDTextImage alloc] initWithImage:pixels]:nil;
            if (pixels) CGImageRelease(pixels);
            if(image&&style.animation==3) {
                NSMutableArray *rects=[NSMutableArray new];
                for(CGRect rect:ifd::glyphSlices((__bridge CFStringRef)text,(__bridge CFStringRef)fontName,fontSize,size))
                    [rects addObject:[NSValue valueWithCGRect:rect]];
                image.glyphRects=rects;
            }
            dispatch_async(dispatch_get_main_queue(),^{
                IFDSession *s=weak; if (!s || generation!=s.renderGeneration) return;
                [s.pendingImages removeObject:key];
                if (image) {
                    [s.textImages setObject:image forKey:key cost:CGImageGetBytesPerRow(image.image)*CGImageGetHeight(image.image)];
                    [CATransaction begin]; [CATransaction setDisableActions:YES];
                    IFDRenderLabel *label=s.labels[key];[label showImage:image];
                    if(label && std::isfinite(s->_lastDrawnTime)) {
                        double now=CACurrentMediaTime();
                        double age=s->_lastDrawnTime-comment.time+MAX(0,now-s->_lastEffectWall)*s->_lastRenderRate;
                        [label driveStyleAt:age rate:s->_lastRenderRate wall:now force:YES];
                    }
                    [CATransaction commit];
                } else [s.labels[key] showFallback:comment font:[UIFont systemFontOfSize:comment.textSize]];
            });
        }
    }];
}
- (void)prewarmAt:(double)time {
    const auto &basEvents=_scenes.entries();
    auto b=std::lower_bound(basEvents.begin(),basEvents.end(),time,[](const ifd::EffectEvent &e,double t){return e.time<t;});
    for(NSUInteger n=0;b!=basEvents.end()&&b->time<=time+2&&n<2;++b,++n)[self prepareScene:self.comments[b->key]];
    const auto &placements=_timeline.placements();
    auto p=std::lower_bound(placements.begin(),placements.end(),time,
        [](const ifd::Placement &entry,double t){ return entry.comment.time<t; });
    const auto &events=_effects.entries();
    auto e=std::lower_bound(events.begin(),events.end(),time,[](const ifd::EffectEvent &v,double t){return v.time<t;});
    for(NSUInteger n=0;e!=events.end()&&e->time<=time+1.5&&n<8;++e,++n)[self prepareImage:self.comments[e->key]];
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
        _clock.reset(); if (self.labels.count||self.sceneLayers.count||self.overlay.layer.mask) [self clearLabels]; return;
    }
    double paused=0, rate=0;
    bool hasPause=_getters.paused.read(player,paused), hasRate=_getters.rate.read(player,rate);
    time=_clock.sample(time,now,link.targetTimestamp,hasPause&&hasRate,paused!=0,rate)-self.delay;
    double renderRate=_clock.advancing()?rate:0;
    if (time==_lastDrawnTime && renderRate==_lastRenderRate) return;
    BOOL jumped=std::isfinite(_lastDrawnTime) && std::abs(time-_lastDrawnTime)>.25;
    if (jumped) [self cancelTextPreparation];
    _lastDrawnTime=time; _lastRenderRate=renderRate;_lastEffectWall=std::clamp(link.targetTimestamp,now,now+.05);
    _timeline.at(time,_visible);
    NSMutableSet<NSNumber *> *active=self.activeKeys; [active removeAllObjects];
    CGFloat row=self.fontSize+8;
    CGFloat base=self.overlay.safeAreaInsets.top+8;
    NSUInteger styled=0,wiggles=0;
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
            label.style=self.effectsEnabled?c.style:nil;label.styleActive=NO;
            label.alpha=self.textOpacity; [self.overlay addSubview:label];
            self.labels[key]=label;
        }
        // A seek or a long callback gap can cancel a queued bitmap while its
        // view survives. Retry empty views, not only newly created ones.
        BOOL styleActive=self.effectsEnabled&&c.style.animation&&styled<8&&(c.style.animation!=3||wiggles<2);
        if(label.styleActive!=styleActive){label.styleActive=styleActive;[label.ink removeFromSuperlayer];label.ink=nil;}
        if (!label.ink && !label.fallback) {
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
        if(label.styleActive){++styled;if(c.style.animation==3)++wiggles;}
        CGFloat y=base+p.lane*row;
        if (p.mode==ifd::Mode::top) y+=self.laneCount*row;
        else if (p.mode==ifd::Mode::bottom) y=self.overlay.bounds.size.height-self.overlay.safeAreaInsets.bottom-42-row*(p.lane+1);
        CGPoint position=CGPointMake(round(p.x*scale)/scale,round(y*scale)/scale);
        double wall=std::clamp(link.targetTimestamp,now,now+.05);
        ifd::placeLayer(label.layer,position,p.mode==ifd::Mode::scrolling?renderRate:0,wall,jumped,label->motion);
        [label driveStyleAt:time-c.time rate:renderRate wall:wall force:jumped];
    }
    _scenes.at(time,_activeScenes);
    NSMutableSet *sceneKeys=[NSMutableSet new];
    for(size_t index:_activeScenes){IFDComment *c=self.comments[index];NSNumber *key=c.renderKey;[sceneKeys addObject:key];IFDBASLayer *scene=self.sceneLayers[key];
        if(!scene){IFDBASPrepared *prepared=[self.sceneCache objectForKey:key];if(prepared){scene=[[IFDBASLayer alloc] initWithPrepared:prepared];self.sceneLayers[key]=scene;[self.overlay.layer addSublayer:scene.root];}else [self prepareScene:c];}
        scene.root.opacity=self.textOpacity;[scene driveAt:time-c.time rate:renderRate wall:_lastEffectWall force:jumped];
    }
    for(NSNumber *key in self.sceneLayers.allKeys)if(![sceneKeys containsObject:key]){[self.sceneLayers[key].root removeFromSuperlayer];[self.sceneLayers removeObjectForKey:key];}
    [self updateMaskAt:time jumped:jumped];
    _effects.at(time,_activeEffects);
    for(size_t index:_activeEffects) {
        IFDComment *c=self.comments[index];NSNumber *key=c.renderKey;[active addObject:key];
        IFDRenderLabel *label=self.labels[key];
        if(!label){label=[IFDRenderLabel new];label.userInteractionEnabled=NO;label.layer.anchorPoint=CGPointZero;
            label.bounds=CGRectMake(0,0,c.width,c.textSize+8);label.contentScaleFactor=scale;label.layer.contentsScale=scale;
            CATransform3D transform=CATransform3DIdentity;transform.m34=-1./600;
            transform=CATransform3DRotate(transform,c.advanced->spec.z*M_PI/180,0,0,1);
            label.layer.transform=CATransform3DRotate(transform,c.advanced->spec.y*M_PI/180,0,1,0);
            double fit=MIN(self.overlay.bounds.size.width/672.,self.overlay.bounds.size.height/438.);
            CGPoint origin=CGPointMake((self.overlay.bounds.size.width-672*fit)/2,(self.overlay.bounds.size.height-438*fit)/2);
            label.advancedAnimation=ifd::advancedAnimation(c.advanced->spec,fit,origin,self.textOpacity);
            self.labels[key]=label;[self.overlay addSubview:label];}
        if(!label.ink&&!label.fallback){IFDTextImage *image=[self.textImages objectForKey:key];if(image)[label showImage:image];else {size_t w=0,h=0;
            if(!ifd::bitmapSize(label.bounds.size,scale,w,h))[label showFallback:c font:[UIFont systemFontOfSize:c.textSize]];
            else [self prepareImage:c];}}
        double wall=std::clamp(link.targetTimestamp,now,now+.05);
        ifd::driveEffect(label.layer,label.advancedAnimation,time-c.time,renderRate,wall,jumped,label->advancedClock);
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
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSMutableArray<IFDComment *> *comments=[NSMutableArray array];NSUInteger skipped=0;
            for (NSDictionary *row in result[@"comments"]) {
                if(comments.count>=30000)break;
                if(![row isKindOfClass:NSDictionary.class]||![row[@"text"] isKindOfClass:NSString.class]){++skipped;continue;}
                IFDComment *c=[IFDComment new];c.time=[row[@"time"] doubleValue];c.mode=[row[@"mode"] integerValue];c.text=row[@"text"];
                c.style=[IFDTextStyle parse:row[@"style"]];
                if(c.mode==7){c.advanced=[IFDAdvancedText parse:c.text fontSize:[row[@"fontSize"] doubleValue]];c.text=c.advanced.text;}
                else if(c.mode==9){c.bas=[IFDBASDocument parse:c.text];c.text=c.bas.error?nil:@"BAS";}
                else if(c.mode>=1&&c.mode<=5)c.text=[c.text substringToIndex:MIN(c.text.length,300)];
                else c.text=nil;
                unsigned int rgb=[row[@"color"] unsignedIntValue]&0xffffff;
                c.color=[UIColor colorWithRed:((rgb>>16)&255)/255.0 green:((rgb>>8)&255)/255.0 blue:(rgb&255)/255.0 alpha:1];
                if(c.text.length&&std::isfinite(c.time)&&c.time>=0)[comments addObject:c];else ++skipped;
            }
            NSDictionary *mask=result[@"mask"];NSData *maskData=mask[@"fileData"];
            IFDBiliMask *maskSource=[maskData isKindOfClass:NSData.class]?[[IFDBiliMask alloc] initWithData:maskData fps:[mask[@"fps"] doubleValue]]:nil;
            dispatch_async(dispatch_get_main_queue(),^{
                IFDSession *current=weak;if(!current||generation!=current.loadGeneration)return;
                if(!comments.count){[current message:@"来源未返回可显示的弹幕；可能没有数据或包含尚未支持的特效。现有弹幕保留。"];return;}
                current.comments=comments;current.sourceReport=result;current.biliMask=maskSource;current.maskError=nil;current.enabled=YES;[current rebuild];
                NSDictionary *acquisition=result[@"acquisition"];
                BOOL partial=[result[@"failedSegments"] integerValue]>0||[result[@"truncated"] boolValue]||[acquisition[@"status"] isEqual:@"partial"];
                [current message:[NSString stringWithFormat:@"已载入 %lu 条弹幕%@。%@ 可在齿轮菜单查看加载结果。",(unsigned long)comments.count,partial?@"（部分数据未获取）":@"",skipped?[NSString stringWithFormat:@" 跳过 %lu 条暂不支持或无效数据。",(unsigned long)skipped]:@""]];
            });
        });
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
        if (!failure && !xml) failure=@"请使用 UTF-8 编码的 XML / BAS 弹幕文件。";
        if (!failure && ([xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
                         [xml rangeOfString:@"<!ENTITY" options:NSCaseInsensitiveSearch].location!=NSNotFound))
            failure=@"该 XML 含有不支持的实体声明。";
        IFDXMLReader *reader=[IFDXMLReader new];
        if(!failure&&[url.pathExtension.lowercaseString isEqual:@"bas"]){
            IFDBASDocument *document=[IFDBASDocument parse:xml];
            if(document.error)failure=[@"BAS 解析失败：" stringByAppendingString:document.error];
            else{IFDComment *comment=[IFDComment new];comment.bas=document;comment.mode=9;comment.text=@"BAS";comment.time=0;[reader.comments addObject:comment];}
        }else if (!failure) {
            NSXMLParser *parser=[[NSXMLParser alloc] initWithData:data];
            parser.shouldResolveExternalEntities=NO; parser.delegate=reader;
            BOOL ok=[parser parse];
            if (!ok && !reader.limited) failure=@"XML 格式不正确，导入失败。";
            else if (!reader.comments.count) failure=@"文件中没有可显示的普通或受支持的高级弹幕。";
        }
        dispatch_async(dispatch_get_main_queue(),^{
            IFDSession *s=weak; if (!s) return; s.importing=NO;
            if (failure) { [s message:failure]; return; }
            s.comments=[reader.comments copy];s.sourceReport=nil;s.biliMask=nil;s.maskError=nil; s.enabled=YES; [s rebuild];
            [s message:[NSString stringWithFormat:@"已导入 %lu 条弹幕%@。%@",
                (unsigned long)s.comments.count,reader.limited?@"（已达到数量上限）":@"",
                reader.unsupported?[NSString stringWithFormat:@" 已跳过 %lu 条未支持或无效的高级/脚本弹幕。",(unsigned long)reader.unsupported]:(s.clockAvailable?@"":@"若播放时仍未显示，当前播放器接口可能尚未适配。")]];
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
