import Foundation

enum DanmakuSourceLink {
    static func isBilibiliShort(_ url: URL) -> Bool {
        ["b23.tv", "www.b23.tv"].contains(url.host?.lowercased() ?? "")
    }

    static func resolve(_ source: URL) async throws -> URL {
        guard isBilibiliShort(source) else { return source }
        guard var components = URLComponents(url: source, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil else { throw ServiceError.invalidURL }
        components.scheme = "https"
        guard let url = components.url else { throw ServiceError.invalidURL }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: BilibiliLinkRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        request.setValue(SiteHTTP.agent, forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.bytes(for: request)
        guard let resolved = response.url, isRecognizedBilibiliPage(resolved) else {
            throw ServiceError.rejected("B站短链接未能解析成视频页，请在浏览器打开后复制完整的 BV、AV 或番剧单集链接。")
        }
        return resolved
    }

    static func isRecognizedBilibiliPage(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return url.scheme == "https" && url.user == nil && url.password == nil
            && (host == "bilibili.com" || host.hasSuffix(".bilibili.com"))
            && NativeDanmakuService.match("(BV[A-Za-z0-9]+|av[0-9]+|ep[0-9]+)", in: url.path) != nil
    }
}

private final class BilibiliLinkRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil,
              DanmakuSourceLink.isBilibiliShort(url) || DanmakuSourceLink.isRecognizedBilibiliPage(url) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }
}
