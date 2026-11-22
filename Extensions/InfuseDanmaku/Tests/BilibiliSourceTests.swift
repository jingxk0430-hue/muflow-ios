import Foundation

// Standalone fixture binary compiles SiteHTTP without the application services.
enum ServiceError: Error { case invalidURL, http(Int) }
private func expect(_ value: @autoclosure () -> Bool, _ label: String) throws {
    if !value() { throw NSError(domain:"BilibiliSourceTests",code:1,userInfo:[NSLocalizedDescriptionKey:label]) }
}
private func variable(_ value: UInt64) -> Data {
    var n = value, out = Data()
    repeat { var b = UInt8(n & 127); n >>= 7; if n > 0 { b |= 128 }; out.append(b) } while n > 0
    return out
}
private func num(_ field: UInt64, _ value: UInt64) -> Data { variable(field << 3) + variable(value) }
private func blob(_ field: UInt64, _ value: Data) -> Data { variable((field << 3) | 2) + variable(UInt64(value.count)) + value }
private func string(_ field: UInt64, _ value: String) -> Data { blob(field,Data(value.utf8)) }
private func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]) }
private func elem(_ id: String, _ mode: UInt64, _ time: UInt64, _ text: String) -> Data {
    blob(1, num(2,time) + num(3,mode) + num(4,32) + num(5,0x12abef) + string(7,text) + string(12,id))
}
private final class Fixture {
    var paths: [String] = []
    var cids: [String] = []
    var blocked = false, cancelled = false, mask = true, oversizedMask = false
    func fetch(_ url: URL) async throws -> Data {
        let q = Dictionary(uniqueKeysWithValues:(URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []).map { ($0.name,$0.value ?? "") })
        paths.append(url.path)
        switch url.path {
        case "/x/web-interface/view":
            let aid = q["aid"] == "102" ? 102 : 101
            return json(["code":0,"data":["aid":aid,"title":"fixture", "pages":[
                ["cid":aid == 102 ? 303 : 201,"duration":720,"part":"first"],
                ["cid":202,"duration":800,"part":"second"]]]])
        case "/pgc/view/web/season":
            return json(["code":0,"result":["episodes":[["id":776,"aid":104,"cid":403,"duration":600000]],
                "section":[["episodes":[["id":777,"aid":105,"cid":404,"duration":800000,"long_title":"section episode"]]]]]])
        case "/x/v2/dm/web/view":
            if cancelled { throw CancellationError() }
            cids.append(q["oid"] ?? "")
            let activity = ["id":20031,"start":10,"end":20,"show_time":10,"font_color":"#97deff","resource":"i0.hdslb.com/bfs/dm/points.txt"] as [String:Any]
            let unknown = ["id":99999,"start":0,"end":10,"resource":"https://attacker.invalid/steal"] as [String:Any]
            return blob(4,num(1,360000)+num(2,3)) + string(6,"//i0.hdslb.com/bfs/dm/bas.bin") +
                blob(14,json(activity)) + blob(14,json(unknown))
        case "/x/v2/dm/web/seg.so":
            if blocked && q["segment_index"] == "2" { throw IFDBilibiliSource.Failure.api(-403) }
            let index = Int(q["segment_index"] ?? "1") ?? 1
            return elem("ordinary-\(index)",1,UInt64(index*1000),"普通弹幕") +
                elem("bas",9,1500,"def text title { content = \"BAS fixture\" }") + elem("unknown",8,0,"not executable")
        case "/bfs/dm/bas.bin": return elem("bas",9,1500,"def text title { content = \"BAS fixture\" }")
        case "/bfs/dm/points.txt": return Data("0,0.1,0.2\n1000,0.9,0.8\n".utf8)
        case "/mask.bin":
            if oversizedMask { return Data(repeating:0,count:4*1024*1024+1) }
            return Data(base64Encoded:"TUFTSwAAAAECAAAAAAAAAQAAAAAAAAAAAAAAAAAAACB4nCWO3QqCMACF9z4FSZuhRRdzZi6cSD8U3s1NZNYwsDb1kXrKLM/NB+c7FwcA8AFTpOQvvlaaV+WiNdWs049NwdtyheZZnC7zPkDFtXuLwVE8PjoibEwCJZS9C1nvGqGFYTW2jPiD1ELROH/mN0kKWPm0xhUjuGPhyDO2tEae2EcOJ8E9Ox3S0Vm6s5MnAftvwsuvmxg1KhmQl8Dxx4C2XxH3ObA=")!
        case "/x/player/wbi/v2":
            return mask ? json(["code":0,"data":["dm_mask":["mask_url":"//upos-sz-mirrorcos.bilivideo.com/mask.bin","fps":15]]]) : json(["code":0,"data":[:]])
        case "/202.xml", "/303.xml", "/404.xml":
            return Data("<i><d p=\"4,7,36,16777215,0,0,0,xml-advanced\"><![CDATA[[0,0,\"1-0\",4,\"移动文字\"]]]></d></i>".utf8)
        default: throw NSError(domain:"UnexpectedRequest",code:1,userInfo:[NSLocalizedDescriptionKey:url.absoluteString])
        }
    }
}
@main struct BilibiliSourceTests {
    static func main() async throws {
        let multipart = Fixture(); multipart.blocked = true
        let result = try await IFDBilibiliSource.load(URL(string:"https://www.bilibili.com/video/BV1Fixture?p=2")!,transport:multipart.fetch)
        let metadata = result["metadata"] as! [String:Any]
        let comments = result["comments"] as! [[String:Any]]
        try expect(metadata["cid"] as? String == "202", "BV multipart CID")
        try expect(metadata["aid"] as? String == "101", "metadata preserves aid")
        try expect(comments.filter { $0["mode"] as? Int == 9 }.count == 1,"BAS retained and deduplicated across packages")
        try expect(comments.contains { $0["mode"] as? Int == 7 },"failed segments retain XML advanced fallback")
        try expect(comments.contains { $0["text"] as? String == "普通弹幕" },"optional failure does not discard ordinary comments")
        try expect(result["failedSegments"] as? Int == 2,"blocked route counts unrequested remaining segments")
        let activity = (result["activities"] as! [[String:Any]])[0]
        try expect(activity["resourceStatus"] as? String == "ready", "scheme-less activity downloaded")
        let points = activity["pointFile"] as! [[String:Double]]
        try expect(points.count == 2 && points[1]["time"] == 1000,"trajectory units retained without guessing")
        let acquisition = result["acquisition"] as! [String:Any]
        try expect((acquisition["unknownModes"] as? [String:Int])?["8"] == 1,"unsupported mode counter")
        try expect((acquisition["unknownActivities"] as? [String:Int])?["99999"] == 1,"unsupported activity counter")
        try expect((result["mask"] as? [String:Any])?["status"] as? String == "downloaded", "actual bounded mask file acquired separately")
        let maskPayload = result["mask"] as! [String:Any]
        let maskBytes = maskPayload["fileData"] as! Data
        let maskSummary = try IFDBilibiliSource.maskFileSummary(maskBytes)
        try expect(maskSummary["entries"] as? Int == 1 && maskBytes.count > 32,"MASK header/index validated")
        try expect(maskPayload["decoded"] as? Bool == false,"download never claims native SVG decoded")
        var badMask = maskBytes; badMask[8] = 1
        do { _ = try IFDBilibiliSource.maskFileSummary(badMask); fatalError("Invalid mask codec accepted") } catch { }
        badMask = maskBytes; badMask[31] = 31
        do { _ = try IFDBilibiliSource.maskFileSummary(badMask); fatalError("Mask offset overlaps index") } catch { }
        badMask = maskBytes; badMask[16] = 1
        do { _ = try IFDBilibiliSource.maskFileSummary(badMask); fatalError("Nonzero 64-bit high word truncated") } catch { }
        try expect(!multipart.paths.contains("/steal"),"external resource rejected")
        try expect(multipart.paths.filter { $0 == "/x/v2/dm/web/seg.so" }.count == 2,"blocked channel not blindly retried")
        let av = Fixture(); av.mask = false
        let avResult = try await IFDBilibiliSource.load(URL(string:"https://www.bilibili.com/video/av102")!,transport:av.fetch)
        try expect((avResult["metadata"] as? [String:Any])?["cid"] as? String == "303","AV resolves different video")
        try expect((avResult["mask"] as? [String:Any])?["status"] as? String == "notProvided","absent mask is not server failure")
        let ep = Fixture()
        let epResult = try await IFDBilibiliSource.load(URL(string:"https://www.bilibili.com/bangumi/play/ep777")!,transport:ep.fetch)
        let epMeta = epResult["metadata"] as! [String:Any]
        try expect(epMeta["cid"] as? String == "404" && epMeta["duration"] as? Double == 800,"bangumi section and millisecond duration")
        try expect(ep.cids == ["404"] && av.cids == ["303"] && multipart.cids == ["202"],"all paths derive IDs without video-specific rules")
        let oversizedMask = Fixture(); oversizedMask.oversizedMask = true
        let limited = try await IFDBilibiliSource.load(URL(string:"https://www.bilibili.com/video/av102")!,transport:oversizedMask.fetch)
        let limitedMask = limited["mask"] as! [String:Any]
        try expect(limitedMask["status"] as? String == "available" && limitedMask["downloadStatus"] as? String == "limited", "oversized mask remains metadata only")
        try expect(limitedMask["fileData"] == nil && !(limited["comments"] as! [[String:Any]]).isEmpty,"mask limit retains ordinary comments")
        let cancellation = Fixture(); cancellation.cancelled = true
        do {
            _ = try await IFDBilibiliSource.load(URL(string:"https://www.bilibili.com/video/av102")!,transport:cancellation.fetch)
            fatalError("Cancellation lost")
        } catch is CancellationError { }
        for bad in ["https://user:secret@i0.hdslb.com/a", "http://i0.hdslb.com/a", "https://hdslb.com.attacker.invalid/a", "https://127.0.0.1/a", "file:///etc/passwd"] {
            try expect(IFDBilibiliSource.resourceURL(bad) == nil,"resource allowlist: \(bad)")
        }
        for bytes in [Data([0x80]), Data([0x0a,0xff,0xff,0xff,0xff,0x7f]), Data([0]), Data(repeating:0xff,count:11)] {
            do { _ = try IFDBilibiliSource.Proto.fields(bytes); fatalError("Malformed protobuf accepted") } catch { }
        }
        let invalidP = Fixture()
        do {
            _ = try await IFDBilibiliSource.load(URL(string:"https://www.bilibili.com/video/BV1Fixture?p=99")!,transport:invalidP.fetch)
            fatalError("Out-of-range page silently selected different video")
        } catch IFDBilibiliSource.Failure.invalidURL { }
        print("bilibili: BV/AV/EP metadata, segmented protobuf, BAS packages, activities, bounded MASK files, partial fallback, limits, cancellation and URL policy passed")
    }
}
