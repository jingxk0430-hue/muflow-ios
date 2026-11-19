import Foundation

enum SiteHTTP {
    static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 Version/26.0 Mobile/15E148 Safari/604.1"

    static func url(_ base: String, query: [String: String] = [:]) throws -> URL {
        guard var components = URLComponents(string: base) else { throw ServiceError.invalidURL }
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { .init(name: $0.key, value: $0.value) } }
        guard let url = components.url else { throw ServiceError.invalidURL }
        return url
    }

    static func data(_ url: URL, referer: String? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard response.expectedContentLength <= 32 * 1024 * 1024 else { throw WebDataError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 32 * 1024 * 1024 { throw WebDataError.tooLarge }
            data.append(byte)
        }
        return data
    }

    static func json(_ base: String, query: [String: String] = [:], referer: String? = nil) async throws -> [String: Any] {
        let data = try await data(url(base, query: query), referer: referer)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw WebDataError.invalid }
        return object
    }

    static func number(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        return Double(value as? String ?? "") ?? 0
    }

    static func mediaPage(_ value: String) -> URL? {
        guard var parts = URLComponents(string: value), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), parts.user == nil, parts.password == nil,
              ["iqiyi.com", "v.qq.com", "youku.com", "mgtv.com", "bilibili.com", "b23.tv"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        // Canonical pages avoid tracking parameters and use the same HTTPS routes as desktop parsers.
        parts.scheme = "https"
        if parts.path.hasSuffix(".html") {
            // Mobile Tencent share pages put the actual episode in ?vid=.
            let videoID = (host == "v.qq.com" || host.hasSuffix(".v.qq.com"))
                ? parts.queryItems?.filter { $0.name == "vid" } : nil
            parts.queryItems = videoID?.isEmpty == false ? videoID : nil
        }
        return parts.url
    }

    enum WebDataError: LocalizedError {
        case invalid, tooLarge
        var errorDescription: String? { "来源站点返回的数据无法读取，请稍后重试或换一个来源。" }
    }
}
