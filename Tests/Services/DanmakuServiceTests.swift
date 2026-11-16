import XCTest
import DanmakuCore
import WebDAVCore
@testable import MuFlow

@MainActor
final class DanmakuServiceTests: XCTestCase {
    func testBilibiliHTTPDeflateIsDecodedBeforeXMLParsing() async throws {
        let data = try await SiteHTTP.data(URL(string: "http://127.0.0.1:18765/bili-comments")!)
        let comments = try DanmakuParser.parse(data)
        XCTAssertEqual(comments.first?.text, "deflated fixture")
        XCTAssertEqual(comments.first?.time, 1.25)
    }

    func testBilibiliShareLinksStayWithinRecognizedHosts() {
        XCTAssertTrue(DanmakuSourceLink.isBilibiliShort(URL(string: "https://b23.tv/fixture")!))
        XCTAssertFalse(DanmakuSourceLink.isBilibiliShort(URL(string: "https://b23.tv.unrelated.test/fixture")!))
        XCTAssertTrue(DanmakuSourceLink.isRecognizedBilibiliPage(URL(string: "https://m.bilibili.com/video/BV1Fixture?p=2")!))
        XCTAssertTrue(DanmakuSourceLink.isRecognizedBilibiliPage(URL(string: "https://www.bilibili.com/bangumi/play/ep123")!))
        XCTAssertFalse(DanmakuSourceLink.isRecognizedBilibiliPage(URL(string: "https://unrelated.test/video/BV1Fixture")!))
    }
    func testTencentMobileSharePagesKeepTheirEpisodeID() throws {
        let mobile = try XCTUnwrap(URL(string: "https://m.v.qq.com/play/play.html?vid=j4101ouc4ve&tracking=1"))
        XCTAssertEqual(NativeDanmakuService.tencentVideoID(mobile), "j4101ouc4ve")
        let normalized = try XCTUnwrap(SiteHTTP.mediaPage(mobile.absoluteString))
        XCTAssertEqual(normalized.absoluteString, "https://m.v.qq.com/play/play.html?vid=j4101ouc4ve")
        XCTAssertEqual(NativeDanmakuService.tencentVideoID(normalized), "j4101ouc4ve")
        XCTAssertNil(NativeDanmakuService.tencentVideoID(URL(string: "https://unrelated.test/?vid=j4101ouc4ve")!))
        XCTAssertNil(NativeDanmakuService.tencentVideoID(URL(string: "https://v.qq.com/x/cover/mzc0020072zgk61.html")!))
    }
    func testWebDAVCanReturnToRootAfterOpeningChild() async throws {
        let connection = WebDAVConnection(address: "http://127.0.0.1:18765/dav/",
                                          username: "fixture-user", password: "fixture-password")
        let root = try connection.rootURL()
        let service = WebDAVService(connection: connection)
        let initial = try await service.list(root)
        let child = try XCTUnwrap(initial.first)
        let media = try await service.list(child.url)
        XCTAssertEqual(media.first?.name, "Episode 01.mkv")
        let restored = try await service.list(root)
        XCTAssertEqual(restored.first?.name, "Series")
    }
    func testMalformedHTTP200AlsoTriesBackupForSearchEpisodesAndComments() async throws {
        let service = DanmakuService(server: "http://127.0.0.1:18765/malformed",
                                     alternateServer: "http://127.0.0.1:18765/backup", fallback: "")
        let matches = try await service.search("Synthetic series")
        let anime = try XCTUnwrap(matches.first)
        let episodes = try await service.episodes(anime)
        XCTAssertEqual(episodes.first?.episodeId, 123001)
        let comments = try await service.comments(episode: 123001)
        XCTAssertEqual(comments.first?.text, "synthetic comment")
    }

    func testEmptyPrimaryCommentsAlsoTryBackup() async throws {
        let service = DanmakuService(server: "http://127.0.0.1:18765/empty",
                                     alternateServer: "http://127.0.0.1:18765/backup", fallback: "")
        let comments = try await service.comments(episode: 123001)
        XCTAssertEqual(comments.count, 1)
    }

    func testSegmentFailurePreservesSuccessfulCommentsAndReportsMissingPart() async throws {
        let urls = ["segment-bad", "segment-good"].map { URL(string: "http://127.0.0.1:18765/" + $0)! }
        let result = try await NativeDanmakuService.segments(urls, referer: "") { try DanmakuParser.parse($0) }
        XCTAssertEqual(result.comments.first?.text, "surviving segment")
        XCTAssertEqual(result.failedSegments, 1)
        do {
            _ = try await NativeDanmakuService.segments([urls[0]], referer: "") { try DanmakuParser.parse($0) }
            XCTFail("An entirely failed download must not be reported as success")
        } catch {
            XCTAssertTrue(DanmakuFailure.message(error).contains("故障"))
        }
    }

    func testNetworkErrorsHaveActionableMessages() {
        XCTAssertTrue(DanmakuFailure.message(URLError(.notConnectedToInternet)).contains("无线数据"))
        XCTAssertTrue(DanmakuFailure.message(URLError(.cannotFindHost)).contains("DNS"))
        XCTAssertTrue(DanmakuFailure.message(URLError(.serverCertificateUntrusted)).contains("证书"))
    }

    func testSearchAndCommentsFailOverWhenPrimaryReturns503() async throws {
        let service = DanmakuService(server: "http://127.0.0.1:18765/unavailable",
                                     alternateServer: "http://127.0.0.1:18765/backup", fallback: "")
        let matches = try await service.search("Synthetic series")
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.animeId, 123)
        let comments = try await service.comments(episode: 123001)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.text, "synthetic comment")
        XCTAssertEqual(comments.first?.time, 1.5)
    }

    func testTencentSegmentUsesMillisecondsAndColors() throws {
        let data = Data("""
        {"barrage_list":[{"time_offset":"1250","content":"测试腾讯弹幕","content_style":{"color":"#00ff11"}},{"time_offset":0,"content":""}]}
        """.utf8)
        let comments = try NativeDanmakuService.tencentSegment(data)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.time, 1.25)
        XCTAssertEqual(comments.first?.color, 0x00FF11)
    }

    func testIqiyiXMLPreservesCDATAAndTiming() throws {
        let xml = Data("""
        <danmu><data><entry><list><bulletInfo><content><![CDATA[测试 <弹幕>]]></content><showTime>12.5</showTime><color>FF0000</color></bulletInfo></list></entry></data></danmu>
        """.utf8)
        let comments = try NativeDanmakuService.iqiyiXML(xml)
        XCTAssertEqual(comments.count, 1)
        XCTAssertEqual(comments.first?.text, "测试 <弹幕>")
        XCTAssertEqual(comments.first?.time, 12.5)
        XCTAssertEqual(comments.first?.color, 0xFF0000)
        XCTAssertThrowsError(try NativeDanmakuService.iqiyiXML(Data("<!DOCTYPE x><danmu/>".utf8)))
    }

    func testTVRowsUseOnlyRecognizedSourcePages() {
        let rows: [Any] = [["url": "http://www.iqiyi.com/v_example.html?tracking=1"],
                           ["url": "https://unrelated.test/video.html"],
                           ["url": "http://www.iqiyi.com/v_example.html?tracking=2"]]
        let episodes = TVSearchService.episodeRows(rows, fallback: URL(string: "https://v.qq.com/x/page/example.html")!)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.url.absoluteString, "https://www.iqiyi.com/v_example.html")
    }
    func testCompressedIqiyiSegmentsSupportZlibGzipAndZip() throws {
        let payloads = [
            "eJxNTkkKgDAQ+5GDgrcwR8G7H6g6YqEL1Cn6fJeimFtCNswm+MyYjRqGs5syxuycaB+WyJhiUAnKiz00JwG9ArY17oP1wnXVtKCPXhEXE3cPbv/NQP9SKjtURqlcOAGicTE5",
            "H4sIAAAAAAAC/01OSQqAMBD7kYOCtzBHwbsfqDpioQvUKfp8l6KYW0I2zCb4zJiNGoazmzLG7JxoH5bImGJQCcqLPTQnAb0CtjXug/XCddW0oI9eERcTdw9u/81A/1IqO1RGqVw4AQM/6JuKAAAA",
            "UEsDBBQAAAAIAGqLcF0DP+ibXQAAAIoAAAALAAAAZml4dHVyZS54bWxNTkkKgDAQ+5GDgrcwR8G7H6g6YqEL1Cn6fJeimFtCNswm+MyYjRqGs5syxuycaB+WyJhiUAnKiz00JwG9ArY17oP1wnXVtKCPXhEXE3cPbv/NQP9SKjtURqlcOAFQSwECFAMUAAAACABqi3BdAz/om10AAACKAAAACwAAAAAAAAAAAAAAgAEAAAAAZml4dHVyZS54bWxQSwUGAAAAAAEAAQA5AAAAhgAAAAAA"
        ]
        for payload in payloads {
            let data = try XCTUnwrap(Data(base64Encoded: payload))
            let xml = try NativeDanmakuService.inflate(data)
            let comments = try NativeDanmakuService.iqiyiXML(xml)
            XCTAssertEqual(comments.first?.text, "fixture")
            XCTAssertEqual(comments.first?.time, 1.25)
        }
        XCTAssertThrowsError(try NativeDanmakuService.inflate(Data([1, 2, 3, 4])))
    }

}
