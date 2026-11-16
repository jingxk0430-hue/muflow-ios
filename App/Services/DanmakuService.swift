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
        case .http: "弹幕服务暂时无法访问，请稍后重试或更换服务地址。"
        case .rejected(let message): message.isEmpty ? "弹幕服务未返回结果，请换个关键词重试。" : message
        }
    }
}

struct DanmakuService: Sendable {
    let server: String
    let fallback: String

    private func endpoint(_ path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
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

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await Self.download(url)
        if let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           status["success"] as? Bool == false {
            throw ServiceError.rejected(status["errorMessage"] as? String ?? "")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    func search(_ keyword: String) async throws -> [AnimeResult] {
        struct Response: Decodable { let animes: [AnimeResult] }
        let url = try endpoint("/api/v2/search/anime", query: [.init(name: "keyword", value: keyword)])
        return try await decode(Response.self, from: url).animes
    }

    func episodes(_ anime: AnimeResult) async throws -> [EpisodeResult] {
        struct Response: Decodable {
            struct Bangumi: Decodable { let episodes: [EpisodeResult] }
            let bangumi: Bangumi
        }
        return try await decode(Response.self, from: endpoint("/api/v2/bangumi/\(anime.animeId)")).bangumi.episodes
    }

    func comments(episode: Int) async throws -> [DanmakuComment] {
        let url = try endpoint("/api/v2/comment/\(episode)", query: [
            .init(name: "withRelated", value: "true"), .init(name: "chConvert", value: "0")
        ])
        return try DanmakuParser.parse(await Self.download(url))
    }

    func comments(link: String) async throws -> [DanmakuComment] {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { throw ServiceError.invalidURL }
        if ["xml", "json"].contains(url.pathExtension.lowercased()) {
            return try DanmakuParser.parse(await Self.download(url))
        }
        do {
            let request = try endpoint("/api/v2/extcomment", query: [.init(name: "url", value: link)])
            let comments = try DanmakuParser.parse(await Self.download(request))
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
