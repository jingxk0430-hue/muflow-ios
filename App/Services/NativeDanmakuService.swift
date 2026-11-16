// Source-site protocol behavior adapted from Tony15246/uosc_danmaku (MIT).
import DanmakuCore
import Foundation
import zlib

struct NativeDanmakuService: Sendable {
    func comments(_ url: URL) async throws -> [DanmakuComment] {
        try await commentsWithStatus(url).comments
    }

    func commentsWithStatus(_ url: URL) async throws -> DanmakuLoadResult {
        let host = url.host?.lowercased() ?? ""
        if host == "v.qq.com" { return try await tencent(url) }
        if host == "iqiyi.com" || host.hasSuffix(".iqiyi.com") { return try await iqiyi(url) }
        if host == "bilibili.com" || host.hasSuffix(".bilibili.com") { return .init(comments: try await bilibili(url)) }
        if host == "mgtv.com" || host.hasSuffix(".mgtv.com") { return try await mgtv(url) }
        throw DanmakuError.empty
    }

    private func tencent(_ url: URL) async throws -> DanmakuLoadResult {
        let identifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "vid" }?.value
            ?? url.deletingPathExtension().lastPathComponent
        guard identifier.range(of: "^[A-Za-z0-9]{5,32}$", options: .regularExpression) != nil else { throw DanmakuError.empty }
        let base = try await SiteHTTP.json("https://dm.video.qq.com/barrage/base/" + identifier)
        let index = base["segment_index"] as? [String: Any] ?? [:]
        let names = index.compactMap { key, value in (value as? [String: Any])?["segment_name"] as? String ?? key }
        let urls = names.sorted().compactMap { name -> URL? in
            guard name.range(of: "^[A-Za-z0-9/_-]+$", options: .regularExpression) != nil else { return nil }
            return URL(string: "https://dm.video.qq.com/barrage/segment/\(identifier)/\(name)")
        }
        return try await Self.segments(urls, referer: "https://v.qq.com/", parse: Self.tencentSegment)
    }

    static func tencentSegment(_ data: Data) throws -> [DanmakuComment] {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = object?["barrage_list"] as? [[String: Any]] ?? []
        return rows.enumerated().compactMap { index, row in
            guard let text = row["content"] as? String, !text.isEmpty else { return nil }
            let style = row["content_style"] as? [String: Any]
            let color = Self.color(style?["color"])
            return .init(id: "qq:\(index):\(SiteHTTP.number(row["time_offset"]))", time: SiteHTTP.number(row["time_offset"]) / 1000,
                         color: color, text: text)
        }
    }

    private func iqiyi(_ url: URL) async throws -> DanmakuLoadResult {
        guard let identifier = Self.match("v_([A-Za-z0-9]+)", in: url.path) else { throw DanmakuError.empty }
        let decode = try await SiteHTTP.json("https://pcw-api.iq.com/api/decode/" + identifier,
                                            query: ["platformId": "3", "modeCode": "intl", "langCode": "sg"])
        let tvid = Self.scalar(decode["data"])
        guard tvid.count >= 4, tvid.allSatisfy(\.isNumber) else { throw DanmakuError.empty }
        let response = try await SiteHTTP.json("https://pcw-api.iqiyi.com/video/video/baseinfo/" + tvid)
        guard let info = response["data"] as? [String: Any] else { throw DanmakuError.empty }
        let duration = SiteHTTP.number(info["durationSec"])
        let count = min(400, max(1, Int(ceil(duration / 300))))
        let tail = String(tvid.suffix(4))
        let urls = try (1...count).map { page in
            try SiteHTTP.url("https://cmts.iqiyi.com/bullet/\(tail.prefix(2))/\(tail.suffix(2))/\(tvid)_300_\(page).z",
                             query: ["business": "danmu", "is_iqiyi": "true", "is_video_page": "true", "tvid": tvid,
                                     "albumid": Self.scalar(info["albumId"]), "categoryid": Self.scalar(info["channelId"] ?? info["categoryId"]),
                                     "qypid": "01010021010000000000"])
        }
        return try await Self.segments(urls, referer: url.absoluteString) { data in
            try Self.iqiyiXML(Self.inflate(data))
        }
    }

    static func iqiyiXML(_ data: Data) throws -> [DanmakuComment] {
        guard data.count <= DanmakuParser.maximumBytes, !data.contains(0),
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else { throw DanmakuError.invalidFormat }
        let reader = IqiyiXMLReader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse() else { throw DanmakuError.invalidFormat }
        return reader.comments
    }

    static func inflate(_ data: Data) throws -> Data {
        if data.first == 0x3C { return data }
        var input = data
        var bits: Int32 = 47 // Automatically detect zlib or gzip.
        if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            guard data.count >= 30 else { throw DanmakuError.invalidFormat }
            func short(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
            guard short(6) & 1 == 0 else { throw DanmakuError.invalidFormat }
            let start = 30 + short(26) + short(28)
            guard start < data.count else { throw DanmakuError.invalidFormat }
            if short(8) == 0 {
                let length = (0..<4).reduce(0) { $0 | Int(data[18 + $1]) << ($1 * 8) }
                guard length > 0, length <= DanmakuParser.maximumBytes, start + length <= data.count else { throw DanmakuError.tooLarge }
                return data.subdata(in: start..<(start + length))
            }
            guard short(8) == 8 else { throw DanmakuError.invalidFormat }
            input = data.subdata(in: start..<data.count); bits = -15
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, bits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw DanmakuError.invalidFormat }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(source.count)
            var output = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let status: Int32 = buffer.withUnsafeMutableBytes { bytes in
                    stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(bytes.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let written = buffer.count - Int(stream.avail_out)
                guard output.count + written <= DanmakuParser.maximumBytes else { throw DanmakuError.tooLarge }
                output.append(contentsOf: buffer.prefix(written))
                if status == Z_STREAM_END { return output }
                guard status == Z_OK, written > 0 || stream.avail_in > 0 else { throw DanmakuError.invalidFormat }
            }
        }
    }

    private func bilibili(_ url: URL) async throws -> [DanmakuComment] {
        var cid: String?
        if let bvid = Self.match("(BV[A-Za-z0-9]+)", in: url.absoluteString) {
            let response = try await SiteHTTP.json("https://api.bilibili.com/x/player/pagelist", query: ["bvid": bvid], referer: "https://www.bilibili.com/")
            let pages = response["data"] as? [[String: Any]] ?? []
            let page = max(1, Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value ?? "1") ?? 1)
            if !pages.isEmpty { cid = Self.scalar(pages[min(page - 1, pages.count - 1)]["cid"]) }
        } else if let aid = Self.match("av([0-9]+)", in: url.path) {
            let response = try await SiteHTTP.json("https://api.bilibili.com/x/player/pagelist", query: ["aid": aid], referer: "https://www.bilibili.com/")
            cid = Self.scalar((response["data"] as? [[String: Any]])?.first?["cid"])
        } else if let episode = Self.match("ep([0-9]+)", in: url.path) {
            let response = try await SiteHTTP.json("https://api.bilibili.com/pgc/view/web/season", query: ["ep_id": episode], referer: "https://www.bilibili.com/")
            let result = response["result"] as? [String: Any] ?? [:]
            var rows = result["episodes"] as? [[String: Any]] ?? []
            for section in result["section"] as? [[String: Any]] ?? [] { rows += section["episodes"] as? [[String: Any]] ?? [] }
            cid = rows.first { Self.scalar($0["id"]) == episode }.map { Self.scalar($0["cid"]) }
        }
        guard let cid, !cid.isEmpty, cid.allSatisfy(\.isNumber), let target = URL(string: "https://comment.bilibili.com/\(cid).xml") else { throw DanmakuError.empty }
        return try DanmakuParser.parse(await SiteHTTP.data(target, referer: "https://www.bilibili.com/"))
    }

    private func mgtv(_ url: URL) async throws -> DanmakuLoadResult {
        guard let cid = Self.match("/b/([0-9]+)/", in: url.path),
              let vid = Self.match("/b/[0-9]+/([A-Za-z0-9_-]+)", in: url.path) else { throw DanmakuError.empty }
        let response = try await SiteHTTP.json("https://pcweb.api.mgtv.com/video/info", query: ["cid": cid, "vid": vid])
        let info = (response["data"] as? [String: Any])?["info"] as? [String: Any] ?? [:]
        let time = Self.scalar(info["time"])
        let duration = time.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
        let count = min(400, max(1, Int(ceil(duration / 60))))
        let urls = try (0..<count).map { try SiteHTTP.url("https://galaxy.bz.mgtv.com/rdbarrage", query: ["vid": vid, "cid": cid, "time": String($0 * 60000)]) }
        return try await Self.segments(urls, referer: "https://www.mgtv.com/") { data in
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let rows = (object?["data"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            return rows.enumerated().compactMap { index, row in
                guard let text = row["content"] as? String, !text.isEmpty else { return nil }
                return .init(id: "mgtv:\(index)", time: SiteHTTP.number(row["time"]) / 1000, text: text)
            }
        }
    }

    private enum SegmentOutcome: Sendable {
        case comments([DanmakuComment]), failed(String)
    }

    static func segments(_ urls: [URL], referer: String,
                         parse: @escaping @Sendable (Data) throws -> [DanmakuComment]) async throws -> DanmakuLoadResult {
        guard !urls.isEmpty else { throw DanmakuError.empty }
        var comments: [DanmakuComment] = []
        var failures: [String] = []
        for start in stride(from: 0, to: min(urls.count, 400), by: 6) {
            try Task.checkCancellation()
            let batch = Array(urls[start..<min(start + 6, urls.count)])
            let incoming = try await withThrowingTaskGroup(of: SegmentOutcome.self) { group in
                for (index, url) in batch.enumerated() {
                    group.addTask {
                        do {
                            let data = try await SiteHTTP.data(url, referer: referer)
                            return .comments(try parse(data).map { item in
                                var item = item; item.id = "\(start + index):" + item.id; return item
                            })
                        } catch ServiceError.http(404) { return .comments([]) }
                        catch {
                            try Task.checkCancellation()
                            return .failed(DanmakuFailure.message(error))
                        }
                    }
                }
                var result: [SegmentOutcome] = []
                for try await item in group { result.append(item) }
                return result
            }
            for outcome in incoming {
                switch outcome {
                case .comments(let items): comments += items
                case .failed(let message): failures.append(message)
                }
            }
            if comments.count >= DanmakuParser.maximumComments { break }
        }
        guard !comments.isEmpty else {
            if let first = failures.first { throw ServiceError.rejected(first) }
            throw DanmakuError.empty
        }
        return .init(comments: Array(comments.sorted { $0.time < $1.time }.prefix(DanmakuParser.maximumComments)),
                     failedSegments: failures.count)
    }

    static func match(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    static func scalar(_ value: Any?) -> String {
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String ?? ""
    }

    static func color(_ value: Any?) -> UInt32 {
        if let text = value as? String { return UInt32(text.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0xFFFFFF }
        return (value as? NSNumber)?.uint32Value ?? 0xFFFFFF
    }
}

private final class IqiyiXMLReader: NSObject, XMLParserDelegate {
    var comments: [DanmakuComment] = []
    private var value = ""
    private var fields: [String: String] = [:]
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        value = ""
        if name == "bulletInfo" { fields = [:] }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { value += String(decoding: data, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if ["content", "showTime", "color"].contains(name) { fields[name] = value }
        if name == "bulletInfo", let text = fields["content"], !text.isEmpty,
           let time = Double(fields["showTime"] ?? ""), time.isFinite, time >= 0,
           comments.count < DanmakuParser.maximumComments {
            comments.append(.init(id: "iqiyi:\(comments.count)", time: time,
                                  color: NativeDanmakuService.color(fields["color"]), text: text))
        }
        value = ""
    }
}
