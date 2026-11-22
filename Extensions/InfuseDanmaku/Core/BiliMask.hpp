#pragma once
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <string>
#include <vector>
#include <zlib.h>

namespace ifd { namespace bili {
// Observed in npd.314.e3edce28.js getHeader/getTopList/loadMask/parse:
// big-endian MASK header; 16-byte time/offset records; independent zlib/gzip
// chunks of [payloadLength:u32, unknown:u32, timeMs:u32, SVG data URI bytes].
// This is Bilibili's SVG format, not iQiyi's bitmap RLE mask protocol.
struct MaskHeader { uint32_t version=0,entries=0; uint8_t codec=0; };
struct MaskIndexEntry { uint32_t timeMs=0,offset=0; };
struct MaskFrame { uint32_t timeMs=0; std::string svg; };
inline uint32_t maskBE32(const uint8_t *p) {
    return uint32_t(p[0])<<24|uint32_t(p[1])<<16|uint32_t(p[2])<<8|p[3];
}
inline bool parseMaskHeader(const uint8_t *p,size_t n,MaskHeader &out) {
    out={}; if(!p||n<16||std::memcmp(p,"MASK",4)||p[8]!=2) return false;
    auto count=maskBE32(p+12); if(!count||count>65536) return false;
    out={maskBE32(p+4),count,p[8]}; return true;
}
inline bool parseMaskIndex(const MaskHeader &h,const uint8_t *p,size_t n,
                           std::vector<MaskIndexEntry> &out) {
    out.clear(); if(!p||h.codec!=2||!h.entries||h.entries>65536||n<size_t(h.entries)*16) return false;
    std::vector<MaskIndexEntry> result;
    for(size_t i=0;i<h.entries;++i) {
        const auto *r=p+16*i;
        // Web player only supports zero high words, so reject rather than truncate.
        if(maskBE32(r)||maskBE32(r+8)) return false;
        MaskIndexEntry e{maskBE32(r+4),maskBE32(r+12)};
        if(e.timeMs>INT32_MAX||e.offset>INT32_MAX||e.offset<16+16*h.entries||
           (!result.empty()&&(e.timeMs<=result.back().timeMs||e.offset<=result.back().offset))) return false;
        result.push_back(e);
    }
    out=std::move(result);return true;
}
inline bool maskBase64(const std::string &s,std::string &out) {
    out.clear(); if(s.size()>4*1024*1024||s.size()%4) return false;
    unsigned acc=0;int bits=0;bool padding=false;size_t padCount=0;
    for(unsigned char c:s) {
        if(c=='=') {padding=true;if(++padCount>2) return false;continue;}
        if(padding) return false;
        int v=c>='A'&&c<='Z'?c-'A':c>='a'&&c<='z'?c-'a'+26:
            c>='0'&&c<='9'?c-'0'+52:c=='+'?62:c=='/'?63:-1;
        if(v<0) return false;
        acc=(acc<<6)|unsigned(v);bits+=6;
        if(bits>=8){bits-=8;out.push_back(char((acc>>bits)&255));}
    }
    if((padCount==1&&bits!=2)||(padCount==2&&bits!=4)||(!padCount&&bits!=0)||
       (bits&&(acc&((1u<<bits)-1)))) {out.clear();return false;}
    return true;
}
inline bool parseMaskFrames(const uint8_t *p,size_t n,std::vector<MaskFrame> &out) {
    out.clear(); if(!p||n>16*1024*1024) return false;
    std::vector<MaskFrame> result;
    constexpr const char *prefix="data:image/svg+xml;base64,";
    for(size_t i=0;i<n;) {
        if(n-i<12) return false;
        uint32_t length=maskBE32(p+i),time=maskBE32(p+i+8);i+=12;
        if(length>2*1024*1024||length>n-i||time>INT32_MAX||
           (!result.empty()&&time<result.back().timeMs)) return false;
        std::string uri(reinterpret_cast<const char*>(p+i),length),svg;i+=length;
        if(uri.compare(0,std::strlen(prefix),prefix)||!maskBase64(uri.substr(std::strlen(prefix)),svg)) return false;
        // XML parsing/rendering is a separate allowlisted native path. Never
        // hand this string to a web view or load external SVG resources.
        if(svg.empty()||svg.size()>1024*1024||svg.find('\0')!=std::string::npos) return false;
        result.push_back({time,std::move(svg)});if(result.size()>4096) return false;
    }
    if(result.empty()) return false;
    out=std::move(result);return true;
}
inline bool decodeMaskChunk(const uint8_t *p,size_t n,std::vector<MaskFrame> &out) {
    out.clear(); if(!p||!n||n>8*1024*1024) return false;
    z_stream stream{};stream.next_in=const_cast<Bytef*>(p);stream.avail_in=static_cast<uInt>(n);
    if(inflateInit2(&stream,15+32)!=Z_OK) return false;
    std::vector<uint8_t> decoded;int code=Z_OK;uint8_t buffer[16384];
    while(code==Z_OK) {
        stream.next_out=buffer;stream.avail_out=sizeof(buffer);code=inflate(&stream,Z_NO_FLUSH);
        size_t got=sizeof(buffer)-stream.avail_out;
        if(decoded.size()+got>16*1024*1024) {inflateEnd(&stream);return false;}
        decoded.insert(decoded.end(),buffer,buffer+got);
    }
    bool valid=code==Z_STREAM_END&&stream.avail_in==0;inflateEnd(&stream);
    return valid&&parseMaskFrames(decoded.data(),decoded.size(),out);
}
// Bounded full-file adapter for the first native integration. Decode only the
// selected interval, so dragging does not decompress the entire movie's masks.
// Time is absolute video seconds; a new seek calls this with the new time.
inline bool decodeMaskFile(const uint8_t *p,size_t n,double timeSeconds,
                           std::vector<MaskFrame> &out) {
    out.clear();if(!p||n>4*1024*1024||!std::isfinite(timeSeconds)||timeSeconds<0)return false;
    MaskHeader header;if(!parseMaskHeader(p,n,header))return false;
    std::vector<MaskIndexEntry> entries;
    if(n<16||!parseMaskIndex(header,p+16,n-16,entries))return false;
    for(const auto&e:entries)if(e.offset>=n)return false;
    double ms=timeSeconds*1000;
    auto it=std::upper_bound(entries.begin(),entries.end(),ms,[](double t,const MaskIndexEntry&e){return t<e.timeMs;});
    // Web player starts its first parsed interval at zero even when the index
    // timestamp begins later. Preserve that behavior for the first chunk.
    size_t index=it==entries.begin()?0:size_t(it-entries.begin()-1);
    size_t end=index+1<entries.size()?entries[index+1].offset:n;
    return decodeMaskChunk(p+entries[index].offset,end-entries[index].offset,out);
}
// Match the first-party look-ahead window exactly. Returning null clears a
// stale frame after seek or a data gap; a caller must not reuse an old video mask.
inline const MaskFrame *selectMaskFrame(const std::vector<MaskFrame> &frames,
                                       double timeMs,double fps) {
    if(!std::isfinite(timeMs)||timeMs<0||!std::isfinite(fps)||fps<1||fps>240) return nullptr;
    double step=std::floor(1000/fps),start=timeMs+step,end=timeMs+3*step;
    auto it=std::lower_bound(frames.begin(),frames.end(),start,[](const MaskFrame &f,double t){return f.timeMs<t;});
    return it!=frames.end()&&it->timeMs<end?&*it:nullptr;
}
}} // namespace ifd::bili
