import Foundation
import XCTest

@testable import LoadSideCore

final class MachOTests: XCTestCase {
    func testInspectAndDetectEncryption() throws {
        let info = try MachO.inspect(data: BinaryFixtures.macho(dependency: "/usr/lib/libSystem.B.dylib", encrypted: true))
        XCTAssertEqual(info.architectures, ["arm64"])
        XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.slices.first?.dependencies, ["/usr/lib/libSystem.B.dylib"])
    }
    func testInjectionPreservesMachineCodeAndIsIdempotent() throws {
        let directory = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("App")
        let original = BinaryFixtures.macho()
        try original.write(to: binary)
        try MachO.addDylib(path: "@executable_path/Frameworks/Tweak.dylib", to: binary)
        try MachO.addDylib(path: "@executable_path/Frameworks/Tweak.dylib", to: binary)
        let result = try Data(contentsOf: binary)
        XCTAssertEqual(result.count, original.count)
        XCTAssertEqual(result[4096...], original[4096...])
        XCTAssertEqual(try MachO.inspect(binary).slices[0].dependencies, ["@executable_path/Frameworks/Tweak.dylib"])
    }
    func testRewriteLongerInstallNameUsesPadding() throws {
        let directory = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("Tweak.dylib")
        try BinaryFixtures.macho(fileType: 6, dependency: "/usr/lib/original.dylib").write(to: binary)
        try MachO.rewrite(
            binary, dependencies: ["/usr/lib/original.dylib": "@executable_path/Frameworks/Replacement.dylib"],
            installName: "@executable_path/Frameworks/Tweak.dylib")
        let info = try MachO.inspect(binary).slices[0]
        XCTAssertEqual(info.installName, "@executable_path/Frameworks/Tweak.dylib")
        XCTAssertEqual(info.dependencies, ["@executable_path/Frameworks/Replacement.dylib"])
    }
    func testNoPaddingFailsWithoutMutation() throws {
        let directory = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("App")
        let original = BinaryFixtures.macho(padding: false)
        try original.write(to: binary)
        XCTAssertThrowsError(try MachO.addDylib(path: "@executable_path/Tweak.dylib", to: binary))
        XCTAssertEqual(try Data(contentsOf: binary), original)
    }
    func testNonzeroPaddingIsNotOverwritten() throws {
        let directory = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("App")
        var bytes = Array(BinaryFixtures.macho())
        bytes[190] = 0xff
        try Data(bytes).write(to: binary)
        XCTAssertThrowsError(try MachO.addDylib(path: "test.dylib", to: binary))
    }
    func testBoundsAndInvalidCommandSizes() throws {
        for data in [Data(), Data([0xcf, 0xfa, 0xed, 0xfe]), Data(repeating: 0xff, count: 32)] {
            XCTAssertThrowsError(try MachO.inspect(data: data))
        }
        for bad: UInt32 in [0, 7, 9, 0xfffffff8] {
            var bytes = Array(BinaryFixtures.macho())
            BinaryFixtures.put32(bad, at: 36, in: &bytes)
            XCTAssertThrowsError(try MachO.inspect(data: Data(bytes)))
        }
        var bytes = Array(BinaryFixtures.macho())
        BinaryFixtures.put64(UInt64.max, at: 80, in: &bytes)
        XCTAssertThrowsError(try MachO.inspect(data: Data(bytes)))
    }
    func testMalformedFatSliceIsRejected() {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<8, with: [0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1])
        bytes.replaceSubrange(16..<20, with: [0xff, 0xff, 0xff, 0xf0])
        bytes.replaceSubrange(20..<24, with: [0, 0, 0, 32])
        XCTAssertThrowsError(try MachO.inspect(data: Data(bytes)))
    }
}

extension MachOTests {
    func testUniversalBinaryEditsEverySliceWithoutChangingSliceOffsets() throws {
        let first = BinaryFixtures.macho(subtype: 0)
        let second = BinaryFixtures.macho(subtype: 2)
        var bytes = [UInt8](repeating: 0, count: 12_288 + second.count)
        func bigEndian(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((3 - index) * 8)) }
        }
        bigEndian(0xcafebabe, at: 0)
        bigEndian(2, at: 4)
        for (index, subtype, offset, length) in [(0, 0, 4_096, first.count), (1, 2, 12_288, second.count)] {
            let table = 8 + index * 20
            bigEndian(0x0100000c, at: table)
            bigEndian(UInt32(subtype), at: table + 4)
            bigEndian(UInt32(offset), at: table + 8)
            bigEndian(UInt32(length), at: table + 12)
            bigEndian(12, at: table + 16)
        }
        bytes.replaceSubrange(4_096..<(4_096 + first.count), with: first)
        bytes.replaceSubrange(12_288..<(12_288 + second.count), with: second)
        let directory = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("Universal")
        try Data(bytes).write(to: binary)
        try MachO.addDylib(path: "@executable_path/Frameworks/Tweak.dylib", to: binary)
        let result = try MachO.inspect(binary)
        XCTAssertEqual(result.architectures, ["arm64", "arm64e"])
        XCTAssertTrue(result.slices.allSatisfy { $0.dependencies == ["@executable_path/Frameworks/Tweak.dylib"] })
        XCTAssertEqual(try Data(contentsOf: binary).prefix(48), Data(bytes).prefix(48))
    }
}
