// Adapted from Tony15246/uosc_danmaku/sites/youku.lua (MIT).
import CryptoKit
import DanmakuCore
import Foundation

struct YoukuDanmakuService: Sendable {
    struct Endpoints: Sendable {
        let metadata: URL
        let visitor: URL
        let session: URL
        let comments: URL
        static let production = Endpoints(
            metadata: URL(string: "https://openapi.youku.com/v2/videos/show.json")!,
            visitor: URL(string: "https://log.mmstat.com/eg.js")!,
            session: URL(string: "https://acs.youku.com/h5/mtop.com.youku.aplatform.weakget/1.0/")!,
            comments: URL(string: "https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/")!)
    }

    let endpoints: Endpoints
    init(endpoints: Endpoints = .production) { self.endpoints = endpoints }
    private static let appKey = "24679788"
    private static let agent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

    static func videoID(_ url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        guard host == "youku.com" || host.hasSuffix(".youku.com") else { return nil }
        let value = NativeDanmakuService.match("id_([A-Za-z0-9=_-]+)", in: url.path)
            ?? URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "vid" }?.value
        guard let value, value.range(of: "^[A-Za-z0-9=_-]{5,80}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    func comments(_ source: URL) async throws -> DanmakuLoadResult {
        guard let vid = Self.videoID(source) else {
            throw ServiceError.rejected("请复制优酷具体一集的播放页链接，合集和搜索页不能直接读取弹幕。")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let policy = YoukuRedirectPolicy(origins: [endpoints.metadata, endpoints.visitor, endpoints.session, endpoints.comments])
        let session = URLSession(configuration: configuration, delegate: policy, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let metadataURL = try Self.url(endpoints.metadata, query: ["client_id": "53e6cc67237fc59a", "video_id": vid,
                                                                 "package": "com.huawei.hwvplayer.youku", "ext": "show"])
        let (metadata, _) = try await Self.fetch(session, url: metadataURL)
        let info = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] ?? [:]
        let duration = SiteHTTP.number(info["duration"])
        guard duration.isFinite, duration > 0 else {
            throw ServiceError.rejected("优酷未返回这集的视频信息，请检查是否为可访问的单集播放页。")
        }
        async let visitorReply = Self.fetch(session, url: endpoints.visitor)
        async let sessionReply = Self.fetch(session, url: try Self.url(endpoints.session, query: ["jsv": "2.5.1", "appKey": Self.appKey]))
        let (_, visitorResponse) = try await visitorReply
        let (_, tokenResponse) = try await sessionReply
        let visitorCookies = Self.cookies(visitorResponse)
        let tokenCookies = Self.cookies(tokenResponse)
        guard let visitor = visitorCookies["cna"], let token = tokenCookies["_m_h5_tk"],
              let encrypted = tokenCookies["_m_h5_tk_enc"], token.count >= 32,
              !visitor.isEmpty, !encrypted.isEmpty else {
            throw ServiceError.rejected("优酷临时弹幕会话未能建立，请稍后重试；无需导入登录 Cookie。")
        }
        let credentials = AnonymousSession(visitor: visitor, token: token, encrypted: encrypted)
        let count = min(400, max(1, Int(floor(min(duration, 24_000) / 60)) + 1))
        var comments: [DanmakuComment] = []
        var failures: [String] = []
        for start in stride(from: 0, to: count, by: 6) {
            try Task.checkCancellation()
            let incoming = try await withThrowingTaskGroup(of: Segment.self) { group in
                for minute in start..<min(count, start + 6) {
                    group.addTask {
                        do {
                            let request = try Self.segmentRequest(endpoint: endpoints.comments, video: vid, minute: minute,
                                                                  credentials: credentials, timestamp: Int64(Date().timeIntervalSince1970 * 1000))
                            let (data, _) = try await Self.fetch(session, request: request)
                            let rows = try Self.parse(data).map { item in
                                var item = item; item.id = "youku:\(minute):" + item.id; return item
                            }
                            return Segment(comments: rows)
                        } catch {
                            try Task.checkCancellation()
                            return Segment(comments: [], failure: DanmakuFailure.message(error))
                        }
                    }
                }
                var items: [Segment] = []
                for try await item in group { items.append(item) }
                return items
            }
            for item in incoming {
                comments += item.comments
                if let failure = item.failure { failures.append(failure) }
            }
            if comments.count >= DanmakuParser.maximumComments { break }
        }
        guard !comments.isEmpty else {
            if let failure = failures.first { throw ServiceError.rejected(failure) }
            throw DanmakuError.empty
        }
        return .init(comments: Array(comments.sorted { $0.time < $1.time }.prefix(DanmakuParser.maximumComments)), failedSegments: failures.count)
    }

    struct AnonymousSession: Sendable {
        let visitor: String
        let token: String
        let encrypted: String
    }
    private struct Segment: Sendable {
        let comments: [DanmakuComment]
        var failure: String? = nil
    }

    static func segmentRequest(endpoint: URL, video: String, minute: Int,
                               credentials: AnonymousSession, timestamp: Int64) throws -> URLRequest {
        var message: [String: Any] = ["ctime": timestamp, "ctype": 10004, "cver": "v1.0", "guid": credentials.visitor,
                                      "mat": minute, "mcount": 1, "pid": 0, "sver": "3.1.0", "type": 1, "vid": video]
        let encoded = try json(message).base64EncodedString()
        message["msg"] = encoded
        message["sign"] = md5(encoded + "MkmC9SoIw6xCkSKHhJ7b5D2r51kBiREr")
        let body = String(decoding: try json(message), as: UTF8.self)
        let signature = md5(String(credentials.token.prefix(32)) + "&\(timestamp)&" + appKey + "&" + body)
        let url = try url(endpoint, query: ["jsv": "2.5.6", "appKey": appKey, "t": String(timestamp), "sign": signature,
                                            "api": "mopen.youku.danmu.list", "v": "1.0", "type": "originaljson",
                                            "dataType": "jsonp", "timeout": "20000", "jsonpIncPrefix": "utility"])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let form = body.addingPercentEncoding(withAllowedCharacters: unreserved) else { throw ServiceError.invalidURL }
        request.httpBody = Data(("data=" + form).utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("_m_h5_tk=\(credentials.token);_m_h5_tk_enc=\(credentials.encrypted);", forHTTPHeaderField: "Cookie")
        return request
    }

    static func parse(_ data: Data) throws -> [DanmakuComment] {
        var object = try JSONSerialization.jsonObject(with: data)
        if let root = object as? [String: Any], let status = root["ret"] as? [String],
           !status.contains(where: { $0.hasPrefix("SUCCESS") }) {
            throw ServiceError.rejected("优酷弹幕接口拒绝了本次请求，请稍后重试以重新建立临时会话。")
        }
        for _ in 0..<8 {
            if let rows = object as? [[String: Any]] {
                let normalized = rows.compactMap { row -> [String: Any]? in
                    guard let text = row["content"] as? String, !text.isEmpty else { return nil }
                    let properties = (row["propertis"] as? String).flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    let color = properties["color"].map { SiteHTTP.number($0) } ?? Double(0xFFFFFF)
                    return ["time": SiteHTTP.number(row["playat"]) / 1000, "text": text, "mode": 1, "color": color, "style": properties]
                }
                return try DanmakuParser.parse(json(["comments": normalized]))
            }
            if let string = object as? String, let bytes = string.data(using: .utf8) {
                object = try JSONSerialization.jsonObject(with: bytes)
            } else if let dictionary = object as? [String: Any] {
                if SiteHTTP.number(dictionary["code"]) == -1 { return [] }
                if let next = dictionary["data"] ?? dictionary["result"] { object = next }
                else { throw DanmakuError.invalidFormat }
            } else { throw DanmakuError.invalidFormat }
        }
        throw DanmakuError.invalidFormat
    }

    private static func cookies(_ response: HTTPURLResponse) -> [String: String] {
        guard let url = response.url else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        return Dictionary(HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).map { ($0.name, $0.value) }, uniquingKeysWith: { _, value in value })
    }
    private static func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func url(_ base: URL, query: [String: String]) throws -> URL {
        try SiteHTTP.url(base.absoluteString, query: query)
    }
    private static func fetch(_ session: URLSession, url: URL) async throws -> (Data, HTTPURLResponse) {
        try await fetch(session, request: URLRequest(url: url))
    }
    private static func fetch(_ session: URLSession, request original: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = original
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://v.youku.com/", forHTTPHeaderField: "Referer")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError.http(0) }
        guard (200..<300).contains(http.statusCode) else { throw ServiceError.http(http.statusCode) }
        guard http.expectedContentLength <= DanmakuParser.maximumBytes else { throw DanmakuError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < DanmakuParser.maximumBytes else { throw DanmakuError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, http)
    }
}

private final class YoukuRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let origins: [URL]
    init(origins: [URL]) { self.origins = origins }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, let source = task.currentRequest?.url,
              source.scheme == target.scheme, source.host == target.host, source.port == target.port,
              origins.contains(where: { $0.scheme == target.scheme && $0.host == target.host && $0.port == target.port }) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
