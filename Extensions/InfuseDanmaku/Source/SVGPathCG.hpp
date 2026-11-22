#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include "../Core/SVGPath.hpp"
namespace ifd { namespace svg {
// Retained path; caller releases. All generated coordinates remain in the SVG
// source coordinate system for the caller's viewBox/contentRect transform.
inline CGPathRef createSVGPath(const std::string &d) {
    std::vector<Segment> segments;if(!parsePath(d,segments))return nullptr;
    CGMutablePathRef path=CGPathCreateMutable();if(!path)return nullptr;
    for(const auto &s:segments)switch(s.kind){
    case Kind::Move:CGPathMoveToPoint(path,nullptr,s.p[0].x,s.p[0].y);break;
    case Kind::Line:CGPathAddLineToPoint(path,nullptr,s.p[0].x,s.p[0].y);break;
    case Kind::Quad:CGPathAddQuadCurveToPoint(path,nullptr,s.p[0].x,s.p[0].y,s.p[1].x,s.p[1].y);break;
    case Kind::Cubic:CGPathAddCurveToPoint(path,nullptr,s.p[0].x,s.p[0].y,s.p[1].x,s.p[1].y,s.p[2].x,s.p[2].y);break;
    case Kind::Close:CGPathCloseSubpath(path);break;
    }
    return path;
}
}}
