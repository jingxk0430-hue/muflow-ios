#pragma once
// Local BAS scene compositor. Parsing/layout/bitmap work runs on the preparation
// queue; playback only adjusts the media-time origin of native CA animations.
#import <UIKit/UIKit.h>
#import "../Core/BAS.hpp"
#import "SVGPathCG.hpp"
#import "EffectAnimation.hpp"
#include <set>
#include <functional>

namespace ifd::nativebas {
inline double num(const bas::Properties& p,const char *key,double fallback=0) {
    auto i=p.find(key);return i==p.end()?fallback:i->second.number;
}
inline double axis(const bas::Properties& p,const char *key,double extent,double fallback=0) {
    auto i=p.find(key);return i==p.end()?fallback:i->second.number*(i->second.kind==bas::Kind::Percent?extent/100:1);
}
inline NSString *str(const bas::Properties& p,const char *key) {
    auto i=p.find(key);return i==p.end()?@"":[NSString stringWithUTF8String:i->second.text.c_str()]?:@"";
}
inline UIColor *color(const bas::Properties& p,const char *key,double alpha=1) {
    unsigned n=(unsigned)num(p,key,0xffffff);
    return [UIColor colorWithRed:((n>>16)&255)/255. green:((n>>8)&255)/255. blue:(n&255)/255. alpha:alpha];
}
inline NSString *variant(const bas::Properties& p,bool button) {
    return [NSString stringWithFormat:@"%@|%@|%.0f",str(p,button?"text":"content"),str(p,"fontFamily"),num(p,"bold",0)];
}
// Match available system faces; unknown Web fonts deliberately use iOS fallback.
inline CTFontRef font(const bas::Properties& p,double size) {
    NSString *family=str(p,"fontFamily");
    NSString *name=([family isEqualToString:@"monospace"]?@"Menlo":
        [family isEqualToString:@"serif"]?@"TimesNewRomanPSMT":@"Helvetica");
    CTFontRef base=CTFontCreateWithName((__bridge CFStringRef)name,size,nullptr);
    if(num(p,"bold",0)!=0){CTFontRef bold=CTFontCreateCopyWithSymbolicTraits(base,size,nullptr,kCTFontBoldTrait,kCTFontBoldTrait);if(bold){CFRelease(base);base=bold;}}
    return base;
}
inline CGSize textSize(NSString *text,CTFontRef face) {
    double width=0;NSArray *lines=[text componentsSeparatedByString:@"\n"];
    if(lines.count>8||text.length>512)return CGSizeZero;
    for(NSString *line in lines){NSAttributedString *a=[[NSAttributedString alloc] initWithString:line attributes:@{(__bridge id)kCTFontAttributeName:(__bridge id)face}];
        CTLineRef l=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);width=MAX(width,CTLineGetTypographicBounds(l,nullptr,nullptr,nullptr));CFRelease(l);}
    return CGSizeMake(ceil(width)+8,ceil((CTFontGetAscent(face)+CTFontGetDescent(face)+CTFontGetLeading(face))*lines.count)+8);
}
inline CGImageRef textImage(NSString *text,CTFontRef face,CGSize points,double scale,double stroke) CF_RETURNS_RETAINED {
    size_t w=0,h=0;if(!ifd::bitmapSize(points,scale,w,h))return nullptr;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef c=CGBitmapContextCreate(nullptr,w,h,8,w*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);CGColorSpaceRelease(space);if(!c)return nullptr;
    CGContextScaleCTM(c,scale,scale);CGContextSetTextMatrix(c,CGAffineTransformIdentity);CGContextSetLineJoin(c,kCGLineJoinRound);
    double lineHeight=CTFontGetAscent(face)+CTFontGetDescent(face)+CTFontGetLeading(face),y=points.height-4-CTFontGetAscent(face);
    for(NSString *line in [text componentsSeparatedByString:@"\n"]){
        NSMutableDictionary *attributes=[@{(__bridge id)kCTFontAttributeName:(__bridge id)face,(__bridge id)kCTForegroundColorAttributeName:(__bridge id)UIColor.whiteColor.CGColor} mutableCopy];
        if(stroke>0){attributes[(__bridge id)kCTStrokeWidthAttributeName]=@(stroke);attributes[(__bridge id)kCTStrokeColorAttributeName]=(__bridge id)UIColor.whiteColor.CGColor;}
        NSAttributedString *a=[[NSAttributedString alloc] initWithString:line attributes:attributes];CTLineRef l=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
        CGContextSetTextPosition(c,4,y);CTLineDraw(l,c);CFRelease(l);y-=lineHeight;
    }
    CGImageRef image=CGBitmapContextCreateImage(c);CGContextRelease(c);return image;
}
inline CAKeyframeAnimation *animation(NSString *key,NSArray *values,NSArray *times,double duration,BOOL discrete=NO) {
    CAKeyframeAnimation *a=[CAKeyframeAnimation animationWithKeyPath:key];a.values=values;a.keyTimes=times;
    a.duration=duration;a.calculationMode=discrete?kCAAnimationDiscrete:kCAAnimationLinear;
    a.fillMode=kCAFillModeBoth;a.removedOnCompletion=NO;return a;
}
}

@interface IFDBASDocument : NSObject {
@public ifd::bas::Scene scene;
}
@property(nonatomic,copy) NSString *error;
+ (instancetype)parse:(NSString *)source;
@end
@implementation IFDBASDocument
+ (instancetype)parse:(NSString *)source {
    IFDBASDocument *d=[IFDBASDocument new];if(!source||source.length>131072){d.error=@"BAS 超过大小限制";return d;}
    auto parsed=ifd::bas::parse(source.UTF8String?:"");
    if(!parsed){d.error=[NSString stringWithUTF8String:parsed.error.c_str()];return d;}
    d->scene=std::move(parsed.scene);return d;
}
@end

@interface IFDBASImage : NSObject
@property(nonatomic,readonly) CGImageRef image;
@property CGSize size;
- (instancetype)initWithImage:(CGImageRef)image size:(CGSize)size;
@end
@implementation IFDBASImage
- (instancetype)initWithImage:(CGImageRef)image size:(CGSize)size {if((self=[super init])){_image=CGImageRetain(image);_size=size;}return self;}
- (void)dealloc {CGImageRelease(_image);}
@end

@interface IFDBASPrepared : NSObject
@property(nonatomic,strong) IFDBASDocument *document;
@property(nonatomic,copy) NSArray<NSDictionary *> *nodes;
@property(nonatomic,copy) NSString *error;
@property NSUInteger bytes;
+ (instancetype)prepare:(IFDBASDocument *)document size:(CGSize)size scale:(double)scale;
@end
@implementation IFDBASPrepared
+ (instancetype)prepare:(IFDBASDocument *)document size:(CGSize)size scale:(double)scale {
    using namespace ifd::nativebas;
    IFDBASPrepared *out=[IFDBASPrepared new];out.document=document;
    const auto &scene=document->scene;
    if(document.error||scene.nodes.empty()||scene.nodes.size()>32||size.width<=0||size.height<=0){out.error=document.error?:@"BAS 场景超过本机节点限制（32）";return out;}
    // A bounded set of keyframes is handed to the compositor, never redrawn on
    // each display-link callback. Include exact sequence boundaries as well.
    std::set<double> steps={0,scene.duration};
    for(const auto &n:scene.nodes)steps.insert(n.duration);
    for(const auto &t:scene.tracks){steps.insert(t.start);steps.insert(t.start+t.duration);}
    for(double t=0;t<scene.duration;t+=1./30)steps.insert(t);
    if(steps.size()*scene.nodes.size()>32768){out.error=@"BAS 时间线超过本机动画预算";return out;}
    NSMutableArray *times=[NSMutableArray new];for(double t:steps)[times addObject:@(t/scene.duration)];
    NSMutableArray *nodes=[NSMutableArray new];
    std::vector<std::map<std::string,CGSize>> measured(scene.nodes.size());
    for(size_t i=0;i<scene.nodes.size();++i){
        const auto &n=scene.nodes[i];bool button=n.type=="button";NSMutableDictionary *images=[NSMutableDictionary new];
        std::vector<ifd::bas::Properties> variants={n.properties};
        for(const auto &track:scene.tracks)if(track.node==i){variants.push_back(track.from);variants.push_back(track.to);
            if(track.to.count("strokeWidth")||track.to.count("textShadow")){out.error=@"尚不支持动态描边宽度或阴影";return out;}}
        if(n.type!="path")for(auto properties:variants){
            auto base=n.properties;for(auto &v:properties)base[v.first]=v.second;
            NSString *key=variant(base,button);if(images[key])continue;
            if(images.count>=8){out.error=@"BAS 文字状态超过限制";return out;}
            NSString *text=str(base,button?"text":"content");CTFontRef face=font(base,64);
            CGSize points=textSize(text,face);CGImageRef fill=textImage(text,face,points,scale,0);
            double stroke=num(base,"strokeWidth",0);if(stroke==0&&num(base,"textShadow",0)!=0)stroke=2;
            CGImageRef outline=stroke>0?textImage(text,face,points,scale,std::clamp(stroke,0.,8.)):nullptr;
            CFRelease(face);
            if(!fill){if(outline)CGImageRelease(outline);out.error=@"BAS 文字贴图超过限制";return out;}
            out.bytes+=CGImageGetBytesPerRow(fill)*CGImageGetHeight(fill)*(outline?2:1);
            if(out.bytes>16*1024*1024){CGImageRelease(fill);if(outline)CGImageRelease(outline);out.error=@"BAS 贴图超过 16 MB";return out;}
            IFDBASImage *ink=[[IFDBASImage alloc] initWithImage:fill size:points];CGImageRelease(fill);
            IFDBASImage *edge=outline?[[IFDBASImage alloc] initWithImage:outline size:points]:nil;if(outline)CGImageRelease(outline);
            images[key]=@{@"fill":ink,@"outline":edge?:NSNull.null};measured[i][key.UTF8String]=points;
        }
        NSInteger parent=-1;for(size_t j=0;j<scene.nodes.size();++j)if(scene.nodes[j].name==n.parent)parent=(NSInteger)j;
        NSMutableDictionary *entry=[@{@"parent":@(parent),@"type":[NSString stringWithUTF8String:n.type.c_str()],@"images":images,@"times":times,@"values":[NSMutableDictionary new]} mutableCopy];
        if(n.type=="path"){
            NSString *viewBox=str(n.properties,"viewBox");std::string vb=viewBox.UTF8String?:"";std::replace(vb.begin(),vb.end(),',',' ');
            double x=0,y=0,w=0,h=0;NSScanner *scan=[NSScanner scannerWithString:[NSString stringWithUTF8String:vb.c_str()]];
            if(![scan scanDouble:&x]||![scan scanDouble:&y]||![scan scanDouble:&w]||![scan scanDouble:&h]||!scan.isAtEnd||!std::isfinite(x+y+w+h)||w<=0||h<=0){out.error=@"BAS path 需要有效 viewBox";return out;}
            CGPathRef path=ifd::svg::createSVGPath(str(n.properties,"d").UTF8String?:"");if(!path){out.error=@"不支持的 BAS SVG 路径";return out;}
            entry[@"path"]=(__bridge id)path;CGPathRelease(path);entry[@"viewBox"]=[NSValue valueWithCGRect:CGRectMake(x,y,w,h)];
        }
        [nodes addObject:entry];
    }
    for(double age:steps){
        std::vector<ifd::bas::Properties> props;for(size_t i=0;i<scene.nodes.size();++i)props.push_back(ifd::bas::sample(scene,i,age));
        std::vector<CGSize> sizes(scene.nodes.size(),CGSizeZero);std::vector<bool> resolved(scene.nodes.size(),false);
        std::function<CGSize(size_t)> layout=[&](size_t i)->CGSize{
            if(resolved[i])return sizes[i];NSInteger parent=[nodes[i][@"parent"] integerValue];CGSize extent=parent<0?size:layout((size_t)parent);
            const auto &p=props[i];BOOL path=scene.nodes[i].type=="path",button=scene.nodes[i].type=="button";
            if(path){CGRect vb=[nodes[i][@"viewBox"] CGRectValue];sizes[i]=CGSizeMake(axis(p,"width",extent.width,vb.size.width),axis(p,"height",extent.height,vb.size.height));}
            else{CGSize base=measured[i][variant(p,button).UTF8String];double f=axis(p,"fontSize",extent.width,25)/64.;sizes[i]=CGSizeMake(base.width*f+(button?20:0),base.height*f+(button?10:0));}
            resolved[i]=true;return sizes[i];
        };
        for(size_t i=0;i<scene.nodes.size();++i){
            CGSize bounds=layout(i);const auto &p=props[i];NSInteger parent=[nodes[i][@"parent"] integerValue];CGSize extent=parent<0?size:sizes[parent];
            if(!std::isfinite(bounds.width+bounds.height)||bounds.width>8192||bounds.height>8192||num(p,"scale",1)>8){out.error=@"BAS 几何超过本机限制";return out;}
            NSMutableDictionary *values=nodes[i][@"values"];
            auto add=[&](NSString *key,id value){if(!values[key])values[key]=[NSMutableArray new];[values[key] addObject:value];};
            BOOL path=scene.nodes[i].type=="path",button=scene.nodes[i].type=="button";
            add(@"position",[NSValue valueWithCGPoint:CGPointMake(axis(p,"x",extent.width),axis(p,"y",extent.height))]);
            add(@"bounds",[NSValue valueWithCGRect:CGRectMake(0,0,bounds.width,bounds.height)]);
            add(@"anchorPoint",[NSValue valueWithCGPoint:CGPointMake(num(p,"anchorX"),num(p,"anchorY"))]);
            CATransform3D tr=CATransform3DIdentity;tr.m34=-1./600;
            for(auto a:{std::string("rotateX"),std::string("rotateY"),std::string("rotateZ")})tr=CATransform3DRotate(tr,num(p,a.c_str())*M_PI/180,a=="rotateX",a=="rotateY",a=="rotateZ");
            tr=CATransform3DScale(tr,num(p,"scale",1),num(p,"scale",1),1);add(@"transform",[NSValue valueWithCATransform3D:tr]);
            add(@"opacity",@(ifd::bas::visible(scene,i,age)?num(p,"alpha",1):0));add(@"zPosition",@(num(p,"zIndex")));
            if(path){CGRect vb=[nodes[i][@"viewBox"] CGRectValue];add(@"ink.transform",[NSValue valueWithCATransform3D:CATransform3DMakeScale(bounds.width/vb.size.width,bounds.height/vb.size.height,1)]);
                add(@"ink.fillColor",(__bridge id)color(p,"fillColor",num(p,"fillAlpha",1)).CGColor);add(@"ink.strokeColor",(__bridge id)color(p,"borderColor",num(p,"borderAlpha",1)).CGColor);add(@"ink.lineWidth",@(num(p,"borderWidth")));}
            else {double fontSize=axis(p,"fontSize",extent.width,25);add(@"ink.transform",[NSValue valueWithCATransform3D:CATransform3DMakeScale(fontSize/64.,fontSize/64.,1)]);
                add(@"ink.color",(__bridge id)color(p,button?"textColor":"color",button?num(p,"textAlpha",1):1).CGColor);
                add(@"ink.stroke",(__bridge id)color(p,"strokeColor").CGColor);add(@"ink.variant",variant(p,button));
                if(button)add(@"backgroundColor",(__bridge id)color(p,"fillColor",num(p,"fillAlpha",1)).CGColor);}
        }
    }
    out.nodes=nodes;return out;
}
@end

@interface IFDBASLayer : NSObject {
@public std::vector<ifd::EffectClock> clocks;
}
@property(nonatomic,strong) CALayer *root;
@property(nonatomic,strong) NSArray<CALayer *> *layers;
@property(nonatomic,strong) NSArray<CAAnimation *> *animations;
- (instancetype)initWithPrepared:(IFDBASPrepared *)prepared;
- (void)driveAt:(double)age rate:(double)rate wall:(double)wall force:(BOOL)force;
@end
@implementation IFDBASLayer
- (instancetype)initWithPrepared:(IFDBASPrepared *)prepared {
    if(!(self=[super init])||prepared.error)return nil;
    using namespace ifd::nativebas;
    self.root=[CALayer layer];NSMutableArray *roots=[NSMutableArray new],*layers=[NSMutableArray new],*animations=[NSMutableArray new];
    const double duration=prepared.document->scene.duration;
    auto install=[&](CALayer *layer,NSDictionary *values,NSArray *times,BOOL discrete=NO){
        NSMutableArray *a=[NSMutableArray new];for(NSString *key in values){CAKeyframeAnimation *animation=ifd::nativebas::animation(key,values[key],times,duration,discrete);[a addObject:animation];}
        CAAnimationGroup *group=[CAAnimationGroup animation];group.animations=a;group.duration=duration;group.removedOnCompletion=NO;group.fillMode=kCAFillModeBoth;
        [layers addObject:layer];[animations addObject:group];
    };
    for(NSDictionary *node in prepared.nodes){CALayer *root=[CALayer layer];root.anchorPoint=CGPointZero;root.cornerRadius=4;[roots addObject:root];
        NSDictionary *values=node[@"values"];NSMutableDictionary *ordinary=[NSMutableDictionary new];for(NSString *key in values)if(![key hasPrefix:@"ink."])ordinary[key]=values[key];install(root,ordinary,node[@"times"]);
        CALayer *ink=[CALayer layer];ink.anchorPoint=CGPointZero;ink.position=CGPointZero;[root addSublayer:ink];
        if([node[@"type"] isEqual:@"path"]){CAShapeLayer *shape=[CAShapeLayer layer];shape.path=(__bridge CGPathRef)node[@"path"];shape.bounds=[node[@"viewBox"] CGRectValue];shape.anchorPoint=CGPointZero;shape.position=CGPointZero;[ink addSublayer:shape];
            install(ink,@{@"transform":values[@"ink.transform"]},node[@"times"]);
            install(shape,@{@"fillColor":values[@"ink.fillColor"],@"strokeColor":values[@"ink.strokeColor"],@"lineWidth":values[@"ink.lineWidth"]},node[@"times"]);
        }else{
            if([node[@"type"] isEqual:@"button"])ink.position=CGPointMake(10,5);
            install(ink,@{@"transform":values[@"ink.transform"]},node[@"times"]);
            for(NSString *key in node[@"images"]){NSDictionary *assets=node[@"images"][key];IFDBASImage *fill=assets[@"fill"];
                CALayer *state=[CALayer layer];state.anchorPoint=CGPointZero;state.position=CGPointZero;state.bounds=(CGRect){CGPointZero,fill.size};[ink addSublayer:state];
                NSMutableArray *opacity=[NSMutableArray new];for(NSString *current in values[@"ink.variant"])[opacity addObject:@([current isEqual:key]?1:0)];install(state,@{@"opacity":opacity},node[@"times"],YES);
                for(NSString *kind in @[@"outline",@"fill"]){IFDBASImage *asset=assets[kind];if((id)asset==NSNull.null)continue;
                    CALayer *paint=[CALayer layer];paint.frame=(CGRect){CGPointZero,asset.size};CALayer *mask=[CALayer layer];mask.frame=paint.bounds;mask.contents=(__bridge id)asset.image;paint.mask=mask;[state addSublayer:paint];
                    install(paint,@{@"backgroundColor":values[[kind isEqual:@"fill"]?@"ink.color":@"ink.stroke"]},node[@"times"]);
                }
            }
        }
    }
    for(NSUInteger i=0;i<roots.count;++i){NSInteger parent=[prepared.nodes[i][@"parent"] integerValue];[(parent<0?self.root:roots[parent]) addSublayer:roots[i]];}
    self.layers=layers;self.animations=animations;clocks.assign(layers.count,{});return self;
}
- (void)driveAt:(double)age rate:(double)rate wall:(double)wall force:(BOOL)force {
    for(NSUInteger i=0;i<self.layers.count;++i)ifd::driveEffect(self.layers[i],self.animations[i],age,rate,wall,force,clocks[i]);
}
@end
