import Foundation
import XCTest
@testable import LoadSideCore

final class ArchiveTests: XCTestCase {
    func testTarAndZipRoundTripPreservesSafeFrameworkSymlink() throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tar = root.appendingPathComponent("input.tar"), unpacked = root.appendingPathComponent("unpacked")
        try ArchiveFixtures.tar([.init(path: "Payload/Test.app/Versions/A/Code", data: Data("binary".utf8)), .init(path: "Payload/Test.app/Code", type: 50, link: "Versions/A/Code")]).write(to: tar)
        try Archive.extract(tar, to: unpacked)
        let zip = root.appendingPathComponent("output.ipa")
        try Archive.createIPA(from: unpacked, to: zip)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: zip.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let again = root.appendingPathComponent("again"); try Archive.extract(zip, to: again)
        XCTAssertEqual(try String(contentsOf: again.appendingPathComponent("Payload/Test.app/Code"), encoding: .utf8), "binary")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: again.appendingPathComponent("Payload/Test.app/Code").path), "Versions/A/Code")
    }
    func testTraversalAbsoluteHardlinkAndDeviceRejected() throws {
        for entry in [ArchiveFixtures.Entry(path: "../escape"), .init(path: "/tmp/escape"), .init(path: "a\\b"), .init(path: "hard", type: 49, link: "target"), .init(path: "device", type: 51), .init(path: "link", type: 50, link: "../../escape")] {
            let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let archive = root.appendingPathComponent("test.tar"); try ArchiveFixtures.tar([entry]).write(to: archive)
            XCTAssertThrowsError(try Archive.extract(archive, to: root.appendingPathComponent("out")), entry.path)
        }
    }
    func testLinkParentPivotAndDuplicatePathsRejected() throws {
        let cases: [[ArchiveFixtures.Entry]] = [
            [.init(path: "link", type: 50, link: "dir"), .init(path: "link/child", data: Data("x".utf8))],
            [.init(path: "same"), .init(path: "same")], [.init(path: "Name"), .init(path: "name")],
            [.init(path: "link", type: 50, link: "missing")]
        ]
        for entries in cases {
            let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let archive = root.appendingPathComponent("test.tar"); try ArchiveFixtures.tar(entries).write(to: archive)
            XCTAssertThrowsError(try Archive.extract(archive, to: root.appendingPathComponent("out")))
        }
    }
    func testExternalCompressionFormatsAreRejected() throws {
        for (name, header) in [("payload.lrz", "LRZI"), ("payload.grz", "GRZipII\0"), ("payload.lz", "LZIP")] {
            let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let archive = root.appendingPathComponent(name)
            try (Data(header.utf8) + Data(repeating: 0, count: 64)).write(to: archive)
            XCTAssertThrowsError(try Archive.extract(archive, to: root.appendingPathComponent("out")))
        }
    }
    func testLimitsAndNonEmptyDestination() throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("test.tar"); try ArchiveFixtures.tar([.init(path: "file", data: Data(repeating: 1, count: 100))]).write(to: archive)
        XCTAssertThrowsError(try Archive.extract(archive, to: root.appendingPathComponent("limited"), limits: .init(maximumFileBytes: 10)))
        XCTAssertThrowsError(try Archive.extract(archive, to: root))
    }

    func testUnreadableExportDirectoryFailsWithoutLeavingPartialArchive() throws {
        let fm = FileManager.default
        let root = try BinaryFixtures.temporaryDirectory()
        let source = root.appendingPathComponent("source")
        let blocked = source.appendingPathComponent("Payload/App.app/Resources")
        defer {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? fm.removeItem(at: root)
        }
        try fm.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("required resource".utf8).write(to: blocked.appendingPathComponent("asset"))
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        guard (try? fm.contentsOfDirectory(atPath: blocked.path)) == nil else {
            throw XCTSkip("This user can read directories despite restrictive permissions.")
        }

        let output = root.appendingPathComponent("output.ipa")
        XCTAssertThrowsError(try Archive.createIPA(from: source, to: output))
        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertThrowsError(try IPAExport.write(from: source, to: output))
        XCTAssertFalse(fm.fileExists(atPath: output.path))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".LoadSide-") })
    }
}

extension ArchiveTests {
    func testBuiltInGzipExtraction() async throws {
        let root = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let tar = root.appendingPathComponent("data.tar"), gzip = root.appendingPathComponent("data.tar.gz")
        try ArchiveFixtures.tar([.init(path: "file", data: Data("gzip fixture".utf8))]).write(to: tar)
        let compressed = try await ProcessRunner().run("/usr/bin/gzip", ["-c", tar.path])
        try compressed.stdout.write(to: gzip)
        let output = root.appendingPathComponent("output")
        try Archive.extract(gzip, to: output)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("file"), encoding: .utf8), "gzip fixture")
    }
}
