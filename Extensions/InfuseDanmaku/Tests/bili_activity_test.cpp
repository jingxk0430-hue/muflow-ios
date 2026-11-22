#include "../Core/BiliActivity.hpp"
#include <cassert>
#include <iostream>
int main(){using namespace ifd::bili;
    Activity20031 a;a.start=713;a.showTime=715;a.end=724;
    assert(parseActivityPoints("713,10,20\n717,30,40\r\n724,60,70",a.points));
    assert(!activityPosition(a,714).active);assert(!activityPosition(a,724).active);
    auto p=activityPosition(a,715,0,.1,1,.8);
    assert(p.active&&std::abs(p.x-.2)<1e-9&&std::abs(p.y-.34)<1e-9&&p.timeOffset==0&&p.duration==9);
    p=activityPosition(a,723);assert(p.active&&p.x>.55&&p.x<.6);
    std::vector<ActivityPoint> v;
    for(auto s:{"", "1,2", "1,nan,3", "1,2,3\n1,4,5", "2,1,1\n1,1,1", "1,2,3,4", "-1,2,3"})assert(!parseActivityPoints(s,v));
    assert(parseActivityPoints("715,50,25",a.points));
    p=activityPosition(a,720,.1,0,.8,1);assert(p.active&&p.x==.5&&p.y==.25);
    std::cout<<"Bilibili activity 20031 timeline and contentRect tests passed\n";
}
