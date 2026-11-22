#include "../Core/Effects.hpp"
#include <cassert>
#include <limits>
int main(){
    ifd::AdvancedSpec s;s.duration=6;s.moveDuration=2;s.delay=1;s.alphaFrom=1;s.alphaTo=0;
    s.points={{0,0},{100,0},{100,300}};
    assert(s.at(0).x==0&&s.at(1).x==0);assert(s.at(1.5).x==100&&s.at(1.5).y==0);
    assert(s.at(2).x==100&&s.at(2).y==100);assert(s.at(4).y==300);assert(s.alpha(3)==.5);
    s.points={{0,0},{100,100}};s.easeOut=true;assert(s.at(2).x==75);
    s.moveDuration=0;assert(s.at(.5).x==0&&s.at(1).x==100);
    s.points={{2,3},{2,3}};assert(s.at(10).x==2);
    assert(ifd::heartbeat(0)==1&&std::abs(ifd::heartbeat(.4)-1.05)<1e-10);
    assert(ifd::wiggle(2.6)==0&&ifd::wiggle(2.74)==0);assert(ifd::trail(0)==0);
    for(int i=0;i<10000;++i){double t=i*.001;assert(ifd::heartbeat(t)>=1&&ifd::heartbeat(t)<=1.05);assert(std::abs(ifd::wiggle(t))<=M_PI/30+1e-10);}
    ifd::EffectTimeline timeline;std::vector<ifd::EffectEvent> events;
    for(size_t i=0;i<20;++i)events.push_back({1,4,i});
    events.push_back({5,2,20});
    events.push_back({0,31,100});events.push_back({std::numeric_limits<double>::infinity(),1,101});
    timeline.prepare(events);std::vector<size_t> active;timeline.at(1,active);assert(active.size()==8);
    timeline.at(5,active);assert(active.size()==1&&active[0]==20);
    timeline.at(2,active);assert(active.size()==8);timeline.at(0,active);assert(active.empty());
    timeline.at(std::numeric_limits<double>::quiet_NaN(),active);assert(active.empty());
}
