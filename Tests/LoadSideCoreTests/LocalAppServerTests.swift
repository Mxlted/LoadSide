import Darwin
import Foundation
import XCTest

@testable import LoadSideCore

final class LocalAppServerTests: XCTestCase {
    func testArchiveTruncatedAfterHeadersClosesTransferWithoutAppendingAnErrorResponse() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let app = try await library.add(try libraryResult(root, bytes: 8 * 1_024 * 1_024))
        let server = LocalAppServer(library: library)
        let session = try await server.start()
        do {
            // A small receive window holds back the body while the real server verifies the
            // archive and commits its headers. The subsequent truncation exercises a failed
            // transfer without a test-only hook in the serving implementation.
            let connection = try SlowHTTPConnection(port: session.port)
            defer { try? connection.handle.close() }
            let path = session.localURL.appendingPathComponent("apps/\(app.id.uuidString).ipa").path
            try connection.handle.write(contentsOf: Data("GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8))
            let delimiter = Data("\r\n\r\n".utf8)
            var response = Data()
            while response.range(of: delimiter) == nil {
                let chunk = try connection.read(maximumBytes: 4_096)
                guard !chunk.isEmpty else { throw LoadSideError("fixture.eof", "The server closed before sending response headers.") }
                response.append(chunk)
            }
            let boundary = try XCTUnwrap(response.range(of: delimiter))
            let headers = String(decoding: response[..<boundary.lowerBound], as: UTF8.self)
            XCTAssertTrue(headers.hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertTrue(headers.contains("Content-Length: \(app.byteCount)"))

            let archive = library.directoryURL.appendingPathComponent("\(app.id.uuidString)/app.ipa")
            let writer = try FileHandle(forWritingTo: archive)
            try writer.truncate(atOffset: 0)
            try writer.close()
            while true {
                do {
                    let chunk = try connection.read(maximumBytes: 64 * 1_024)
                    if chunk.isEmpty { break }
                    response.append(chunk)
                } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ECONNRESET) {
                    break  // A cancelled partial response may end in either EOF or a reset.
                }
            }
            let body = response[boundary.upperBound...]
            XCTAssertLessThan(body.count, Int(app.byteCount), "The fixture must interrupt an in-progress transfer")
            XCTAssertNil(body.range(of: Data("HTTP/1.1".utf8)), "A failed download must not append another HTTP response")
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testRealServerStreamsRangesDeniesUnlistedPathsAndRotatesLinks() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let result = try libraryResult(root, bytes: 5_000_000)
        let app = try await library.add(result)
        let server = LocalAppServer(library: library)
        let session = try await server.start()
        do {
            let (page, response) = try await fetch(session.localURL)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("Example"))
            let downloadURL = session.localURL.appendingPathComponent("apps/\(app.id.uuidString).ipa")
            let (archive, archiveResponse) = try await fetch(downloadURL)
            XCTAssertEqual(archiveResponse.statusCode, 200)
            XCTAssertEqual(archive, try Data(contentsOf: result.output))
            let (partial, partialResponse) = try await fetch(downloadURL, headers: ["Range": "bytes=256-1023"])
            XCTAssertEqual(partialResponse.statusCode, 206)
            XCTAssertEqual(partial.count, 768)
            XCTAssertEqual(partial, archive.subdata(in: 256..<1024))
            let (head, headResponse) = try await fetch(downloadURL, method: "HEAD")
            XCTAssertTrue(head.isEmpty)
            XCTAssertEqual(headResponse.statusCode, 200)
            XCTAssertEqual(headResponse.value(forHTTPHeaderField: "Content-Length"), "5000000")
            for url in [
                session.localURL.deletingLastPathComponent(), session.localURL.appendingPathComponent("apps/\(UUID().uuidString).ipa"),
                session.localURL.appendingPathComponent("apps/\(app.id.uuidString).plist"),
                session.localURL.appendingPathComponent("manifest.json")
            ] {
                let (_, denied) = try await fetch(url)
                XCTAssertEqual(denied.statusCode, 404)
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
            let (_, old) = try await fetch(session.localURL)
            XCTAssertEqual(old.statusCode, 404)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testRealServerManifestRequiresConfiguredHTTPSAndRefusesTamperedDownload() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let app = try await library.add(try libraryResult(root))
        let server = LocalAppServer(library: library)
        let session = try await server.start(httpsBaseURL: URL(string: "https://apps.example.com"))
        do {
            let manifestURL = session.localURL.appendingPathComponent("apps/\(app.id.uuidString).plist")
            let (data, response) = try await fetch(manifestURL)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("https://apps.example.com/"))
            let archive = library.directoryURL.appendingPathComponent("\(app.id.uuidString)/app.ipa")
            try Data(repeating: 0, count: Int(app.byteCount)).write(to: archive)
            let (_, denied) = try await fetch(session.localURL.appendingPathComponent("apps/\(app.id.uuidString).ipa"))
            XCTAssertEqual(denied.statusCode, 404)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testRunningServerAttachesHTTPSWithoutRotatingLinksAndServesInstallManifest() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let app = try await library.add(try libraryResult(root, version: "207.3"))
        let server = LocalAppServer(library: library)
        let initial = try await server.start()
        do {
            let manifestPath = "apps/\(app.id.uuidString).plist"
            let (initialPage, initialResponse) = try await fetch(initial.localURL)
            XCTAssertEqual(initialResponse.statusCode, 200)
            XCTAssertFalse(initial.installEnabled)
            XCTAssertFalse(String(decoding: initialPage, as: UTF8.self).contains("itms-services"))
            let (_, unavailableManifest) = try await fetch(initial.localURL.appendingPathComponent(manifestPath))
            XCTAssertEqual(unavailableManifest.statusCode, 404)

            let origin = URL(string: "https://apps.example.com:8443")!
            let updated = try await server.configureHTTPS(baseURL: origin, expectedLocalURL: initial.localURL)
            let expectedHTTPS = origin.appendingPathComponent(initial.localURL.lastPathComponent, isDirectory: true)
            XCTAssertEqual(updated.localURL, initial.localURL)
            XCTAssertEqual(updated.networkURLs, initial.networkURLs)
            XCTAssertEqual(updated.port, initial.port)
            XCTAssertEqual(updated.httpsURL, expectedHTTPS)
            XCTAssertTrue(updated.installEnabled)
            let current = await server.currentSession()
            XCTAssertEqual(current?.httpsURL, expectedHTTPS)

            let (pageData, pageResponse) = try await fetch(initial.localURL)
            XCTAssertEqual(pageResponse.statusCode, 200)
            let page = String(decoding: pageData, as: UTF8.self)
            let installLink = try XCTUnwrap(
                page.components(separatedBy: "href=\"")
                    .dropFirst().map { String($0.prefix(while: { $0 != "\"" })) }
                    .first { $0.hasPrefix("itms-services:") }
            )
            .replacingOccurrences(of: "&amp;", with: "&")
            let install = try XCTUnwrap(URLComponents(string: installLink))
            XCTAssertEqual(install.scheme, "itms-services")
            XCTAssertEqual(install.queryItems?.first { $0.name == "action" }?.value, "download-manifest")
            XCTAssertEqual(
                install.queryItems?.first { $0.name == "url" }?.value,
                expectedHTTPS.appendingPathComponent(manifestPath).absoluteString)

            let (manifestData, manifestResponse) = try await fetch(initial.localURL.appendingPathComponent(manifestPath))
            XCTAssertEqual(manifestResponse.statusCode, 200)
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any])
            let items = try XCTUnwrap(plist["items"] as? [[String: Any]])
            let metadata = try XCTUnwrap(items.first?["metadata"] as? [String: String])
            XCTAssertEqual(metadata["bundle-version"], "207.3")
            XCTAssertEqual(metadata["bundle-identifier"], app.bundleIdentifier)
            let assets = try XCTUnwrap(items.first?["assets"] as? [[String: String]])
            XCTAssertEqual(assets.first?["kind"], "software-package")
            XCTAssertEqual(assets.first?["url"], expectedHTTPS.appendingPathComponent("apps/\(app.id.uuidString).ipa").absoluteString)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    func testHTTPSAttachmentRejectsUnsafeOriginsAndStaleSessionsWithoutChangingState() async throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let server = LocalAppServer(library: LocalAppLibrary(directory: root.appendingPathComponent("apps")))
        let original = try await server.start()
        let origin = URL(string: "https://apps.example.com")!
        do {
            let configured = try await server.configureHTTPS(baseURL: origin, expectedLocalURL: original.localURL)
            for value in [
                "http://apps.example.com", "https://user:password@apps.example.com", "https://apps.example.com/path",
                "https://apps.example.com?query", "https://apps.example.com#fragment", "https://apps.example.com:0"
            ] {
                do {
                    _ = try await server.configureHTTPS(baseURL: URL(string: value)!, expectedLocalURL: original.localURL)
                    XCTFail("Accepted an unsafe HTTPS origin: \(value)")
                } catch let error as LoadSideError {
                    XCTAssertEqual(error.code, "server.https")
                }
                let current = await server.currentSession()
                XCTAssertEqual(current?.localURL, configured.localURL)
                XCTAssertEqual(current?.httpsURL, configured.httpsURL)
            }

            await server.stop()
            do {
                _ = try await server.configureHTTPS(baseURL: origin, expectedLocalURL: original.localURL)
                XCTFail("Attached HTTPS after the listener stopped")
            } catch let error as LoadSideError {
                XCTAssertEqual(error.code, "server.session")
            }
            let stopped = await server.currentSession()
            XCTAssertNil(stopped)

            let restarted = try await server.start()
            XCTAssertNotEqual(restarted.localURL, original.localURL)
            do {
                _ = try await server.configureHTTPS(baseURL: origin, expectedLocalURL: original.localURL)
                XCTFail("Attached a stale HTTPS result to a new sharing session")
            } catch let error as LoadSideError {
                XCTAssertEqual(error.code, "server.session")
            }
            let current = await server.currentSession()
            XCTAssertEqual(current?.localURL, restarted.localURL)
            XCTAssertNil(current?.httpsURL)
            let (page, response) = try await fetch(restarted.localURL)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertFalse(String(decoding: page, as: UTF8.self).contains("itms-services"))
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    private func fetch(_ url: URL, method: String = "GET", headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }
}

/// A loopback client with a bounded receive window and timeout for interrupted-transfer tests.
private struct SlowHTTPConnection {
    let handle: FileHandle

    init(port: UInt16) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw LoadSideError("fixture.socket", "Could not create a test socket.") }
        let socketHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var bufferSize: Int32 = 4_096
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            guard setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout.size(ofValue: bufferSize))) == 0,
                setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout))) == 0
            else {
                throw LoadSideError("fixture.socket", "Could not configure the test socket.")
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard status == 0 else { throw LoadSideError("fixture.socket", "Could not connect to the test server.") }
            handle = socketHandle
        } catch {
            try? socketHandle.close()
            throw error
        }
    }

    func read(maximumBytes: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        let count = Darwin.read(handle.fileDescriptor, &buffer, maximumBytes)
        guard count >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return Data(buffer.prefix(count))
    }
}
