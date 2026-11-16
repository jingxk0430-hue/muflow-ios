import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum WebDAVError: Error, LocalizedError {
    case invalidAddress, invalidListing, outsideServer, authentication, forbidden, unavailable, tooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入 HTTP 或 HTTPS 的 WebDAV 文件夹地址，账号和密码请填在下方。"
        case .invalidListing: "服务器未返回有效的 WebDAV 目录，请检查地址是否为 WebDAV 入口。"
        case .outsideServer: "服务器返回了其他地址，请检查 WebDAV 地址或重定向设置。"
        case .authentication: "登录失败，请检查账号、密码或应用专用密码。"
        case .forbidden: "此账号没有访问该文件夹的权限。"
        case .unavailable: "WebDAV 暂时无法访问，请检查网络和服务器地址后重试。"
        case .tooLarge: "目录内容过多，请打开更具体的子文件夹。"
        }
    }
}

public struct WebDAVConnection: Codable, Sendable {
    public var address: String
    public var username: String
    public var password: String

    public init(address: String = "", username: String = "", password: String = "") {
        self.address = address; self.username = username; self.password = password
    }

    public func rootURL() throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, !username.contains(":"),
              !address.contains(where: { $0.isNewline }) else { throw WebDAVError.invalidAddress }
        if !components.path.hasSuffix("/") { components.path += "/" }
        guard let url = components.url else { throw WebDAVError.invalidAddress }
        return url.standardized
    }

    public var authorization: String? {
        username.isEmpty && password.isEmpty ? nil : "Basic " + Data((username + ":" + password).utf8).base64EncodedString()
    }

    public func playbackURL(for url: URL) throws -> URL {
        let root = try rootURL()
        guard WebDAVLocation.contains(url, in: root),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw WebDAVError.outsideServer
        }
        // Credentials belong only to this load URL, never global mpv headers.
        // FFmpeg negotiates HTTP authentication and re-parses redirects separately.
        if authorization != nil { components.user = username; components.password = password }
        guard let result = components.url else { throw WebDAVError.invalidAddress }
        return result
    }
}

public enum WebDAVLocation {
    public static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased() && port(left) == port(right)
    }

    public static func contains(_ url: URL, in root: URL) -> Bool {
        guard sameOrigin(url, root), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return false }
        let path = url.standardized.pathComponents
        let base = root.standardized.pathComponents
        return !path.contains("..") && !path.contains(".") && !url.path.contains("\\")
            && path.count >= base.count && Array(path.prefix(base.count)) == base
    }
}

public struct WebDAVItem: Identifiable, Sendable, Equatable {
    public var id: String { url.absoluteString }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public var isPlayable: Bool {
        !isDirectory && ["mp4", "mkv", "mov", "avi", "webm", "m4v", "ts", "m2ts", "flv", "wmv", "mpg", "mpeg", "3gp", "vob", "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(url.pathExtension.lowercased())
    }
}

public enum WebDAVListing {
    public static let maximumBytes = 8 * 1024 * 1024

    public static func parse(_ data: Data, directory: URL, root: URL) throws -> [WebDAVItem] {
        guard data.count <= maximumBytes else { throw WebDAVError.tooLarge }
        // No DTDs or external entities are needed for a DAV multistatus response.
        guard !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE") else {
            throw WebDAVError.invalidListing
        }
        let delegate = ListingParser(directory: directory, root: root)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let parsed = parser.parse()
        if delegate.tooMany { throw WebDAVError.tooLarge }
        guard parsed, delegate.isMultistatus else { throw WebDAVError.invalidListing }
        return delegate.items.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

private final class ListingParser: NSObject, XMLParserDelegate {
    struct Properties {
        var name = ""
        var isDirectory = false
        var size: Int64?
    }
    let directory: URL
    let root: URL
    var items: [String: WebDAVItem] = [:]
    var isMultistatus = false
    var tooMany = false
    private var stack: [String] = []
    private var text = ""
    private var href = ""
    private var properties = Properties()
    private var pending = Properties()
    private var status = ""
    private var hasProperties = false

    init(directory: URL, root: URL) { self.directory = directory; self.root = root }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); text = ""
        if stack.count == 1 { isMultistatus = name == "multistatus" && namespaceURI == "DAV:" }
        if name == "response" {
            href = ""; properties = Properties(); hasProperties = false
        }
        if name == "propstat" { pending = Properties(); status = "" }
        if name == "collection", stack.contains("resourcetype") { pending.isDirectory = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == "href", stack.dropLast().last == "response" { href = value }
        if stack.contains("propstat") {
            switch name {
            case "displayname": pending.name = value
            case "getcontentlength": if let size = Int64(value), size >= 0 { pending.size = size }
            case "status": status = value
            case "propstat":
                if let code = status.split(separator: " ").dropFirst().first.flatMap({ Int($0) }), (200..<300).contains(code) {
                    hasProperties = true
                    if !pending.name.isEmpty { properties.name = pending.name }
                    properties.isDirectory = properties.isDirectory || pending.isDirectory
                    if let size = pending.size { properties.size = size }
                }
            default: break
            }
        }
        if name == "response", hasProperties, !href.isEmpty,
           let url = URL(string: href, relativeTo: directory)?.absoluteURL.standardized,
           WebDAVLocation.contains(url, in: root),
           url.pathComponents != directory.standardized.pathComponents,
           url.deletingLastPathComponent().standardized.pathComponents == directory.standardized.pathComponents {
            if items.count >= 20_000 { tooMany = true; parser.abortParsing() }
            else {
                let target = properties.isDirectory && !url.absoluteString.hasSuffix("/")
                    ? URL(string: url.absoluteString + "/")! : url
                items[target.absoluteString] = WebDAVItem(url: target, name: properties.name.isEmpty ? url.lastPathComponent : properties.name,
                                                     isDirectory: properties.isDirectory, size: properties.size)
            }
        }
        _ = stack.popLast(); text = ""
    }
}
