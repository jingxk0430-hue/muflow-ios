#pragma once
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <string>
#include <vector>

namespace ifd { namespace bili {
// Activity 20031 (SandDune): first-party core.a37280df.js parseSandDuneData
// and npd.505.84951d71.js calculateCoordination. Times are absolute seconds.
struct ActivityPoint { double timeoffset=0, x=0, y=0; };
struct Activity20031 {
    double start=0, end=0, showTime=0;
    std::vector<ActivityPoint> points;
};
struct ActivityPosition { double x=0,y=0,timeOffset=0,duration=0; bool active=false; };
inline bool parseActivityPoints(const std::string &text, std::vector<ActivityPoint> &output) {
    output.clear();
    if(text.size()>2*1024*1024) return false;
    std::vector<ActivityPoint> result;
    size_t begin=0;
    while(begin<text.size()) {
        size_t end=text.find('\n',begin); if(end==std::string::npos) end=text.size();
        std::string line=text.substr(begin,end-begin); begin=end+1;
        if(line.find_first_not_of(" \t\r")==std::string::npos) continue;
        const char *p=line.c_str(); double values[3];
        for(int i=0;i<3;++i) {
            while(*p==' '||*p=='\t'||*p=='\r') ++p;
            char *next=nullptr; values[i]=std::strtod(p,&next);
            if(next==p||!std::isfinite(values[i])) return false;
            p=next; while(*p==' '||*p=='\t'||*p=='\r') ++p;
            if(i<2) { if(*p!=',') return false; ++p; } else if(*p) return false;
        }
        if(values[0]<0||values[0]>1e7||std::abs(values[1])>10000||std::abs(values[2])>10000) return false;
        if(!result.empty()&&values[0]<=result.back().timeoffset) return false;
        result.push_back({values[0],values[1],values[2]});
        if(result.size()>20000) return false;
    }
    if(result.empty()) return false;
    output=std::move(result); return true;
}
// contentRect normalized to overlay coordinates; using its real x/y/w/h also
// handles pillarboxing, unlike the web's vertical-letterbox-only equation.
inline ActivityPosition activityPosition(const Activity20031 &a,double time,
    double rectX=0,double rectY=0,double rectW=1,double rectH=1) {
    ActivityPosition out;
    if(!std::isfinite(time)||!std::isfinite(a.start)||!std::isfinite(a.end)||
       !std::isfinite(a.showTime)||a.start>a.showTime||a.showTime>=a.end||
       time<a.showTime||time>=a.end||a.points.empty()||
       !std::isfinite(rectX)||!std::isfinite(rectY)||!std::isfinite(rectW)||
       !std::isfinite(rectH)||rectW<=0||rectH<=0) return out;
    const auto &p=a.points;
    auto it=std::upper_bound(p.begin(),p.end(),time,[](double t,const ActivityPoint &v){return t<v.timeoffset;});
    double x,y;
    if(it==p.begin()) {x=p.front().x;y=p.front().y;}
    else if(it==p.end()) {x=p.back().x;y=p.back().y;}
    else { auto &b=*it; auto &v=*(it-1); double dt=b.timeoffset-v.timeoffset;
        if(dt<=0) return out;
        double f=(time-v.timeoffset)/dt;x=v.x+(b.x-v.x)*f;y=v.y+(b.y-v.y)*f;
    }
    if(!std::isfinite(x)||!std::isfinite(y)) return out;
    return {rectX+rectW*x/100,rectY+rectH*y/100,time-a.showTime,a.end-a.showTime,true};
}
}} // namespace ifd::bili
