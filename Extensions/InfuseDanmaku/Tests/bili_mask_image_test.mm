#import <Foundation/Foundation.h>
#include "../Source/BiliMaskImage.hpp"
#include <cassert>
#include <iostream>
// macOS: clang++ -std=c++17 -fobjc-arc ... -framework Foundation -framework CoreGraphics
static unsigned alpha(CGImageRef image,size_t x,size_t y){
    CFDataRef data=CGDataProviderCopyData(CGImageGetDataProvider(image));
    assert(data);auto p=CFDataGetBytePtr(data);unsigned a=p[y*CGImageGetBytesPerRow(image)+x*4+3];CFRelease(data);return a;
}
int main(){@autoreleasepool{
    using namespace ifd::bili;SVGMaskDocument doc;
    // Synthetic inverse-person silhouette: retain SVG alpha; the center stays
    // transparent while the outer region is opaque. No polarity guessing.
    std::string svg="<svg width=\"100\" height=\"100\" viewBox=\"0 0 100 100\"><g fill=\"#000\" fill-rule=\"evenodd\"><path d=\"M0 0H100V100H0ZM25 25H75V75H25Z\"/></g></svg>";
    assert(parseSVGMask(svg,doc));
    CGImageRef image=createSVGMaskImage(doc,CGSizeMake(200,120),CGRectMake(50,10,100,100),2);
    assert(image&&CGImageGetWidth(image)==400&&CGImageGetHeight(image)==240);
    assert(alpha(image,200,120)==0);assert(alpha(image,110,120)>250);assert(alpha(image,10,120)>250);CGImageRelease(image);
    assert(parseSVGMask("<svg viewBox=\"0 0 100 100\"><g transform=\"translate(0,100) scale(.1,-.1)\" fill=\"white\"><path d=\"M0 0H1000V1000H0Z\"/></g></svg>",doc));
    image=createSVGMaskImage(doc,CGSizeMake(100,100),CGRectMake(0,0,100,100));assert(image&&alpha(image,50,50)>250);CGImageRelease(image);
    assert(parseSVGMask("<svg viewBox=\"0 0 100 100\"><rect x=\"0\" y=\"0\" width=\"100\" height=\"100\" fill-opacity=\"0.5\"/></svg>",doc));
    image=createSVGMaskImage(doc,CGSizeMake(100,100),CGRectMake(0,0,100,100));assert(image&&alpha(image,50,50)>=127&&alpha(image,50,50)<=128);CGImageRelease(image);
    for(auto s:{"<svg><path d='M0 0'/></svg>","<svg viewBox='0 0 0 100'><path d='M0 0'/></svg>","<svg viewBox='0 0 10 10'><image href='https://example.org/a'/></svg>","<!DOCTYPE svg [<!ENTITY foo 'bar'>]><svg/>","<svg viewBox='0 0 10 10'><path d='M0 0R1 2'/></svg>","<svg viewBox='0 0 10 10'><path d='M0 0H10' filter='url(#a)'/></svg>"})assert(!parseSVGMask(s,doc));
    CGPathRef path=ifd::svg::createSVGPath("M0 0C10 0 10 10 20 10A10 10 0 0 1 30 20Z");assert(path);CGPathRelease(path);
    std::cout<<"Native SVG mask alpha, bounds, transforms, contentRect and malformed input tests passed\n";
}}
