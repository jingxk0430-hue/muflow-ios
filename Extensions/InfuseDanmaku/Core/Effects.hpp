#pragma once
#include <algorithm>
#include <cmath>
#include <queue>
#include <vector>

namespace ifd {
struct EffectPoint { double x=0,y=0; };
struct AdvancedSpec {
    double duration=4, moveDuration=4, delay=0, alphaFrom=1, alphaTo=1, z=0, y=0;
    bool easeOut=false;
    std::vector<EffectPoint> points;
    EffectPoint at(double age) const {
        if (points.empty()) return {};
        double t=moveDuration>0?std::clamp((age-delay)/moveDuration,0.0,1.0):(age<delay?0:1);
        if (easeOut && points.size()==2) t=t*(2-t);
        double total=0;
        for (size_t i=1;i<points.size();++i) total+=std::hypot(points[i].x-points[i-1].x,points[i].y-points[i-1].y);
        double remaining=t*total;
        for (size_t i=1;i<points.size();++i) {
            double length=std::hypot(points[i].x-points[i-1].x,points[i].y-points[i-1].y);
            if (length>0 && remaining<length) {
                double f=remaining/length;
                return {points[i-1].x+(points[i].x-points[i-1].x)*f,points[i-1].y+(points[i].y-points[i-1].y)*f};
            }
            remaining-=length;
        }
        return points.back();
    }
    double alpha(double age) const { return alphaFrom+(alphaTo-alphaFrom)*std::clamp(age/duration,0.0,1.0); }
};
inline double heartbeat(double seconds) { return 1+.05*std::abs(std::sin(M_PI*std::fmod(std::max(0.0,seconds),.8)/.8)); }
inline double trail(double seconds) { return std::max(0.0,std::sin(std::fmod(std::max(0.0,seconds),1.2)/1.2*M_PI/1.2)); }
inline double wiggle(double seconds) {
    double t=std::fmod(std::max(0.0,seconds),2.75),period=1,n=t;
    if (t>=2.55) return 0;
    if (t>=2.4) { period=.6;n=t-2.4+.15; }
    else if(t>=1.8) { period=.3;n=t-1.8+.075; }
    else if(t>=1.5) { period=.6;n=t-1.5+.45; }
    else if(t>=.7) { period=.2;n=t-.7+.15; }
    else if(t>=.25) { period=.3;n=t-.25+.075; }
    return 6*std::sin(2*M_PI*std::fmod(n,period)/period)*M_PI/180;
}
struct EffectEvent { double time,duration; size_t key; };
class EffectTimeline {
    std::vector<EffectEvent> entries_;
    double maxDuration_=30;
public:
    void prepare(std::vector<EffectEvent> items,double maxDuration=30,size_t capacity=8) {
        maxDuration_=std::clamp(maxDuration,.1,120.0);
        entries_.clear();
        std::stable_sort(items.begin(),items.end(),[](auto &a,auto &b){return a.time<b.time;});
        std::priority_queue<double,std::vector<double>,std::greater<double>> ends;
        for (auto &e:items) {
            if (!std::isfinite(e.time)||e.time<0||!std::isfinite(e.duration)||e.duration<.1||e.duration>maxDuration_) continue;
            while(!ends.empty()&&ends.top()<=e.time) ends.pop();
            if(ends.size()>=capacity) continue;
            entries_.push_back(e);ends.push(e.time+e.duration);
        }
    }
    const std::vector<EffectEvent>& entries() const {return entries_;}
    void at(double t,std::vector<size_t>& keys) const {
        keys.clear();if(!std::isfinite(t))return;
        auto p=std::lower_bound(entries_.begin(),entries_.end(),t-maxDuration_,[](auto &a,double b){return a.time<b;});
        for(;p!=entries_.end()&&p->time<=t;++p)if(t<p->time+p->duration)keys.push_back(p->key);
    }
};
} // namespace ifd
