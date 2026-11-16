import Foundation
import XCTest
@testable import WebDAVCore

final class WebDAVTests: XCTestCase {
    func testAuthenticationIsEncodedOnlyForSelectedServer() throws {
        let connection = WebDAVConnection(address: "https://example.test/dav", username: "alice", password: "p@ss:/?#% 中文")
        let root = try connection.rootURL()
        XCTAssertEqual(root.absoluteString, "https://example.test/dav/")
        XCTAssertEqual(connection.authorization, "Basic " + Data("alice:p@ss:/?#% 中文".utf8).base64EncodedString())
        let url = try connection.playbackURL(for: root.appendingPathComponent("中文 #1.mkv"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.user, "alice")
        XCTAssertEqual(components.password, connection.password)
        XCTAssertEqual(url.lastPathComponent, "中文 #1.mkv")
        XCTAssertNil(root.user)
        XCTAssertThrowsError(try connection.playbackURL(for: URL(string: "https://other.test/dav/movie.mp4")!))
        XCTAssertThrowsError(try connection.playbackURL(for: URL(string: "http://example.test/dav/movie.mp4")!))
        XCTAssertThrowsError(try connection.playbackURL(for: URL(string: "https://example.test/elsewhere/movie.mp4")!))
    }

    func testRejectsCredentialBearingAndInvalidServerAddresses() {
        for address in ["file:///tmp/", "https://u:p@example.test/dav", "https://example.test/dav?secret=1", "not a url"] {
            XCTAssertThrowsError(try WebDAVConnection(address: address).rootURL())
        }
        XCTAssertThrowsError(try WebDAVConnection(address: "https://example.test", username: "a:b").rootURL())
    }

    func testDirectoryParsingHandlesNamespacesEscapingAndFailedProperties() throws {
        let xml = """
        <D:multistatus xmlns:D="DAV:">
          <D:response><D:href>/dav/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/dav/Series/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype><D:displayname>Series &amp; Films</D:displayname></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/dav/%E4%B8%AD%E6%96%87%20%231.mkv</D:href><D:propstat><D:prop><D:displayname>中文 #1.mkv</D:displayname><D:getcontentlength>4294967296</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat><D:propstat><D:prop><D:displayname>wrong</D:displayname></D:prop><D:status>HTTP/1.1 404 Not Found</D:status></D:propstat></D:response>
          <D:response><D:href>relative.mp4</D:href><D:propstat><D:prop><D:getcontentlength>12</D:getcontentlength></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>https://evil.test/dav/leak.mp4</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/dav/../private.mp4</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
          <D:response><D:href>/dav/nested/hidden.mp4</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
        </D:multistatus>
        """
        let root = URL(string: "https://example.test/dav/")!
        let items = try WebDAVListing.parse(Data(xml.utf8), directory: root, root: root)
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items[0].isDirectory)
        XCTAssertEqual(items[0].name, "Series & Films")
        let movie = try XCTUnwrap(items.first { $0.name == "中文 #1.mkv" })
        XCTAssertEqual(movie.size, 4294967296)
        XCTAssertTrue(movie.isPlayable)
        XCTAssertEqual(movie.url.lastPathComponent, "中文 #1.mkv")
        XCTAssertTrue(items.contains { $0.name == "relative.mp4" })
    }

    func testRejectsInvalidAndEntityBearingListings() {
        let root = URL(string: "https://example.test/dav/")!
        for xml in ["<html>not WebDAV</html>", "<multistatus xmlns='DAV:'>", "<!DOCTYPE x [<!ENTITY a 'x'>]><multistatus xmlns='DAV:' />"] {
            XCTAssertThrowsError(try WebDAVListing.parse(Data(xml.utf8), directory: root, root: root))
        }
    }
}
