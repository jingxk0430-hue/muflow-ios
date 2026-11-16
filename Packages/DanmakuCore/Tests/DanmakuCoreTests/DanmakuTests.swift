import XCTest
@testable import DanmakuCore

final class DanmakuTests: XCTestCase {
    func testAppearanceUpgradePreservesCustomSettingsAndVideoSync() throws {
        var legacy = DanmakuSettings()
        legacy.opacity = 0.84
        legacy.fontSize = 24; legacy.outline = 2
        legacy.displayArea = 0.62; legacy.maximumOnScreen = 58
        legacy.delay = 3.5; legacy.enabled = false
        let saved = try JSONEncoder().encode(legacy)
        let upgraded = try JSONDecoder().decode(DanmakuSettings.self, from: saved).migratingLegacyAppearance()
        XCTAssertEqual(upgraded.fontSize, 20)
        XCTAssertEqual(upgraded.opacity, 1)
        XCTAssertEqual(upgraded.outline, 0.65)
        XCTAssertEqual(upgraded.displayArea, 0.5)
        XCTAssertEqual(upgraded.maximumOnScreen, 30)
        XCTAssertEqual(upgraded.delay, 3.5)
        XCTAssertFalse(upgraded.enabled)

        legacy.fontSize = 18; legacy.outline = 0; legacy.opacity = 0.7
        legacy.displayArea = 0.3; legacy.maximumOnScreen = 12
        XCTAssertEqual(legacy.migratingLegacyAppearance(), legacy)
        XCTAssertEqual(upgraded.migratingLegacyAppearance(), upgraded)
    }

    func testDandanAndLegacyJSONUseTheirOwnFieldOrder() throws {
        let json = Data("""
        {"comments":[{"p":"1.5,5,16711680,user","m":"顶部"},{"c":"2,65280,4,25","m":"底部"}]}
        """.utf8)
        let values = try DanmakuParser.parse(json)
        XCTAssertEqual(values.map(\.mode), [.top, .bottom])
        XCTAssertEqual(values.map(\.color), [0xFF0000, 0x00FF00])
        XCTAssertEqual(values.map(\.time), [1.5, 2])
    }

    func testXMLRoundTripAndEscaping() throws {
        let input = [DanmakuComment(id: "one", time: 1.25, mode: .top, color: 42, text: "A&B <你好> \"test\"")]
        let output = try DanmakuParser.parse(DanmakuParser.xml(input))
        XCTAssertEqual(output.first?.text, input.first?.text)
        XCTAssertEqual(output.first?.color, 42)
        XCTAssertEqual(output.first?.time, 1.25)
    }

    func testMalformedAndUnsupportedEntriesAreSkipped() throws {
        let json = Data("""
        [{"p":"-1,1,1","m":"negative"},{"p":"1,7,1","m":"advanced"},{"p":"2,1,1","m":"ok"}]
        """.utf8)
        XCTAssertEqual(try DanmakuParser.parse(json).map(\.text), ["ok"])
        XCTAssertThrowsError(try DanmakuParser.parse(Data("<i><d>".utf8)))
    }

    func testDuplicateMergeKeepsDifferentStylesAndDistantComments() {
        let values = [
            DanmakuComment(id: "1", time: 1, text: "相同"),
            DanmakuComment(id: "2", time: 1.5, text: "相同"),
            DanmakuComment(id: "3", time: 1.6, mode: .top, text: "相同"),
            DanmakuComment(id: "4", time: 3, text: "相同")
        ]
        XCTAssertEqual(DanmakuProcessing.merge(values, tolerance: 1).map(\.id), ["1", "3", "4"])
    }

    func testSeekingProducesTheSameVisiblePositions() {
        var settings = DanmakuSettings(); settings.mergeTolerance = 0
        let timeline = DanmakuTimeline(comments: [.init(id: "1", time: 5, text: "测试")],
                                       width: 400, height: 200, settings: settings) { _, _ in 80 }
        XCTAssertTrue(timeline.active(at: 4).isEmpty)
        XCTAssertEqual(timeline.active(at: 5).first?.x(at: 5), 400)
        let before = timeline.active(at: 10).first?.x(at: 10)
        XCTAssertTrue(timeline.active(at: 30).isEmpty)
        XCTAssertEqual(timeline.active(at: 10).first?.x(at: 10), before)
        XCTAssertTrue(timeline.active(at: .nan).isEmpty)
    }

    func testDensityAndLaneCollisionLimits() {
        var settings = DanmakuSettings(); settings.maximumOnScreen = 2; settings.mergeTolerance = 0
        let comments = (0..<20).map { DanmakuComment(id: String($0), time: 0, text: "弹幕\($0)") }
        let timeline = DanmakuTimeline(comments: comments, width: 400, height: 400, settings: settings) { _, _ in 80 }
        XCTAssertEqual(timeline.active(at: 1).count, 2)
        XCTAssertEqual(Set(timeline.active(at: 1).map(\.y)).count, 2)
        let oneLane = DanmakuTimeline(comments: comments, width: 400, height: 30, settings: settings) { _, _ in 80 }
        XCTAssertEqual(oneLane.active(at: 1).count, 1)
    }

    func testFasterTrailingCommentDoesNotCatchUp() {
        var settings = DanmakuSettings(); settings.mergeTolerance = 0
        let comments = [DanmakuComment(id: "1", time: 0, text: "短"), DanmakuComment(id: "2", time: 1, text: "长")]
        let timeline = DanmakuTimeline(comments: comments, width: 400, height: 30, settings: settings) { text, _ in
            text == "短" ? 10 : 1000
        }
        XCTAssertEqual(timeline.items.count, 1)
    }
}
