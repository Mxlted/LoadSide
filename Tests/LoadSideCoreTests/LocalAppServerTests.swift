import Foundation
import XCTest
@testable import LoadSideCore

final class LocalAppServerTests: XCTestCase {
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

    func testRealServerStreamsRangesDeniesUnlistedPathsAndRotatesLinks() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let result = try libraryResult(root, bytes: 5_000_000), app = try await library.add(result)
        let server = LocalAppServer(library: library)
        let session = try await server.start()
        do {
            let (page, response) = try await fetch(session.localURL)
            XCTAssertEqual(response.statusCode, 200); XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Example"))
            let downloadURL = session.localURL.appendingPathComponent("apps/\(app.id.uuidString).ipa")
            let (archive, archiveResponse) = try await fetch(downloadURL)
            XCTAssertEqual(archiveResponse.statusCode, 200); XCTAssertEqual(archive, try Data(contentsOf: result.output))
            let (partial, partialResponse) = try await fetch(downloadURL, headers: ["Range": "bytes=256-1023"])
            XCTAssertEqual(partialResponse.statusCode, 206); XCTAssertEqual(partial.count, 768)
            XCTAssertEqual(partial, archive.subdata(in: 256..<1024))
            let (head, headResponse) = try await fetch(downloadURL, method: "HEAD")
            XCTAssertTrue(head.isEmpty); XCTAssertEqual(headResponse.statusCode, 200)
            XCTAssertEqual(headResponse.value(forHTTPHeaderField: "Content-Length"), "5000000")
            for url in [session.localURL.deletingLastPathComponent(), session.localURL.appendingPathComponent("apps/\(UUID().uuidString).ipa"), session.localURL.appendingPathComponent("apps/\(app.id.uuidString).plist"), session.localURL.appendingPathComponent("manifest.json")] {
                let (_, denied) = try await fetch(url); XCTAssertEqual(denied.statusCode, 404)
            }
            let (_, badRange) = try await fetch(downloadURL, headers: ["Range": "bytes=5000000-"])
            XCTAssertEqual(badRange.statusCode, 416)
            let (_, post) = try await fetch(session.localURL, method: "POST")
            XCTAssertEqual(post.statusCode, 405)
            await server.stop()
            let stopped = await server.currentSession()
            XCTAssertNil(stopped)
            let restarted = try await server.start(port: session.port)
            XCTAssertNotEqual(session.localURL, restarted.localURL)
            let (_, old) = try await fetch(session.localURL); XCTAssertEqual(old.statusCode, 404)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

    func testRealServerManifestRequiresConfiguredHTTPSAndRefusesTamperedDownload() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps")), app = try await library.add(try libraryResult(root))
        let server = LocalAppServer(library: library)
        let session = try await server.start(httpsBaseURL: URL(string: "https://apps.example.com"))
        do {
            let manifestURL = session.localURL.appendingPathComponent("apps/\(app.id.uuidString).plist")
            let (data, response) = try await fetch(manifestURL)
            XCTAssertEqual(response.statusCode, 200); XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("https://apps.example.com/"))
            let archive = library.directoryURL.appendingPathComponent("\(app.id.uuidString)/app.ipa")
            try Data(repeating: 0, count: Int(app.byteCount)).write(to: archive)
            let (_, denied) = try await fetch(session.localURL.appendingPathComponent("apps/\(app.id.uuidString).ipa"))
            XCTAssertEqual(denied.statusCode, 404)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

    private func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 15
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }
}
