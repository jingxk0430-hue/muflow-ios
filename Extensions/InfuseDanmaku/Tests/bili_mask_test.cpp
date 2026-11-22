#include "../Core/BiliMask.hpp"
#include "../Core/SVGPath.hpp"
#include <cassert>
#include <iostream>
using namespace ifd::bili;
void put32(std::vector<uint8_t>&v,uint32_t x){for(int s=24;s>=0;s-=8)v.push_back(uint8_t(x>>s));}
std::string base64(std::string s){const char*d="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";std::string o;unsigned acc=0;int b=0;for(unsigned char c:s){acc=acc<<8|c;b+=8;while(b>=6){b-=6;o+=d[(acc>>b)&63];}}if(b)o+=d[(acc<<(6-b))&63];while(o.size()%4)o+='=';return o;}
int main(){
    std::vector<uint8_t> header={'M','A','S','K'};put32(header,1);put32(header,0x02000000);put32(header,2);
    MaskHeader h;assert(parseMaskHeader(header.data(),16,h)&&h.entries==2&&h.codec==2);
    assert(!parseMaskHeader(header.data(),15,h));assert(parseMaskHeader(header.data(),16,h));
    std::vector<uint8_t> index;put32(index,0);put32(index,0);put32(index,0);put32(index,48);put32(index,0);put32(index,1000);put32(index,0);put32(index,300);
    std::vector<MaskIndexEntry> entries;assert(parseMaskIndex(h,index.data(),index.size(),entries));
    index[0]=1;assert(!parseMaskIndex(h,index.data(),index.size(),entries));index[0]=0;
    index[22]=index[23]=0;assert(!parseMaskIndex(h,index.data(),index.size(),entries));
    std::string svg="<svg width=\"320\" height=\"180\"><path d=\"M0 0H320V180H0Z\"/></svg>";
    std::vector<uint8_t> frames;
    for(auto t:{40,80,120}){std::string s="data:image/svg+xml;base64,"+base64(svg);put32(frames,uint32_t(s.size()));put32(frames,0);put32(frames,t);frames.insert(frames.end(),s.begin(),s.end());}
    uLongf size=compressBound(frames.size());std::vector<uint8_t> compressed(size);
    assert(compress2(compressed.data(),&size,frames.data(),frames.size(),9)==Z_OK);compressed.resize(size);
    std::vector<MaskFrame> result;assert(decodeMaskChunk(compressed.data(),compressed.size(),result));assert(result.size()==3&&result[1].svg==svg);
    std::vector<uint8_t> file={'M','A','S','K'};put32(file,1);put32(file,0x02000000);put32(file,1);
    put32(file,0);put32(file,0);put32(file,0);put32(file,32);file.insert(file.end(),compressed.begin(),compressed.end());
    assert(decodeMaskFile(file.data(),file.size(),0,result)&&result.size()==3);
    assert(!decodeMaskFile(file.data(),file.size(),-1,result));
    file[31]=31;assert(!decodeMaskFile(file.data(),file.size(),0,result));
    assert(decodeMaskChunk(compressed.data(),compressed.size(),result));
    auto selected=selectMaskFrame(result,0,25);assert(selected&&selected->timeMs==40);
    selected=selectMaskFrame(result,40,25);assert(selected&&selected->timeMs==80);
    assert(!selectMaskFrame(result,1000,25));assert(!selectMaskFrame(result,-1,25));
    assert(!decodeMaskChunk(compressed.data(),compressed.size()-1,result));
    compressed.back()^=1;assert(!decodeMaskChunk(compressed.data(),compressed.size(),result));
    frames[0]=0xff;assert(!parseMaskFrames(frames.data(),frames.size(),result));
    std::string decoded;assert(!maskBase64("a===",decoded));assert(!maskBase64("AB==",decoded));assert(maskBase64("YQ==",decoded)&&decoded=="a");
    using namespace ifd::svg;std::vector<Segment> path;
    assert(parsePath("M10 20l10 0h5v5z",path));assert(path.size()==5&&path[1].p[0].x==20&&path[3].p[0].y==25);
    assert(parsePath("M0 0C1 2 3 4 5 6S9 10 11 12Q13 14 15 16T19 20",path));
    assert(path[2].p[0].x==7&&path[2].p[0].y==8);assert(path[4].p[0].x==17&&path[4].p[0].y==18);
    assert(parsePath("M0 0a10 20 30 01 40 50",path));assert(path.back().kind==Kind::Cubic&&path.back().p[2].x==40&&path.back().p[2].y==50);
    assert(parsePath("M0 0A0 10 0 0 1 20 30",path)&&path.back().kind==Kind::Line);
    for(auto s:{"", "L1 2", "Mnan 2", "M0x10 2", "M1e999 2", "M0 0 C1 2", "M0 0Z1 2", "M0 0R1 2", "M0 0A10 20 30 2 0 40 50", "M0 0A1e-320 1e-320 0 0 0 10 10"})assert(!parsePath(s,path));
    std::string huge="M0 0";for(int i=0;i<17000;++i)huge+="L1 2";assert(!parsePath(huge,path));
    std::cout<<"Bilibili MASK protocol, compressed frames, clock, and native SVG path tests passed\n";
}
