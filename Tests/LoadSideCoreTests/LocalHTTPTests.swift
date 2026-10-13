import Foundation
import XCTest
@testable import LoadSideCore

final class LocalHTTPTests: XCTestCase {
    func testRoutesOnlyCanonicalPathsWithinTheSessionCapability() {
        let localURL = URL(string: "http://127.0.0.1:8080/private-token/")!
        let id = UUID(uuidString: "01A133A9-767F-7F53-8427-FEEBE213D5EE")!
        XCTAssertEqual(LocalHTTP.route("/private-token/", localURL: localURL), .catalog)
        XCTAssertEqual(LocalHTTP.route("/private-token/apps/\(id.uuidString).ipa", localURL: localURL), .archive(id))
        XCTAssertEqual(LocalHTTP.route("/private-token/apps/\(id.uuidString).plist", localURL: localURL), .manifest(id))
        for target in [
            "/", "/private-token", "/private-token-extra/", "/old-token/",
            "/private-token//", "/private-token/apps/", "/private-token/manifest.json",
            "/private-token/apps/\(id.uuidString.lowercased()).ipa",
            "/private-token/apps/\(id.uuidString).IPA",
            "/private-token/apps/\(id.uuidString).ipa/",
            "/private-token/apps/\(id.uuidString).ipa.plist"
        ] {
            XCTAssertNil(LocalHTTP.route(target, localURL: localURL), target)
        }
    }

    func testParsingRejectsDuplicateHeadersRegardlessOfCaseAndBoundedInput() throws {
        for request in [
            "GET / HTTP/1.1\r\nRange: bytes=0-1\r\nrAnGe: bytes=2-3\r\n\r\n",
            "GET / HTTP/1.1\r\nHost: example\r\n folded: value\r\n\r\n",
            "GET / HTTP/2\r\n\r\n",
            "GET / HTTP/1.1\r\nHeader: value\nvalue\r\n\r\n",
            "GET / HTTP/1.1\r\nHeader: " + String(repeating: "x", count: LocalHTTP.maximumHeaderBytes) + "\r\n\r\n"
        ] {
            XCTAssertThrowsError(try LocalHTTP.parse(Data(request.utf8)))
        }
        let parsed = try LocalHTTP.parse(Data("HEAD /private-token/ HTTP/1.0\r\nContent-Length: 0\r\nRange: bytes=0-0\r\n\r\n".utf8))
        XCTAssertEqual(parsed.method, "HEAD")
        XCTAssertEqual(parsed.target, "/private-token/")
        XCTAssertEqual(parsed.headers["range"], "bytes=0-0")
        XCTAssertEqual(try LocalHTTP.byteRange(nil, size: 1), 0...0)
        XCTAssertEqual(try LocalHTTP.byteRange("bytes=-999", size: 10), 0...9)
        XCTAssertThrowsError(try LocalHTTP.byteRange(nil, size: 0))
    }

    func testFinalHeaderValuesArePreservedBeforeTheCRLFTerminator() throws {
        let range = try LocalHTTP.parse(Data("GET / HTTP/1.1\r\nRange: bytes=0-0\r\n\r\n".utf8))
        XCTAssertEqual(range.headers["range"], "bytes=0-0")

        let emptyBody = try LocalHTTP.parse(Data("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8))
        XCTAssertEqual(emptyBody.headers["content-length"], "0")
        for field in ["Content-Length: 001", "Content-Length: 0AB", "Transfer-Encoding: chunked"] {
            XCTAssertThrowsError(try LocalHTTP.parse(Data("GET / HTTP/1.1\r\n\(field)\r\n\r\n".utf8)), field)
        }
        XCTAssertThrowsError(try LocalHTTP.parse(Data("GET / HTTP/1.1\r\nContent-Length: 0\r\n\r\nbody".utf8)))
    }

    func testRejectsUnsafeURLsRequestsAndAmbiguousRanges() throws {
        for value in ["http://apps.example.com", "https://user:password@apps.example.com", "https://apps.example.com/path", "https://apps.example.com?query", "https://apps.example.com#fragment", "file:///tmp/apps"] {
            XCTAssertThrowsError(try LocalHTTP.validateHTTPSBase(URL(string: value)))
        }
        XCTAssertEqual(try LocalHTTP.validateHTTPSBase(URL(string: "https://apps.example.com:8443"))?.host, "apps.example.com")
        for target in ["/../secret", "/%2e%2e/secret", "/token?x=1", "https://apps.example.com/", "/token\\secret"] {
            XCTAssertThrowsError(try LocalHTTP.parse(Data("GET \(target) HTTP/1.1\r\nHost: example\r\n\r\n".utf8)))
        }
        for fields in ["Content-Length: 1", "Transfer-Encoding: chunked", "Range: bytes=0-1\r\nRange: bytes=2-3", "Bad Header: x"] {
            XCTAssertThrowsError(try LocalHTTP.parse(Data("GET /token/ HTTP/1.1\r\n\(fields)\r\n\r\n".utf8)))
        }
        XCTAssertThrowsError(try LocalHTTP.parse(Data("GET / HTTP/1.1\r\n\r\nbody".utf8)))
        for value in ["bytes=1-2,4-5", "bytes=-0", "bytes=999-", "bytes=7-2", "bytes=--1", "bytes=+1-3", "bytes=99999999999999999999999999-"] {
            XCTAssertThrowsError(try LocalHTTP.byteRange(value, size: 10))
        }
        XCTAssertEqual(try LocalHTTP.byteRange("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(try LocalHTTP.byteRange("bytes=4-99", size: 10), 4...9)
        XCTAssertEqual(try LocalHTTP.byteRange("bytes=4-", size: 10), 4...9)
    }

    func testManifestUsesActualBundleVersionEscapesNamesAndNeverInstallsWithoutHTTPS() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let result = try libraryResult(root, name: "<script>alert('x')</script> & App")
        let app = try await library.add(result)
        let base = URL(string: "https://apps.example.com/012345/")!
        let local = URL(string: "http://127.0.0.1:8080/012345/")!
        let session = LocalAppServerSession(localURL: local, networkURLs: [], httpsURL: nil, port: 8080)
        XCTAssertNil(session.installURL(for: app)); XCTAssertFalse(session.installEnabled)
        let page = LocalHTTP.page([app], session: session)
        XCTAssertFalse(page.contains("<script>")); XCTAssertTrue(page.contains("&lt;script&gt;"))
        XCTAssertFalse(page.contains("itms-services"))
        let httpsSession = LocalAppServerSession(localURL: local, networkURLs: [], httpsURL: base, port: 8080)
        XCTAssertNotNil(httpsSession.installURL(for: app))
        let data = try LocalHTTP.manifest(app, baseURL: base)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let items = try XCTUnwrap(plist["items"] as? [[String: Any]]), metadata = try XCTUnwrap(items.first?["metadata"] as? [String: String])
        XCTAssertEqual(metadata["bundle-version"], "42.1"); XCTAssertEqual(metadata["title"], result.displayName)
        let assets = try XCTUnwrap(items.first?["assets"] as? [[String: String]])
        XCTAssertEqual(assets.first?["url"], base.appendingPathComponent("apps/\(app.id.uuidString).ipa").absoluteString)
        let legacy = try await library.add(try libraryResult(root, version: nil))
        XCTAssertNil(httpsSession.installURL(for: legacy))
        XCTAssertThrowsError(try LocalHTTP.manifest(legacy, baseURL: base))
    }

}
