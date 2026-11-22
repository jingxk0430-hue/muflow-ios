#pragma once
#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <string>
#include <vector>

namespace ifd { namespace svg {
struct Point { double x=0,y=0; };
enum class Kind { Move,Line,Cubic,Quad,Close };
struct Segment { Kind kind; Point p[3]{}; };
// Strict, bounded SVG path parser. Arc segments are lowered to <=90 degree
// cubic Beziers; no script, DOM, resource loading, or platform dependency.
class PathParser {
    const char *p; size_t count=0; std::vector<Segment> result;
    Point current{},origin{},control{}; char previous=0;
    void space(){while(*p&&(std::isspace(static_cast<unsigned char>(*p))||*p==',')) ++p;}
    bool number(double &v){space();const char*start=p,*end=p;
        if(*end=='+'||*end=='-')++end;
        bool digits=false;while(*end>='0'&&*end<='9'){digits=true;++end;}
        if(*end=='.'){++end;while(*end>='0'&&*end<='9'){digits=true;++end;}}
        if(!digits)return false;
        if(*end=='e'||*end=='E'){++end;if(*end=='+'||*end=='-')++end;
            const char*exponent=end;while(*end>='0'&&*end<='9')++end;if(end==exponent)return false;}
        if(end-start>64)return false;
        std::string token(start,size_t(end-start));char*parsed=nullptr;v=std::strtod(token.c_str(),&parsed);
        if(!parsed||*parsed||!std::isfinite(v)||std::abs(v)>1e7)return false;
        p=end;return true;}
    bool point(Point &v,bool relative){if(!number(v.x)||!number(v.y))return false;
        if(relative){v.x+=current.x;v.y+=current.y;}return true;}
    bool add(Kind k,Point a={},Point b={},Point c={}){
        if(++count>16384) return false;
        for(auto v:{a,b,c})if(!std::isfinite(v.x)||!std::isfinite(v.y)||std::abs(v.x)>1e8||std::abs(v.y)>1e8)return false;
        result.push_back({k,{a,b,c}});return true;
    }
    static Point reflected(Point p,Point c){return {2*p.x-c.x,2*p.y-c.y};}
    bool arc(double rx,double ry,double deg,bool large,bool sweep,Point to) {
        if(to.x==current.x&&to.y==current.y)return true;
        rx=std::abs(rx);ry=std::abs(ry);
        if(rx==0||ry==0)return add(Kind::Line,to);
        // Avoid underflow/division overflow from adversarial subnormal radii.
        // Zero radii are specified as lines; positive sub-resolution radii
        // outside this implementation budget are rejected, never cast NaN.
        if(rx<1e-8||ry<1e-8)return false;
        constexpr double pi=3.14159265358979323846;
        double phi=std::fmod(deg,360)*pi/180,cp=std::cos(phi),sp=std::sin(phi);
        double dx=(current.x-to.x)/2,dy=(current.y-to.y)/2;
        double xp=cp*dx+sp*dy,yp=-sp*dx+cp*dy;
        double lambda=xp*xp/(rx*rx)+yp*yp/(ry*ry);
        if(!std::isfinite(lambda))return false;
        if(lambda>1){double scale=std::sqrt(lambda);rx*=scale;ry*=scale;}
        double den=rx*rx*yp*yp+ry*ry*xp*xp;
        if(den<=0)return add(Kind::Line,to);
        double factor=std::sqrt(std::max(0.0,(rx*rx*ry*ry-den)/den));
        if(large==sweep)factor=-factor;
        double cxp=factor*rx*yp/ry,cyp=-factor*ry*xp/rx;
        double cx=cp*cxp-sp*cyp+(current.x+to.x)/2,cy=sp*cxp+cp*cyp+(current.y+to.y)/2;
        double ux=(xp-cxp)/rx,uy=(yp-cyp)/ry,vx=(-xp-cxp)/rx,vy=(-yp-cyp)/ry;
        double from=std::atan2(uy,ux),delta=std::atan2(ux*vy-uy*vx,ux*vx+uy*vy);
        if(!sweep&&delta>0)delta-=2*pi;
        if(sweep&&delta<0)delta+=2*pi;
        int pieces=std::max(1,int(std::ceil(std::abs(delta)/(pi/2))));
        double step=delta/pieces;
        auto map=[&](double x,double y){return Point{cx+cp*rx*x-sp*ry*y,cy+sp*rx*x+cp*ry*y};};
        for(int i=0;i<pieces;++i){double a=from+i*step,b=a+step,k=4.0/3*std::tan(step/4);
            Point c1=map(std::cos(a)-k*std::sin(a),std::sin(a)+k*std::cos(a));
            Point c2=map(std::cos(b)+k*std::sin(b),std::sin(b)-k*std::cos(b));
            if(!add(Kind::Cubic,c1,c2,i+1==pieces?to:map(std::cos(b),std::sin(b))))return false;
        }return true;
    }
public:
    explicit PathParser(const std::string &s):p(s.c_str()){}
    bool run(std::vector<Segment> &out){
        char cmd=0;bool first=true;
        while(true){space();if(!*p)break;
            if(std::isalpha(static_cast<unsigned char>(*p)))cmd=*p++;
            else if(!cmd)return false;
            bool relative=std::islower(static_cast<unsigned char>(cmd));
            char upper=char(std::toupper(static_cast<unsigned char>(cmd)));
            if(first&&upper!='M')return false;
            first=false;
            Point a,b,c;double value=0,rx=0,ry=0,angle=0,large=0,sweep=0;
            switch(upper){
            case 'M':if(!point(a,relative)||!add(Kind::Move,a))return false;
                current=origin=a;cmd=relative?'l':'L';break;
            case 'L':if(!point(a,relative)||!add(Kind::Line,a))return false;
                current=a;break;
            case 'H':if(!number(value))return false;a={relative?current.x+value:value,current.y};
                if(!add(Kind::Line,a))return false;
                current=a;break;
            case 'V':if(!number(value))return false;a={current.x,relative?current.y+value:value};
                if(!add(Kind::Line,a))return false;
                current=a;break;
            case 'C':if(!point(a,relative)||!point(b,relative)||!point(c,relative)||!add(Kind::Cubic,a,b,c))return false;
                control=b;current=c;break;
            case 'S':a=previous=='C'||previous=='S'?reflected(current,control):current;
                if(!point(b,relative)||!point(c,relative)||!add(Kind::Cubic,a,b,c))return false;
                control=b;current=c;break;
            case 'Q':if(!point(a,relative)||!point(b,relative)||!add(Kind::Quad,a,b))return false;
                control=a;current=b;break;
            case 'T':a=previous=='Q'||previous=='T'?reflected(current,control):current;
                if(!point(b,relative)||!add(Kind::Quad,a,b))return false;
                control=a;current=b;break;
            case 'A':if(!number(rx)||!number(ry)||!number(angle))return false;
                // Flags are a single digit, also valid adjacent without spaces.
                space();if(*p!='0'&&*p!='1')return false;large=*p++-'0';
                space();if(*p!='0'&&*p!='1')return false;sweep=*p++-'0';
                if(!point(a,relative)||!arc(rx,ry,angle,large,sweep,a))return false;
                current=a;break;
            case 'Z':if(!add(Kind::Close))return false;current=origin;cmd=0;break;
            default:return false;
            }
            previous=upper;
        }
        if(result.empty())return false;
        out=std::move(result);return true;
    }
};
inline bool parsePath(const std::string &d,std::vector<Segment> &out,std::string *error=nullptr){
    out.clear();bool ok=d.size()<=1024*1024&&d.find('\0')==std::string::npos&&PathParser(d).run(out);
    if(!ok&&error)*error="Unsupported, malformed, or over-budget SVG path";
    return ok;
}
}} // namespace ifd::svg
