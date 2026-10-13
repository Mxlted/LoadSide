import Foundation
import CryptoKit
import XCTest
@testable import LoadSideCore

final class LocalAppLibraryTests: XCTestCase {
    func testCopiesVerifiedExportPrivatelyAndRemovalPreservesOriginal() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try libraryResult(root), library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let app = try await library.add(result)
        let folder = library.directoryURL.appendingPathComponent(app.id.uuidString)
        XCTAssertEqual(app.bundleVersion, "42.1")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("app.ipa").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let fresh = LocalAppLibrary(directory: library.directoryURL)
        let catalog = try await fresh.library()
        XCTAssertEqual(catalog.apps, [app]); XCTAssertTrue(catalog.issues.isEmpty)
        let download = try await fresh.download(app.id)
        XCTAssertEqual(try download.handle.readToEnd(), try Data(contentsOf: result.output)); try download.handle.close()
        try await fresh.remove(app.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))
        let removed = try await fresh.library()
        XCTAssertTrue(removed.apps.isEmpty)
    }

    func testModifiedExportAndUnsignedResultsNeverEnterLibraryAndStagingIsCleaned() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try libraryResult(root), library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        try Data("changed".utf8).write(to: result.output)
        do { _ = try await library.add(result); XCTFail("Accepted a modified output") } catch {}
        let unsigned = SigningResult(output: result.output, bundleIdentifier: result.bundleIdentifier, displayName: "Unsigned",
            certificateName: "", teamIdentifier: "", signedCodeCount: 0, injectedLibraryCount: 1, warnings: [], sha256: result.sha256)
        do { _ = try await library.add(unsigned); XCTFail("Accepted an unsigned output") } catch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: library.directoryURL.path).isEmpty)
    }

    func testMissingVersionIsDownloadOnlyAndSymlinkSourcesAreRejected() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try libraryResult(root, version: nil), library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let app = try await library.add(result)
        XCTAssertFalse(app.supportsInstallation)
        let source = root.appendingPathComponent("source-copy")
        try FileManager.default.moveItem(at: result.output, to: source)
        try FileManager.default.createSymbolicLink(at: result.output, withDestinationURL: source)
        do { _ = try await library.add(result); XCTFail("Followed a source symlink") } catch {}
    }

    func testTamperedArchivesAndLinkedCatalogEntriesAreNeverServed() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let result = try libraryResult(root), library = LocalAppLibrary(directory: root.appendingPathComponent("apps"))
        let app = try await library.add(result), folder = library.directoryURL.appendingPathComponent(app.id.uuidString)
        let archive = folder.appendingPathComponent("app.ipa")
        try Data(repeating: 9, count: Int(app.byteCount)).write(to: archive)
        do { _ = try await library.download(app.id); XCTFail("Served tampered archive") } catch {}
        try FileManager.default.removeItem(at: archive)
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: result.output)
        do { _ = try await library.download(app.id); XCTFail("Followed library file symlink") } catch {}
        let catalog = try await library.library()
        XCTAssertTrue(catalog.apps.isEmpty); XCTAssertEqual(catalog.issues.count, 1)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: root)
        do { _ = try await library.download(app.id); XCTFail("Followed library folder symlink") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.output.path))
    }

    func testMalformedRecordIsReportedAndPreserved() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let library = LocalAppLibrary(directory: root.appendingPathComponent("apps")), result = try libraryResult(root)
        let app = try await library.add(result)
        let record = library.directoryURL.appendingPathComponent("\(app.id.uuidString)/manifest.json")
        try Data("{invalid".utf8).write(to: record)
        let catalog = try await library.library()
        XCTAssertTrue(catalog.apps.isEmpty); XCTAssertEqual(catalog.issues.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.path))
    }
}
