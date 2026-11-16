import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum DanmakuMode: Int, Codable, Sendable {
    case scrolling = 1, bottom = 4, top = 5
}

public struct DanmakuComment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var time: Double
    public var mode: DanmakuMode
    public var color: UInt32
    public var text: String

    public init(id: String, time: Double, mode: DanmakuMode = .scrolling,
                color: UInt32 = 0xFFFFFF, text: String) {
        self.id = id; self.time = time; self.mode = mode
        self.color = color & 0xFFFFFF; self.text = text
    }
}

public enum DanmakuError: Error, LocalizedError {
    case invalidFormat, tooLarge, empty
    public var errorDescription: String? {
        switch self {
        case .invalidFormat: "弹幕格式无法识别，请选择 XML 或 JSON 弹幕文件。"
        case .tooLarge: "弹幕文件过大，请选择小于 32 MB 的文件。"
        case .empty: "没有找到可显示的滚动、顶部或底部弹幕。"
        }
    }
}

public enum DanmakuParser {
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumComments = 100_000

    public static func parse(_ data: Data) throws -> [DanmakuComment] {
        guard data.count <= maximumBytes else { throw DanmakuError.tooLarge }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let first = bytes.first { ![9, 10, 13, 32].contains($0) }
        let comments: [DanmakuComment]
        if first == 60 {
            let delegate = XMLDanmakuDelegate()
            let parser = XMLParser(data: bytes)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse() else { throw DanmakuError.invalidFormat }
            comments = delegate.comments
        } else {
            let root = try JSONSerialization.jsonObject(with: bytes)
            let entries: [[String: Any]]
            if let dict = root as? [String: Any] {
                if let xml = dict["xml"] as? String { return try parse(Data(xml.utf8)) }
                guard let list = dict["comments"] as? [[String: Any]] else {
                    throw DanmakuError.invalidFormat
                }
                entries = list
            } else if let list = root as? [[String: Any]] { entries = list }
            else { throw DanmakuError.invalidFormat }
            comments = entries.prefix(maximumComments).enumerated().compactMap { index, entry in
                guard let text = entry["m"] as? String ?? entry["text"] as? String else { return nil }
                if let p = entry["p"] as? String {
                    let fields = p.split(separator: ",", omittingEmptySubsequences: false)
                    guard fields.count >= 3 else { return nil }
                    let shift = (entry["shift"] as? NSNumber)?.doubleValue ?? 0
                    return make(id: "json-\(index)", time: (Double(fields[0]) ?? -.infinity) + shift,
                                mode: Int(fields[1]) ?? 0, color: UInt32(fields[2]) ?? 0xFFFFFF, text: text)
                }
                if let c = entry["c"] as? String {
                    let fields = c.split(separator: ",", omittingEmptySubsequences: false)
                    guard fields.count >= 3 else { return nil }
                    return make(id: "json-\(index)", time: Double(fields[0]) ?? -.infinity,
                                mode: Int(fields[2]) ?? 0, color: UInt32(fields[1]) ?? 0xFFFFFF, text: text)
                }
                guard let time = (entry["time"] as? NSNumber)?.doubleValue else { return nil }
                return make(id: "json-\(index)", time: time,
                            mode: (entry["mode"] as? NSNumber)?.intValue ?? 1,
                            color: (entry["color"] as? NSNumber)?.uint32Value ?? 0xFFFFFF, text: text)
            }
        }
        return comments.sorted { $0.time == $1.time ? $0.id < $1.id : $0.time < $1.time }
    }

    fileprivate static func make(id: String, time: Double, mode: Int, color: UInt32,
                                  text: String) -> DanmakuComment? {
        guard time.isFinite, time >= 0, let mode = DanmakuMode(rawValue: mode) else { return nil }
        let clean = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let value = String(String.UnicodeScalarView(clean)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return .init(id: id, time: time, mode: mode, color: color, text: String(value.prefix(500)))
    }

    public static func xml(_ comments: [DanmakuComment]) -> Data {
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
        }
        let lines = comments.map {
            "<d p=\"\($0.time),\($0.mode.rawValue),25,\($0.color),0,0,0,0\">\(escape($0.text))</d>"
        }
        return Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><i>\n" + lines.joined(separator: "\n") + "\n</i>").utf8)
    }
}

private final class XMLDanmakuDelegate: NSObject, XMLParserDelegate {
    var comments: [DanmakuComment] = []
    private var parameters: [Substring]?
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "d", comments.count < DanmakuParser.maximumComments,
           let p = attributes["p"] {
            parameters = p.split(separator: ",", omittingEmptySubsequences: false)
            text = ""
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if parameters != nil, text.count < 2000 { text += string }
    }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let value = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: value) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "d", let p = parameters else { return }
        defer { parameters = nil; text = "" }
        guard p.count >= 4 else { return }
        if let comment = DanmakuParser.make(id: "xml-\(comments.count)", time: Double(p[0]) ?? -.infinity,
                                           mode: Int(p[1]) ?? 0, color: UInt32(p[3]) ?? 0xFFFFFF, text: text) {
            comments.append(comment)
        }
    }
}

public struct DanmakuSettings: Codable, Equatable, Sendable {
    public var opacity = 0.84
    public var displayArea = 0.62
    public var fontSize = 24.0
    public var scrollDuration = 15.0
    public var fixedDuration = 5.0
    public var maximumOnScreen = 58
    public var mergeTolerance = 1.0
    public var simplifiedChinese = true
    public var outline = 2.0
    public var delay = 0.0
    public var enabled = true
    public init() {}
}

public enum DanmakuProcessing {
    public static func merge(_ input: [DanmakuComment], tolerance: Double) -> [DanmakuComment] {
        let sorted = input.sorted { $0.time < $1.time }
        guard tolerance > 0 else { return sorted }
        struct Key: Hashable { let text: String; let mode: Int; let color: UInt32 }
        var lastTime: [Key: Double] = [:]
        return sorted.filter { comment in
            let key = Key(text: comment.text, mode: comment.mode.rawValue, color: comment.color)
            if let last = lastTime[key], comment.time - last <= tolerance { return false }
            lastTime[key] = comment.time
            return true
        }
    }
}

public struct ScheduledDanmaku: Sendable {
    public let comment: DanmakuComment
    public let end: Double
    public let width: Double
    public let y: Double
    public let viewportWidth: Double
    public func x(at time: Double) -> Double {
        guard comment.mode == .scrolling else { return (viewportWidth - width) / 2 }
        let progress = (time - comment.time) / (end - comment.time)
        return viewportWidth - progress * (viewportWidth + width)
    }
}

public struct DanmakuTimeline: Sendable {
    public private(set) var items: [ScheduledDanmaku] = []
    private var longestDuration = 0.0

    public init(comments: [DanmakuComment], width: Double, height: Double,
                settings: DanmakuSettings, measure: (String, Double) -> Double) {
        guard width > 0, height > 0 else { return }
        let fontSize = min(60, max(12, settings.fontSize))
        let lineHeight = fontSize * 1.4
        let area = height * min(1, max(0.1, settings.displayArea))
        let laneCount = max(1, Int(area / lineHeight))
        var lanes = Array<ScheduledDanmaku?>(repeating: nil, count: laneCount)
        let scrollDuration = min(60, max(2, settings.scrollDuration))
        let fixedDuration = min(30, max(1, settings.fixedDuration))
        longestDuration = max(scrollDuration, fixedDuration)
        var activeEnds: [Double] = []
        for comment in DanmakuProcessing.merge(comments, tolerance: settings.mergeTolerance) {
            activeEnds.removeAll { $0 <= comment.time }
            guard activeEnds.count < max(1, settings.maximumOnScreen) else { continue }
            let textWidth = max(1, measure(comment.text, fontSize))
            let duration = comment.mode == .scrolling ? scrollDuration : fixedDuration
            let order = comment.mode == .bottom ? Array((0..<laneCount).reversed()) : Array(0..<laneCount)
            let lane = order.first { index in
                guard let previous = lanes[index], previous.end > comment.time else { return true }
                guard previous.comment.mode == .scrolling, comment.mode == .scrolling else { return false }
                let oldSpeed = (width + previous.width) / (previous.end - previous.comment.time)
                let newSpeed = (width + textWidth) / duration
                let previousRight = width - oldSpeed * (comment.time - previous.comment.time) + previous.width
                guard previousRight + 12 <= width else { return false }
                return newSpeed <= oldSpeed || newSpeed * (previous.end - comment.time) + 12 <= width
            }
            guard let lane else { continue }
            let item = ScheduledDanmaku(comment: comment, end: comment.time + duration, width: textWidth,
                                       y: Double(lane) * lineHeight + 8, viewportWidth: width)
            items.append(item); lanes[lane] = item; activeEnds.append(item.end)
        }
    }

    public func active(at time: Double) -> [ScheduledDanmaku] {
        guard time.isFinite else { return [] }
        var lower = 0, upper = items.count
        let start = time - longestDuration
        while lower < upper {
            let middle = (lower + upper) / 2
            if items[middle].comment.time < start { lower = middle + 1 } else { upper = middle }
        }
        var result: [ScheduledDanmaku] = []
        for item in items.dropFirst(lower) {
            if item.comment.time > time { break }
            if item.end > time { result.append(item) }
        }
        return result
    }
}
