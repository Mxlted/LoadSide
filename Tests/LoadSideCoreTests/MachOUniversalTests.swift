import Foundation
import XCTest
@testable import LoadSideCore

final class MachOUniversalTests: XCTestCase {
    func testInjectionUpdatesEveryUniversalSliceWithoutMovingCode() throws {
        let root = try BinaryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let slices = [BinaryFixtures.macho(subtype: 0), BinaryFixtures.macho(subtype: 2)]
        let offsets = [4096, 12288]
        var bytes = [UInt8](repeating: 0, count: offsets[1] + slices[1].count)
        func bigEndian(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
        }
        bigEndian(0xcafebabe, at: 0)
        bigEndian(2, at: 4)
        for index in 0..<2 {
            let entry = 8 + index * 20
            bigEndian(0x0100000c, at: entry)
            bigEndian(index == 0 ? 0 : 2, at: entry + 4)
            bigEndian(UInt32(offsets[index]), at: entry + 8)
            bigEndian(UInt32(slices[index].count), at: entry + 12)
            bigEndian(12, at: entry + 16)
            bytes.replaceSubrange(offsets[index]..<(offsets[index] + slices[index].count), with: slices[index])
        }
        let binary = root.appendingPathComponent("Universal")
        let original = Data(bytes)
        try original.write(to: binary)
        let loadPath = "@executable_path/Frameworks/UniversalTweak.dylib"
        try MachO.addDylib(path: loadPath, to: binary)
        let modified = try Data(contentsOf: binary)
        let parsed = try MachO.inspect(binary)
        XCTAssertEqual(parsed.slices.count, 2)
        XCTAssertTrue(parsed.slices.allSatisfy { $0.dependencies == [loadPath] })
        XCTAssertEqual(modified.count, original.count)
        XCTAssertEqual(modified.prefix(4096), original.prefix(4096))
        for offset in offsets {
            XCTAssertEqual(modified[(offset + 4096)..<(offset + 4112)], original[(offset + 4096)..<(offset + 4112)])
        }
    }
}
