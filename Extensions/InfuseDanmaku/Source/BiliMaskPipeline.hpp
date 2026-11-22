#pragma once
#import "BiliMaskImage.hpp"
#import "../Core/BiliMask.hpp"

@interface IFDBiliMaskImage : NSObject
@property(nonatomic,readonly) CGImageRef image;
@property double timeMs;
- (instancetype)initWithImage:(CGImageRef)image time:(double)time;
@end
@implementation IFDBiliMaskImage
- (instancetype)initWithImage:(CGImageRef)image time:(double)time {if((self=[super init])){_image=CGImageRetain(image);_timeMs=time;}return self;}
- (void)dealloc {CGImageRelease(_image);}
@end

@interface IFDBiliMask : NSObject {
    std::vector<ifd::bili::MaskIndexEntry> _index;
    std::vector<ifd::bili::MaskFrame> _frames;
    size_t _chunk;
}
@property(nonatomic,copy) NSData *data;
@property double fps;
@property(nonatomic,strong) NSOperationQueue *queue;
@property(nonatomic,strong) NSCache<NSString *,IFDBiliMaskImage *> *cache;
- (instancetype)initWithData:(NSData *)data fps:(double)fps;
- (void)prepareAt:(double)time canvas:(CGSize)canvas contentRect:(CGRect)contentRect completion:(void(^)(IFDBiliMaskImage *,NSString *))completion;
@end
@implementation IFDBiliMask
- (instancetype)initWithData:(NSData *)data fps:(double)fps {
    if(!(self=[super init])||data.length>4*1024*1024||!std::isfinite(fps)||fps<1||fps>60)return nil;
    ifd::bili::MaskHeader header;
    if(!ifd::bili::parseMaskHeader((const uint8_t *)data.bytes,data.length,header)||
       !ifd::bili::parseMaskIndex(header,(const uint8_t *)data.bytes+16,data.length-16,_index))return nil;
    for(auto &e:_index)if(e.offset>=data.length)return nil;
    _data=data;_fps=fps;_chunk=SIZE_MAX;
    _queue=[NSOperationQueue new];_queue.maxConcurrentOperationCount=1;_queue.qualityOfService=NSQualityOfServiceUserInitiated;
    _cache=[NSCache new];_cache.countLimit=6;_cache.totalCostLimit=8*1024*1024;return self;
}
- (void)prepareAt:(double)time canvas:(CGSize)canvas contentRect:(CGRect)contentRect completion:(void(^)(IFDBiliMaskImage *,NSString *))completion {
    if(!std::isfinite(time)||time<0)return;
    // The queue owns the mutable decoded chunk and cache. No XML, inflate or
    // bitmap creation occurs in the display-link callback.
    [self.queue cancelAllOperations];
    [self.queue addOperationWithBlock:^{@autoreleasepool{
        auto it=std::upper_bound(self->_index.begin(),self->_index.end(),time*1000,[](double t,const ifd::bili::MaskIndexEntry &e){return t<e.timeMs;});
        size_t chunk=it==self->_index.begin()?0:size_t(it-self->_index.begin()-1);
        NSString *error=nil;IFDBiliMaskImage *image=nil;
        if(chunk!=self->_chunk){size_t start=self->_index[chunk].offset,end=chunk+1<self->_index.size()?self->_index[chunk+1].offset:self.data.length;
            self->_frames.clear();self->_chunk=chunk;
            if(!ifd::bili::decodeMaskChunk((const uint8_t *)self.data.bytes+start,end-start,self->_frames))error=@"人物遮挡：蒙版区块解析失败";
        }
        const auto *frame=ifd::bili::selectMaskFrame(self->_frames,time*1000,self.fps);
        if(frame){NSString *key=[NSString stringWithFormat:@"%u-%.0f-%.0f-%.3f",frame->timeMs,canvas.width,canvas.height,contentRect.size.width/contentRect.size.height];image=[self.cache objectForKey:key];
            if(!image){ifd::bili::SVGMaskDocument document;
                if(!ifd::bili::parseSVGMask(frame->svg,document))error=@"人物遮挡：该 SVG 使用了暂不支持的结构";
                else {CGImageRef pixels=ifd::bili::createSVGMaskImage(document,canvas,contentRect,1);
                    if(pixels){image=[[IFDBiliMaskImage alloc] initWithImage:pixels time:frame->timeMs];CGImageRelease(pixels);[self.cache setObject:image forKey:key cost:CGImageGetBytesPerRow(image.image)*CGImageGetHeight(image.image)];}
                    else error=@"人物遮挡：蒙版绘制超过限制";}
            }
        }
        dispatch_async(dispatch_get_main_queue(),^{completion(image,error);});
    }}];
}
- (void)dealloc {[_queue cancelAllOperations];}
@end
