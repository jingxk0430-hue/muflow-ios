import XCTest
@testable import MuFlow

@MainActor
final class YoukuDanmakuTests: XCTestCase {
    func testAnonymousSessionAndSignedFormRequestsEndToEnd() async throws {
        let root = "http://127.0.0.1:18765/youku/"
        let service = YoukuDanmakuService(endpoints: .init(metadata: URL(string: root + "meta")!,
                    visitor: URL(string: root + "visitor")!, session: URL(string: root + "session")!,
                    comments: URL(string: root + "comments")!))
        let result = try await service.comments(URL(string: "https://v.youku.com/v_show/id_XFixtureVideo==.html")!)
        XCTAssertEqual(result.failedSegments, 0)
        XCTAssertEqual(result.comments.map(\.text), ["fixture minute 0", "fixture minute 1"])
        XCTAssertEqual(result.comments.map(\.time), [1.25, 61.25])
        XCTAssertEqual(result.comments.first?.color, 65280)
    }

    func testVideoIDHandlesPaddingAndRejectsOtherSites() {
        XCTAssertEqual(YoukuDanmakuService.videoID(URL(string: "https://v.youku.com/v_show/id_XFixtureVideo==.html?s=tracking")!), "XFixtureVideo==")
        XCTAssertEqual(YoukuDanmakuService.videoID(URL(string: "https://m.youku.com/video?vid=XFixtureVideo%3D%3D")!), "XFixtureVideo==")
        XCTAssertNil(YoukuDanmakuService.videoID(URL(string: "https://unrelated.test/v_show/id_XFixtureVideo.html")!))
    }

    func testServerRejectionIsNotMistakenForEmptyComments() {
        XCTAssertThrowsError(try YoukuDanmakuService.parse(Data("{\"ret\":[\"FAIL_SYS_TOKEN_EXPIRED::expired\"],\"data\":{}}".utf8)))
    }
}
