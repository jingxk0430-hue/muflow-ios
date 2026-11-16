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
    case invalidURL, http(Int), rejected(String)
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

    private func request(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        var previous: Error = ServiceError.invalidURL
        var visited = Set<String>()
        for base in [server, alternateServer] {
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
                return data
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                previous = error
            }
        }
        throw previous
    }

    private func decode<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        try await JSONDecoder().decode(type, from: request(path, query: query))
    }

    func search(_ keyword: String) async throws -> [AnimeResult] {
        struct Response: Decodable { let animes: [AnimeResult] }
        return try await decode(Response.self, path: "/api/v2/search/anime", query: [.init(name: "keyword", value: keyword)]).animes
    }

    func episodes(_ anime: AnimeResult) async throws -> [EpisodeResult] {
        struct Response: Decodable {
            struct Bangumi: Decodable { let episodes: [EpisodeResult] }
            let bangumi: Bangumi
        }
        return try await decode(Response.self, path: "/api/v2/bangumi/\(anime.animeId)").bangumi.episodes
    }

    func comments(episode: Int) async throws -> [DanmakuComment] {
        let data = try await request("/api/v2/comment/\(episode)", query: [
            .init(name: "withRelated", value: "true"), .init(name: "chConvert", value: "0")
        ])
        return try DanmakuParser.parse(data)
    }

    func comments(link: String) async throws -> [DanmakuComment] {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw ServiceError.invalidURL }
        if ["xml", "json"].contains(url.pathExtension.lowercased()) {
            return try DanmakuParser.parse(await Self.download(url))
        }
        do {
            let comments = try await NativeDanmakuService().comments(url)
            if !comments.isEmpty { return comments }
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation() }
        do {
            let data = try await request("/api/v2/extcomment", query: [.init(name: "url", value: link)])
            let comments = try DanmakuParser.parse(data)
            guard !comments.isEmpty else { throw DanmakuError.empty }
            return comments
        } catch is CancellationError { throw CancellationError() }
        catch {
            guard var components = URLComponents(string: fallback), components.host != nil,
                  ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { throw error }
            components.queryItems = [.init(name: "ac", value: "dm"), .init(name: "url", value: link)]
            guard let fallbackURL = components.url else { throw ServiceError.invalidURL }
            return try DanmakuParser.parse(await Self.download(fallbackURL))
        }
    }
}
