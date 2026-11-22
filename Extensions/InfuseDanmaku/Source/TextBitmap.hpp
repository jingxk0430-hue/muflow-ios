#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#include <cmath>

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

// CoreText/CoreGraphics only: safe to prepare on a worker queue. The resulting
// CGImage is already outlined at physical screen resolution and can be placed
// directly in a layer without a second shadow or rasterization pass.
inline CGImageRef createTextBitmap(CFStringRef text, CFStringRef fontName, double fontSize,
                                  CGColorRef color, CGSize points, double scale) CF_RETURNS_RETAINED {
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
        (__bridge id)kCTStrokeColorAttributeName:(__bridge id)black,
        (__bridge id)kCTStrokeWidthAttributeName:@(-2.0)};
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
    CTLineDraw(line,context);
    CGImageRef image=CGBitmapContextCreateImage(context);
    CFRelease(line); CGColorRelease(black); CFRelease(font); CGContextRelease(context);
    return image;
}
} // namespace ifd
