import Foundation
import XCTest
@testable import LoadSideCore

struct BinaryFixtures {
    static func put32(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<4 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    static func put64(_ value: UInt64, at offset: Int, in bytes: inout [UInt8]) {
        for i in 0..<8 { bytes[offset + i] = UInt8(truncatingIfNeeded: value >> (i * 8)) }
    }
    static func dylibCommand(_ name: String, kind: UInt32 = 0xc) -> [UInt8] {
        let length = (24 + name.utf8.count + 1 + 7) / 8 * 8
        var result = [UInt8](repeating: 0, count: length)
        put32(kind, at: 0, in: &result); put32(UInt32(length), at: 4, in: &result); put32(24, at: 8, in: &result)
        result.replaceSubrange(24..<(24 + name.utf8.count), with: name.utf8)
        return result
    }
    static func macho(fileType: UInt32 = 2, dependency: String? = nil, encrypted: Bool = false, padding: Bool = true, subtype: UInt32 = 0) -> Data {
        var commands = [UInt8](repeating: 0, count: 152)
        put32(0x19, at: 0, in: &commands); put32(152, at: 4, in: &commands)
        commands.replaceSubrange(8..<14, with: "__TEXT".utf8)
        put32(1, at: 64, in: &commands)
        commands.replaceSubrange(72..<78, with: "__text".utf8)
        commands.replaceSubrange(88..<94, with: "__TEXT".utf8)
        put64(16, at: 112, in: &commands)
        var count: UInt32 = 1
        if let dependency { commands += dylibCommand(dependency); count += 1 }
        if fileType == 6 { commands += dylibCommand("/usr/lib/fixture.dylib", kind: 0xd); count += 1 }
        if encrypted {
            var command = [UInt8](repeating: 0, count: 24)
            put32(0x2c, at: 0, in: &command); put32(24, at: 4, in: &command); put32(1, at: 16, in: &command)
            commands += command; count += 1
        }
        let section = padding ? 4096 : 32 + commands.count
        put64(UInt64(section + 16), at: 48, in: &commands)
        put32(UInt32(section), at: 120, in: &commands)
        var bytes = [UInt8](repeating: 0, count: section + 16)
        put32(0xfeedfacf, at: 0, in: &bytes); put32(0x0100000c, at: 4, in: &bytes); put32(subtype, at: 8, in: &bytes)
        put32(fileType, at: 12, in: &bytes); put32(count, at: 16, in: &bytes); put32(UInt32(commands.count), at: 20, in: &bytes)
        bytes.replaceSubrange(32..<(32 + commands.count), with: commands)
        bytes.replaceSubrange(section..<(section + 16), with: repeatElement(UInt8(0xaa), count: 16))
        return Data(bytes)
    }
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loadside-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

final class MachOTests: XCTestCase {
    func testInspectAndDetectEncryption() throws {
        let info = try MachO.inspect(data: BinaryFixtures.macho(dependency: "/usr/lib/libSystem.B.dylib", encrypted: true))
        XCTAssertEqual(info.architectures, ["arm64"]); XCTAssertTrue(info.isEncrypted)
        XCTAssertEqual(info.slices.first?.dependencies, ["/usr/lib/libSystem.B.dylib"])
    }
    func testInjectionPreservesMachineCodeAndIsIdempotent() throws {
        let directory = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("App"), original = BinaryFixtures.macho()
        try original.write(to: binary)
        try MachO.addDylib(path: "@executable_path/Frameworks/Tweak.dylib", to: binary)
        try MachO.addDylib(path: "@executable_path/Frameworks/Tweak.dylib", to: binary)
        let result = try Data(contentsOf: binary)
        XCTAssertEqual(result.count, original.count); XCTAssertEqual(result[4096...], original[4096...])
        XCTAssertEqual(try MachO.inspect(binary).slices[0].dependencies, ["@executable_path/Frameworks/Tweak.dylib"])
    }
    func testRewriteLongerInstallNameUsesPadding() throws {
        let directory = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("Tweak.dylib")
        try BinaryFixtures.macho(fileType: 6, dependency: "/usr/lib/original.dylib").write(to: binary)
        try MachO.rewrite(binary, dependencies: ["/usr/lib/original.dylib": "@executable_path/Frameworks/Replacement.dylib"], installName: "@executable_path/Frameworks/Tweak.dylib")
        let info = try MachO.inspect(binary).slices[0]
        XCTAssertEqual(info.installName, "@executable_path/Frameworks/Tweak.dylib")
        XCTAssertEqual(info.dependencies, ["@executable_path/Frameworks/Replacement.dylib"])
    }
    func testNoPaddingFailsWithoutMutation() throws {
        let directory = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("App"), original = BinaryFixtures.macho(padding: false)
        try original.write(to: binary)
        XCTAssertThrowsError(try MachO.addDylib(path: "@executable_path/Tweak.dylib", to: binary))
        XCTAssertEqual(try Data(contentsOf: binary), original)
    }
    func testNonzeroPaddingIsNotOverwritten() throws {
        let directory = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("App")
        var bytes = Array(BinaryFixtures.macho()); bytes[190] = 0xff; try Data(bytes).write(to: binary)
        XCTAssertThrowsError(try MachO.addDylib(path: "test.dylib", to: binary))
    }
    func testBoundsAndInvalidCommandSizes() throws {
        for data in [Data(), Data([0xcf, 0xfa, 0xed, 0xfe]), Data(repeating: 0xff, count: 32)] { XCTAssertThrowsError(try MachO.inspect(data: data)) }
        for bad: UInt32 in [0, 7, 9, 0xfffffff8] {
            var bytes = Array(BinaryFixtures.macho()); BinaryFixtures.put32(bad, at: 36, in: &bytes)
            XCTAssertThrowsError(try MachO.inspect(data: Data(bytes)))
        }
        var bytes = Array(BinaryFixtures.macho()); BinaryFixtures.put64(UInt64.max, at: 80, in: &bytes)
        XCTAssertThrowsError(try MachO.inspect(data: Data(bytes)))
    }
    func testMalformedFatSliceIsRejected() {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<8, with: [0xca,0xfe,0xba,0xbe,0,0,0,1])
        bytes.replaceSubrange(16..<20, with: [0xff,0xff,0xff,0xf0]); bytes.replaceSubrange(20..<24, with: [0,0,0,32])
        XCTAssertThrowsError(try MachO.inspect(data: Data(bytes)))
    }
}

extension MachOTests {
    func testUniversalBinaryEditsEverySliceWithoutChangingSliceOffsets() throws {
        let first = BinaryFixtures.macho(subtype: 0), second = BinaryFixtures.macho(subtype: 2)
        var bytes = [UInt8](repeating: 0, count: 12_288 + second.count)
        func bigEndian(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((3 - index) * 8)) }
        }
        bigEndian(0xcafebabe, at: 0); bigEndian(2, at: 4)
        for (index, subtype, offset, length) in [(0, 0, 4_096, first.count), (1, 2, 12_288, second.count)] {
            let table = 8 + index * 20
            bigEndian(0x0100000c, at: table); bigEndian(UInt32(subtype), at: table + 4)
            bigEndian(UInt32(offset), at: table + 8); bigEndian(UInt32(length), at: table + 12); bigEndian(12, at: table + 16)
        }
        bytes.replaceSubrange(4_096..<(4_096 + first.count), with: first)
        bytes.replaceSubrange(12_288..<(12_288 + second.count), with: second)
        let directory = try BinaryFixtures.temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("Universal")
        try Data(bytes).write(to: binary)
        try MachO.addDylib(path: "@executable_path/Frameworks/Tweak.dylib", to: binary)
        let result = try MachO.inspect(binary)
        XCTAssertEqual(result.architectures, ["arm64", "arm64e"])
        XCTAssertTrue(result.slices.allSatisfy { $0.dependencies == ["@executable_path/Frameworks/Tweak.dylib"] })
        XCTAssertEqual(try Data(contentsOf: binary).prefix(48), Data(bytes).prefix(48))
    }
}
