#import "../Source/TextBitmap.hpp"
#import <ImageIO/ImageIO.h>
#include <cassert>
#include <iostream>

int main(int argc,const char *argv[]) {
    @autoreleasepool {
        CGColorSpaceRef rgb=CGColorSpaceCreateDeviceRGB();
        CGFloat components[]={1,.2,.1,1}; CGColorRef color=CGColorCreate(rgb,components);
        CGColorSpaceRelease(rgb);
        for (double scale : {1.,2.,3.}) {
            CGImageRef image=ifd::createTextBitmap(CFSTR("幕流 Fg Aa 0123"),CFSTR("Helvetica"),24,
                color,CGSizeMake(300,42),scale);
            assert(image && CGImageGetWidth(image)==300*scale && CGImageGetHeight(image)==42*scale);
            CFDataRef bytes=CGDataProviderCopyData(CGImageGetDataProvider(image));
            const UInt8 *pixels=CFDataGetBytePtr(bytes);
            const size_t width=CGImageGetWidth(image),height=CGImageGetHeight(image),stride=CGImageGetBytesPerRow(image);
            size_t ink=0,outline=0; bool colored=false;
            for(size_t y=0;y<height;++y) for(size_t x=0;x<width;++x) {
                const UInt8 *p=pixels+y*stride+x*4;
                if(p[3]>8 && p[0]<25 && p[1]<25 && p[2]<25) ++outline;
                if(p[3]>128) {
                    ++ink;
                    if(p[0]>120 && p[0]>p[1]*2) colored=true;
                }
            }
            assert(ink>100*scale*scale && outline>0 && colored);
            assert(pixels[3]==0 && pixels[(height-1)*stride+(width-1)*4+3]==0);
            if(scale==3 && argc>1) {
                NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
                CGImageDestinationRef out=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,nullptr);
                assert(out); CGImageDestinationAddImage(out,image,nullptr); assert(CGImageDestinationFinalize(out)); CFRelease(out);
            }
            CFRelease(bytes); CGImageRelease(image);
        }
        CGImageRef gradient=ifd::createTextBitmap(CFSTR("MMMMMMMMMMMM"),CFSTR("Helvetica"),24,
            color,CGSizeMake(250,42),3,@[@0xff0000,@0x0000ff],90);
        assert(gradient);
        CFDataRef gradientBytes=CGDataProviderCopyData(CGImageGetDataProvider(gradient));
        const UInt8 *g=CFDataGetBytePtr(gradientBytes);size_t stride=CGImageGetBytesPerRow(gradient);
        bool red=false,blue=false;
        for(size_t y=0;y<CGImageGetHeight(gradient);++y)for(size_t x=0;x<CGImageGetWidth(gradient);++x){
            const UInt8 *p=g+y*stride+x*4;if(p[3]>200){if(x<250&&p[0]>p[2]*2)red=true;if(x>500&&p[2]>p[0]*2)blue=true;}}
        assert(red&&blue);
        if(argc>2){NSURL *url=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
            CGImageDestinationRef out=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,nullptr);
            assert(out);CGImageDestinationAddImage(out,gradient,nullptr);assert(CGImageDestinationFinalize(out));CFRelease(out);}
        CFRelease(gradientBytes);CGImageRelease(gradient);
        auto slices=ifd::glyphSlices(CFSTR("A👨‍👩‍👧‍👦中é"),CFSTR("Helvetica"),24,CGSizeMake(250,42));
        assert(slices.size()==4);double end=0;
        for(auto &r:slices){assert(std::abs(r.origin.x-end)<.01&&r.size.width>=0);end=CGRectGetMaxX(r);}
        assert(end==250);
        assert(ifd::glyphSlices((__bridge CFStringRef)[@"A" stringByPaddingToLength:65 withString:@"A" startingAtIndex:0],CFSTR("Helvetica"),24,CGSizeMake(2000,42)).empty());
        size_t w=0,h=0;
        assert(!ifd::bitmapSize(CGSizeMake(100000,1000),3,w,h));
        assert(!ifd::bitmapSize(CGSizeMake(100,20),NAN,w,h));
        assert(!ifd::bitmapSize(CGSizeZero,3,w,h));
        CGColorRelease(color);
        std::cout << "text bitmap: native 1x/2x/3x dimensions, CJK/Latin coverage, colored fill, outline, transparent padding and allocation bounds passed\n";
    }
}
