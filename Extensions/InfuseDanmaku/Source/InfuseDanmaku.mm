#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <cmath>
#import "../Core/Timeline.hpp"

@interface IFDOnlineSourceBridge : NSObject
+ (NSProgress *)loadSourceURL:(NSString *)source completion:(void (^)(NSDictionary *, NSError *))completion;
@end
@class IFDSession;
static NSHashTable<IFDSession *> *IFDSessions;
static NSString *const IFDMenuIdentifier=@"com.muflow.infusedanmaku.controls";

// This add-on does not link Infuse or InfusePlus, and does not alter purchases.
// Candidate classes/selectors come from the v2.6 shipped plugin. They have NOT
// been validated in Infuse 8.5.1. Every dynamic call checks its ABI first.
static id IFDObject(id object, NSString *name) {
    if (!object) return nil;
    @try {
        SEL sel = NSSelectorFromString(name);
        NSMethodSignature *s = [object methodSignatureForSelector:sel];
        if (!s || s.numberOfArguments != 2 || s.methodReturnType[0] != '@') return nil;
        NSInvocation *i = [NSInvocation invocationWithMethodSignature:s];
        i.target = object; i.selector = sel; [i invoke];
        __unsafe_unretained id value = nil; [i getReturnValue:&value];
        return value;
    } @catch (__unused NSException *e) { return nil; }
}
static BOOL IFDNumber(id object, NSString *name, double *value) {
    if (!object) return NO;
    @try {
        SEL sel = NSSelectorFromString(name);
        NSMethodSignature *s = [object methodSignatureForSelector:sel];
        if (!s || s.numberOfArguments != 2) return NO;
        const char type = s.methodReturnType[0];
        if (type != 'd' && type != 'f' && type != 'B' && type != 'c') return NO;
        NSInvocation *i = [NSInvocation invocationWithMethodSignature:s];
        i.target = object; i.selector = sel; [i invoke];
        if (type == 'd') { double v; [i getReturnValue:&v]; *value = v; }
        else if (type == 'f') { float v; [i getReturnValue:&v]; *value = v; }
        else if (type == 'B') { bool v; [i getReturnValue:&v]; *value = v; }
        else { signed char v; [i getReturnValue:&v]; *value = v; }
        return std::isfinite(*value);
    } @catch (__unused NSException *e) { return NO; }
}

@interface IFDComment : NSObject
@property double time;
@property NSInteger mode;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, strong) UIColor *color;
@property CGFloat width;
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
}
@property(nonatomic, weak) UIViewController *controller;
@property(nonatomic, strong) IFDOverlay *overlay;
@property(nonatomic, strong) UIMenu *controlsMenu;
@property(nonatomic, strong) NSProgress *onlineProgress;
@property NSUInteger loadGeneration;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic, strong) NSArray<IFDComment *> *comments;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *,UILabel *> *labels;
@property BOOL enabled;
@property BOOL importing;
@property BOOL clockAvailable;
@property CGFloat fontSize;
@property CGFloat textOpacity;
@property CGFloat area;
@property double delay;
@property CGSize preparedSize;
@property NSInteger laneCount;
- (instancetype)initWithController:(UIViewController *)controller;
- (void)start;
- (void)stop;
- (void)updateMenu;
@end

@implementation IFDSession
- (instancetype)initWithController:(UIViewController *)controller {
    if ((self=[super init])) {
        _controller=controller; _comments=@[]; _labels=[NSMutableDictionary dictionary];
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
    if (!self.displayLink) {
        IFDDisplayProxy *proxy=[IFDDisplayProxy new]; proxy.target=self;
        self.displayLink=[CADisplayLink displayLinkWithTarget:proxy selector:@selector(tick:)];
        self.displayLink.preferredFrameRateRange=CAFrameRateRangeMake(30,60,60);
        [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
- (void)stop {
    [self.displayLink invalidate]; self.displayLink=nil; self.overlay.hidden=YES;
}
- (void)dealloc { [_onlineProgress cancel]; [_displayLink invalidate]; [_overlay removeFromSuperview]; }
- (UIAction *)action:(NSString *)title block:(void (^)(IFDSession *))block {
    __weak IFDSession *weak=self;
    return [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__unused UIAction *a) {
        IFDSession *s=weak; if (s) block(s);
    }];
}
- (void)updateMenu {
    NSMutableArray<UIMenuElement *> *items=[NSMutableArray array];
    UIAction *status=[UIAction actionWithTitle:(self.onlineProgress ? @"正在获取弹幕…" :
        [NSString stringWithFormat:@"扩展 0.1.1 · %lu 条 · %g 号 · 延迟 %+.1fs",(unsigned long)self.comments.count,
                                  (double)self.fontSize,self.delay]) image:nil identifier:nil handler:^(__unused UIAction *a){}];
    status.attributes=UIMenuElementAttributesDisabled;
    [items addObject:status];
    [items addObject:[self action:@"从视频网页获取弹幕" block:^(IFDSession *s){ [s enterSourceURL]; }]];
    if (self.onlineProgress) [items addObject:[self action:@"取消获取弹幕" block:^(IFDSession *s){ [s cancelOnline]; }]];
    [items addObject:[self action:@"导入 XML 弹幕" block:^(IFDSession *s){ [s importXML]; }]];
    [items addObject:[self action:(self.enabled?@"关闭弹幕":@"开启弹幕") block:^(IFDSession *s){
        s.enabled=!s.enabled; [s clearLabels]; [s updateMenu];
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
    for (UILabel *l in self.labels.allValues) [l removeFromSuperview];
    [self.labels removeAllObjects];
}
- (void)rebuild {
    [self clearLabels];
    CGSize size=self.overlay.bounds.size; self.preparedSize=size;
    CGFloat row=self.fontSize+8;
    CGFloat usableHeight=MAX(0,size.height-self.overlay.safeAreaInsets.top-self.overlay.safeAreaInsets.bottom-64);
    int lanes=MAX(1,(int)floor(usableHeight*self.area/(3*row)));
    lanes=MIN(lanes,12);
    self.laneCount=lanes;
    UIFont *font=[UIFont systemFontOfSize:self.fontSize weight:UIFontWeightRegular];
    std::vector<ifd::Comment> comments;
    for (NSUInteger i=0;i<self.comments.count;++i) {
        IFDComment *c=self.comments[i];
        c.width=ceil([c.text sizeWithAttributes:@{NSFontAttributeName:font}].width)+4;
        auto mode=c.mode==4?ifd::Mode::bottom:c.mode==5?ifd::Mode::top:ifd::Mode::scrolling;
        // Top and scrolling comments share a visual band split below in tick.
        comments.push_back({c.time,(double)c.width,mode,i});
    }
    _timeline.prepare(std::move(comments),size.width,lanes,90,36);
    [self updateMenu];
}
- (void)tick:(CADisplayLink *)link {
    if (!CGSizeEqualToSize(self.preparedSize,self.overlay.bounds.size)) [self rebuild];
    id vc=self.controller;
    id player=IFDObject(vc,@"player");
    if (!player) player=IFDObject(IFDObject(vc,@"modelContainer"),@"player");
    double time=0;
    self.clockAvailable=IFDNumber(player,@"currentTime",&time);
    if (!self.clockAvailable) { [self clearLabels]; return; }
    if (!self.enabled || !self.comments.count) return;
    // No independent animation clock: pause freezes text, seeks reconstruct it,
    // and speed follows the player's media timestamp automatically.
    auto visible=_timeline.at(time-self.delay);
    NSMutableSet<NSNumber *> *active=[NSMutableSet set];
    CGFloat scale=self.overlay.window.screen.scale ?: UIScreen.mainScreen.scale;
    CGFloat row=self.fontSize+8;
    CGFloat base=self.overlay.safeAreaInsets.top+8;
    for (auto &p:visible) {
        NSNumber *key=@(p.key); [active addObject:key];
        IFDComment *c=self.comments[p.key]; UILabel *label=self.labels[key];
        if (!label) {
            label=[UILabel new]; label.userInteractionEnabled=NO; label.numberOfLines=1;
            label.font=[UIFont systemFontOfSize:self.fontSize weight:UIFontWeightRegular];
            label.textColor=c.color; label.text=c.text;
            label.layer.contentsScale=scale; label.layer.shouldRasterize=NO;
            label.layer.shadowColor=UIColor.blackColor.CGColor;
            label.layer.shadowOpacity=.9; label.layer.shadowRadius=1; label.layer.shadowOffset=CGSizeMake(0,.5);
            label.alpha=self.textOpacity; [self.overlay addSubview:label];
            self.labels[key]=label;
        }
        CGFloat y=base+p.lane*row;
        if (p.mode==ifd::Mode::top) y+=self.laneCount*row;
        else if (p.mode==ifd::Mode::bottom) y=self.overlay.bounds.size.height-self.overlay.safeAreaInsets.bottom-42-row*(p.lane+1);
        label.frame=CGRectMake(round(p.x*scale)/scale,round(y*scale)/scale,c.width,row);
    }
    for (NSNumber *key in self.labels.allKeys) {
        if (![active containsObject:key]) { [self.labels[key] removeFromSuperview]; [self.labels removeObjectForKey:key]; }
    }
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
