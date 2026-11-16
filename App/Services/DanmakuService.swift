import Foundation
import DanmakuCore

struct AnimeResult: Decodable, Identifiable, Sendable {
    let animeId: Int
    let animeTitle: String
    let episodeCount: Int?
    var id: Int { animeId }
}

struct EpisodeResult: Decodable, Identifiable, Sendable {
    let episodeId: Int
    let episodeTitle: String
    var id: Int { episodeId }
}

enum ServiceError: Error, LocalizedError {
    case invalidURL, http(Int), rejected(String), routes([String])
    var errorDescription: String? {
        switch self {
        case .invalidURL: "请输入有效的 HTTP 或 HTTPS 地址。"
        case .http(let status):
            switch status {
            case 401, 403: "弹幕服务拒绝访问，请检查服务的访问限制或更换线路。"
            case 404: "服务未找到对应弹幕或不支持此接口，请换一个结果或来源链接。"
            case 429: "弹幕服务请求过于频繁，请稍等后重试。"
            case 500...599: "弹幕服务器暂时故障，请稍后重试或更换线路。"
            default: "弹幕服务返回异常，请重试或更换线路。"
            }
        case .rejected(let message): message.isEmpty ? "弹幕服务未返回结果，请换个关键词重试。" : message
        case .routes(let failures): failures.joined(separator: "\n")
        }
    }
}

struct DanmakuService: Sendable {
    let server: String
    let alternateServer: String
    let fallback: String

    private func endpoint(_ base: String, _ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { throw ServiceError.invalidURL }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 } + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw ServiceError.invalidURL }
        return url
    }

    static func download(_ url: URL) async throws -> Data {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ServiceError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("mpv_danmaku/1.0", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw ServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard response.expectedContentLength <= DanmakuParser.maximumBytes else { throw DanmakuError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= DanmakuParser.maximumBytes { throw DanmakuError.tooLarge }
            data.append(byte)
        }
        return data
    }

    private func request<T: Sendable>(_ path: String, query: [URLQueryItem] = [],
                                     parse: @Sendable (Data) throws -> T) async throws -> T {
        var failures: [String] = []
        var visited = Set<String>()
        for (index, base) in [server, alternateServer].enumerated() {
            let base = base.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty, visited.insert(base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).inserted else { continue }
            do {
                let url = try endpoint(base, path, query: query)
                let data = try await Self.download(url)
                try Task.checkCancellation()
                if let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   status["success"] as? Bool == false {
                    throw ServiceError.rejected(status["errorMessage"] as? String ?? "")
                }
                // An HTTP 200 can still contain an error page or unusable payload.
                // Validate within this loop so those responses also try the next route.
                return try parse(data)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                failures.append("\(index == 0 ? "主服务" : "备用服务")：\(DanmakuFailure.message(error))")
            }
        }
        throw ServiceError.routes(failures.isEmpty ? ["请在设置中填写有效的弹幕服务地址。"] : failures)
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        try await request(path, query: query) { try JSONDecoder().decode(type, from: $0) }
    }

    func search(_ keyword: String) async throws -> [AnimeResult] {
        struct Response: Decodable, Sendable { let animes: [AnimeResult] }
        return try await decode(Response.self, path: "/api/v2/search/anime", query: [.init(name: "keyword", value: keyword)]).animes
    }

    func episodes(_ anime: AnimeResult) async throws -> [EpisodeResult] {
        struct Response: Decodable, Sendable {
            struct Bangumi: Decodable, Sendable { let episodes: [EpisodeResult] }
            let bangumi: Bangumi
        }
        return try await decode(Response.self, path: "/api/v2/bangumi/\(anime.animeId)").bangumi.episodes
    }

    func comments(episode: Int) async throws -> [DanmakuComment] {
        try await request("/api/v2/comment/\(episode)", query: [
            .init(name: "withRelated", value: "true"), .init(name: "chConvert", value: "0")
        ]) { data in
            let comments = try DanmakuParser.parse(data)
            guard !comments.isEmpty else { throw DanmakuError.empty }
            return comments
        }
    }

    func comments(link: String) async throws -> [DanmakuComment] {
        try await commentsWithStatus(link: link).comments
    }

    func commentsWithStatus(link: String) async throws -> DanmakuLoadResult {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw ServiceError.invalidURL }
        if ["xml", "json"].contains(url.pathExtension.lowercased()) {
            return .init(comments: try DanmakuParser.parse(await Self.download(url)))
        }
        var failures: [String] = []
        do {
            let result = try await NativeDanmakuService().commentsWithStatus(url)
            if !result.comments.isEmpty { return result }
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); failures.append("来源站点：" + DanmakuFailure.message(error)) }
        do {
            let comments = try await request("/api/v2/extcomment", query: [.init(name: "url", value: link)]) { data in
                let comments = try DanmakuParser.parse(data)
                guard !comments.isEmpty else { throw DanmakuError.empty }
                return comments
            }
            return .init(comments: comments)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            failures.append(DanmakuFailure.message(error))
            guard var components = URLComponents(string: fallback), components.host != nil,
                  ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { throw ServiceError.routes(failures) }
            components.queryItems = [.init(name: "ac", value: "dm"), .init(name: "url", value: link)]
            guard let fallbackURL = components.url else { throw ServiceError.invalidURL }
            do {
                let comments = try DanmakuParser.parse(await Self.download(fallbackURL))
                guard !comments.isEmpty else { throw DanmakuError.empty }
                return .init(comments: comments)
            } catch {
                try Task.checkCancellation()
                failures.append("备用解析：" + DanmakuFailure.message(error))
                throw ServiceError.routes(failures)
            }
        }
    }
}

struct DanmakuLoadResult: Sendable {
    let comments: [DanmakuComment]
    var failedSegments = 0
}

enum DanmakuFailure {
    static func message(_ error: Error) -> String {
        if let network = error as? URLError {
            switch network.code {
            case .notConnectedToInternet, .dataNotAllowed:
                return "手机未能联网，请检查网络，并在系统设置中允许幕流使用无线数据。"
            case .cannotFindHost, .dnsLookupFailed:
                return "无法找到服务器，请检查当前网络或 DNS 后重试。"
            case .timedOut: return "连接超时，请重试或更换网络。"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "安全连接未能建立，请检查手机日期、网络和服务器证书。"
            default: return "网络连接中断，请重试或更换网络。"
            }
        }
        if error is DecodingError || (error as NSError).domain == NSCocoaErrorDomain {
            return "服务返回的内容无法识别。"
        }
        return (error as? LocalizedError)?.errorDescription ?? "弹幕请求未完成，请重试。"
    }
}
