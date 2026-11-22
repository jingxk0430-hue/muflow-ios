#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include <cmath>
#include <vector>

namespace ifd {
// Bound each allocation independently of the cache budget. Very long comments
// retain the host UILabel fallback rather than allocating a huge bitmap.
inline bool bitmapSize(CGSize points, double scale, size_t &width, size_t &height) {
    if (!std::isfinite(points.width) || !std::isfinite(points.height) ||
        !std::isfinite(scale) || scale < .25 || scale > 8 || points.width <= 0 || points.height <= 0)
        return false;
    const double w=std::ceil(points.width*scale), h=std::ceil(points.height*scale);
    if (w < 1 || h < 1 || w > 32768 || h > 4096 || w*h > 2*1024*1024) return false;
    width=static_cast<size_t>(w); height=static_cast<size_t>(h); return true;
}

// Partition one shaped line at composed-character boundaries. Overlong or
// non-monotonic (e.g. complex bidi) lines retain their intact static bitmap.
inline std::vector<CGRect> glyphSlices(CFStringRef text,CFStringRef fontName,double fontSize,CGSize size) {
    std::vector<CGRect> result;
    if(!text||!fontName||!std::isfinite(fontSize)||fontSize<=0)return result;
    CTFontRef font=CTFontCreateWithName(fontName,fontSize,nullptr);if(!font)return result;
    NSAttributedString *a=[[NSAttributedString alloc] initWithString:(__bridge NSString *)text attributes:@{
        (__bridge id)kCTFontAttributeName:(__bridge id)font}];
    CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)a);
    __block std::vector<CGRect> slices;
    NSString *value=(__bridge NSString *)text;
    [value enumerateSubstringsInRange:NSMakeRange(0,value.length) options:NSStringEnumerationByComposedCharacterSequences
        usingBlock:^(__unused NSString *part,NSRange range,__unused NSRange enclosing,BOOL *stop){
            if(slices.size()>=64){slices.clear();*stop=YES;return;}
            double left=range.location==0?0:CTLineGetOffsetForStringIndex(line,range.location,nullptr)+2;
            double right=NSMaxRange(range)==value.length?size.width:CTLineGetOffsetForStringIndex(line,NSMaxRange(range),nullptr)+2;
            if(right<left||left<0||right>size.width){slices.clear();*stop=YES;return;}
            slices.push_back(CGRectMake(left,0,right-left,size.height));
        }];
    result=std::move(slices);CFRelease(line);CFRelease(font);return result;
}

// CoreText/CoreGraphics only: safe to prepare on a worker queue. The resulting
// CGImage is already outlined at physical screen resolution and can be placed
// directly in a layer without a second shadow or rasterization pass.
inline CGImageRef createTextBitmap(CFStringRef text, CFStringRef fontName, double fontSize,
                                  CGColorRef color, CGSize points, double scale, NSArray<NSNumber *> *colors=nil,
                                  double angle=90, CGColorRef stroke=nullptr, bool outline=true) CF_RETURNS_RETAINED {
    size_t width=0,height=0;
    if (!text || !fontName || !color || !std::isfinite(fontSize) || fontSize<=0 ||
        !bitmapSize(points,scale,width,height)) return nullptr;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGFloat blackComponents[]={0,0,0,.9};
    CGColorRef black=CGColorCreate(space,blackComponents);
    CGContextRef context=CGBitmapContextCreate(nullptr,width,height,8,width*4,space,
        kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!context) { CGColorRelease(black); return nullptr; }
    CTFontRef font=CTFontCreateWithName(fontName,fontSize,nullptr);
    if (!font) { CGColorRelease(black); CGContextRelease(context); return nullptr; }
    NSDictionary *attributes=@{(__bridge id)kCTFontAttributeName:(__bridge id)font,
        (__bridge id)kCTForegroundColorAttributeName:(__bridge id)color,
        (__bridge id)kCTStrokeColorAttributeName:(__bridge id)(stroke?:black),
        (__bridge id)kCTStrokeWidthAttributeName:@(outline?2.0:0)};
    NSAttributedString *string=[[NSAttributedString alloc] initWithString:(__bridge NSString *)text attributes:attributes];
    CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGFloat ascent=0,descent=0;
    CTLineGetTypographicBounds(line,&ascent,&descent,nullptr);
    CGContextScaleCTM(context,scale,scale);
    CGContextSetAllowsAntialiasing(context,true);
    CGContextSetShouldAntialias(context,true);
    CGContextSetLineJoin(context,kCGLineJoinRound);
    CGContextSetTextMatrix(context,CGAffineTransformIdentity);
    const double baseline=(height/scale-ascent-descent)/2+descent;
    CGContextSetTextPosition(context,2,baseline);
    // CJK fonts can have overlapping contours. Stroke first, then paint a
    // separate fill pass so outlines cannot cut black seams through the ink.
    if(outline)CTLineDraw(line,context);
    NSAttributedString *fillString=[[NSAttributedString alloc] initWithString:(__bridge NSString *)text attributes:@{
        (__bridge id)kCTFontAttributeName:(__bridge id)font,(__bridge id)kCTForegroundColorAttributeName:(__bridge id)color}];
    CTLineRef baseFill=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)fillString);
    CGContextSetTextPosition(context,2,baseline);CTLineDraw(baseFill,context);CFRelease(baseFill);
    if(colors.count>=2 && colors.count<=16 && std::isfinite(angle)) {
        CGColorSpaceRef gradientSpace=CGColorSpaceCreateDeviceRGB();
        CGContextRef maskContext=CGBitmapContextCreate(nullptr,width,height,8,width*4,gradientSpace,
            kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
        if(maskContext) {
            CGFloat whiteComponents[]={1,1,1,1};CGColorRef white=CGColorCreate(gradientSpace,whiteComponents);
            NSAttributedString *fill=[[NSAttributedString alloc] initWithString:(__bridge NSString *)text attributes:@{
                (__bridge id)kCTFontAttributeName:(__bridge id)font,(__bridge id)kCTForegroundColorAttributeName:(__bridge id)white}];
            CTLineRef fillLine=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)fill);
            CGContextScaleCTM(maskContext,scale,scale);CGContextSetTextPosition(maskContext,2,baseline);CTLineDraw(fillLine,maskContext);
            CGImageRef mask=CGBitmapContextCreateImage(maskContext);
            CGFloat components[64]={};
            for(NSUInteger i=0;i<colors.count;++i){unsigned rgb=colors[i].unsignedIntValue;
                components[i*4]=((rgb>>16)&255)/255.;components[i*4+1]=((rgb>>8)&255)/255.;
                components[i*4+2]=(rgb&255)/255.;components[i*4+3]=1;}
            CGGradientRef gradient=CGGradientCreateWithColorComponents(gradientSpace,components,nullptr,colors.count);
            if(mask&&gradient) {
                CGContextSaveGState(context);
                CGSize actual=CGSizeMake(width/scale,height/scale);
                CGContextClipToMask(context,CGRectMake(0,0,actual.width,actual.height),mask);
                double dx=std::sin(angle*M_PI/180),dy=std::cos(angle*M_PI/180);
                double radius=(std::abs(dx)*actual.width+std::abs(dy)*actual.height)/2;
                CGPoint center=CGPointMake(actual.width/2,actual.height/2);
                CGContextDrawLinearGradient(context,gradient,CGPointMake(center.x-dx*radius,center.y-dy*radius),
                    CGPointMake(center.x+dx*radius,center.y+dy*radius),kCGGradientDrawsBeforeStartLocation|kCGGradientDrawsAfterEndLocation);
                CGContextRestoreGState(context);
            }
            if(gradient)CGGradientRelease(gradient);if(mask)CGImageRelease(mask);
            CFRelease(fillLine);CGColorRelease(white);CGContextRelease(maskContext);
        }
        CGColorSpaceRelease(gradientSpace);
    }
    CGImageRef image=CGBitmapContextCreateImage(context);
    CFRelease(line); CGColorRelease(black); CFRelease(font); CGContextRelease(context);
    return image;
}
} // namespace ifd
