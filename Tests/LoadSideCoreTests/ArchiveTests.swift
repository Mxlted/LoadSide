import Foundation
import XCTest
@testable import LoadSideCore

struct ArchiveFixtures {
    struct Entry { let path: String; var data: Data = Data(); var type: UInt8 = 48; var link: String = "" }
    static func tar(_ entries: [Entry]) -> Data {
        var result = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            func field(_ string: String, _ offset: Int, _ width: Int) {
                for (index, byte) in string.utf8.prefix(width).enumerated() { header[offset + index] = byte }
            }
            field(entry.path, 0, 100); field("0000755", 100, 8); field("0000000", 108, 8); field("0000000", 116, 8)
            field(String(format: "%011o", entry.data.count), 124, 12); field("00000000000", 136, 12)
            field("        ", 148, 8); header[156] = entry.type; field(entry.link, 157, 100); field("ustar", 257, 6); field("00", 263, 2)
            field(String(format: "%06o", header.reduce(0) { $0 + Int($1) }) + "\0 ", 148, 8)
            result.append(contentsOf: header); result.append(entry.data)
            result.append(Data(repeating: 0, count: (512 - entry.data.count % 512) % 512))
        }
        result.append(Data(repeating: 0, count: 1024)); return result
    }
    static func deb(data: Data) -> Data {
        var result = Data("!<arch>\n".utf8)
        for (name, contents) in [("debian-binary", Data("2.0\n".utf8)), ("data.tar", data)] {
            func padded(_ value: String, _ width: Int) -> String { value + String(repeating: " ", count: width - value.count) }
            result.append(Data((padded(name + "/", 16) + padded("0", 12) + padded("0", 6) + padded("0", 6) + padded("100644", 8) + padded(String(contents.count), 10) + "`\n").utf8))
            result.append(contents); if contents.count % 2 != 0 { result.append(10) }
        }
        return result
    }
}

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
