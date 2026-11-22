import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Public, anonymous Bilibili acquisition. No player JavaScript, WBI signing,
/// user credentials or anti-bot retries. A blocked optional channel is partial data.
enum IFDBilibiliSource {
    typealias Transport = (URL) async throws -> Data
    enum Failure: Error { case invalidURL, invalidData, limit, api(Int) }
    static func load(_ source: URL, transport: Transport? = nil) async throws -> [String: Any] {
        try await Loader(transport: transport).load(source)
    }

    /// Validate the complete bounded MASK container. Actual zlib/SVG decoding is
    /// native; "downloaded" is deliberately distinct from successful rendering.
    static func maskFileSummary(_ data: Data) throws -> [String: Any] {
        guard data.count <= 4*1024*1024 else { throw Failure.limit }
        guard data.count >= 32 else { throw Failure.invalidData }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset+1]) << 16 |
                UInt32(bytes[offset+2]) << 8 | UInt32(bytes[offset+3])
        }
        guard Array(bytes.prefix(4)) == Array("MASK".utf8), bytes[8] == 2 else { throw Failure.invalidData }
        let count = Int(u32(12))
        guard count > 0, count <= 65536, 16 + count*16 < bytes.count else { throw Failure.invalidData }
        var previousTime: UInt32?, previousOffset: UInt32?
        for entry in 0..<count {
            let at = 16 + entry*16, time = u32(at+4), offset = u32(at+12)
            guard u32(at) == 0, u32(at+8) == 0, time <= UInt32(Int32.max),
                  offset >= UInt32(16+count*16), Int(offset) < bytes.count,
                  previousTime == nil || time > previousTime!,
                  previousOffset == nil || offset > previousOffset! else { throw Failure.invalidData }
            previousTime = time; previousOffset = offset
        }
        return ["version":u32(4),"codec":2,"entries":count,"bytes":data.count]
    }

    /// Only CDN/API addresses, including scheme-less activity resource strings.
    static func resourceURL(_ input: String) -> URL? {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("//") { value = "https:" + value }
        else if !value.contains("://") { value = "https://" + value }
        guard let parts = URLComponents(string: value), parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443,
              let host = parts.host?.lowercased(),
              ["bilibili.com", "hdslb.com", "bilivideo.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return parts.url
    }

    private final class SafeRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(request.url.flatMap { resourceURL($0.absoluteString) } == nil ? nil : request)
        }
    }
    private static func network(_ url: URL) async throws -> Data {
        guard resourceURL(url.absoluteString) != nil else { throw Failure.invalidURL }
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: SafeRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(SiteHTTP.agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Failure.api((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard response.expectedContentLength <= 4 * 1024 * 1024 else { throw Failure.limit }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw Failure.limit }
            data.append(byte)
        }
        return data
    }

    private final class Loader {
        let transport: Transport
        var requests = 0, bytes = 0, failedSegments = 0
        var truncated = false
        var issues: [[String: Any]] = []
        var unknownModes: [String: Int] = [:]
        var unknownActivities: [String: Int] = [:]
        var rows: [[String: Any]] = []
        var seen = Set<String>()
        init(transport: Transport?) { self.transport = transport ?? IFDBilibiliSource.network }
        func fetch(_ url: URL) async throws -> Data {
            try Task.checkCancellation()
            guard requests < 64, bytes < 48 * 1024 * 1024 else { truncated = true; throw Failure.limit }
            requests += 1
            let result = try await transport(url)
            try Task.checkCancellation()
            guard result.count <= 4 * 1024 * 1024, bytes + result.count <= 48 * 1024 * 1024 else {
                truncated = true; throw Failure.limit
            }
            bytes += result.count
            // API error envelopes must never be interpreted as protobuf.
            return result
        }
        func api(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
            let data = try await fetch(SiteHTTP.url("https://api.bilibili.com" + path, query: query))
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.invalidData }
            let rawCode = SiteHTTP.number(value["code"])
            guard rawCode.isFinite, abs(rawCode) <= Double(Int32.max) else { throw Failure.invalidData }
            let code = Int(rawCode)
            guard code == 0 else { throw Failure.api(code) }
            return value
        }
        func note(_ stage: String, _ error: Error) throws {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            var issue: [String: Any] = ["stage": stage, "status": "unavailable"]
            if case Failure.api(let code) = error { issue["code"] = code }
            if case Failure.limit = error { issue["status"] = "limited"; truncated = true }
            issues.append(issue)
        }
        func load(_ source: URL) async throws -> [String: Any] {
            guard let host = source.host?.lowercased(), source.scheme == "https",
                  host == "bilibili.com" || host.hasSuffix(".bilibili.com"),
                  source.user == nil, source.password == nil else { throw Failure.invalidURL }
            let meta = try await metadata(source)
            let aid = Self.scalar(meta["aid"]), cid = Self.scalar(meta["cid"])
            let duration = SiteHTTP.number(meta["duration"])
            var activities: [[String: Any]] = []
            var specials: [String] = []
            var total = max(1, Int(min(1_000_000, ceil(duration / 360))))
            var viewReady = false
            do {
                let data = try await fetch(SiteHTTP.url("https://api.bilibili.com/x/v2/dm/web/view",
                    query: ["type": "1", "oid": cid, "pid": aid, "duration": String(Int(duration))]))
                let fields = try Proto.fields(data)
                guard fields.contains(where: { [1,4,6,8,14].contains($0.id) }) else { throw Failure.invalidData }
                viewReady = true
                if let config = fields.first(where: { $0.id == 4 })?.data {
                    let n = try Proto.fields(config).first(where: { $0.id == 2 })?.number ?? 0
                    if n > 0 { total = Int(min(n, 1_000_000)) }
                }
                specials = fields.filter { $0.id == 6 }.compactMap { $0.string }
                for field in fields.filter({ $0.id == 14 }).prefix(24) {
                    guard let value = field.data,
                          let object = try? JSONSerialization.jsonObject(with: value) as? [String: Any] else {
                        issues.append(["stage": "activity", "status": "invalid"]); continue
                    }
                    activities.append(try await activity(object))
                }
                if fields.filter({ $0.id == 14 }).count > 24 { truncated = true }
            } catch { try note("view", error) }
            // The anonymous legacy segment route is attempted once per segment.
            // If the site demands WBI/login, retain XML rather than manufacture signatures.
            let segmentLimit = min(total, 32)
            truncated = truncated || total > segmentLimit
            var segmentChannelFailed = false
            for index in 1...segmentLimit {
                if segmentChannelFailed { failedSegments += 1; continue }
                do {
                    let data = try await fetch(SiteHTTP.url("https://api.bilibili.com/x/v2/dm/web/seg.so",
                        query: ["type":"1", "oid":cid, "pid":aid, "segment_index":String(index)]))
                    try appendSegment(data)
                } catch {
                    failedSegments += 1
                    try note("segment", error)
                    // Stop a blocked/malformed channel; do not repeat 32 equivalent failures.
                    segmentChannelFailed = true
                }
            }
            var usedSpecials = Set<String>()
            for raw in specials.prefix(12) where usedSpecials.insert(raw).inserted {
                guard let url = resourceURL(raw) else {
                    issues.append(["stage":"special", "status":"rejectedURL"]); continue
                }
                do { try appendSegment(await fetch(url)) } catch { try note("special", error) }
            }
            if specials.count > 12 { truncated = true }
            if !viewReady || failedSegments > 0 || rows.isEmpty {
                do {
                    let data = try await fetch(URL(string: "https://comment.bilibili.com/\(cid).xml")!)
                    for row in try XMLComments.read(data) { append(row) }
                } catch { try note("xmlFallback", error) }
            }
            var mask: [String: Any] = ["status":"notProvided"]
            do {
                var query = ["aid":aid,"cid":cid]
                if let ep = meta["episodeID"] as? String { query["ep_id"] = ep }
                let result = try await api("/x/player/wbi/v2", query)
                let body = result["data"] as? [String: Any] ?? [:]
                if let value = body["dm_mask"] as? [String: Any] {
                    if let raw = value["mask_url"] as? String, let url = resourceURL(raw) {
                        let fps = SiteHTTP.number(value["fps"])
                        guard fps.isFinite, fps >= 1, fps <= 240 else { throw Failure.invalidData }
                        mask = ["status":"available", "url":url.absoluteString, "fps":fps,
                                "kind":"svgMask", "decoded":false]
                        do {
                            // One bounded full-file request avoids repeated range requests
                            // during playback. Native code selects/decompresses the needed
                            // indexed chunk and applies the SVG mask at video time.
                            let file = try await fetch(url)
                            mask["container"] = try IFDBilibiliSource.maskFileSummary(file)
                            mask["fileData"] = file
                            mask["status"] = "downloaded"
                            mask["downloadStatus"] = "complete"
                        } catch {
                            try note("maskFile", error)
                            mask["downloadStatus"] = "unavailable"
                            if case Failure.limit = error { mask["downloadStatus"] = "limited" }
                        }
                    } else { mask = ["status":"unavailable", "reason":"invalidMaskURL"] }
                }
            } catch { try note("maskMetadata", error); mask = ["status":"unavailable"] }
            rows.sort { SiteHTTP.number($0["time"]) < SiteHTTP.number($1["time"]) }
            return ["metadata":meta, "comments":rows, "activities":activities, "mask":mask,
                    "failedSegments":failedSegments, "truncated":truncated,
                    "acquisition":["status":issues.isEmpty ? (rows.isEmpty && activities.isEmpty ? "empty" : "ready") : "partial",
                                   "issues":issues, "unknownModes":unknownModes, "unknownActivities":unknownActivities,
                                   "requests":requests, "bytes":bytes, "viewReady":viewReady]]
        }
        func metadata(_ source: URL) async throws -> [String: Any] {
            if let ep = Self.match("(?:^|/)ep([0-9]+)(?:/|$)", source.path) {
                let reply = try await api("/pgc/view/web/season", ["ep_id":ep])
                let result = reply["result"] as? [String: Any] ?? [:]
                var episodes = result["episodes"] as? [[String: Any]] ?? []
                for section in result["section"] as? [[String: Any]] ?? [] { episodes += section["episodes"] as? [[String: Any]] ?? [] }
                guard let row = episodes.first(where: { Self.scalar($0["id"]) == ep || Self.scalar($0["ep_id"]) == ep }),
                      let aid = Self.positiveID(row["aid"]), let cid = Self.positiveID(row["cid"]) else { throw Failure.invalidData }
                // PGC duration is milliseconds, unlike UGC pages.duration (seconds).
                return ["aid":aid,"cid":cid,"duration":Self.duration(row["duration"], divisor:1000),
                        "title":row["long_title"] as? String ?? row["title"] as? String ?? "", "episodeID":ep]
            }
            var query: [String: String] = [:]
            if let bv = Self.match("(?:^|/)(BV[A-Za-z0-9]+)(?:/|$)", source.path) { query["bvid"] = bv }
            else if let av = Self.match("(?:^|/)av([0-9]+)(?:/|$)", source.path) { query["aid"] = av }
            else { throw Failure.invalidURL }
            let reply = try await api("/x/web-interface/view", query)
            guard let body = reply["data"] as? [String: Any], let aid = Self.positiveID(body["aid"]) else { throw Failure.invalidData }
            let parts = URLComponents(url: source, resolvingAgainstBaseURL:false)?.queryItems ?? []
            let selected = Int(parts.first(where: { $0.name == "p" })?.value ?? "1") ?? 1
            guard selected >= 1 else { throw Failure.invalidURL }
            let pages = body["pages"] as? [[String: Any]] ?? []
            let page: [String: Any]
            if !pages.isEmpty {
                guard selected <= pages.count else { throw Failure.invalidURL }
                page = pages[selected - 1]
            } else {
                guard selected == 1 else { throw Failure.invalidURL }
                page = body
            }
            guard let cid = Self.positiveID(page["cid"]) else { throw Failure.invalidData }
            return ["aid":aid,"cid":cid,"duration":Self.duration(page["duration"],divisor:1),
                    "title":page["part"] as? String ?? body["title"] as? String ?? "", "page":selected]
        }
        func appendSegment(_ data: Data) throws {
            let fields = try Proto.fields(data)
            // An actually empty protobuf is a valid empty segment; JSON/XML error envelopes are not.
            var parsed: [[String: Any]] = []
            for item in fields where item.id == 1 {
                guard let bytes = item.data else { throw Failure.invalidData }
                let f = try Proto.fields(bytes)
                func n(_ id: Int, _ fallback: UInt64 = 0) -> UInt64 { f.first(where: { $0.id == id })?.number ?? fallback }
                func s(_ id: Int) -> String { f.first(where: { $0.id == id })?.string ?? "" }
                let mode = Int(min(n(3,1),1_000_000)), text = s(7)
                guard !text.isEmpty else { continue }
                var row: [String: Any] = ["id":s(12),"time":Double(n(2))/1000,"mode":mode,
                    "fontSize":min(200, max(1, n(4,25))),"color":n(5,0xffffff)&0xffffff,"text":text]
                if let id = f.first(where: { $0.id == 1 })?.number, s(12).isEmpty { row["id"] = String(id) }
                if n(24) != 0 { row["colorful"] = n(24) }
                if !s(22).isEmpty { row["animation"] = String(s(22).prefix(16384)) }
                parsed.append(row)
            }
            var colorfulSources: [UInt64: String] = [:]
            for item in fields where item.id == 5 {
                guard let bytes = item.data else { continue }
                let values = try Proto.fields(bytes)
                if let kind = values.first(where: { $0.id == 1 })?.number,
                   let raw = values.first(where: { $0.id == 2 })?.string, let url = resourceURL(raw) {
                    colorfulSources[kind] = url.absoluteString
                }
            }
            for var row in parsed {
                if let kind = row["colorful"] as? UInt64, let url = colorfulSources[kind] { row["colorfulResourceURL"] = url }
                append(row)
            }
        }
        func append(_ row: [String: Any]) {
            let mode = Int(SiteHTTP.number(row["mode"]))
            guard [1,2,3,4,5,6,7,9].contains(mode) else {
                unknownModes[String(mode),default:0] += 1; return
            }
            let text = row["text"] as? String ?? "", time = SiteHTTP.number(row["time"])
            guard time.isFinite, time >= 0, !text.isEmpty else { return }
            guard text.utf8.count <= (mode == 9 ? 256*1024 : mode == 7 ? 64*1024 : 4096) else { truncated = true; return }
            let id = row["id"] as? String ?? ""
            let key = id.isEmpty ? "\(mode)|\(time)|\(SiteHTTP.number(row["color"]))|\(text)" : "id:" + id
            guard seen.insert(key).inserted else { return }
            guard rows.count < 30_000 else { truncated = true; return }
            rows.append(row)
        }
        func activity(_ object: [String: Any]) async throws -> [String: Any] {
            let rawID = SiteHTTP.number(object["id"])
            guard rawID.isFinite, rawID > 0, rawID <= Double(Int32.max) else { return ["id":0,"resourceStatus":"invalid"] }
            let id = Int(rawID)
            let start = SiteHTTP.number(object["start"]), end = SiteHTTP.number(object["end"])
            guard id > 0, start.isFinite, end.isFinite, start >= 0, end >= start, end <= 86400 else {
                return ["id":id, "resourceStatus":"invalid"]
            }
            var result: [String: Any] = ["id":id,"start":start,"end":end,
                "showTime":SiteHTTP.number(object["show_time"]), "resourceStatus":"notProvided"]
            var colors: [String: String] = [:]
            for key in ["font_color","stroke_color","self_font_color","self_stroke_color"] {
                if let value = object[key] as? String, value.range(of:"^#[0-9a-fA-F]{6,8}$",options:.regularExpression) != nil { colors[key] = value }
            }
            result["colors"] = colors
            if ![20016,20017,20022,20023,20025,20026,20031,20032,20033].contains(id) {
                unknownActivities[String(id),default:0] += 1
                result["resourceStatus"] = "unsupported"
            }
            // Some activity families carry image/gradient resources in color_picture.
            if let picture = object["color_picture"] as? [String: Any],
               let raw = picture["resource"] as? String, let url = resourceURL(raw) {
                result["colorPictureURL"] = url.absoluteString
                if result["resourceStatus"] as? String != "unsupported" { result["resourceStatus"] = "metadataOnly" }
            }
            guard let raw = object["resource"] as? String else { return result }
            guard let url = resourceURL(raw) else { result["resourceStatus"] = "rejectedURL"; return result }
            result["resourceURL"] = url.absoluteString
            // Known text trajectory. Other resource packages stay metadata, never execute remote code.
            guard id == 20031 else {
                if result["resourceStatus"] as? String != "unsupported" { result["resourceStatus"] = "metadataOnly" }
                return result
            }
            do {
                let data = try await fetch(url)
                guard let text = String(data:data,encoding:.utf8) else { throw Failure.invalidData }
                var points: [[String: Double]] = []
                for line in text.split(whereSeparator:\.isNewline).prefix(8192) {
                    let nums = line.split(separator:",",omittingEmptySubsequences:false).map { Double($0.trimmingCharacters(in:.whitespaces)) }
                    guard nums.count == 3, let t = nums[0], let x = nums[1], let y = nums[2],
                          t.isFinite, x.isFinite, y.isFinite, t >= 0, abs(x) <= 100000, abs(y) <= 100000 else { throw Failure.invalidData }
                    points.append(["time":t,"x":x,"y":y])
                }
                guard !points.isEmpty else { throw Failure.invalidData }
                result["pointFile"] = points
                result["resourceStatus"] = "ready"
            } catch { try note("activityResource",error); result["resourceStatus"] = "unavailable" }
            return result
        }
        static func scalar(_ value: Any?) -> String {
            if let value = value as? String { return value }
            if let value = value as? NSNumber { return value.stringValue }
            return ""
        }
        static func positiveID(_ value: Any?) -> String? {
            let s = scalar(value)
            return !s.isEmpty && s.utf8.count <= 20 && s.allSatisfy(\.isNumber) && UInt64(s) != nil && UInt64(s) != 0 ? s : nil
        }
        static func duration(_ value: Any?, divisor: Double) -> Double {
            let n = SiteHTTP.number(value) / divisor
            return n.isFinite ? max(0,min(n,86400)) : 0
        }
        static func match(_ pattern: String, _ string: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern:pattern),
                  let found = regex.firstMatch(in:string,range:NSRange(string.startIndex...,in:string)),
                  let range = Range(found.range(at:1),in:string) else { return nil }
            return String(string[range])
        }
    }

    /// Bounded wire decoder: never assumes unknown fields are strings or nested messages.
    enum Proto {
        struct Field {
            let id: Int
            var number: UInt64? = nil
            var data: Data? = nil
            var string: String? { data.flatMap { String(data:$0,encoding:.utf8) } }
        }
        static func fields(_ data: Data) throws -> [Field] {
            let bytes = [UInt8](data)
            var offset = 0, result: [Field] = []
            func variable() throws -> UInt64 {
                var value: UInt64 = 0
                for shift in stride(from:0,through:63,by:7) {
                    guard offset < bytes.count else { throw Failure.invalidData }
                    let byte = bytes[offset]; offset += 1
                    if shift == 63 && byte > 1 { throw Failure.invalidData }
                    value |= UInt64(byte & 127) << shift
                    if byte & 128 == 0 { return value }
                }
                throw Failure.invalidData
            }
            while offset < bytes.count {
                guard result.count < 200_000 else { throw Failure.limit }
                let key = try variable(), field = key >> 3, wire = key & 7
                guard field > 0, field <= 0x1fffffff else { throw Failure.invalidData }
                var entry = Field(id:Int(field))
                switch wire {
                case 0: entry.number = try variable()
                case 1,5:
                    let n = wire == 1 ? 8 : 4
                    guard n <= bytes.count - offset else { throw Failure.invalidData }; offset += n
                case 2:
                    let size = try variable()
                    guard size <= UInt64(bytes.count - offset) else { throw Failure.invalidData }
                    entry.data = Data(bytes[offset..<offset+Int(size)]); offset += Int(size)
                default: throw Failure.invalidData
                }
                result.append(entry)
            }
            return result
        }
    }

    private final class XMLComments: NSObject, XMLParserDelegate {
        var rows: [[String: Any]] = [], current: [String: Any]?, text = ""
        var invalid = false
        static func read(_ data: Data) throws -> [[String: Any]] {
            let delegate = XMLComments(), parser = XMLParser(data:data)
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), !delegate.invalid else { throw Failure.invalidData }
            return delegate.rows
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
            guard name == "d", let value = attributes["p"] else { return }
            let p = value.split(separator:",",omittingEmptySubsequences:false)
            guard p.count >= 4, let time = Double(p[0]), let mode = Int(p[1]), let size = Int(p[2]), let color = UInt32(p[3]), time.isFinite, time >= 0 else { return }
            current = ["time":time,"mode":mode,"fontSize":size,"color":color,"id":p.count > 7 ? String(p[7]) : ""]
            text = ""
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard current != nil else { return }
            if text.utf8.count + string.utf8.count > 256*1024 { invalid = true; parser.abortParsing() } else { text += string }
        }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let string = String(data:CDATABlock,encoding:.utf8) { self.parser(parser,foundCharacters:string) }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "d", var row = current else { return }
            row["text"] = text
            if rows.count < 30_000 { rows.append(row) }
            current = nil; text = ""
        }
    }
}
