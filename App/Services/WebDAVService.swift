import Foundation
import Security
import WebDAVCore

struct WebDAVService: Sendable {
    let connection: WebDAVConnection

    func list(_ directory: URL) async throws -> [WebDAVItem] {
        let root = try connection.rootURL()
        guard WebDAVLocation.contains(directory, in: root) else { throw WebDAVError.outsideServer }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: DAVRedirectPolicy(root: root), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: directory)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(connection.authorization, forHTTPHeaderField: "Authorization")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw WebDAVError.unavailable }
        switch response.statusCode {
        case 207: break
        case 401: throw WebDAVError.authentication
        case 403: throw WebDAVError.forbidden
        case 300..<400: throw WebDAVError.outsideServer
        default: throw WebDAVError.invalidListing
        }
        guard response.expectedContentLength <= WebDAVListing.maximumBytes else { throw WebDAVError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            if data.count >= WebDAVListing.maximumBytes { throw WebDAVError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try WebDAVListing.parse(data, directory: response.url ?? directory, root: root)
    }
}

private final class DAVRedirectPolicy: NSObject, URLSessionTaskDelegate {
    let root: URL
    init(root: URL) { self.root = root }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // A directory listing must never forward a password to a different server.
        guard let url = request.url, WebDAVLocation.contains(url, in: root),
              let original = task.originalRequest else { completionHandler(nil); return }
        var redirected = original
        redirected.url = url
        completionHandler(redirected)
    }
}

enum WebDAVKeychain {
    private static let service = "MuFlow.WebDAV"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "default-server"]
    }

    static func load() throws -> WebDAVConnection? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError.unavailable }
        return try JSONDecoder().decode(WebDAVConnection.self, from: data)
    }

    static func save(_ connection: WebDAVConnection) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(connection),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unavailable }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unavailable }
    }

    enum KeychainError: LocalizedError {
        case unavailable
        var errorDescription: String? { "手机钥匙串暂时不可用，请解锁手机后重试。" }
    }
}
