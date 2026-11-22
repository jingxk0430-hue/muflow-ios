#pragma once
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include "SVGPathCG.hpp"

// SVG is parsed as data using NSXMLParser; no WebKit, external entities, scripts,
// network resource loads or arbitrary SVG filters. Unsupported shapes fail
// closed (caller removes the mask), rather than hiding random video regions.
namespace ifd { namespace bili {
struct SVGMaskShape {
    CGPathRef path=nullptr;CGAffineTransform transform=CGAffineTransformIdentity;
    double alpha=1;bool evenOdd=false;
    SVGMaskShape()=default;
    SVGMaskShape(const SVGMaskShape&o):path(o.path?CGPathRetain(o.path):nullptr),transform(o.transform),alpha(o.alpha),evenOdd(o.evenOdd){}
    SVGMaskShape(SVGMaskShape&&o)noexcept:path(o.path),transform(o.transform),alpha(o.alpha),evenOdd(o.evenOdd){o.path=nullptr;}
    SVGMaskShape&operator=(const SVGMaskShape&o){if(this!=&o){if(path)CGPathRelease(path);path=o.path?CGPathRetain(o.path):nullptr;transform=o.transform;alpha=o.alpha;evenOdd=o.evenOdd;}return *this;}
    ~SVGMaskShape(){if(path)CGPathRelease(path);}
};
struct SVGMaskDocument {CGRect viewBox=CGRectZero;bool preserveAspect=true;std::vector<SVGMaskShape> shapes;};
inline bool maskNumbers(NSString *text,std::vector<double> &numbers){
    if(!text)return false;std::string s=text.UTF8String?text.UTF8String:"";
    if(s.size()>4096)return false;const char*p=s.c_str();numbers.clear();
    while(*p){while(*p&&(std::isspace(static_cast<unsigned char>(*p))||*p==','))++p;if(!*p)break;
        char*e=nullptr;double d=std::strtod(p,&e);if(e==p||!std::isfinite(d)||std::abs(d)>1e7)return false;
        numbers.push_back(d);if(numbers.size()>64)return false;p=e;
    }return !numbers.empty();
}
inline bool maskTransform(NSString *text,CGAffineTransform &out){
    out=CGAffineTransformIdentity;if(!text.length)return true;
    std::string s=text.UTF8String?text.UTF8String:"";if(s.size()>4096)return false;
    size_t pos=0,count=0;while(pos<s.size()){
        while(pos<s.size()&&(std::isspace(static_cast<unsigned char>(s[pos]))||s[pos]==','))++pos;
        if(pos==s.size())break;size_t start=pos;
        while(pos<s.size()&&std::isalpha(static_cast<unsigned char>(s[pos])))++pos;
        std::string name=s.substr(start,pos-start);
        while(pos<s.size()&&std::isspace(static_cast<unsigned char>(s[pos])))++pos;
        if(pos==s.size()||s[pos++]!='(')return false;size_t end=s.find(')',pos);if(end==std::string::npos)return false;
        NSString *body=[[NSString alloc] initWithBytes:s.data()+pos length:end-pos encoding:NSUTF8StringEncoding];
        std::vector<double> v;if(!maskNumbers(body,v))return false;pos=end+1;
        CGAffineTransform t=CGAffineTransformIdentity;
        constexpr double pi=3.14159265358979323846;
        if(name=="matrix"&&v.size()==6)t=CGAffineTransformMake(v[0],v[1],v[2],v[3],v[4],v[5]);
        else if(name=="translate"&&(v.size()==1||v.size()==2))t=CGAffineTransformMakeTranslation(v[0],v.size()==2?v[1]:0);
        else if(name=="scale"&&(v.size()==1||v.size()==2))t=CGAffineTransformMakeScale(v[0],v.size()==2?v[1]:v[0]);
        else if(name=="rotate"&&(v.size()==1||v.size()==3)){
            t=CGAffineTransformMakeRotation(v[0]*pi/180);
            if(v.size()==3){t.tx=v[1]-t.a*v[1]-t.c*v[2];t.ty=v[2]-t.b*v[1]-t.d*v[2];}
        }else if(name=="skewX"&&v.size()==1)t=CGAffineTransformMake(1,0,std::tan(v[0]*pi/180),1,0,0);
        else if(name=="skewY"&&v.size()==1)t=CGAffineTransformMake(1,std::tan(v[0]*pi/180),0,1,0,0);
        else return false;
        if(!std::isfinite(t.a)||!std::isfinite(t.b)||!std::isfinite(t.c)||!std::isfinite(t.d)||!std::isfinite(t.tx)||!std::isfinite(t.ty))return false;
        out=CGAffineTransformConcat(t,out);if(++count>32)return false;
    }return true;
}
struct SVGMaskState {CGAffineTransform transform=CGAffineTransformIdentity;double opacity=1,fillOpacity=1;bool fill=true,evenOdd=false;};
}}

@interface IFDBiliMaskXMLReader : NSObject <NSXMLParserDelegate> {
@public ifd::bili::SVGMaskDocument document;
    std::vector<ifd::bili::SVGMaskState> states;
    NSUInteger depth,elementCount;BOOL invalid,rootSeen;
}
@end
@implementation IFDBiliMaskXMLReader
- (void)parser:(NSXMLParser*)parser didStartElement:(NSString*)element namespaceURI:(NSString*)uri qualifiedName:(NSString*)qualified attributes:(NSDictionary<NSString*,NSString*>*)attributes {
    (void)uri;(void)qualified;
    using namespace ifd::bili;
    if(invalid)return;
    auto fail=[&](){invalid=YES;[parser abortParsing];};
    if(++depth>32||++elementCount>2048){fail();return;}
    if(!rootSeen){if(![element isEqualToString:@"svg"]){fail();return;}rootSeen=YES;}
    else if([element isEqualToString:@"svg"]){fail();return;}
    if(![@[@"svg",@"g",@"path",@"rect",@"title",@"desc",@"metadata"] containsObject:element]){fail();return;}
    NSMutableDictionary *attrs=[attributes mutableCopy];
    NSString *style=attrs[@"style"];
    if(style.length){for(NSString*piece in [style componentsSeparatedByString:@";"]){
        if(![piece stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)continue;
        NSArray *pair=[piece componentsSeparatedByString:@":"];if(pair.count!=2){fail();return;}
        NSString*k=[pair[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString*v=[pair[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if(![@[@"fill",@"fill-rule",@"fill-opacity",@"opacity",@"stroke"] containsObject:k]){fail();return;}attrs[k]=v;
    }}
    if(attrs[@"mask"]||attrs[@"clip-path"]||attrs[@"filter"]||attrs[@"href"]||attrs[@"xlink:href"]){fail();return;}
    if(attrs[@"stroke"]&&![attrs[@"stroke"] isEqualToString:@"none"]){fail();return;}
    SVGMaskState state=states.empty()?SVGMaskState{}:states.back();
    CGAffineTransform local;if(!maskTransform(attrs[@"transform"],local)){fail();return;}
    state.transform=CGAffineTransformConcat(local,state.transform);
    for(NSString*k in @[@"opacity",@"fill-opacity"]){if(attrs[k]){
        std::vector<double> v;if(!maskNumbers(attrs[k],v)||v.size()!=1||v[0]<0||v[0]>1){fail();return;}
        if([k isEqualToString:@"opacity"])state.opacity*=v[0];else state.fillOpacity=v[0];
    }}
    if(attrs[@"fill"]){NSString*f=attrs[@"fill"];if([f containsString:@"url("]||[f containsString:@"rgba"]||([f hasPrefix:@"#"]&&(f.length==5||f.length==9))){fail();return;}state.fill=![f isEqualToString:@"none"]&&![f isEqualToString:@"transparent"];}
    if(attrs[@"fill-rule"]){NSString*r=attrs[@"fill-rule"];if(![r isEqualToString:@"evenodd"]&&![r isEqualToString:@"nonzero"]){fail();return;}state.evenOdd=[r isEqualToString:@"evenodd"];}
    states.push_back(state);
    if([element isEqualToString:@"svg"]){
        std::vector<double> v;
        if(attrs[@"viewBox"]){if(!maskNumbers(attrs[@"viewBox"],v)||v.size()!=4||v[2]<=0||v[3]<=0){fail();return;}document.viewBox=CGRectMake(v[0],v[1],v[2],v[3]);}
        else{std::vector<double>w,h;if(!maskNumbers(attrs[@"width"],w)||!maskNumbers(attrs[@"height"],h)||w.size()!=1||h.size()!=1||w[0]<=0||h[0]<=0){fail();return;}document.viewBox=CGRectMake(0,0,w[0],h[0]);}
        NSString *aspect=attrs[@"preserveAspectRatio"];
        if(aspect&&![aspect isEqualToString:@"xMidYMid meet"]&&![aspect isEqualToString:@"none"]){fail();return;}
        document.preserveAspect=![aspect isEqualToString:@"none"];
    }else if([element isEqualToString:@"path"]||[element isEqualToString:@"rect"]){
        SVGMaskShape shape;shape.transform=state.transform;shape.alpha=state.fill?state.opacity*state.fillOpacity:0;shape.evenOdd=state.evenOdd;
        if([element isEqualToString:@"path"]){NSString*d=attrs[@"d"];shape.path=ifd::svg::createSVGPath(d.UTF8String?d.UTF8String:"");}
        else{
            if(attrs[@"rx"]||attrs[@"ry"]){fail();return;}
            double values[4]={0,0,0,0};NSArray*names=@[@"x",@"y",@"width",@"height"];
            for(int i=0;i<4;++i){if(!attrs[names[i]]&&i<2)continue;std::vector<double>v;if(!maskNumbers(attrs[names[i]],v)||v.size()!=1){fail();return;}values[i]=v[0];}
            if(values[2]<0||values[3]<0){fail();return;}shape.path=CGPathCreateWithRect(CGRectMake(values[0],values[1],values[2],values[3]),nullptr);
        }
        if(!shape.path){fail();return;}document.shapes.push_back(std::move(shape));
    }
}
- (void)parser:(NSXMLParser*)parser didEndElement:(NSString*)name namespaceURI:(NSString*)uri qualifiedName:(NSString*)q {
    (void)parser;(void)name;(void)uri;(void)q;if(depth)--depth;if(!states.empty())states.pop_back();
}
- (void)parser:(NSXMLParser*)parser foundInternalEntityDeclarationWithName:(NSString*)name value:(NSString*)value{(void)name;(void)value;invalid=YES;[parser abortParsing];}
- (void)parser:(NSXMLParser*)parser foundExternalEntityDeclarationWithName:(NSString*)name publicID:(NSString*)pub systemID:(NSString*)sys{(void)name;(void)pub;(void)sys;invalid=YES;[parser abortParsing];}
@end

namespace ifd { namespace bili {
inline bool parseSVGMask(const std::string &svg,SVGMaskDocument &out){
    out={};if(svg.empty()||svg.size()>1024*1024||svg.find("<!DOCTYPE")!=std::string::npos||svg.find("<!ENTITY")!=std::string::npos)return false;
    NSData*data=[NSData dataWithBytes:svg.data() length:svg.size()];
    NSXMLParser*parser=[[NSXMLParser alloc]initWithData:data];IFDBiliMaskXMLReader*reader=[IFDBiliMaskXMLReader new];
    parser.shouldResolveExternalEntities=NO;parser.delegate=reader;
    if(![parser parse]||reader->invalid||!reader->rootSeen||reader->depth||reader->document.shapes.empty())return false;
    out=std::move(reader->document);return true;
}
// Retained alpha-mask bitmap. SVG alpha is preserved, NOT inverted. Comments
// outside contentRect remain visible, matching web padding gradients. The
// caller provides the true video content rect after letterbox/pillarbox fit.
inline CGImageRef createSVGMaskImage(const SVGMaskDocument &doc,CGSize canvas,CGRect contentRect,double scale=1){
    if(!std::isfinite(canvas.width)||!std::isfinite(canvas.height)||!std::isfinite(scale)||scale<.25||scale>4||canvas.width<=0||canvas.height<=0||
       !std::isfinite(contentRect.origin.x)||!std::isfinite(contentRect.origin.y)||
       !std::isfinite(contentRect.size.width)||!std::isfinite(contentRect.size.height)||
       CGRectIsEmpty(contentRect)||CGRectIsEmpty(doc.viewBox)||canvas.width*scale>8192||canvas.height*scale>8192)return nullptr;
    size_t width=size_t(std::ceil(canvas.width*scale)),height=size_t(std::ceil(canvas.height*scale));
    if(width*height>16*1024*1024)return nullptr;
    CGColorSpaceRef cs=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(nullptr,width,height,8,width*4,cs,kCGImageAlphaPremultipliedLast);CGColorSpaceRelease(cs);if(!ctx)return nullptr;
    CGContextTranslateCTM(ctx,0,height);CGContextScaleCTM(ctx,scale,-scale);
    CGContextSetRGBFillColor(ctx,1,1,1,1);CGContextFillRect(ctx,CGRectMake(0,0,canvas.width,canvas.height));
    CGContextClearRect(ctx,contentRect);CGContextClipToRect(ctx,contentRect);
    double sx=contentRect.size.width/doc.viewBox.size.width,sy=contentRect.size.height/doc.viewBox.size.height;
    double ox=0,oy=0;if(doc.preserveAspect){sx=sy=std::min(sx,sy);ox=(contentRect.size.width-doc.viewBox.size.width*sx)/2;oy=(contentRect.size.height-doc.viewBox.size.height*sy)/2;}
    CGContextTranslateCTM(ctx,contentRect.origin.x+ox,contentRect.origin.y+oy);
    CGContextScaleCTM(ctx,sx,sy);
    CGContextTranslateCTM(ctx,-doc.viewBox.origin.x,-doc.viewBox.origin.y);
    for(const auto&s:doc.shapes){if(!s.path||s.alpha<=0)continue;CGContextSaveGState(ctx);CGContextConcatCTM(ctx,s.transform);
        CGContextSetRGBFillColor(ctx,1,1,1,s.alpha);CGContextAddPath(ctx,s.path);
        if(s.evenOdd)CGContextEOFillPath(ctx);else CGContextFillPath(ctx);CGContextRestoreGState(ctx);}
    CGImageRef image=CGBitmapContextCreateImage(ctx);CGContextRelease(ctx);return image;
}
}}
