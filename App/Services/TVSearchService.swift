import Foundation

struct TVEpisode: Identifiable, Sendable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
}

struct TVResult: Identifiable, Sendable {
    var id: String { contentID + ":" + site }
    let title: String
    let category: String
    let year: String
    let contentID: String
    let site: String
    let siteName: String
    let playURL: URL
    let cachedEpisodes: [TVEpisode]
}

struct TVSearchService: Sendable {
    private let sites = ["qiyi": "爱奇艺", "qq": "腾讯", "youku": "优酷", "imgo": "芒果TV", "bilibili1": "B站"]

    func search(_ keyword: String) async throws -> [TVResult] {
        let data = try await SiteHTTP.json("https://api.so.360kan.com/index", query: ["force_v": "1", "kw": keyword])
        let rows = ((data["data"] as? [String: Any])?["longData"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        return rows.flatMap { row -> [TVResult] in
            guard let title = row["titleTxt"] as? String, let identifier = row["en_id"] as? String,
                  let links = row["playlinks"] as? [String: String] else { return [] }
            return sites.sorted { $0.key < $1.key }.compactMap { site, name in
                guard let link = links[site], let url = SiteHTTP.mediaPage(link) else { return nil }
                let cached = row["seriesSite"] as? String == site
                    ? Self.episodeRows(row["seriesPlaylinks"] as? [Any] ?? [], fallback: url) : []
                return TVResult(title: title, category: row["cat_name"] as? String ?? "影视",
                                year: String(describing: row["year"] ?? ""), contentID: identifier,
                                site: site, siteName: name, playURL: url, cachedEpisodes: cached)
            }
        }
    }

    func episodes(_ result: TVResult) async throws -> [TVEpisode] {
        if !result.cachedEpisodes.isEmpty { return result.cachedEpisodes }
        if result.category == "电影" { return [.init(title: "正片", url: result.playURL)] }
        let category = ["电影": "1", "电视剧": "2", "综艺": "3", "动漫": "4"][result.category] ?? "2"
        let selector: [[String: String]] = [["cat_id": category, "ent_id": result.contentID, "site": result.site]]
        let encoded = String(decoding: try JSONEncoder().encode(selector), as: UTF8.self)
        if let data = try? await SiteHTTP.json("https://api.so.360kan.com/episodesv2", query: ["v_ap": "1", "s": encoded]),
           let first = (data["data"] as? [[String: Any]])?.first,
           let series = first["seriesHTML"] as? [String: Any] {
            let episodes = Self.episodeRows(series["seriesPlaylinks"] as? [Any] ?? [], fallback: result.playURL)
            if !episodes.isEmpty { return episodes }
        }
        try Task.checkCancellation()
        let info = try await SiteHTTP.json("https://api.web.360kan.com/v1/detail",
                                         query: ["cat": category, "id": result.contentID, "site": result.site])
        let metadata = info["data"] as? [String: Any] ?? [:]
        let count = min(1000, max(1, Int(SiteHTTP.number((metadata["allupinfo"] as? [String: Any])?[result.site]))))
        var episodes: [TVEpisode] = []
        for start in stride(from: 1, through: count, by: 200) {
            let data = try await SiteHTTP.json("https://api.web.360kan.com/v1/detail", query: [
                "cat": category, "id": result.contentID, "site": result.site,
                "start": String(start), "end": String(min(start + 199, count))
            ])
            let details = (data["data"] as? [String: Any])?["allepidetail"] as? [String: Any]
            let rows = details?[result.site] as? [[String: Any]] ?? []
            episodes += rows.compactMap {
                guard let link = $0["url"] as? String, let url = SiteHTTP.mediaPage(link) else { return nil }
                return TVEpisode(title: "第 \(String(describing: $0["playlink_num"] ?? "")) 集", url: url)
            }
        }
        return episodes.isEmpty ? [.init(title: "来源播放页", url: result.playURL)] : episodes
    }

    static func episodeRows(_ rows: [Any], fallback: URL) -> [TVEpisode] {
        var seen = Set<String>()
        return rows.enumerated().compactMap { index, item in
            // The desktop plugin treats string placeholders as the source's main play URL.
            let link = (item as? [String: Any])?["url"] as? String ?? (item is String ? fallback.absoluteString : "")
            guard let url = SiteHTTP.mediaPage(link), seen.insert(url.absoluteString).inserted else { return nil }
            return TVEpisode(title: "第 \(index + 1) 集", url: url)
        }
    }
}

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
