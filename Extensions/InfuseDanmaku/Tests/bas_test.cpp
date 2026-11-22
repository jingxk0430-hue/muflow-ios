#include "../Core/BAS.hpp"
#include <cassert>
#include <fstream>
#include <iostream>
#include <sstream>
using namespace ifd::bas;
static void near(double a,double b) {assert(std::abs(a-b)<1e-6);}
static Scene good(const std::string& s) {auto r=parse(s);if(!r){std::cerr<<s<<"\n"<<r.error<<'\n';std::abort();}return r.scene;}
static void bad(const std::string& s) {auto r=parse(s);assert(!r);assert(r.scene.nodes.empty());assert(!r.error.empty());}
int main(int argc,char** argv) {
    auto scene=good(R"(def text t {content="bilibili" fontSize=5% x=50% y=50% duration=5s strokeWidth=1 strokeColor=0xffffff}
      def text y {content="干杯" parent="t" fontSize=2% x=100% y=100%})");
    assert(scene.nodes.size()==2);near(scene.duration,5);assert(scene.nodes[1].parent=="t");
    assert(scene.nodes[0].properties.at("x").kind==Kind::Percent);near(scene.nodes[0].properties.at("x").number,50);
    auto serial=good(R"(def text t {content="A"} set t {x=50% y=50%} 1s then set t {alpha=0} 1s)");
    near(serial.duration,2);near(sample(serial,0,.5).at("x").number,25);near(sample(serial,0,1.5).at("alpha").number,.5);
    // Sampling depends only on media age: pause, seek backwards and forward are deterministic.
    auto before=sample(serial,0,.4);sample(serial,0,1.9);auto again=sample(serial,0,.4);
    near(before.at("x").number,again.at("x").number);assert(visible(serial,0,1.99));assert(!visible(serial,0,2));
    auto grouped=good(R"(def text t {content="A"} {set t {x=100%} 1s set t {alpha=0} 2s} then set t {y=50%} 1s)");
    near(grouped.duration,3);near(sample(grouped,0,.5).at("alpha").number,.75);near(sample(grouped,0,2.5).at("y").number,25);
    auto inherited=good(R"(def text a {content="base" x=25% duration=3s} let b = a {content="child" x=75%})");
    assert(inherited.nodes[1].properties.at("content").text=="child");near(inherited.nodes[1].duration,3);near(inherited.nodes[1].properties.at("x").number,75);
    auto unicode=good(R"(def text t {content="\u5e55\u6d41 \uD83D\uDE00\n\"\\"})");
    assert(unicode.nodes[0].properties.at("content").text=="幕流 😀\n\"\\");
    auto colors=good(R"(def text t {color=0x000000} set t {color=0xffffff} 2s)");
    near(sample(colors,0,1).at("color").number,0x808080);
    auto conflict=good(R"(def text t {} set t {x=50% alpha=0} 1s set t {y=50%} 1s)");
    assert(conflict.tracks.size()==1);near(sample(conflict,0,.5).at("alpha").number,1);near(sample(conflict,0,.5).at("y").number,25);
    auto unrelated=good(R"(def text a {} def text b {} {set a {x=50%} 1s set b {alpha=0} 1s} set a {y=50%} 1s)");
    assert(unrelated.tracks.size()==2);near(sample(unrelated,1,.5).at("alpha").number,.5);
    auto dup=good(R"(def text t {x=1 x=2} set t {x=10 x=20} 1s)");near(sample(dup,0,.5).at("x").number,11);
    auto zero=good(R"(def text t {} set t {alpha=0} 0s)");near(sample(zero,0,0).at("alpha").number,0);
    auto targets=good(R"(def button b {text="Jump" target=seek {time=1m30s pause=true} duration=2s} def path p {d="M0,0 L32,0 L32,32 Z" viewBox="0 0 32 32" width=20%})");
    near(targets.nodes[0].properties.at("target").object.at("time").number,90);assert(targets.nodes[0].type=="button");assert(targets.nodes[1].type=="path");
    auto ease=good(R"(def text t {} set t {alpha=0} 1s,"ease-in")");assert(sample(ease,0,.5).at("alpha").number>.5);
    auto parent=good(R"(def text p {duration=1s} def text c {parent="p" duration=2s})");assert(!visible(parent,1,1.5));
    for(const auto& s:{"", "def text t {", "def text t {content=\"bad\\uD800\"}", "def text t {content=\"bad\\q\"}", "def text t {alpha=5}", "def text t {fontSize=-1}", "def text t {eval=1}", "def text t {x=nan}", "def text t {} set missing {} 1s", "def text t {} set t {} 121s", "def text t {} set t {} 60s then set t {} 61s", "def text a {parent=\"b\"} def text b {parent=\"a\"}", "def text a {} def text a {}", "def text a {parent=\"missing\"}", "def text a {} set a {d=\"M0 0\"} 1s", "def text a {} set a {} 1s,\"bogus\"", "def text a {x=20} set a {x=50%} 1s", "def text a {} apply(a)", "def text a {} set a {alpha=[0,\"ease\"]} 1s"})bad(s);
    bad(std::string(131073,' '));bad("def text t {content=\""+std::string(16385,'a')+"\"}");
    std::string many;for(int i=0;i<129;++i)many+="def text t"+std::to_string(i)+" {}\n";bad(many);
    many="def text t {} ";for(int i=0;i<513;++i)many+="set t {} 1s ";bad(many);
    many="def text t {} ";for(int i=0;i<18;++i)many+="{";many+="set t {} 1s";for(int i=0;i<18;++i)many+="}";bad(many);
    // Deterministic malformed-input corpus exercises bounded lexer/parser failure paths.
    unsigned state=0x91ab23u;
    const std::string alphabet="def text {}set then let=0123.%+-,;\\\"abc_/()[]\n";
    for(int caseIndex=0;caseIndex<3000;++caseIndex) {
        std::string input;state=state*1664525u+1013904223u;size_t length=state%256;
        for(size_t j=0;j<length;++j){state=state*1664525u+1013904223u;input+=alphabet[state%alphabet.size()];}
        auto result=parse(input);
        if(!result){assert(result.scene.nodes.empty());assert(result.scene.tracks.empty());}
        else {assert(std::isfinite(result.scene.duration));assert(result.scene.nodes.size()<=128);}
    }
    for(int i=1;i<argc;++i){std::ifstream file(argv[i]);assert(file);std::ostringstream ss;ss<<file.rdbuf();auto fixture=good(ss.str());assert(!fixture.nodes.empty());}
    std::cout<<"BAS parser/timeline tests passed\n";
}
