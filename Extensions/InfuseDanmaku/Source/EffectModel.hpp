#pragma once
#import <Foundation/Foundation.h>
#import "../Core/Effects.hpp"

namespace ifd {
inline bool number(id value,double &out) {
    if(![value isKindOfClass:NSString.class] && ![value isKindOfClass:NSNumber.class])return false;
    NSScanner *s=[NSScanner scannerWithString:[value description]];
    return [s scanDouble:&out]&&s.isAtEnd&&std::isfinite(out);
}
inline NSNumber *hexColor(id value) {
    if(![value isKindOfClass:NSString.class])return nil;
    NSString *v=[value hasPrefix:@"#"]?[value substringFromIndex:1]:value;
    if(v.length!=6)return nil;
    NSScanner *s=[NSScanner scannerWithString:v];unsigned int rgb=0;
    return [s scanHexInt:&rgb]&&s.isAtEnd?@(rgb):nil;
}
inline double coordinate(id value,double axis,bool &valid) {
    double n=0;valid=number(value,n)&&std::abs(n)<=axis*8;
    // Fractional coordinates use the historical 672 x 438 stage.
    return n>0&&n<1?n*axis:n;
}
}

@interface IFDAdvancedText : NSObject {
@public ifd::AdvancedSpec spec;
}
@property(nonatomic,copy) NSString *text;
@property double fontSize;
@property BOOL outline;
+ (instancetype)parse:(NSString *)json fontSize:(double)fontSize;
@end
@implementation IFDAdvancedText
+ (instancetype)parse:(NSString *)json fontSize:(double)fontSize {
    if(![json isKindOfClass:NSString.class]||json.length>16384)return nil;
    NSData *bytes=[json dataUsingEncoding:NSUTF8StringEncoding];
    id root=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if(![root isKindOfClass:NSArray.class]||[root count]<5||[root count]>15)return nil;
    NSArray *a=root;
    if(![a[4] isKindOfClass:NSString.class]||![a[4] length]||[a[4] length]>300)return nil;
    IFDAdvancedText *r=[IFDAdvancedText new];
    r.text=[a[4] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    r.fontSize=std::isfinite(fontSize)?std::clamp(fontSize,8.0,96.0):25;r.outline=YES;
    auto &s=r->spec;bool ok=false;
    double x=ifd::coordinate(a[0],672,ok);if(!ok)return nil;
    double y=ifd::coordinate(a[1],438,ok);if(!ok)return nil;
    s.points={{x,y},{x,y}};
    if(!ifd::number(a[3],s.duration)||s.duration<.1||s.duration>30)return nil;
    s.moveDuration=s.duration;
    if(![a[2] isKindOfClass:NSString.class]&&![a[2] isKindOfClass:NSNumber.class])return nil;
    NSArray *alpha=[[a[2] description] componentsSeparatedByString:@"-"];
    if(alpha.count<1||alpha.count>2||!ifd::number(alpha[0],s.alphaFrom)||s.alphaFrom<0||s.alphaFrom>1)return nil;
    s.alphaTo=s.alphaFrom;
    if(alpha.count==2&&(!ifd::number(alpha[1],s.alphaTo)||s.alphaTo<0||s.alphaTo>1))return nil;
    if(a.count>=7&&(!ifd::number(a[5],s.z)||!ifd::number(a[6],s.y)||std::abs(s.z)>3600||std::abs(s.y)>3600))return nil;
    if(a.count>=11) {
        x=ifd::coordinate(a[7],672,ok);if(!ok)return nil;
        y=ifd::coordinate(a[8],438,ok);if(!ok)return nil;s.points[1]={x,y};
        if(![a[9] isEqual:@""]) {if(!ifd::number(a[9],s.moveDuration))return nil;s.moveDuration/=1000;}
        if(![a[10] isEqual:@""]) {if(!ifd::number(a[10],s.delay))return nil;s.delay/=1000;}
        if(s.moveDuration<0||s.moveDuration>30||s.delay<0||s.delay>30)return nil;
    }
    if(a.count>=12)r.outline=![[[a[11] description] lowercaseString] isEqualToString:@"true"];
    if(a.count>=14)s.easeOut=[[a[13] description] isEqualToString:@"0"];
    if(a.count>=15&&![a[14] isEqual:@""]) {
        if(![a[14] isKindOfClass:NSString.class])return nil;
        NSScanner *p=[NSScanner scannerWithString:a[14]];if(![p scanString:@"M" intoString:nil])return nil;
        s.points.clear();
        do {
            if(s.points.size()>=64||![p scanDouble:&x]||![p scanString:@"," intoString:nil]||![p scanDouble:&y]||
               !std::isfinite(x)||!std::isfinite(y)||std::abs(x)>5376||std::abs(y)>3504)return nil;
            s.points.push_back({x,y});
        }while([p scanString:@"L" intoString:nil]);
        if(!p.isAtEnd||s.points.size()<2)return nil;
    }
    return r;
}
@end

@interface IFDTextStyle : NSObject
@property NSInteger animation;
@property(nonatomic,copy) NSArray<NSNumber *> *colors;
@property(nonatomic,strong) NSNumber *stroke;
@property double angle;
+ (instancetype)parse:(NSDictionary *)fields;
@end
@implementation IFDTextStyle
+ (instancetype)parse:(NSDictionary *)fields {
    IFDTextStyle *s=[IFDTextStyle new];s.angle=90;s.colors=@[];
    if(![fields isKindOfClass:NSDictionary.class])return s;
    double animation=0;
    if(ifd::number(fields[@"animation"],animation)&&animation>=1&&animation<=3&&std::floor(animation)==animation)s.animation=(NSInteger)animation;
    id info=fields[@"colorInfo"];
    if([info isKindOfClass:NSString.class]&&[info length]<=4096)info=[NSJSONSerialization JSONObjectWithData:[info dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if(![info isKindOfClass:NSDictionary.class])info=fields; // Portable fixture style.
    id details=info[@"details"]?:info[@"colors"];
    if([details isKindOfClass:NSString.class]&&[details length]<=4096)details=[NSJSONSerialization JSONObjectWithData:[details dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if([details isKindOfClass:NSArray.class]&&[details count]>=1&&[details count]<=16) {
        NSMutableArray *colors=[NSMutableArray new];
        for(id value in details){NSNumber *c=ifd::hexColor(value);if(!c){[colors removeAllObjects];break;}[colors addObject:c];}
        double type=0;BOOL gradient=ifd::number(info[@"type"],type)&&type==1;
        if(gradient||info[@"colors"])s.colors=colors;
    }
    s.stroke=ifd::hexColor(info[@"stroke"]);
    id orientation=info[@"orientation"];
    if([orientation isKindOfClass:NSString.class]&&[orientation hasSuffix:@"deg"]) {
        double angle=0;if(ifd::number([orientation substringToIndex:[orientation length]-3],angle)&&std::abs(angle)<=36000)s.angle=angle;
    }
    return s;
}
@end
