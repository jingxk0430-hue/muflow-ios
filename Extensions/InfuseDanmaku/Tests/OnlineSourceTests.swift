import Foundation
import DanmakuCore

private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try value() else { throw NSError(domain: "OnlineSourceTests", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main struct OnlineSourceTests {
    static func main() async throws {
        let sources = [
            "https://v.qq.com/x/cover/series/j4101ouc4ve.html",
            "https://m.v.qq.com/play/play.html?vid=j4101ouc4ve&tracking=1",
            "https://www.iqiyi.com/v_19rrfixture.html",
            "https://v.youku.com/v_show/id_XFixtureVideo==.html?s=tracking",
            "https://www.bilibili.com/video/BV1Fixture?p=2",
            "https://b23.tv/fixture"
        ]
        for source in sources { _ = try IFDSourcePolicy.normalize(source) }
        for invalid in ["https://v.qq.com.unrelated.test/video", "https://user:pass@v.qq.com/x/page",
                        "file:///private/file.xml", "https://unrelated.test/video", "not a URL"] {
            do { _ = try IFDSourcePolicy.normalize(invalid); fatalError("Unexpected accepted source") }
            catch is ServiceError { }
        }
        let mobile = try IFDSourcePolicy.normalize(sources[1])
        try expect(mobile.absoluteString == "https://m.v.qq.com/play/play.html?vid=j4101ouc4ve", "mobile Tencent episode was lost")
        try expect(NativeDanmakuService.tencentVideoID(mobile) == "j4101ouc4ve", "Tencent ID")
        try expect(YoukuDanmakuService.videoID(try IFDSourcePolicy.normalize(sources[3])) == "XFixtureVideo==", "Youku padding")
        try expect(try IFDSourcePolicy.normalize(sources[4]).query == "p=2", "Bilibili multi-part selection")
        try expect(DanmakuSourceLink.isBilibiliShort(try IFDSourcePolicy.normalize(sources[5])), "Bilibili short link")

        let tencent = try NativeDanmakuService.tencentSegment(Data(#"{"barrage_list":[{"content":"腾讯弹幕","time_offset":1250,"content_style":{"color":"#00ff00"}}]}"#.utf8))
        try expect(tencent.count == 1 && tencent[0].time == 1.25 && tencent[0].color == 65280, "Tencent timestamp/color")
        let iqiyi = try NativeDanmakuService.iqiyiXML(Data("<i><bulletInfo><contentId>1</contentId><showTime>1.5</showTime><content><![CDATA[爱奇艺弹幕]]></content><color>ffffff</color></bulletInfo></i>".utf8))
        try expect(iqiyi.count == 1 && iqiyi[0].text == "爱奇艺弹幕" && iqiyi[0].time == 1.5, "iQiyi CDATA/time")

        let root="http://127.0.0.1:18765/youku/"
        let youku=YoukuDanmakuService(endpoints: .init(metadata: URL(string: root+"meta")!,
            visitor: URL(string: root+"visitor")!, session: URL(string: root+"session")!, comments: URL(string: root+"comments")!))
        let loaded=try await youku.comments(URL(string:sources[3])!)
        try expect(loaded.comments.map(\.time)==[1.25,61.25] && loaded.failedSegments==0, "Youku anonymous signed request pipeline")
        let deflated=try await SiteHTTP.data(URL(string:"http://127.0.0.1:18765/bili-comments")!)
        let bili=try DanmakuParser.parse(deflated)
        try expect(bili.first?.text=="deflated fixture", "Bilibili deflate transport")
        let payload=IFDSourcePolicy.payload(.init(comments:tencent,failedSegments:2))
        let rows=payload["comments"] as? [[String:Any]]
        try expect(rows?.first?["text"] as? String == "腾讯弹幕", "Objective-C text bridge")
        try expect(payload["failedSegments"] as? Int == 2, "Partial segment status bridge")
        print("online sources: four-site URL policy, share IDs, timestamp/color, iQiyi XML, Youku signed fixtures, Bilibili deflate and bridge passed")
    }
}
