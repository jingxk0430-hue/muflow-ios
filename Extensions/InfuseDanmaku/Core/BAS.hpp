#pragma once
// Independent, bounded BAS format implementation. No JavaScript is executed.
// Supported language: def text/button/path; let copy-with-properties; set/then/groups.
// Templates, apply, scripts and unsupported properties fail the whole scene.
#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstdlib>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace ifd::bas {
enum class Kind { Number, Percent, String, Boolean, Object };
struct Value {
    Kind kind=Kind::Number;
    double number=0;
    std::string text;
    std::map<std::string,Value> object;
};
using Properties=std::map<std::string,Value>;
struct Node { std::string name,type,parent; Properties properties; double duration=4; };
struct Track {
    size_t node=0; double start=0,duration=0; std::string easing="linear";
    Properties from,to; size_t group=0;
};
struct Scene { std::vector<Node> nodes; std::vector<Track> tracks; double duration=0; };
struct Result {
    Scene scene; std::string error;
    explicit operator bool() const { return error.empty(); }
};
inline Value numeric(double x,Kind k=Kind::Number) {Value v;v.kind=k;v.number=x;return v;}
inline Value stringValue(std::string s) {Value v;v.kind=Kind::String;v.text=std::move(s);return v;}
inline bool colorProperty(const std::string& s) {return s=="color"||s=="strokeColor"||s=="fillColor"||s=="borderColor"||s=="textColor";}
inline double bezier(double t,double a,double b) {double q=1-t;return 3*q*q*t*a+3*q*t*t*b+t*t*t;}
inline double eased(double t,const std::string& s) {
    t=std::clamp(t,0.0,1.0);if(s=="linear")return t;
    if(s=="step-start")return 1;
    if(s=="step-end")return t<1?0:1;
    double x1=.25,y1=.1,x2=.25,y2=1;
    if(s=="ease-in") {x1=.42;y1=0;x2=1;y2=1;}
    else if(s=="ease-out") {x1=0;y1=0;x2=.58;y2=1;}
    else if(s=="ease-in-out") {x1=.42;y1=0;x2=.58;y2=1;}
    double lo=0,hi=1;for(int i=0;i<32;++i){double m=(lo+hi)/2;if(bezier(m,x1,x2)<t)lo=m;else hi=m;}
    return bezier((lo+hi)/2,y1,y2);
}
inline Value interpolate(const Value& a,const Value& b,double t,const std::string& property) {
    if((a.kind==Kind::Number||a.kind==Kind::Percent)&&(b.kind==Kind::Number||b.kind==Kind::Percent)) {
        Kind k=a.kind==Kind::Percent||b.kind==Kind::Percent?Kind::Percent:Kind::Number;
        if(colorProperty(property)) {
            unsigned aa=static_cast<unsigned>(a.number),bb=static_cast<unsigned>(b.number),c=0;
            for(unsigned shift:{0u,8u,16u}) {double x=(aa>>shift)&255,y=(bb>>shift)&255;c|=static_cast<unsigned>(std::lround(x+(y-x)*t))<<shift;}
            return numeric(c);
        }
        return numeric(a.number+(b.number-a.number)*t,k);
    }
    // BAS non-tweenable mutable values change immediately at the set's start.
    return b;
}
inline Properties sample(const Scene& scene,size_t node,double age) {
    if(node>=scene.nodes.size()||!std::isfinite(age))return {};
    Properties p=scene.nodes[node].properties;
    for(const auto& track:scene.tracks)if(track.node==node&&age>=track.start) {
        const double t=track.duration>0?eased((age-track.start)/track.duration,track.easing):1;
        for(const auto& kv:track.to) {
            auto f=track.from.find(kv.first);
            p[kv.first]=f==track.from.end()?kv.second:interpolate(f->second,kv.second,t,kv.first);
        }
    }
    return p;
}
inline bool visible(const Scene& scene,size_t node,double age) {
    if(node>=scene.nodes.size()||!std::isfinite(age)||age<0)return false;
    for(size_t depth=0;depth<=scene.nodes.size();++depth) {
        const auto& n=scene.nodes[node];if(age>=n.duration)return false;
        if(n.parent.empty())return true;
        auto p=std::find_if(scene.nodes.begin(),scene.nodes.end(),[&](const Node& x){return x.name==n.parent;});
        if(p==scene.nodes.end())return false;
        node=static_cast<size_t>(p-scene.nodes.begin());
    }
    return false;
}
namespace detail {
constexpr size_t maxBytes=131072,maxNodes=128,maxTracks=512,maxTokens=32768,maxString=16384,maxDepth=16;
constexpr double maxDuration=120;
struct Token {std::string s; bool quoted=false;size_t offset=0;};
class Parser {
    std::vector<Token> tokens_;size_t at_=0;Scene scene_;std::map<std::string,size_t> names_;
    std::vector<bool> explicitDuration_;size_t currentGroup_=0;
    [[noreturn]] void fail(const std::string& message) const {
        throw std::runtime_error(message+" at byte "+std::to_string(tokens_[std::min(at_,tokens_.size()-1)].offset));
    }
    const Token& peek() const{return tokens_[at_];}
    bool accept(const std::string& s){if(!peek().quoted&&peek().s==s){++at_;return true;}return false;}
    void expect(const std::string& s){if(!accept(s))fail("Expected "+s);}
    std::string id(){std::string s=peek().s;if(peek().quoted||s.empty()||!(std::isalpha(static_cast<unsigned char>(s[0]))||s[0]=='_'))fail("Expected identifier");++at_;return s;}
    static void utf8(std::string& s,unsigned cp) {
        if(cp<0x80)s+=static_cast<char>(cp);
        else if(cp<0x800){s+=static_cast<char>(0xc0|(cp>>6));s+=static_cast<char>(0x80|(cp&63));}
        else if(cp<0x10000){s+=static_cast<char>(0xe0|(cp>>12));s+=static_cast<char>(0x80|((cp>>6)&63));s+=static_cast<char>(0x80|(cp&63));}
        else {s+=static_cast<char>(0xf0|(cp>>18));s+=static_cast<char>(0x80|((cp>>12)&63));s+=static_cast<char>(0x80|((cp>>6)&63));s+=static_cast<char>(0x80|(cp&63));}
    }
    static unsigned hex4(const std::string& s,size_t& i,size_t count) {
        unsigned n=0;for(size_t j=0;j<count;++j){if(i>=s.size()||!std::isxdigit(static_cast<unsigned char>(s[i])))throw std::runtime_error("Invalid Unicode escape");char c=s[i++];n=n*16+static_cast<unsigned>(c<='9'?c-'0':std::tolower(static_cast<unsigned char>(c))-'a'+10);}return n;
    }
    void lex(const std::string& s) {
        if(s.size()>maxBytes)throw std::runtime_error("BAS source exceeds 128 KiB");
        for(size_t i=0;i<s.size();) {
            if(std::isspace(static_cast<unsigned char>(s[i]))){++i;continue;}
            if(s.compare(i,2,"//")==0){while(i<s.size()&&s[i]!='\n')++i;continue;}
            if(s.compare(i,2,"/*")==0){auto end=s.find("*/",i+2);if(end==std::string::npos)throw std::runtime_error("Unterminated comment");i=end+2;continue;}
            const size_t start=i;
            if(s[i]=='"') {
                ++i;std::string value;bool closed=false;
                while(i<s.size()) {
                    char c=s[i++];if(c=='"'){closed=true;break;}
                    if(static_cast<unsigned char>(c)<32)throw std::runtime_error("Control character in string");
                    if(c!='\\')value+=c;
                    else {
                        if(i==s.size())throw std::runtime_error("Unterminated escape");
                        c=s[i++];
                        if(c=='n')value+='\n';else if(c=='r')value+='\r';else if(c=='t')value+='\t';
                        else if(c=='"'||c=='\\'||c=='/')value+=c;
                        else if(c=='u'||c=='x'){
                            unsigned cp=hex4(s,i,c=='u'?4:2);
                            if(cp>=0xd800&&cp<=0xdbff){if(s.compare(i,2,"\\u")!=0)throw std::runtime_error("Unpaired surrogate");i+=2;unsigned low=hex4(s,i,4);if(low<0xdc00||low>0xdfff)throw std::runtime_error("Unpaired surrogate");cp=0x10000+((cp-0xd800)<<10)+(low-0xdc00);}
                            else if(cp>=0xdc00&&cp<=0xdfff)throw std::runtime_error("Unpaired surrogate");
                            utf8(value,cp);
                        } else throw std::runtime_error("Unsupported escape");
                    }
                    if(value.size()>maxString)throw std::runtime_error("BAS string exceeds 16 KiB");
                }
                if(!closed)throw std::runtime_error("Unterminated string");
                tokens_.push_back({value,true,start});
            } else if(std::isdigit(static_cast<unsigned char>(s[i]))||s[i]=='.') {
                if(s.compare(i,2,"0x")==0||s.compare(i,2,"0X")==0){i+=2;while(i<s.size()&&std::isxdigit(static_cast<unsigned char>(s[i])))++i;}
                else {while(i<s.size()&&(std::isdigit(static_cast<unsigned char>(s[i]))||s[i]=='.'))++i;}
                tokens_.push_back({s.substr(start,i-start),false,start});
            } else if(std::isalpha(static_cast<unsigned char>(s[i]))||s[i]=='_') {
                const bool suffix=!tokens_.empty()&&!tokens_.back().quoted&&
                    tokens_.back().offset+tokens_.back().s.size()==i&&
                    !tokens_.back().s.empty()&&(std::isdigit(static_cast<unsigned char>(tokens_.back().s[0]))||tokens_.back().s[0]=='.');
                if(suffix&&(s[i]=='m'||s[i]=='s'||s[i]=='h')) { ++i;if(s[start]=='m'&&i<s.size()&&s[i]=='s')++i; }
                else { ++i;while(i<s.size()&&(std::isalnum(static_cast<unsigned char>(s[i]))||s[i]=='_'))++i; }
                tokens_.push_back({s.substr(start,i-start),false,start});
            } else {
                if(std::string("{}[]=,;%+-()").find(s[i])==std::string::npos)throw std::runtime_error("Unsupported BAS character at byte "+std::to_string(i));
                tokens_.push_back({s.substr(i++,1),false,start});
            }
            if(tokens_.size()>maxTokens)throw std::runtime_error("BAS token ceiling exceeded");
        }
        tokens_.push_back({"",false,s.size()});
    }
    double number() {
        double sign=accept("-")?-1:1;accept("+");
        if(peek().quoted||peek().s.empty()||!(std::isdigit(static_cast<unsigned char>(peek().s[0]))||peek().s[0]=='.'))fail("Expected finite number");
        char* end=nullptr;double n=std::strtod(peek().s.c_str(),&end);if(*end||!std::isfinite(n)||std::abs(n)>16777215)fail("Numeric limit exceeded");++at_;return sign*n;
    }
    bool timeUnit() const {return !peek().quoted&&(peek().s=="ms"||peek().s=="s"||peek().s=="m"||peek().s=="h");}
    Value value(size_t depth=0) {
        if(depth>4)fail("Object depth exceeded");
        if(peek().quoted){auto s=peek().s;++at_;return stringValue(s);}
        if(peek().s=="true"||peek().s=="false"){Value v=numeric(peek().s=="true"?1:0,Kind::Boolean);++at_;return v;}
        if(!peek().s.empty()&&std::isalpha(static_cast<unsigned char>(peek().s[0]))) {
            std::string type=id();if(type!="av"&&type!="bangumi"&&type!="seek")fail("Unsupported object value");
            Value v;v.kind=Kind::Object;v.text=type;v.object=properties(depth+1);return v;
        }
        double n=number();if(accept("%"))return numeric(n,Kind::Percent);
        if(timeUnit()) {
            double total=0;
            for(;;){auto u=peek().s;++at_;total+=n*(u=="ms"?.001:u=="s"?1:u=="m"?60:3600);
                if(peek().s.empty()||(!std::isdigit(static_cast<unsigned char>(peek().s[0]))&&peek().s[0]!='.'))break;
                // Composite durations must be contiguous (1m30s), not the next property.
                n=number();if(!timeUnit())fail("Expected composite time unit");}
            if(total<0||total>maxDuration)fail("Duration exceeds 120 seconds");
            return numeric(total);
        }
        return numeric(n);
    }
    Properties properties(size_t depth=0) {
        expect("{");Properties p;
        while(!accept("}")){if(peek().s.empty())fail("Unterminated property block");std::string k=id();expect("=");p[k]=value(depth);if(p.size()>48)fail("Property ceiling exceeded");accept(";");accept(",");}
        return p;
    }
    static bool numericValue(const Value& v){return v.kind==Kind::Number||v.kind==Kind::Percent||v.kind==Kind::Boolean;}
    void validate(const Properties& p,const std::string& type,bool animated) {
        const std::set<std::string> common={"x","y","zIndex","scale","duration"};
        const std::set<std::string> text={"content","alpha","color","anchorX","anchorY","fontSize","fontFamily","bold","textShadow","strokeWidth","strokeColor","rotateX","rotateY","rotateZ","parent"};
        const std::set<std::string> button={"text","fontSize","textColor","textAlpha","fillColor","fillAlpha","target"};
        const std::set<std::string> path={"d","viewBox","width","height","borderColor","borderAlpha","borderWidth","fillColor","fillAlpha"};
        const std::set<std::string> strings={"content","fontFamily","parent","text","d","viewBox"};
        const auto& specific=type=="text"?text:type=="button"?button:path;
        for(const auto& kv:p) {
            const auto& k=kv.first;const auto& v=kv.second;
            if(!common.count(k)&&!specific.count(k))fail("Unsupported "+type+" property: "+k);
            if(animated&&(k=="duration"||k=="parent"||k=="target"||k=="d"||k=="viewBox"))fail("Unsupported animated property: "+k);
            if(strings.count(k)){if(v.kind!=Kind::String)fail("Expected string property: "+k);}
            else if(k=="target"){
                if(v.kind!=Kind::Object)fail("Expected target object");
                const std::set<std::string> keys=v.text=="av"?std::set<std::string>{"av","page","time"}:v.text=="bangumi"?std::set<std::string>{"seasonId","episodeId","time"}:std::set<std::string>{"time","pause"};
                for(auto& f:v.object)if(!keys.count(f.first)||!numericValue(f.second)||f.second.kind==Kind::Percent)fail("Invalid button target");
            } else {
                if(!numericValue(v))fail("Expected numeric property: "+k);
                if(!colorProperty(k)&&std::abs(v.number)>1000000)fail("Numeric property limit exceeded");
                if(colorProperty(k)&&(v.kind!=Kind::Number||v.number<0||v.number>16777215||std::floor(v.number)!=v.number))fail("Invalid RGB color");
                if(k=="duration"&&(v.kind!=Kind::Number||v.number<=0||v.number>maxDuration))fail("Invalid node duration");
                if((k=="alpha"||k=="fillAlpha"||k=="textAlpha"||k=="borderAlpha")&&(v.kind!=Kind::Number||v.number<0||v.number>1))fail("Invalid opacity");
                if((k=="width"||k=="height"||k=="fontSize"||k=="strokeWidth"||k=="borderWidth"||k=="scale")&&v.number<0)fail("Negative size");
            }
        }
    }
    static Properties defaults(const std::string& type) {
        Properties p;for(auto k:{"x","y","zIndex"})p[k]=numeric(0);p["scale"]=numeric(1);
        if(type=="text") {
            p["content"]=stringValue("请输入内容");p["fontFamily"]=stringValue("SimHei");
            for(auto k:{"alpha","bold","textShadow"})p[k]=numeric(1);
            for(auto k:{"anchorX","anchorY","strokeWidth","rotateX","rotateY","rotateZ"})p[k]=numeric(0);
            p["fontSize"]=numeric(25);p["color"]=p["strokeColor"]=numeric(16777215);
        } else if(type=="button") {
            p["text"]=stringValue("请输入内容");p["fontSize"]=numeric(25);p["textColor"]=numeric(0);
            p["textAlpha"]=p["fillAlpha"]=numeric(1);p["fillColor"]=numeric(16777215);
        } else {
            p["borderColor"]=p["borderWidth"]=numeric(0);p["borderAlpha"]=p["fillAlpha"]=numeric(1);p["fillColor"]=numeric(16777215);
        }
        return p;
    }
    void definition(bool copy) {
        std::string type,name;Properties p;
        if(copy) {
            name=id();expect("=");std::string base=id();auto found=names_.find(base);
            if(found!=names_.end()){const auto& n=scene_.nodes[found->second];type=n.type;p=n.properties;}
            else if(base=="text"||base=="button"||base=="path"){type=base;p=defaults(type);}
            else fail("Unknown base definition");
        } else {type=id();name=id();if(type!="text"&&type!="button"&&type!="path")fail("Unsupported definition type");p=defaults(type);}
        if(names_.count(name))fail("Duplicate node name");
        auto attrs=properties();validate(attrs,type,false);for(auto& kv:attrs)p[kv.first]=kv.second;
        if(scene_.nodes.size()>=maxNodes)fail("BAS node ceiling exceeded");
        Node n;n.name=name;n.type=type;n.properties=std::move(p);
        auto parent=n.properties.find("parent");if(parent!=n.properties.end())n.parent=parent->second.text;
        auto d=n.properties.find("duration");bool hasDuration=d!=n.properties.end();if(hasDuration)n.duration=d->second.number;
        names_[name]=scene_.nodes.size();scene_.nodes.push_back(std::move(n));explicitDuration_.push_back(hasDuration);
        accept(";");
    }
    struct Expression {std::vector<Track> tracks;double duration=0;};
    Expression unit(size_t depth) {
        if(depth>maxDepth)fail("Animation group depth exceeded");
        Expression e;
        if(accept("{")) {
            while(!accept("}")){if(peek().s.empty())fail("Unterminated animation group");auto child=expression(depth+1);e.duration=std::max(e.duration,child.duration);e.tracks.insert(e.tracks.end(),child.tracks.begin(),child.tracks.end());if(e.tracks.size()>maxTracks)fail("BAS track ceiling exceeded");}
        } else {
            expect("set");std::string name=id();auto found=names_.find(name);if(found==names_.end())fail("Set refers to unknown node");
            Track t;t.node=found->second;t.group=currentGroup_;t.to=properties();validate(t.to,scene_.nodes[t.node].type,true);
            Value duration=value();if(duration.kind!=Kind::Number||duration.number<0||duration.number>maxDuration)fail("Invalid set duration");t.duration=duration.number;e.duration=t.duration;
            if(accept(",")){if(!peek().quoted)fail("Expected easing string");t.easing=peek().s;++at_;const std::set<std::string> allowed={"linear","ease","ease-in","ease-out","ease-in-out","step-start","step-end"};if(!allowed.count(t.easing))fail("Unsupported easing");}
            e.tracks.push_back(std::move(t));
        }
        return e;
    }
    Expression expression(size_t depth) {
        auto e=unit(depth);
        while(accept("then")) {auto next=unit(depth);for(auto& t:next.tracks)t.start+=e.duration;e.duration+=next.duration;if(e.duration>maxDuration)fail("Timeline exceeds 120 seconds");e.tracks.insert(e.tracks.end(),next.tracks.begin(),next.tracks.end());if(e.tracks.size()>maxTracks)fail("BAS track ceiling exceeded");}
        accept(";");return e;
    }
    static std::string conflictKey(const std::string& k) {return k=="x"||k=="y"||k=="rotateX"||k=="rotateY"||k=="rotateZ"||k=="scale"?"transform":k;}
    void finalize() {
        for(size_t i=0;i<scene_.nodes.size();++i) {
            const auto& n=scene_.nodes[i];size_t cursor=i;
            for(size_t d=0;d<=scene_.nodes.size();++d) {
                const auto& parent=scene_.nodes[cursor].parent;if(parent.empty())break;
                auto f=names_.find(parent);if(f==names_.end()||scene_.nodes[f->second].type!="text")fail("Parent must refer to text node");
                cursor=f->second;if(cursor==i||d==scene_.nodes.size())fail("Parent cycle");if(d>=maxDepth)fail("Parent depth exceeded");
            }
            (void)n;
        }
        // Published BAS resolves overlapping attributes in different top-level groups
        // by removing the prior group's animation, with transforms sharing one key.
        std::set<std::pair<size_t,size_t>> removed;
        for(size_t i=0;i<scene_.tracks.size();++i)for(size_t j=0;j<i;++j) {
            const auto& a=scene_.tracks[j];const auto& b=scene_.tracks[i];
            if(a.group==b.group||a.node!=b.node||a.duration==0||b.duration==0||removed.count({a.node,a.group})||removed.count({b.node,b.group}))continue;
            if(std::max(a.start,b.start)>=std::min(a.start+a.duration,b.start+b.duration))continue;
            bool conflict=false;for(const auto& x:a.to)for(const auto& y:b.to)if(conflictKey(x.first)==conflictKey(y.first))conflict=true;
            if(conflict)removed.insert({a.node,a.group});
        }
        scene_.tracks.erase(std::remove_if(scene_.tracks.begin(),scene_.tracks.end(),[&](const Track& t){return removed.count({t.node,t.group})>0;}),scene_.tracks.end());
        std::stable_sort(scene_.tracks.begin(),scene_.tracks.end(),[](const Track& a,const Track& b){return a.start<b.start;});
        for(size_t i=0;i<scene_.tracks.size();++i) {
            auto& t=scene_.tracks[i];Properties initial=scene_.nodes[t.node].properties;
            for(size_t j=0;j<i;++j) {
                const auto& old=scene_.tracks[j];if(old.node!=t.node||old.start>t.start)continue;
                double phase=old.duration>0?eased((t.start-old.start)/old.duration,old.easing):1;
                for(const auto& kv:old.to){auto f=old.from.find(kv.first);initial[kv.first]=f==old.from.end()?kv.second:interpolate(f->second,kv.second,phase,kv.first);}
            }
            for(const auto& kv:t.to) {
                auto f=initial.find(kv.first);if(f==initial.end())fail("Missing initial property");
                if((f->second.kind==Kind::Number&&kv.second.kind==Kind::Percent)||(f->second.kind==Kind::Percent&&kv.second.kind==Kind::Number)) {
                    if(f->second.number!=0&&kv.second.number!=0)fail("Mixed pixel/percentage interpolation unsupported");
                }
                t.from[kv.first]=f->second;
            }
        }
        for(size_t i=0;i<scene_.nodes.size();++i) {
            auto& n=scene_.nodes[i];double end=0;bool animated=false;
            for(const auto& t:scene_.tracks)if(t.node==i){end=std::max(end,t.start+t.duration);animated=true;}
            if(!explicitDuration_[i])n.duration=animated?std::max(end,.001):4;
            // Explicit lifetime does not truncate a longer animation in published BAS.
            n.duration=std::max(n.duration,end);scene_.duration=std::max(scene_.duration,n.duration);
        }
    }
public:
    Scene run(const std::string& source) {
        lex(source);
        while(!peek().s.empty()) {
            if(accept("def"))definition(false);else if(accept("let"))definition(true);
            else {auto e=expression(0);++currentGroup_;scene_.tracks.insert(scene_.tracks.end(),e.tracks.begin(),e.tracks.end());if(scene_.tracks.size()>maxTracks)fail("BAS track ceiling exceeded");}
        }
        if(scene_.nodes.empty())fail("BAS scene contains no definitions");
        finalize();return std::move(scene_);
    }
};
} // namespace detail
inline Result parse(const std::string& source) {
    Result r;try{r.scene=detail::Parser().run(source);}catch(const std::exception& e){r.error=e.what();r.scene={};}return r;
}
} // namespace ifd::bas
